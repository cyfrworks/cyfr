// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/internal/admission"
	"github.com/cyfr/locus/keeper/internal/logx"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// twoIdleVMs makes a test keeper whose pool holds a's VM and b's VM at
// their readings, each come to rest after its one session, a before b, and
// beside them a third person's first start less one byte: that start needs
// one of them to give way. The idle bound is an hour, so only room ends one.
func twoIdleVMs(t *testing.T) (*vmKeeper, *fakeVM, *fakeVM) {
	t.Helper()
	idleFor(t, time.Hour)
	k := newVMKeeper(t)
	own := admission.MachineBytes(k.s.machineGuest())
	allowance := admission.Allowance(admission.Kinds["program"])
	const reading = 64 << 20
	k.s.ledger = admission.New(own+allowance+2*reading-1, false)
	k.disk(t, "ath_a", "vlt_a1")
	k.disk(t, "ath_b", "vlt_b1")
	ms := int64(0)
	for _, who := range []string{"a", "b"} {
		id, _ := k.session(t, "s"+who, "ath_"+who, "vlt_"+who+"1", nil)
		k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: id, GraceMs: &ms})
		k.expect(t, "released")
		f := k.guest.booted()[len(k.guest.booted())-1]
		f.mu.Lock()
		f.used = reading
		f.mu.Unlock()
		k.s.mu.Lock()
		k.s.ledger.Spawned(k.s.vms["ath_"+who].entry, now().Add(-time.Minute))
		k.s.mu.Unlock()
		k.s.read()()
		time.Sleep(5 * time.Millisecond) // sleep-ok: b comes to rest after a
	}
	return k, k.guest.booted()[0], k.guest.booted()[1]
}

// gateResets makes every guest of k hold a folder's reset until the gate
// it answers is opened, which the test's end opens too.
func gateResets(t *testing.T, k *vmKeeper) func() {
	gate := make(chan struct{})
	open := sync.OnceFunc(func() { close(gate) })
	t.Cleanup(open)
	k.guest.mu.Lock()
	k.guest.answer = func(_ *fakeVM, req map[string]any) ([]any, bool) {
		if req["type"] == protocol.TypeHomeReset {
			<-gate
		}
		return nil, false
	}
	k.guest.mu.Unlock()
	return open
}

// guestAsked waits until a guest of k has read a request of typ.
func guestAsked(t *testing.T, k *vmKeeper, typ string) {
	t.Helper()
	vmEventually(t, "the guest's "+typ, func() bool { return slices.Contains(k.guest.requests(), typ) })
}

// ending says whether m's end has begun (endMachine's End is asynchronous).
func (k *vmKeeper) ending(m *machine) bool {
	k.s.mu.Lock()
	defer k.s.mu.Unlock()
	return m.ending
}

// While a folder's operation holds a person's VM, the admission does not
// count it as giving way: another person's idle VM is asked, though the held
// one has rested longer, and a third person's start is admitted; the held
// VM stands, and its operation ends as asked.
func TestAVMHeldForAFoldersOperationIsNotAskedToGiveWay(t *testing.T) {
	k, fa, fb := twoIdleVMs(t)
	open := gateResets(t, k)
	go k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeHomeReset, ID: "r1", Home: "vlt_a1"})
	guestAsked(t, k, protocol.TypeHomeReset)
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypePlace, ID: "p-c", Kind: "program", Athanor: "ath_c", Subject: "mcp_c"})
	vmEventually(t, "b's idle VM's end for c's start", fb.ended)
	if m := k.next(t); m["id"] != "p-c" || m["type"] != "placed" {
		t.Fatalf("c's start answered %v while b's VM stood idle (b ended %t, a ended %t)", m, fb.ended(), fa.ended())
	}
	if fa.ended() || k.ending(k.machineOfAthanor("ath_a")) {
		t.Fatal("the VM a folder's operation holds gave way")
	}
	open()
	if m := k.next(t); m["id"] != "r1" || m["type"] != "home_made" {
		t.Fatalf("the held VM's reset answered %v", m)
	}
}

// With no folder's operation, the same pool asks a's VM, at rest longest,
// to give way, and c's start is admitted.
func TestWithNoHoldTheVMAtRestLongestGivesWay(t *testing.T) {
	k, fa, fb := twoIdleVMs(t)
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypePlace, ID: "p-c", Kind: "program", Athanor: "ath_c", Subject: "mcp_c"})
	vmEventually(t, "an idle VM's end for c's start", func() bool { return fa.ended() || fb.ended() })
	if m := k.next(t); m["id"] != "p-c" || m["type"] != "placed" {
		t.Fatalf("c's start answered %v (a ended %t, b ended %t)", m, fa.ended(), fb.ended())
	}
	if !fa.ended() || fb.ended() {
		t.Fatalf("a ended %t and b %t, want a, at rest longest, alone", fa.ended(), fb.ended())
	}
}

// A VM held for a folder's operation does not end idle, though it has
// rested past its bound, nor for an ask to give way; it is idle from the
// operation's end, so the next sweep after the operation leaves it standing.
func TestAHeldVMEndsNotIdleAndRestsFromItsOperationsEnd(t *testing.T) {
	idleFor(t, time.Hour)
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1")
	id, _ := k.session(t, "s1", "ath_a", "vlt_a1", nil)
	ms := int64(0)
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: id, GraceMs: &ms})
	k.expect(t, "released")
	m := k.machineOfAthanor("ath_a")
	k.s.mu.Lock()
	m.idleSince = now().Add(-2 * time.Hour)
	k.s.mu.Unlock()
	open := gateResets(t, k)
	go k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeHomeReset, ID: "r1", Home: "vlt_a1"})
	guestAsked(t, k, protocol.TypeHomeReset)
	k.s.endIdleMachines()
	if k.ending(m) {
		t.Fatal("a VM a folder's operation holds ended idle")
	}
	// An ask to give way sent before the hold, as the admission's ask runs
	// apart from it, is refused by the keeper's own test of rest.
	k.s.giveWay(m)
	if k.ending(m) {
		t.Fatal("a VM a folder's operation holds gave way to an ask that came after its hold")
	}
	open()
	if r := k.next(t); r["id"] != "r1" || r["type"] != "home_made" {
		t.Fatalf("the reset answered %v", r)
	}
	k.s.endIdleMachines()
	if k.ending(m) {
		t.Fatal("a VM idle from its operation's end ended at the next sweep, its idle bound an hour")
	}
}

// A folder's operation whose person's VM is not yet started and waits for
// room, for one of their sessions or for another operation on their
// folders, is refused at once as no room, with a log line that says which
// and to ask again; the VM boots once there is room, for what waited.
func TestAFoldersOperationIsRefusedWhileItsPersonsVMWaitsForRoom(t *testing.T) {
	// Each waits in a pool one program's place fills: a session's start,
	// which needs its VM's room beside its own, and a VM placed alone for an
	// operation, which needs its own alone.
	for name, c := range map[string]struct {
		beside uint64
		wait   func(k *vmKeeper)
	}{
		"one of their sessions": {767 << 20, func(k *vmKeeper) {
			k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypePlace, ID: "p-s1", Kind: "program", Athanor: "ath_a", Subject: "mcp_s1"})
		}},
		"another operation on their folders": {383 << 20, func(k *vmKeeper) {
			go k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeHomeReset, ID: "r0", Home: "vlt_a2"})
		}},
	} {
		t.Run(name, func(t *testing.T) {
			k := newVMKeeper(t)
			log := &lockedLog{}
			k.s.log = logx.NewWriter(log, "cyfr-locus", false)
			k.s.ledger = admission.New(admission.MachineBytes(k.s.machineGuest())+c.beside, false)
			k.disk(t, "ath_a", "vlt_a1", "vlt_a2")
			held := &admission.Entry{Role: "backends", Kind: "program", Athanor: "ath_b", Subject: "mcp_b", Ref: placeRef{c: k.c, id: "pb"}}
			k.s.mu.Lock()
			k.s.admit(k.s.ledger.Place(held, now()))
			k.s.mu.Unlock()
			if m := k.next(t); m["type"] != "placed" {
				t.Fatalf("the place that fills the pool answered %v", m)
			}
			c.wait(k)
			vmEventually(t, "the person's VM's wait for room", func() bool {
				m := k.machineOfAthanor("ath_a")
				k.s.mu.Lock()
				defer k.s.mu.Unlock()
				return m != nil && m.places == 1
			})
			go k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeHomeReset, ID: "r1", Home: "vlt_a1"})
			if m := k.next(t); m["id"] != "r1" || m["type"] != "error" || m["code"] != protocol.CodeCapacity {
				t.Fatalf("an operation while its person's VM waits for room answered %v", m)
			}
			if said := log.lines("waits for room for " + name + "; asked again once that has room, it goes ahead"); len(said) != 1 {
				t.Fatalf("the keeper's log says %q", log.lines("refused"))
			}
			if n := len(k.guest.booted()); n != 0 {
				t.Fatalf("%d VMs booted with no room for one", n)
			}
			k.s.mu.Lock()
			k.s.admit(k.s.ledger.Drop(held, now()))
			k.s.mu.Unlock()
			want := map[string]string{"one of their sessions": "placed", "another operation on their folders": "home_made"}[name]
			if m := k.next(t); m["type"] != want {
				t.Fatalf("what waited answered %v once room came, want %s", m, want)
			}
		})
	}
}

// A guest's refusal of a folder's operation reaches the keeper's log only
// quoted and cut, as every other guest refusal does: a code that carries a
// newline makes no line of its own.
func TestAFoldersRefusalQuotesTheGuestsCode(t *testing.T) {
	k := newVMKeeper(t)
	log := &lockedLog{}
	k.s.log = logx.NewWriter(log, "cyfr-locus", false)
	k.disk(t, "ath_a", "vlt_a1")
	forged := "home_absent\n[cyfr-locus] info: FORGED by the guest " + strings.Repeat("x", 4096)
	k.guest.mu.Lock()
	k.guest.answer = func(_ *fakeVM, req map[string]any) ([]any, bool) {
		if req["type"] == protocol.TypeHomeReset {
			return []any{map[string]any{"v": protocol.Version, "type": "error", "id": req["id"], "code": forged}}, true
		}
		return nil, false
	}
	k.guest.mu.Unlock()
	if m := k.homeOp(t, protocol.TypeHomeReset, "r1", "vlt_a1"); m["type"] != "error" {
		t.Fatalf("a refused reset answered %v", m)
	}
	said := log.lines("FORGED by the guest")
	if len(said) == 0 {
		t.Fatal("the keeper's log does not say the guest's refusal")
	}
	for _, line := range said {
		if strings.HasPrefix(line, "[cyfr-locus] info: FORGED") || len(line) > 1024 {
			t.Fatalf("the guest's code made a log line of its own, or one of %d bytes: %.160q", len(line), line)
		}
	}
}

// A reset of a home the guest holds nothing of (its keeper answers
// home_retired for a home it does not hold) is a reset: the home is
// answered made, empty, under its disk's uid, and the host's record still
// holds it, as a reset on the host leaves it.
func TestAResetTheGuestAnswersRetiredIsAReset(t *testing.T) {
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1")
	k.guest.mu.Lock()
	k.guest.answer = func(_ *fakeVM, req map[string]any) ([]any, bool) {
		if req["type"] == protocol.TypeHomeReset {
			return []any{protocol.NewHomeRetired(req["id"].(string))}, true
		}
		return nil, false
	}
	k.guest.mu.Unlock()
	m := k.homeOp(t, protocol.TypeHomeReset, "r1", "vlt_a1")
	if m["type"] != "home_made" || m["id"] != "r1" {
		t.Fatalf("a reset the guest answered retired answered %v, want home_made", m)
	}
	if !k.recorded("ath_a", "vlt_a1") {
		t.Fatal("a reset the guest answered retired took the home out of the host's record")
	}
}

// A line a guest sends that answers no request spends its budget whatever
// it is: one that does not read, and a session's exit and its release, as a
// refusal of no request does (TestAGuestPastItsUnansweredBudgetEndsItsVM).
// Two such lines at the line's bound overdraw it, and the VM ends, as one
// whose guest stops answering does.
func TestEveryLineThatAnswersNoRequestSpendsItsGuestsBudget(t *testing.T) {
	pad := strings.Repeat("x", protocol.MaxLineBytes-256)
	for name, lines := range map[string]func(guest string) []string{
		"a line that does not read": func(string) []string {
			junk := `{"v":9,"type":"exited","pad":"` + pad
			return []string{junk, junk}
		},
		"a session's exit": func(guest string) []string {
			exit := `{"v":9,"type":"exited","spawn_id":"` + guest + `","code":0,"pad":"` + pad + `"}`
			return []string{exit, exit}
		},
		"a session's release": func(guest string) []string {
			return []string{`{"v":9,"type":"released","spawn_id":"` + guest + `","pad":"` + pad + `"}`,
				`{"v":9,"type":"released","spawn_id":"` + guest + `","pad":"` + pad + `"}`}
		},
	} {
		t.Run(name, func(t *testing.T) {
			k := newVMKeeper(t)
			log := &lockedLog{}
			k.s.log = logx.NewWriter(log, "cyfr-locus", false)
			k.disk(t, "ath_a", "vlt_a1")
			id, _ := k.session(t, "s1", "ath_a", "vlt_a1", nil)
			k.s.mu.Lock()
			guest := k.s.spawns[id].guest
			k.s.mu.Unlock()
			if guest == "" {
				t.Fatal("the session has no guest spawn id")
			}
			f := k.guest.booted()[0]
			f.mu.Lock()
			control := f.controls[0]
			f.mu.Unlock()
			go func() {
				for _, l := range lines(guest) {
					if _, err := control.Write([]byte(l + "\n")); err != nil {
						return
					}
				}
			}()
			vmEventually(t, "the VM's end past its guest's budget", f.ended)
			if said := log.lines("lines that answer no request than its budget holds"); len(said) != 1 {
				t.Fatalf("the VM ended, and the keeper's log says %q", log.lines("VM"))
			}
		})
	}
}
