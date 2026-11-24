// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/cyfr/locus/keeper/internal/brainwire"
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

func listingFolder(home, boot string) string {
	return filepath.Join(driverFolder(home), "listing", boot)
}

// listingRecords is the folder of the listings' records, one a listing.
func listingRecords(home string) string { return filepath.Join(driverFolder(home), "listings") }

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

// listOnce makes a listing session and answers what it offers, or says the
// program is signed out, the one shape its profile names.
func (d *driver) listOnce() (sessionAnswer, string, error) {
	if err := d.forgetInterrupted(); err != nil {
		return sessionAnswer{}, "", err
	}
	record, named, err := d.holdRecord()
	if err != nil {
		return sessionAnswer{}, "", err
	}
	// Removed while its lock is held, then released, unless its session
	// could not be removed, which a later listing removes by it.
	keep := false
	defer func() {
		if !keep {
			_ = os.Remove(named)
		}
		record.Close()
	}()
	folder := listingFolder(d.home, d.c.Boot)
	if os.RemoveAll(folder) != nil || os.MkdirAll(folder, 0o700) != nil {
		return sessionAnswer{}, "", errors.New("its listing folder could not be made")
	}
	defer os.RemoveAll(folder)
	o, err := d.openOneOff()
	if err != nil {
		return sessionAnswer{}, "", err
	}
	answer, err := o.call("session/new", map[string]any{"cwd": folder, "mcpServers": []any{}})
	if err != nil {
		o.close()
		return sessionAnswer{}, "", err
	}
	if answer.Error != nil {
		o.close()
		if answer.Error.Code == d.p.signedOut {
			return sessionAnswer{}, brainwire.SignedOut, nil
		}
		return sessionAnswer{}, "", errors.New("it refused to open a session to list them")
	}
	var listed sessionAnswer
	_ = json.Unmarshal(answer.Result, &listed)
	// A session CYFR cannot name is no positive answer, nor one it can
	// forget.
	if !brainwire.IsUUID(listed.SessionID) {
		o.close()
		return sessionAnswer{}, "", errors.New("it opened no session CYFR can name")
	}
	_, _ = record.WriteString(listed.SessionID)
	_, _ = o.call("session/close", map[string]any{"sessionId": listed.SessionID})
	o.close()
	keep = d.removeSession(listed.SessionID) != nil
	return listed, brainwire.SignedIn, nil
}

// holdRecord makes this listing's record and holds its lock. A record is
// named in place only once locked, so no other listing takes an unlocked
// one for an interrupted listing's.
func (d *driver) holdRecord() (*os.File, string, error) {
	folder := listingRecords(d.home)
	failed := errors.New("its listing record could not be made")
	if os.MkdirAll(folder, 0o700) != nil {
		return nil, "", failed
	}
	making, named := filepath.Join(folder, "."+d.c.Boot), filepath.Join(folder, d.c.Boot)
	f, err := os.OpenFile(making, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0o600)
	if err != nil {
		return nil, "", failed
	}
	if syscall.Flock(int(f.Fd()), syscall.LOCK_EX) != nil || os.Rename(making, named) != nil {
		f.Close()
		_ = os.Remove(making)
		return nil, "", failed
	}
	return f, named, nil
}

// forgetInterrupted removes each interrupted listing's session and record,
// under its record's lock; a record whose lock is held is a live listing's.
func (d *driver) forgetInterrupted() error {
	folder := listingRecords(d.home)
	records, err := os.ReadDir(folder)
	if err != nil {
		return nil
	}
	for _, entry := range records {
		if strings.HasPrefix(entry.Name(), ".") {
			continue
		}
		if err := d.forgetRecord(filepath.Join(folder, entry.Name())); err != nil {
			return err
		}
	}
	return nil
}

func (d *driver) forgetRecord(name string) error {
	f, err := os.OpenFile(name, os.O_RDWR, 0)
	if err != nil {
		return nil
	}
	defer f.Close()
	if syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		return nil
	}
	held, err := io.ReadAll(f)
	if err != nil {
		return errors.New("an earlier listing's record could not be read")
	}
	if session := strings.TrimSpace(string(held)); brainwire.IsUUID(session) {
		if err := d.removeSession(session); err != nil {
			return errors.New("an earlier listing's session could not be removed")
		}
	}
	_ = os.Remove(name)
	return nil
}
