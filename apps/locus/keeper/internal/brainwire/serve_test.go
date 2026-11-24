// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package brainwire

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// failing is a driver whose every command ends it as `end` says.
type failing struct{ end error }

func (d *failing) Command(string, map[string]json.RawMessage) error { return d.end }
func (d *failing) Process() *Process                                { return nil }
func (d *failing) Line([]byte) error                                { return nil }
func (d *failing) Ended() error                                     { return nil }
func (d *failing) Close()                                           {}
func (d *failing) Deadline() <-chan time.Time                       { return nil }
func (d *failing) Expired() error                                   { return nil }
func (d *failing) Inbox() <-chan func() error                       { return nil }

// A driver's end tells the holder its Why alone, as its last line, and its
// reason, which may carry a path or the program's words, only its standard
// error.
func TestAnEndTellsTheHolderItsWhyAndNoMore(t *testing.T) {
	reason := "the harness did not start: exec /home/person/.local/bin/agy: no such file"
	var out, errOut bytes.Buffer
	c := NewConn("cyfr-test", &out, &errOut)
	in := strings.NewReader(`{"t":"models","id":"m1"}` + "\n")
	if status := Serve(c, &failing{Fail(4, WhyUnrunnable, reason)}, in, nil); status != 4 {
		t.Fatalf("the driver ends with the end's status: %d", status)
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 2 || lines[1] != `{"t":"ending","why":"unrunnable"}` {
		t.Fatalf("hello, then the ending alone: %q", lines)
	}
	if _, _, err := ReadLine([]byte(lines[1]), Events); err != nil {
		t.Fatalf("the ending reads as the wire's: %v", err)
	}
	if strings.Contains(out.String(), "/home/person") || errOut.String() != "cyfr-test: "+reason+"\n" {
		t.Fatalf("the reason is the standard error's alone: %q %q", out.String(), errOut.String())
	}
}

// Every Why is one the wire reads, and an end cannot be made without one.
func TestEveryEndNamesAWhyTheWireReads(t *testing.T) {
	for _, why := range Whys {
		line, err := EncodeEvent(NewEvent("ending").Set("why", why.code))
		if err != nil {
			t.Fatalf("%s: %v", why.code, err)
		}
		if _, _, err := ReadLine(line, Events); err != nil {
			t.Fatalf("%s does not read: %v", why.code, err)
		}
	}
	defer func() {
		if recover() == nil {
			t.Fatal("an end with no Why was made")
		}
	}()
	_ = Fail(1, Why{}, "no code")
}
