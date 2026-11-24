// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/cyfr/locus/keeper/internal/brainwire"
)

// A listing when no session runs is a session of the driver's own, made in
// an empty folder of its own (`<home>/.cache/cyfr-acp/listing`) with no
// server, read for its config options, closed, and forgotten: its id is
// kept in `<home>/.cache/cyfr-acp/listing.session` from its answer until
// its files are proved absent, so a listing interrupted before then is
// forgotten by the next one first.

func listingFolder(home string) string { return filepath.Join(driverFolder(home), "listing") }

func listingRecord(home string) string { return filepath.Join(driverFolder(home), "listing.session") }

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
	record := listingRecord(d.home)
	if left, err := os.ReadFile(record); err == nil {
		if session := strings.TrimSpace(string(left)); brainwire.IsUUID(session) {
			if err := d.removeSession(session); err != nil {
				return sessionAnswer{}, "", errors.New("an earlier listing's session could not be removed")
			}
		}
		_ = os.Remove(record)
	}
	folder := listingFolder(d.home)
	if os.RemoveAll(folder) != nil || os.MkdirAll(folder, 0o700) != nil {
		return sessionAnswer{}, "", errors.New("its listing folder could not be made")
	}
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
	if brainwire.IsUUID(listed.SessionID) {
		_ = os.WriteFile(record, []byte(listed.SessionID), 0o600)
		_, _ = o.call("session/close", map[string]any{"sessionId": listed.SessionID})
	}
	o.close()
	if brainwire.IsUUID(listed.SessionID) && d.removeSession(listed.SessionID) == nil {
		_ = os.Remove(record)
	}
	return listed, brainwire.SignedIn, nil
}
