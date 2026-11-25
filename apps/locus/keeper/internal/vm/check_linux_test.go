// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package vm

import (
	"net"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/internal/protocol"
)

// The console's tail keeps its last bytes and says how many it dropped,
// each kept line marked.
func TestTailKeepsTheLastBytesAndSaysWhatItDropped(t *testing.T) {
	tl := &tail{max: 16}
	for _, piece := range []string{"first line\n", "second line\n", "third\n"} {
		if n, err := tl.Write([]byte(piece)); err != nil || n != len(piece) {
			t.Fatalf("Write %q: %d, %v", piece, n, err)
		}
	}
	var out strings.Builder
	tl.print(&out, "guest: ")
	want := "guest: (the first 13 bytes were dropped: the check keeps the last 16)\nguest: cond line\nguest: third\n"
	if out.String() != want {
		t.Fatalf("printed %q, want %q", out.String(), want)
	}
	if len(tl.buf) != 16 {
		t.Fatalf("kept %d bytes, not 16", len(tl.buf))
	}
}

// The space's output is kept to its first bytes, the rest counted.
func TestBoundedKeepsTheFirstBytesAndCountsTheRest(t *testing.T) {
	b := &bounded{max: 5}
	for _, piece := range []string{"abc", "defg", "hi"} {
		if n, err := b.Write([]byte(piece)); err != nil || n != len(piece) {
			t.Fatalf("Write %q: %d, %v", piece, n, err)
		}
	}
	if b.buf.String() != "abcde" || b.dropped != 4 {
		t.Fatalf("kept %q and dropped %d, want abcde and 4", b.buf.String(), b.dropped)
	}
}

// control is a Control over one end of a pipe, the other end the guest
// keeper's, which writes lines.
func control(t *testing.T, lines ...string) *Control {
	t.Helper()
	host, guest := net.Pipe()
	t.Cleanup(func() { _ = host.Close(); _ = guest.Close() })
	go func() {
		for _, l := range lines {
			if _, err := guest.Write([]byte(l + "\n")); err != nil {
				return
			}
		}
	}()
	return &Control{conn: host, lines: protocol.NewLineReader(host)}
}

func TestExpectSkipsOtherTypesAndIDs(t *testing.T) {
	want := `{"v":4,"type":"placed","id":"p1"}`
	c := control(t,
		`{"v":4,"type":"measured","id":"p1"}`,
		`{"v":4,"type":"placed","id":"p0"}`,
		want)
	line, err := expect(c, "placed", "p1")
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(line)); got != want {
		t.Fatalf("expect returned %s, want %s", got, want)
	}
}

func TestExpectWithoutAnIDTakesTheFirstOfItsType(t *testing.T) {
	want := `{"v":4,"type":"exited","spawn_id":"s","code":0}`
	c := control(t, `{"v":4,"type":"spawned","id":"x"}`, want)
	line, err := expect(c, "exited", "")
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(line)); got != want {
		t.Fatalf("expect returned %s, want %s", got, want)
	}
}

func TestExpectRefusesAnErrorLineNamingItsCode(t *testing.T) {
	c := control(t, `{"v":4,"type":"error","id":"p1","code":"bad_request"}`, `{"v":4,"type":"placed","id":"p1"}`)
	_, err := expect(c, "placed", "p1")
	if err == nil || !strings.Contains(err.Error(), "bad_request") {
		t.Fatalf("expect gave %v, not a refusal naming bad_request", err)
	}
}

// A line from the guest past the keeper protocol's bound is refused, and
// the next is read whole.
func TestControlRefusesALinePastTheBound(t *testing.T) {
	long := strings.Repeat("x", protocol.MaxLineBytes+1)
	want := `{"v":4,"type":"placed","id":"p1"}`
	c := control(t, long, want)
	if _, err := c.Next(10 * time.Second); err != ErrLineTooLong {
		t.Fatalf("a line of %d bytes: %v, not ErrLineTooLong", len(long), err)
	}
	line, err := c.Next(10 * time.Second)
	if err != nil || string(line) != want {
		t.Fatalf("the next line: %q, %v", line, err)
	}
}
