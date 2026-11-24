// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package brainwire

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
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

// A driver started with no harness to drive, off a terminal, ends as every
// other end does: its hello, then its ending, unrunnable, and its usage on
// standard error alone.
func TestADriverWithNoHarnessEndsUnrunnable(t *testing.T) {
	inR, inW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	outR, outW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	stdin, stdout := os.Stdin, os.Stdout
	os.Stdin, os.Stdout = inR, outW
	status := Main("cyfr-test", nil, nil)
	os.Stdin, os.Stdout = stdin, stdout
	_ = outW.Close()
	_ = inW.Close()
	written, _ := io.ReadAll(outR)
	lines := strings.Split(strings.TrimSpace(string(written)), "\n")
	if status != 2 || len(lines) != 2 || lines[1] != `{"t":"ending","why":"unrunnable"}` {
		t.Fatalf("hello, then the ending alone, and 2: %d %q", status, lines)
	}
	if !strings.HasPrefix(lines[0], `{"t":"hello"`) {
		t.Fatalf("the first line is its hello: %q", lines[0])
	}
}

// placing is a driver that places every scroll and records its unplacing.
type placing struct {
	failing
	unplaced int
	c        *Conn
}

func (d *placing) Scroll(id, name, _, _ string) error { return d.c.Placed(id, "x:"+name) }
func (d *placing) Unplace()                           { d.unplaced++ }

// A driver that places no scroll answers each `yielded` without being
// asked, so its scrolls keep the model's harness's way; one that places
// answers each itself, and what it placed is removed once as it ends,
// however it ends.
func TestAScrollIsYieldedByADriverThatPlacesNoneAndUnplacedAtTheEnd(t *testing.T) {
	scroll := `{"t":"scroll","id":"s1","name":"research","description":"d","body":"b"}` + "\n"
	var out bytes.Buffer
	c := NewConn("cyfr-test", &out, io.Discard)
	if status := Serve(c, &failing{}, strings.NewReader(scroll), nil); status != 0 {
		t.Fatalf("the input's end ends the driver: %d", status)
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 2 || lines[1] != `{"t":"yielded","id":"s1"}` {
		t.Fatalf("hello, then the scroll yielded: %q", lines)
	}
	for name, input := range map[string]string{
		"the input's end": scroll,
		"an ending":       scroll + `{"t":"models","id":"m1"}` + "\n",
	} {
		out.Reset()
		c = NewConn("cyfr-test", &out, io.Discard)
		d := &placing{failing: failing{end: Fail(1, WhyBroken, "")}, c: c}
		Serve(c, d, strings.NewReader(input), nil)
		lines = strings.Split(strings.TrimSpace(out.String()), "\n")
		if lines[1] != `{"t":"placed","id":"s1","as":"x:research"}` || d.unplaced != 1 {
			t.Fatalf("%s: the placer answers and is unplaced once: %q %d", name, lines, d.unplaced)
		}
	}
}
