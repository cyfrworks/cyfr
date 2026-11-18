// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"

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

// forget removes the transcript of `session` from the folder, and nothing
// else: another session's, and the sign-in, stay. A session the harness
// runs now is not removed. `forgot` says the session's paths are gone,
// each removed or proved absent, looked at again after the removal; a
// folder or an entry that cannot be inspected or removed is `refused`,
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
	Type string `json:"type"`
	UUID string `json:"uuid"`
}

func readTranscript(path string, each func(transcriptEntry)) {
	file, err := os.Open(path)
	if err != nil {
		return
	}
	defer file.Close()
	reader := brainwire.NewLineReader(file, brainwire.MaxHarnessLineBytes)
	for {
		line, err := reader.Next()
		var entry transcriptEntry
		if line != nil && json.Unmarshal(line, &entry) == nil {
			each(entry)
		}
		// The end, a read that fails, or a line past every bound the
		// harness keeps to: the rest is not read.
		if err != nil {
			return
		}
	}
}
