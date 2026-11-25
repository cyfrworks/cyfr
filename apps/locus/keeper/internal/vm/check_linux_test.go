// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package vm

import (
	"bufio"
	"net"
	"strings"
	"testing"
)

func TestPrefixedWritesWholeLinesOnly(t *testing.T) {
	var out strings.Builder
	p := &prefixed{w: &out}
	in := "first line\nsecond\npartial"
	for i := 0; i < len(in); i++ {
		n, err := p.Write([]byte{in[i]})
		if err != nil || n != 1 {
			t.Fatalf("Write of byte %d: %d, %v", i, n, err)
		}
	}
	if got, want := out.String(), "guest: first line\nguest: second\n"; got != want {
		t.Fatalf("wrote %q, want %q", got, want)
	}
	if _, err := p.Write([]byte(" end\n")); err != nil {
		t.Fatal(err)
	}
	if got, want := out.String(), "guest: first line\nguest: second\nguest: partial end\n"; got != want {
		t.Fatalf("wrote %q, want %q", got, want)
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
	return &Control{conn: host, lines: bufio.NewReader(host)}
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
