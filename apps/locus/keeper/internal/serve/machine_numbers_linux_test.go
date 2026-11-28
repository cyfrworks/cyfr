// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package serve

import (
	"bytes"
	"fmt"
	"strconv"
	"strings"
	"testing"

	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/logx"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// What the host takes from a guest as a number is bounded before it enters
// the ledger, a counter or a report: a session's reading by its VM's
// memory, a home's measure by its image, and an exit by what an exit can
// be. A guest that lies harms only its own person.

// @Opus2's (4521 fail 4): a guest's reading of 2^54 bytes, in a report
// that carries another person's counters too.
func TestAGuestsReadingStaysWithinTheReportsNumbers(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1")
	k.disk(t, "ath_b", "vlt_b1")
	k.session(t, "s1", "ath_a", "vlt_a1", nil)
	k.session(t, "s2", "ath_b", "vlt_b1", nil)
	first := k.guest.booted()[0]
	k.guest.mu.Lock()
	k.guest.answer = func(f *fakeVM, req map[string]any) ([]any, bool) {
		if f != first || req["type"] != protocol.TypeMeasure {
			return nil, false
		}
		id, _ := req["id"].(string)
		return []any{protocol.NewMeasured(id, protocol.Whose{Kind: "program"}, protocol.Reading{Bytes: 1 << 54}, 0)}, true
	}
	k.guest.mu.Unlock()
	k.s.read()()
	k.s.read()()
	req, perr := protocol.ParseRequest([]byte(`{"v":9,"type":"report","id":"r1","after":0}`))
	if perr != nil {
		t.Fatal(perr.Detail)
	}
	k.s.handle(k.c, req)
	report := k.expect(t, "reported")["report"].(map[string]any)
	athanors := map[string]bool{}
	for _, c := range report["counters"].([]any) {
		c := c.(map[string]any)
		athanors[fmt.Sprint(c["athanor"])] = true
		for _, n := range []string{"bytes", "peak_bytes", "mib_ms", "measured_ms"} {
			if v, ok := c[n].(float64); ok && v > float64(protocol.MaxRev) {
				t.Errorf("counter of %v: %s is %.0f, past %d, in a report that carries %v's counters", c["athanor"], n, v, uint64(protocol.MaxRev), athanors)
			}
		}
		if v, ok := c["peak_bytes"].(float64); ok && c["athanor"] == "ath_a" && v > float64(k.s.machineGuest()) {
			t.Errorf("person A's peak is %.0f, past their VM's %d bytes", v, k.s.machineGuest())
		}
	}
	if !athanors["ath_a"] || !athanors["ath_b"] {
		t.Fatalf("the report's counters are of %v, want both people's", athanors)
	}
}

// A guest's measure of a home of 2^54 bytes is answered as no more than
// its image holds.
func TestAGuestsHomeMeasureIsHeldToItsImage(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1")
	k.session(t, "s1", "ath_a", "vlt_a1", nil)
	k.guest.mu.Lock()
	k.guest.answer = func(_ *fakeVM, req map[string]any) ([]any, bool) {
		if req["type"] != protocol.TypeHomeMeasure {
			return nil, false
		}
		id, _ := req["id"].(string)
		return []any{protocol.NewHomeMeasured(id, 1<<54)}, true
	}
	k.guest.mu.Unlock()
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeHomeMeasure, ID: "m1", Home: "vlt_a1"})
	m := k.expect(t, "home_measured")
	if got := m["bytes"].(float64); got > float64(home.ImageBytes) {
		t.Fatalf("a home was measured at %.0f bytes, past its image's %d", got, uint64(home.ImageBytes))
	}
}

// A guest's exit whose code no exit has (2^54) and whose memory word is
// none of an exited's is said as SIGKILL with no memory word, and counts no
// kill; an exit a guest's keeper could send is passed as it is.
func TestAGuestsExitIsReadAsAnExitCanBe(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2")
	ends := map[string]map[string]any{
		"s1": {"code": 1 << 54, "signal": nil, "memory": "everything"},
		"s2": {"code": nil, "signal": "SIGTERM", "memory": protocol.MemoryCap},
	}
	n := 0
	k.guest.mu.Lock()
	k.guest.answer = func(_ *fakeVM, req map[string]any) ([]any, bool) {
		if req["type"] != protocol.TypeSpawn {
			return nil, false
		}
		n++
		id, _ := req["id"].(string)
		spawnID := fmt.Sprintf("%032x", 100+n)
		end := ends[fmt.Sprintf("s%d", n)]
		k.guest.mu.Lock()
		k.guest.spawns[spawnID] = true
		k.guest.mu.Unlock()
		exited := map[string]any{"v": protocol.Version, "type": "exited", "spawn_id": spawnID, "code": end["code"], "signal": end["signal"], "memory": end["memory"]}
		return []any{protocol.NewSpawned(id, spawnID, 40001, 77), exited}, true
	}
	k.guest.mu.Unlock()
	for _, c := range []struct {
		id, home       string
		code           any
		signal, memory any
	}{
		{"s1", "vlt_a1", nil, "SIGKILL", nil},
		{"s2", "vlt_a2", nil, "SIGTERM", protocol.MemoryCap},
	} {
		k.place(t, "p-"+c.id, "ath_a")
		k.s.handleSpawn(k.c, k.spawnReq(c.id, "p-"+c.id, c.home, nil))
		spawnID := k.expect(t, "spawned")["spawn_id"].(string)
		m := k.expect(t, "exited")
		if m["code"] != c.code || m["signal"] != c.signal || m["memory"] != c.memory {
			t.Errorf("%s: exited with code %v, signal %v, memory %v; want %v, %v, %v", c.id, m["code"], m["signal"], m["memory"], c.code, c.signal, c.memory)
		}
		ms := int64(0)
		k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: spawnID, GraceMs: &ms})
		k.expect(t, "released")
	}
}

// A guest's words reach the keeper's log quoted and bounded, never raw
// (5444's note): a refusal whose code holds a newline and a forged line
// leaves one line of the keeper's, its code quoted in it.
func TestAGuestsWordsReachTheLogQuoted(t *testing.T) {
	k := newVMKeeper(t)
	var log bytes.Buffer
	k.s.log = logx.NewWriter(&log, "cyfr-locus", false)
	k.disk(t, "ath_a", "vlt_a1")
	forged := "capacity\n[cyfr-locus] error: the VM of another person ended"
	k.guest.mu.Lock()
	k.guest.answer = func(_ *fakeVM, req map[string]any) ([]any, bool) {
		if req["type"] != protocol.TypePlace {
			return nil, false
		}
		id, _ := req["id"].(string)
		return []any{map[string]any{"v": protocol.Version, "type": "error", "id": id, "code": forged}}, true
	}
	k.guest.mu.Unlock()
	k.place(t, "p-s1", "ath_a")
	k.s.handleSpawn(k.c, k.spawnReq("s1", "p-s1", "vlt_a1", nil))
	if m := k.next(t); m["type"] != "error" {
		t.Fatalf("a spawn whose place the guest refused answered %v", m)
	}
	said := log.String()
	for _, line := range strings.Split(said, "\n") {
		if strings.HasPrefix(line, "[cyfr-locus] error: the VM of another person ended") {
			t.Fatalf("a guest's code forged a line of the keeper's log:\n%s", said)
		}
	}
	if !strings.Contains(said, strconv.Quote(forged)) {
		t.Fatalf("the guest's code is not in the log quoted:\n%s", said)
	}
}

// A guest's pid for its session's leader is passed on only as a pid a
// Linux kernel gives, else as none known (5444's note): 2^40 and -5 reach
// the role as 0, 77 as 77.
func TestAGuestsPIDIsHeldToAPid(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2", "vlt_a3")
	pids := []int{1 << 40, -5, 77}
	n := 0
	k.guest.mu.Lock()
	k.guest.answer = func(_ *fakeVM, req map[string]any) ([]any, bool) {
		if req["type"] != protocol.TypeSpawn {
			return nil, false
		}
		id, _ := req["id"].(string)
		spawnID := fmt.Sprintf("%032x", 200+n)
		k.guest.mu.Lock()
		k.guest.spawns[spawnID] = true
		k.guest.mu.Unlock()
		pid := pids[n]
		n++
		return []any{protocol.NewSpawned(id, spawnID, 40001, pid)}, true
	}
	k.guest.mu.Unlock()
	for i, want := range []float64{0, 0, 77} {
		id := fmt.Sprintf("s%d", i+1)
		k.place(t, "p-"+id, "ath_a")
		k.s.handleSpawn(k.c, k.spawnReq(id, "p-"+id, fmt.Sprintf("vlt_a%d", i+1), nil))
		if m := k.expect(t, "spawned"); m["pid"] != want {
			t.Fatalf("a guest's pid %d reached the role as %v, want %v", pids[i], m["pid"], want)
		}
	}
}

// A guest's line that does not decode, its number past every integer, ends
// its VM with a reason whose guest bytes are quoted and cut: the keeper's
// log line about it is short.
func TestAnUndecodableGuestLineReachesTheLogCut(t *testing.T) {
	if _, err := parseAnswer([]byte(`{"type":"placed","id":"x","pid":1` + strings.Repeat("9", 1<<20) + `}`)); err == nil || len(err.Error()) > 300 {
		t.Fatalf("an undecodable line answered %d bytes: %.120q", len(fmt.Sprint(err)), err)
	}
}
