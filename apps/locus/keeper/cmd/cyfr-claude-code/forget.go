// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"

	"github.com/cyfr/locus/keeper/internal/brainwire"
)

// A native session's transcript, as Claude Code keeps it in the folder:
// `<config>/projects/<the working folder, encoded>/<session>.jsonl`, and
// beside it a folder of the session's own (its subagents and kept tool
// results) named by the session, and the session's environment folder
// `<config>/session-env/<session>` (Claude Code 2.1.323 made one for each
// session, empty in the probe). `<config>` is CLAUDE_CONFIG_DIR, or
// `.claude` in the home. The working folder's encoding is the harness's,
// so a session is found in whichever project holds it.
//
// Plan mode writes a plan file of the session's own text without asking:
// `<plans>/<slug>.md`, and a subagent's `<slug>-agent-<id>.md` beside it,
// where `<slug>` is the session's, which every entry of its transcript
// names (`slug`), and `<plans>` is `<config>/plans` or the folder the
// project's settings name, which the transcript's plan-mode reminders
// name with the file (`attachment.planFilePath`) (Claude Code 2.1.323).

// configDir is where the harness keeps its sessions and its sign-in.
func configDir(home string) string {
	if dir := os.Getenv("CLAUDE_CONFIG_DIR"); dir != "" {
		return dir
	}
	return filepath.Join(home, ".claude")
}

// transcripts are the paths of the session's own in the folder: its
// transcript and its folder in each project, and its environment folder,
// whatever is there under those names; a session id is a uuid, so it
// names no other path. Beside what it found it answers each folder or
// entry it could not inspect: one is never an absence, since what cannot
// be looked at may hold the transcript, and it takes nothing from what
// the other inspections found.
func transcripts(home, session string) (found []string, failed []error) {
	if !brainwire.IsUUID(session) {
		return nil, nil
	}
	projects := filepath.Join(configDir(home), "projects")
	entries, err := os.ReadDir(projects)
	if err != nil && !brainwire.Absent(err) {
		failed = append(failed, err)
	}
	names := []string{filepath.Join(configDir(home), "session-env", session)}
	for _, entry := range entries {
		project := filepath.Join(projects, entry.Name())
		names = append(names, filepath.Join(project, session+".jsonl"), filepath.Join(project, session))
	}
	for _, name := range names {
		if _, err := os.Lstat(name); err == nil {
			found = append(found, name)
		} else if !brainwire.Absent(err) {
			failed = append(failed, err)
		}
	}
	sort.Strings(found)
	return found, failed
}

// sessionTranscripts are the transcripts among the session's paths
// `found`: each `.jsonl` file, the session's own and its helpers' (in the
// session's folder, `subagents/`), with each part of a folder that could
// not be walked. Only a regular file or a folder is the session's own: a
// link, or anything else, among the paths or under them, stands for what
// cannot be inspected as the session's, and is answered as a failure. The
// walk follows no link, the session's top-level transcript included.
func sessionTranscripts(found []string) (files []string, failed []error) {
	for _, path := range found {
		err := filepath.WalkDir(path, func(name string, entry fs.DirEntry, err error) error {
			if err != nil {
				failed = append(failed, err)
				return nil
			}
			if !entry.IsDir() && !entry.Type().IsRegular() {
				failed = append(failed, fmt.Errorf("%s: neither a file nor a folder", name))
				return nil
			}
			if !entry.IsDir() && filepath.Ext(name) == ".jsonl" {
				files = append(files, name)
			}
			return nil
		})
		if err != nil {
			failed = append(failed, err)
		}
	}
	return files, failed
}

// planFiles are the plan files of the session whose paths are `found`: in
// each plans folder, the files named by a slug its transcripts or its
// helpers' name. Beside them it answers each transcript, line or folder it
// could not read: a plan file is tied to its session only by the
// transcripts, so a line, an attachment or a planFilePath that does not
// read may name a slug or a folder, and a folder past inspection may hold
// the file.
func planFiles(home string, found []string) (plans []string, failed []error) {
	slugs := map[string]bool{}
	folders := map[string]bool{filepath.Join(configDir(home), "plans"): true}
	files, failed := sessionTranscripts(found)
	for _, file := range files {
		err := readTranscript(file, func(entry transcriptEntry) {
			if len(entry.Slug) > 0 {
				if slug, ok := jsonString(entry.Slug); !ok {
					failed = append(failed, fmt.Errorf("%s: a slug that is no string", file))
				} else if slug != "" {
					slugs[slug] = true
				}
			}
			// A record of type attachment carries an object; one that
			// carries none, or null, may have named a plans folder.
			if entry.Type == "attachment" && (len(entry.Attachment) == 0 || entry.Attachment[0] != '{') {
				failed = append(failed, fmt.Errorf("%s: an attachment record with no attachment", file))
				return
			}
			if len(entry.Attachment) == 0 || string(entry.Attachment) == "null" {
				return
			}
			var attachment map[string]json.RawMessage
			if err := json.Unmarshal(entry.Attachment, &attachment); err != nil {
				failed = append(failed, fmt.Errorf("%s: an attachment that does not read", file))
			} else if raw, ok := attachment["planFilePath"]; !ok {
				return
			} else if path, ok := jsonString(raw); !ok {
				failed = append(failed, fmt.Errorf("%s: a planFilePath that is no string", file))
			} else if path != "" {
				folders[filepath.Dir(path)] = true
			}
		})
		if err != nil {
			failed = append(failed, err)
		}
	}
	if len(slugs) == 0 {
		return nil, failed
	}
	for folder := range folders {
		entries, err := os.ReadDir(folder)
		if err != nil {
			if !brainwire.Absent(err) {
				failed = append(failed, err)
			}
			continue
		}
		for _, entry := range entries {
			name := entry.Name()
			for slug := range slugs {
				if name == slug+".md" || (strings.HasPrefix(name, slug+"-agent-") && strings.HasSuffix(name, ".md")) {
					// A plan file the slug names that is a link, or no
					// file, is not one whose removal removes its text.
					if !entry.Type().IsRegular() {
						failed = append(failed, fmt.Errorf("%s: a plan that is no file", filepath.Join(folder, name)))
						continue
					}
					plans = append(plans, filepath.Join(folder, name))
				}
			}
		}
	}
	sort.Strings(plans)
	return plans, failed
}

// forget removes the transcript of `session` from the folder, and its plan
// files, and nothing else: another session's, and the sign-in, stay. A
// session the harness runs now is not removed. The plan files go first,
// so that a removal cut short leaves the transcript that ties them to the
// session for the next forget. `forgot` says the session's paths are
// gone, each removed or proved absent, looked at again after the removal;
// a folder or an entry that cannot be inspected or removed is `refused`,
// with its reason.
func (d *driver) forget(id, session string) error {
	if !brainwire.IsUUID(session) {
		return d.c.Refuse(id, "That names no session of Claude Code's.")
	}
	if d.h != nil && !d.h.Expected && (d.session == session || (d.starting != nil && d.starting.session == session)) {
		return d.c.Refuse(id, "That session runs now; it is closed before it is forgotten.")
	}
	found, failed := transcripts(d.home, session)
	if len(failed) > 0 {
		return d.c.Refuse(id, "The folder could not be read to find the session's transcript, so it may still be there.")
	}
	plans, failed := planFiles(d.home, found)
	if len(failed) > 0 {
		return d.c.Refuse(id, "The session's plan file could not be looked for, so it may still be there.")
	}
	for _, name := range plans {
		if err := os.Remove(name); err != nil && !brainwire.Absent(err) {
			return d.c.Refuse(id, "The session's plan file could not be removed from the folder.")
		}
	}
	for _, name := range plans {
		if _, err := os.Lstat(name); !brainwire.Absent(err) {
			return d.c.Refuse(id, "The session's plan file is still in the folder after its removal.")
		}
	}
	for _, name := range found {
		if err := os.RemoveAll(name); err != nil {
			return d.c.Refuse(id, "The session's transcript could not be removed from the folder.")
		}
	}
	if left, failed := transcripts(d.home, session); len(failed) > 0 || len(left) > 0 {
		return d.c.Refuse(id, "The session's transcript is still in the folder after its removal.")
	}
	return d.c.Emit(brainwire.NewEvent("forgot").Set("id", id).Set("session", session))
}

// heldPosts are the posts of `pending` whose lines the session's
// transcript holds: a user line under the uuid derived from each post's
// id. The transcript is the program's, so what it says is its word. A
// post it leaves out is not established, never proved absent: a
// transcript, or a project folder that may hold one, can be past
// inspection, and what the other inspections found is kept all the same.
func heldPosts(home, session string, pending []string) []string {
	want := map[string]string{}
	for _, id := range pending {
		want[brainwire.PostUUID(id)] = id
	}
	found := map[string]bool{}
	names, _ := transcripts(home, session)
	for _, file := range names {
		if filepath.Ext(file) != ".jsonl" {
			continue
		}
		readTranscript(file, func(entry transcriptEntry) {
			if id, ok := want[entry.UUID]; ok && entry.Type == "user" {
				found[id] = true
			}
		})
	}
	held := []string{}
	for _, id := range pending {
		if found[id] && len(held) < brainwire.MaxList {
			held = append(held, id)
		}
	}
	return held
}

type transcriptEntry struct {
	Type       string          `json:"type"`
	UUID       string          `json:"uuid"`
	Slug       json.RawMessage `json:"slug"`
	Attachment json.RawMessage `json:"attachment"`
}

// jsonString is the string `raw` holds, or false for any other value,
// null included.
func jsonString(raw json.RawMessage) (string, bool) {
	var s string
	if len(raw) == 0 || raw[0] != '"' || json.Unmarshal(raw, &s) != nil {
		return "", false
	}
	return s, true
}

// readTranscript gives each entry of the transcript at `path` to `each`
// and answers what kept it from reading the whole: a line that is no
// entry, which is skipped and the rest read, a read that failed, or a line
// past every bound the harness keeps to, after which the rest is not read.
// A blank line is none of these; an entry is an object, so a line of null
// or any other value is no entry. A link is not opened.
func readTranscript(path string, each func(transcriptEntry)) error {
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return err
	}
	defer file.Close()
	reader := brainwire.NewLineReader(file, brainwire.MaxHarnessLineBytes)
	var unread error
	for {
		line, err := reader.Next()
		if trimmed := bytes.TrimSpace(line); len(trimmed) > 0 {
			var entry transcriptEntry
			if trimmed[0] == '{' && json.Unmarshal(trimmed, &entry) == nil {
				each(entry)
			} else if unread == nil {
				unread = fmt.Errorf("%s: a line that is no entry", path)
			}
		}
		if errors.Is(err, io.EOF) {
			return unread
		}
		if err != nil {
			return err
		}
	}
}
