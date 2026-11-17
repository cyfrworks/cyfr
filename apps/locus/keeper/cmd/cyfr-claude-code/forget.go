// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
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

// transcripts are the session's transcript files and its folders, found
// by its id in every project; a session id is a uuid, so it names no
// other path.
func transcripts(home, session string) (files, folders []string) {
	if !isUUID(session) {
		return nil, nil
	}
	projects := filepath.Join(configDir(home), "projects")
	matches, _ := filepath.Glob(filepath.Join(projects, "*", session+".jsonl"))
	for _, match := range matches {
		if info, err := os.Lstat(match); err == nil && info.Mode().IsRegular() {
			files = append(files, match)
		}
	}
	matches, _ = filepath.Glob(filepath.Join(projects, "*", session))
	matches = append(matches, filepath.Join(configDir(home), "session-env", session))
	for _, match := range matches {
		if info, err := os.Lstat(match); err == nil && info.IsDir() {
			folders = append(folders, match)
		}
	}
	sort.Strings(files)
	sort.Strings(folders)
	return files, folders
}

// forget removes the transcript of `session` from the folder, and nothing
// else: another session's, and the sign-in, stay. A session the harness
// runs now is not removed.
func (d *driver) forget(id, session string) error {
	if !isUUID(session) {
		return d.refuse(id, "That names no session of Claude Code's.")
	}
	if d.h != nil && !d.h.expected && (d.session == session || (d.starting != nil && d.starting.session == session)) {
		return d.refuse(id, "That session runs now; it is closed before it is forgotten.")
	}
	files, folders := transcripts(d.home, session)
	for _, file := range files {
		if err := os.Remove(file); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return d.refuse(id, "The session's transcript could not be removed from the folder.")
		}
	}
	for _, folder := range folders {
		if err := os.RemoveAll(folder); err != nil {
			return d.refuse(id, "The session's folder could not be removed from the folder.")
		}
	}
	return d.emit(newEvent("forgot").set("id", id).set("session", session))
}

// heldPosts are the posts of `pending` whose lines the session's
// transcript holds: a user line under the uuid derived from each post's
// id. The transcript is the program's, so what it says is its word.
func heldPosts(home, session string, pending []string) []string {
	want := map[string]string{}
	for _, id := range pending {
		want[postUUID(id)] = id
	}
	found := map[string]bool{}
	files, _ := transcripts(home, session)
	for _, file := range files {
		readTranscript(file, func(entry transcriptEntry) {
			if id, ok := want[entry.UUID]; ok && entry.Type == "user" {
				found[id] = true
			}
		})
	}
	held := []string{}
	for _, id := range pending {
		if found[id] && len(held) < maxList {
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
	reader := newLineReader(file, maxHarnessLineBytes)
	for {
		line, err := reader.next()
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
