// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/cyfr/locus/keeper/internal/brainwire"
	"github.com/cyfr/locus/keeper/internal/homepath"
)

// A listing when no session runs is a session of the driver's own, made in
// an empty folder of this process's own (`<home>/.cache/cyfr-acp/listing/<boot>`)
// with no server, read for its config options, closed, and forgotten.
// Listings of one home may run at once, each in a session of the backends
// service with its own process numbering, so a listing is known live only
// by the kernel's lock: each holds an exclusive flock on its own record,
// `<home>/.cache/cyfr-acp/listings/<boot>`, for its whole life, the record
// naming its session once the program answered it. The record is opened
// close-on-exec (as Go opens every file), so the program never holds the
// lock, and the kernel releases it when its holder ends. A later listing
// removes another's session and record only under that record's lock,
// taken without waiting: a record whose lock is held is a live listing's,
// and is left alone.

// listingRecords is the folder of the listings' records, one a listing,
// and listingFolders that of their working folders.
const (
	listingRecords = driverFolder + "/listings"
	listingFolders = driverFolder + "/listing"
)

var errListingLinked = errors.New("a folder of the driver's own on the way to its listing is a link or no folder of this user's own, which CYFR does not follow")

// reached is the driver's words for a way down its own folder that failed.
func reached(err error, what string) error {
	if homepath.Refused(err) {
		return errListingLinked
	}
	return errors.New(what)
}

// oneOff is a program of a command's own, started for a few requests and
// stopped after. Its errors are the driver's own sentences, never the
// program's or the system's words, since a refusal carries them to the
// wire.
type oneOff struct {
	p        *brainwire.Process
	n        int
	deadline <-chan time.Time
}

func (d *driver) openOneOff() (*oneOff, error) {
	p, err := d.c.Spawn(append(append([]string{}, d.harnessCommand...), d.p.args...))
	if err != nil {
		return nil, err
	}
	o := &oneOff{p: p, deadline: time.After(d.answerWait)}
	answer, err := o.call("initialize", initializeParams())
	if err == nil {
		var init initialized
		var caps agentCapabilities
		switch {
		case answer.Error != nil || json.Unmarshal(answer.Result, &init) != nil:
			err = errors.New("it refused to start")
		case json.Unmarshal(init.Capabilities, &caps) != nil || qualify(d.p, init, caps) != "":
			err = errors.New("it is no version CYFR drives")
		}
	}
	if err != nil {
		o.close()
		return nil, err
	}
	return o, nil
}

// call writes one request and reads to its answer; the program's requests
// meanwhile are answered as a session's are, and its notifications are no
// one's.
func (o *oneOff) call(method string, params any) (rpc, error) {
	o.n++
	if err := o.p.Write(request(o.n, method, params)); err != nil {
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
			switch {
			case m.Method == "" && idKey(m.ID) == strconv.Itoa(o.n):
				return m, nil
			case m.Method == "session/request_permission" && len(m.ID) > 0:
				o.p.WriteUnchecked(answerLine(m.ID, allowOption(m.Params)))
			case m.Method != "" && len(m.ID) > 0:
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

// listing is what a listing session offered: its answer, and each model's
// efforts where the profile reads them by selecting the model.
type listing struct {
	answer  sessionAnswer
	efforts map[string][]string
}

// listOnce makes a listing session and answers what it offers, or says the
// program is signed out, the one shape its profile names.
func (d *driver) listOnce() (listing, string, error) {
	records, err := homepath.Walk(d.home, listingRecords, true)
	if err != nil {
		return listing{}, "", reached(err, "its listing records could not be reached")
	}
	defer records.Close()
	if err := d.forgetInterrupted(records); err != nil {
		return listing{}, "", err
	}
	record, err := holdRecord(records, d.c.Boot)
	if err != nil {
		return listing{}, "", reached(err, "its listing record could not be made")
	}
	// Removed while its lock is held, then released, unless its session
	// could not be removed, which a later listing removes by it.
	keep := false
	defer func() {
		if !keep {
			_ = records.Remove(d.c.Boot)
		}
		record.Close()
	}()
	folders, err := homepath.Walk(d.home, listingFolders, true)
	if err != nil {
		return listing{}, "", reached(err, "its listing folder could not be made")
	}
	defer folders.Close()
	if folders.RemoveAll(d.c.Boot) != nil {
		return listing{}, "", errors.New("its listing folder could not be made")
	}
	folder, err := folders.Folder(d.c.Boot, true)
	if err != nil {
		return listing{}, "", reached(err, "its listing folder could not be made")
	}
	folder.Close()
	defer folders.RemoveAll(d.c.Boot)
	o, err := d.openOneOff()
	if err != nil {
		return listing{}, "", err
	}
	answer, err := o.call("session/new", map[string]any{"cwd": folder.Path(), "mcpServers": []any{}})
	if err != nil {
		o.close()
		return listing{}, "", err
	}
	if answer.Error != nil {
		o.close()
		if answer.Error.Code == d.p.signedOut {
			return listing{}, brainwire.SignedOut, nil
		}
		return listing{}, "", errors.New("it refused to open a session to list them")
	}
	var listed sessionAnswer
	_ = json.Unmarshal(answer.Result, &listed)
	// A session CYFR cannot name is no positive answer, nor one it can
	// forget.
	if !d.p.sessionID(listed.SessionID) {
		o.close()
		return listing{}, "", errors.New("it opened no session CYFR can name")
	}
	_, _ = record.WriteString(listed.SessionID)
	out := listing{answer: listed}
	if d.p.selectEfforts {
		out.efforts = o.selectEach(listed)
	}
	_, _ = o.call("session/close", map[string]any{"sessionId": listed.SessionID})
	var gone error
	if d.p.deletes {
		gone = d.deleteIn(o, listed.SessionID)
	}
	o.close()
	keep = gone != nil || d.removeFiles(listed.SessionID) != nil
	return out, brainwire.SignedIn, nil
}

// selectEach selects each model the listing session offers in turn and
// reads the efforts the session then offers for it. A model whose
// selection is not answered is listed with none.
func (o *oneOff) selectEach(answer sessionAnswer) map[string][]string {
	efforts := map[string][]string{}
	model := option(answer.Options, "model")
	if model == nil {
		return efforts
	}
	for _, c := range model.choices() {
		efforts[c.value] = []string{}
		m, err := o.call("session/set_config_option", map[string]any{"sessionId": answer.SessionID, "configId": model.ID, "value": c.value})
		if err != nil {
			return efforts
		}
		var selected sessionAnswer
		if m.Error == nil && json.Unmarshal(m.Result, &selected) == nil {
			efforts[c.value] = selectedEfforts(selected.Options)
		}
	}
	return efforts
}

// holdRecord makes the listing `boot`'s record in `records` and holds its
// lock. A record is named in place only once locked, so no other listing
// takes an unlocked one for an interrupted listing's.
func holdRecord(records *homepath.Dir, boot string) (*os.File, error) {
	making := "." + boot
	f, err := records.Open(making, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		_ = records.Remove(making)
		return nil, err
	}
	if err := records.Rename(making, boot); err != nil {
		f.Close()
		_ = records.Remove(making)
		return nil, err
	}
	return f, nil
}

// forgetInterrupted removes each interrupted listing's session and record,
// under its record's lock; a record whose lock is held is a live listing's,
// and one that is a link or no file of this user's own is never opened.
func (d *driver) forgetInterrupted(records *homepath.Dir) error {
	names, err := records.Names()
	if err != nil {
		return errors.New("its listing records could not be read")
	}
	for _, name := range names {
		if strings.HasPrefix(name, ".") {
			continue
		}
		f, err := records.Open(name, os.O_RDWR, 0)
		if err != nil {
			continue
		}
		err = d.forgetRecord(records, name, f)
		f.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

func (d *driver) forgetRecord(records *homepath.Dir, name string, f *os.File) error {
	if syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		return nil
	}
	held, err := io.ReadAll(f)
	if err != nil {
		return errors.New("an earlier listing's record could not be read")
	}
	if session := strings.TrimSpace(string(held)); d.p.sessionID(session) {
		if err := d.removeSession(session); err != nil {
			return errors.New("an earlier listing's session could not be removed")
		}
	}
	_ = records.Remove(name)
	return nil
}
