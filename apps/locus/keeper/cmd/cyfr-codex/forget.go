// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/cyfr/locus/keeper/internal/brainwire"
)

// A native session is a Codex thread, as Codex keeps it in the folder:
// `<codex>/sessions/<year>/<month>/<day>/rollout-<time>-<thread>.jsonl`
// (or under `archived_sessions/` once archived), its rows in Codex's own
// databases beside it, which hold its first message and its items, and
// its shell snapshots, `<codex>/shell_snapshots/<thread>.<n>.sh`, which
// hold the environment its commands ran in. The driver keeps one record
// of its own beside them, the thread's instructions' digest
// (instructions.go). `<codex>` is CODEX_HOME, or `.codex` in the home.
// Codex's own `thread/delete` removes the rollout and the rows (0.169.0);
// the snapshots and the record it leaves, and the driver removes them.
//
// A sub-agent's thread is a thread of its own, with its own rollout and
// snapshots, and the driver looks for the named thread's files alone.
// Whether `thread/delete` removes a sub-agent's thread with its parent's is
// not established for 0.169.0: no run of Codex itself here started a
// sub-agent, and the app-server's own document does not say. The driver
// neither removes nor verifies a sub-agent's thread's shell snapshots, so
// they may remain; what else of that thread survives, its rollout and its
// rows, depends on Codex's own deletion.

// oneOffWait bounds a one-off app-server's answer: a first start fetches
// the program.
const oneOffWait = 150 * time.Second

// codexHome is where Codex keeps its threads and its sign-in.
func codexHome(home string) string {
	if dir := os.Getenv("CODEX_HOME"); dir != "" {
		return dir
	}
	return filepath.Join(home, ".codex")
}

// threadFiles are the thread's own files in the folder: its rollouts, its
// shell snapshots and the record of its instructions, whatever is there
// under those names; a thread id is a uuid, so it names no other thread's. Beside what it found it answers
// each folder or entry it could not inspect: one is never an absence,
// since what cannot be looked at may hold the transcript, and it takes
// nothing from what the other inspections found.
func threadFiles(home, thread string) (found []string, failed []error) {
	if !brainwire.IsUUID(thread) {
		return nil, nil
	}
	codex := codexHome(home)
	for _, root := range []string{filepath.Join(codex, "sessions"), filepath.Join(codex, "archived_sessions")} {
		err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				if path == root && brainwire.Absent(err) {
					return nil
				}
				failed = append(failed, err)
				if entry != nil && entry.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
			if !entry.IsDir() && strings.HasSuffix(entry.Name(), "-"+thread+".jsonl") {
				found = append(found, path)
			}
			return nil
		})
		if err != nil {
			failed = append(failed, err)
		}
	}
	snapshots := filepath.Join(codex, "shell_snapshots")
	entries, err := os.ReadDir(snapshots)
	if err != nil && !brainwire.Absent(err) {
		failed = append(failed, err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), thread+".") {
			found = append(found, filepath.Join(snapshots, entry.Name()))
		}
	}
	if record, err := instructionsRecord(home, thread); err != nil {
		failed = append(failed, err)
	} else if record != "" {
		found = append(found, record)
	}
	sort.Strings(found)
	return found, failed
}

// forget removes the thread `session` from the folder, and nothing else:
// another thread, and the sign-in, stay. The thread Codex runs now is not
// removed: Codex would end it. Codex removes the thread itself
// (`thread/delete`, in an app-server of the forget's own), its rollout and
// its rows, or answers that it holds no rollout of it; the driver removes
// what Codex leaves of it, and `forgot` says the thread's files are gone,
// each removed or proved absent, looked at again after the removal. A
// removal Codex refuses, and a folder or an entry that cannot be inspected
// or removed, are `refused`, with the reason. While a session runs, the
// forget's app-server runs beside the session's own on the same folder:
// the stand-in's tests run that order, but Codex itself has not been run
// so, and against it that order is unproved.
func (d *driver) forget(id, session string) error {
	if !brainwire.IsUUID(session) {
		return d.c.Refuse(id, "That names no thread of Codex's.")
	}
	if d.h != nil && (d.session == session || (d.starting != nil && d.starting.session == session)) {
		return d.c.Refuse(id, "That session runs now; it is closed before it is forgotten.")
	}
	o, err := d.openOneOff()
	if err != nil {
		return d.c.Refuse(id, "OpenAI Codex could not be asked to remove the session's thread: "+err.Error()+".")
	}
	answer, err := o.call(func(rid string) []byte { return request(rid, "thread/delete", map[string]any{"threadId": session}) })
	o.close()
	switch {
	case err != nil:
		return d.c.Refuse(id, "OpenAI Codex did not answer the removal of the session's thread: "+err.Error()+".")
	case answer.Error != nil && !strings.HasPrefix(answer.Error.Message, noRolloutWords):
		return d.c.Refuse(id, "OpenAI Codex could not remove the session's thread, so it may still be there.")
	}
	found, failed := threadFiles(d.home, session)
	if len(failed) > 0 {
		return d.c.Refuse(id, "The folder could not be read to find the session's thread, so it may still be there.")
	}
	for _, name := range found {
		if err := os.RemoveAll(name); err != nil {
			return d.c.Refuse(id, "The session's thread could not be removed from the folder.")
		}
	}
	if left, failed := threadFiles(d.home, session); len(failed) > 0 || len(left) > 0 {
		return d.c.Refuse(id, "The session's thread is still in the folder after its removal.")
	}
	return d.c.Emit(brainwire.NewEvent("forgot").Set("id", id).Set("session", session))
}

// heldPosts are the posts of `pending` the thread's rollout holds: a user
// message Codex recorded under the uuid derived from each post's id (its
// `clientUserMessageId`, which the rollout keeps as an item's
// `client_id`). The rollout is the program's, so what it says is its
// word. A post it leaves out is not established, never proved absent: a
// rollout, or a folder that may hold one, can be past inspection, and what
// the other inspections found is kept all the same. Codex records a post
// once its turn takes it in, which `accepted` does not wait for: a post
// Codex accepted and then lost with its process may be held or not.
func heldPosts(home, thread string, pending []string) ([]string, []error) {
	want := map[string]string{}
	for _, id := range pending {
		want[brainwire.PostUUID(id)] = id
	}
	found := map[string]bool{}
	names, failed := threadFiles(home, thread)
	for _, file := range names {
		if filepath.Ext(file) != ".jsonl" {
			continue
		}
		if err := readRollout(file, func(entry rolloutEntry) {
			if id, ok := want[entry.Payload.Item.ClientID]; ok && entry.Type == "event_msg" &&
				entry.Payload.Type == "item_completed" && entry.Payload.Item.Type == "UserMessage" {
				found[id] = true
			}
		}); err != nil {
			failed = append(failed, err)
		}
	}
	held := []string{}
	for _, id := range pending {
		if found[id] && len(held) < brainwire.MaxList {
			held = append(held, id)
		}
	}
	return held, failed
}

type rolloutEntry struct {
	Type    string `json:"type"`
	Payload struct {
		Type string `json:"type"`
		Item struct {
			Type     string `json:"type"`
			ClientID string `json:"client_id"`
		} `json:"item"`
	} `json:"payload"`
}

func readRollout(path string, each func(rolloutEntry)) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	reader := brainwire.NewLineReader(file, brainwire.MaxHarnessLineBytes)
	for {
		line, err := reader.Next()
		var entry rolloutEntry
		if line != nil && json.Unmarshal(line, &entry) == nil {
			each(entry)
		}
		// The end, or a line past every bound Codex keeps to: the rest is
		// not read. A read that fails is a rollout past inspection.
		if errors.Is(err, io.EOF) || errors.Is(err, brainwire.ErrLineTooLong) {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

// oneOff is an app-server of a command's own, started for one request and
// closed after: a removal or a listing when no session runs. Its errors are
// the driver's own sentences, never Codex's or the system's words, since a
// refusal carries them to the wire.
type oneOff struct {
	p        *brainwire.Process
	n        int
	deadline <-chan time.Time
}

func (d *driver) openOneOff() (*oneOff, error) {
	p, err := d.c.Spawn(append(append([]string{}, d.harnessCommand...), appServer))
	if err != nil {
		return nil, err
	}
	o := &oneOff{p: p, deadline: time.After(oneOffWait)}
	answer, err := o.call(initializeLine)
	if err == nil && answer.Error != nil {
		err = errors.New("it refused to start")
	}
	if err == nil && o.p.Write(initializedLine()) != nil {
		err = errors.New("it ended before it was asked")
	}
	if err != nil {
		o.close()
		return nil, err
	}
	return o, nil
}

// call writes the request `build` makes and reads to its answer; the
// requests of Codex's meanwhile are answered as a session's are, and its
// notifications are no one's.
func (o *oneOff) call(build func(id string) []byte) (rpc, error) {
	o.n++
	id := fmt.Sprintf("cyfr-once-%d", o.n)
	if err := o.p.Write(build(id)); err != nil {
		return rpc{}, errors.New("it ended before it was asked")
	}
	for {
		select {
		case line := <-o.p.Lines:
			if line == nil {
				return rpc{}, errors.New("it wrote a line past its bound")
			}
			var m rpc
			if json.Unmarshal(line, &m) != nil {
				continue
			}
			var got string
			_ = json.Unmarshal(m.ID, &got)
			switch {
			case m.Method == "" && got == id:
				return m, nil
			case m.Method == "currentTime/read" && len(m.ID) > 0:
				answer, _ := allowed(m.Method, m.Params, time.Now().Unix())
				o.p.WriteUnchecked(answerLine(m.ID, answer))
			case m.Method != "" && len(m.ID) > 0:
				// No session runs in it, so it asks for nothing CYFR answers.
				o.p.WriteUnchecked(refuseLine(m.ID, m.Method))
			}
		case <-o.p.Done:
			return rpc{}, errors.New("it ended before it answered")
		case <-o.deadline:
			return rpc{}, errors.New("it did not answer in time")
		}
	}
}

func (o *oneOff) close() { o.p.Stop() }

// listOnce is Codex's model listing, every page of it up to listingPages,
// read once Codex's account read says it has a sign-in (`signedOut`),
// from an app-server of its own.
func (d *driver) listOnce() ([]json.RawMessage, string, error) {
	o, err := d.openOneOff()
	if err != nil {
		return nil, "", err
	}
	defer o.close()
	read, err := o.call(func(id string) []byte { return request(id, "account/read", map[string]any{}) })
	if err != nil {
		return nil, "", err
	}
	if read.Error != nil {
		return nil, "", errors.New("its account could not be read")
	}
	account := accountOf(read)
	if account == brainwire.SignedOut {
		return nil, account, nil
	}
	var listing []json.RawMessage
	cursor := ""
	for pages := 0; pages < listingPages; pages++ {
		params := map[string]any{}
		if cursor != "" {
			params["cursor"] = cursor
		}
		answer, err := o.call(func(id string) []byte { return request(id, "model/list", params) })
		if err != nil {
			return nil, "", err
		}
		var page struct {
			Data       []json.RawMessage `json:"data"`
			NextCursor *string           `json:"nextCursor"`
		}
		if answer.Error != nil || json.Unmarshal(answer.Result, &page) != nil {
			return nil, "", errors.New("it refused to list them")
		}
		listing = append(listing, page.Data...)
		if page.NextCursor == nil || *page.NextCursor == "" {
			break
		}
		cursor = *page.NextCursor
	}
	return listing, account, nil
}
