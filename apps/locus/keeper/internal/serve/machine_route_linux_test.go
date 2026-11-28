// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package serve

import (
	"errors"
	"fmt"
	"net/netip"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/guard"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// A person's VM's route and its sessions: a release and a start of the
// person's change the sessions the route holds and the route itself in one
// step (reroute, joinMachine), so whatever their order the route allows
// exactly the person's live sessions' union, or a narrowing is owed.

// routeOf is what m's route allows now and its live sessions' union.
func routeOf(k *vmKeeper, m *machine) (allows, union []netip.Addr) {
	k.s.mu.Lock()
	defer k.s.mu.Unlock()
	var live []*spawn
	for _, sp := range m.sessions {
		live = append(live, sp)
	}
	_, union = unionOf(live)
	return append([]netip.Addr(nil), m.addrs...), union
}

// spawnIn is the spawn of kept home home.
func spawnIn(t *testing.T, k *vmKeeper, home string) *spawn {
	t.Helper()
	k.s.mu.Lock()
	defer k.s.mu.Unlock()
	for _, sp := range k.s.spawns {
		if sp.keptHome == home {
			return sp
		}
	}
	t.Fatalf("no spawn in %s", home)
	return nil
}

// Two releases whose steps interleave, each narrowing the route as it takes
// its session out: the route allows the one session left, and no narrowing
// is owed (@Opus2's replay, 4521 fail 1).
func TestTwoReleasesInterleavedLeaveNoReleasedSessionsHosts(t *testing.T) {
	fakeResolver(t, map[string][]string{"a.example.com": {"203.0.113.1"}, "b.example.com": {"203.0.113.2"}, "c.example.com": {"203.0.113.3"}})
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2", "vlt_a3")
	k.session(t, "s1", "ath_a", "vlt_a1", []string{"a.example.com"})
	k.session(t, "s2", "ath_a", "vlt_a2", []string{"b.example.com"})
	k.session(t, "s3", "ath_a", "vlt_a3", []string{"c.example.com"})
	m := k.machineOfAthanor("ath_a")
	two, three := spawnIn(t, k, "vlt_a2"), spawnIn(t, k, "vlt_a3")
	if err := k.s.reroute(m, two); err != nil {
		t.Fatal(err)
	}
	if err := k.s.reroute(m, three); err != nil {
		t.Fatal(err)
	}
	k.s.mu.Lock()
	delete(m.sessions, two.id)
	delete(m.sessions, three.id)
	narrowing := !m.narrowing.IsZero()
	k.s.mu.Unlock()
	got, want := routeOf(k, m)
	if !slices.Equal(got, want) || narrowing {
		t.Errorf("the VM's route allows %v with one live session, whose union is %v (narrowing %t)", got, want, narrowing)
	}
	k.s.retryNarrowing()
	if got, _ = routeOf(k, m); !slices.Equal(got, want) {
		t.Errorf("after a sweep the route allows %v", got)
	}
}

// Four of a person's five sessions released at once, each by its own
// release (@Opus2's, 4521 fail 1): the route allows the fifth's host alone.
func TestConcurrentReleasesLeaveNoReleasedSessionsHosts(t *testing.T) {
	fakeResolver(t, map[string][]string{"a.example.com": {"203.0.113.1"}, "b.example.com": {"203.0.113.2"}, "c.example.com": {"203.0.113.3"},
		"d.example.com": {"203.0.113.4"}, "e.example.com": {"203.0.113.5"}})
	bad, runs := 0, 60
	for i := 0; i < runs; i++ {
		k := newVMKeeper(t)
		k.disk(t, "ath_a", "vlt_a1", "vlt_a2", "vlt_a3", "vlt_a4", "vlt_a5")
		for j, h := range []string{"a", "b", "c", "d", "e"} {
			k.session(t, fmt.Sprintf("s%d", j+1), "ath_a", fmt.Sprintf("vlt_a%d", j+1), []string{h + ".example.com"})
		}
		m := k.machineOfAthanor("ath_a")
		var leaving []*spawn
		for j := 2; j <= 5; j++ {
			leaving = append(leaving, spawnIn(t, k, fmt.Sprintf("vlt_a%d", j)))
		}
		var wg sync.WaitGroup
		start := make(chan struct{})
		for _, sp := range leaving {
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-start
				k.s.leaveMachine(sp)
			}()
		}
		close(start)
		wg.Wait()
		if got, want := routeOf(k, m); !slices.Equal(got, want) {
			bad++
			t.Logf("run %d: the route allows %v, its live session's union is %v", i, got, want)
		}
		for _, f := range k.guest.booted() {
			f.Kill()
		}
	}
	if bad > 0 {
		t.Errorf("%d of %d runs left a released session's hosts in the route", bad, runs)
	}
}

// gatedGuard is the tests' guard, its first change held at a gate and
// every later one answered meanwhile.
type gatedGuard struct {
	*fakeRouteGuard
	gate          sync.Mutex
	gated         bool
	held, release chan struct{}
}

func (g *gatedGuard) Change(spawnID string, r guard.Route, reach string, addrs []netip.Addr) error {
	g.gate.Lock()
	first := !g.gated
	g.gated = true
	g.gate.Unlock()
	if first {
		close(g.held)
		<-g.release
	}
	return g.fakeRouteGuard.Change(spawnID, r, reach, addrs)
}

func gate(k *vmKeeper) *gatedGuard {
	g := &gatedGuard{fakeRouteGuard: k.guard, held: make(chan struct{}), release: make(chan struct{})}
	k.s.guard = g
	return g
}

func sessionsOf(k *vmKeeper, m *machine) int {
	k.s.mu.Lock()
	defer k.s.mu.Unlock()
	return len(m.sessions)
}

// One session of a person released as another of theirs starts, the
// release's narrowing at the guard as the start comes to join (@Fable3's,
// 4742's note): the route's last change allows the live session's host
// alone, or a narrowing is owed. The start waits for the release's step,
// so it is let in once its spawn is made.
func TestAReleaseAsAnotherStartsLeavesTheRouteToTheLiveSession(t *testing.T) {
	fakeResolver(t, map[string][]string{"a.example.com": {"203.0.113.7"}, "b.example.com": {"203.0.113.8"}})
	const tries = 30
	wider, last := 0, ""
	for i := 0; i < tries; i++ {
		k := newVMKeeper(t)
		k.disk(t, "ath_a", "vlt_a1", "vlt_a2")
		one, _ := k.session(t, "s1", "ath_a", "vlt_a1", []string{"a.example.com"})
		m := k.machineOfAthanor("ath_a")
		g := gate(k)
		ms := int64(0)
		go k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: one, GraceMs: &ms})
		select {
		case <-g.held:
		case <-time.After(20 * time.Second):
			t.Fatal("the release's narrowing never reached the guard")
		}
		k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypePlace, ID: "p-s2", Kind: "program", Athanor: "ath_a", Subject: "mcp_s2"})
		k.expect(t, "placed")
		go k.s.handleSpawn(k.c, k.spawnReq("s2", "p-s2", "vlt_a2", []string{"b.example.com"}))
		vmEventually(t, "the start's spawn", func() bool {
			k.s.mu.Lock()
			defer k.s.mu.Unlock()
			p := k.c.places["p-s2"]
			return p != nil && p.spawn != nil
		})
		time.Sleep(100 * time.Millisecond) // sleep-ok: a start that did not wait for the route's lock would reach the guard meanwhile
		close(g.release)
		k.expect(t, "spawned")
		vmEventually(t, "the released session's leaving", func() bool { return sessionsOf(k, m) == 1 })
		changes := k.routeChanges()
		last = changes[len(changes)-1]
		k.s.mu.Lock()
		narrowing := !m.narrowing.IsZero()
		k.s.mu.Unlock()
		if strings.Contains(last, "203.0.113.7") && !narrowing {
			wider++
		}
		if got, want := routeOf(k, m); !slices.Equal(got, want) && !narrowing {
			t.Fatalf("try %d: the route allows %v, its live session's union is %v", i, got, want)
		}
	}
	if wider > 0 {
		t.Fatalf("in %d of %d tries a person's VM's route allows a released session's host (203.0.113.7) beside the live one's, with no narrowing owed; the last try's: %s", wider, tries, last)
	}
}

// A person's two sessions released at once (@Fable3's, 4742's note): once
// both are gone the route's last change allows none.
func TestTwoReleasesAtOnceLeaveTheRouteAtNone(t *testing.T) {
	fakeResolver(t, map[string][]string{"a.example.com": {"203.0.113.7"}, "b.example.com": {"203.0.113.8"}})
	const tries = 30
	open, last := 0, ""
	for i := 0; i < tries; i++ {
		k := newVMKeeper(t)
		k.disk(t, "ath_a", "vlt_a1", "vlt_a2")
		one, _ := k.session(t, "s1", "ath_a", "vlt_a1", []string{"a.example.com"})
		two, _ := k.session(t, "s2", "ath_a", "vlt_a2", []string{"b.example.com"})
		m := k.machineOfAthanor("ath_a")
		g := gate(k)
		ms := int64(0)
		go k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: one, GraceMs: &ms})
		select {
		case <-g.held:
		case <-time.After(20 * time.Second):
			t.Fatal("the first release's narrowing never reached the guard")
		}
		go k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: two, GraceMs: &ms})
		// The second release's exit is told before its narrowing is asked;
		// then a moment for it to reach the route's lock.
		for told := false; !told; {
			if l := k.next(t); l["type"] == "exited" && l["spawn_id"] == two {
				told = true
			}
		}
		time.Sleep(100 * time.Millisecond) // sleep-ok: lets the second release reach the route's lock; either order passes
		close(g.release)
		vmEventually(t, "both sessions' leaving", func() bool { return sessionsOf(k, m) == 0 })
		changes := k.routeChanges()
		last = changes[len(changes)-1]
		k.s.mu.Lock()
		narrowing := !m.narrowing.IsZero()
		k.s.mu.Unlock()
		if !strings.HasPrefix(last, "none") && !narrowing {
			open++
		}
	}
	if open > 0 {
		t.Fatalf("in %d of %d tries a person's VM with no session left keeps a route that allows a released session's host, with no narrowing owed; the last try's: %s", open, tries, last)
	}
}

// A start whose widening the guard refuses is taken out of the VM's
// sessions before the route's lock is let go (ruling 2's second half,
// 5444's gap). The test holds the keeper's lock as the guard refuses: a
// start that takes its session out under the route's lock waits for the
// keeper's lock with the route's lock held, so the route's lock is never
// free while the refused session is still a session; one that lets the
// route's lock go first leaves it free with the session still in.
func TestARefusedWideningLeavesTheSessionsBeforeTheLockIsLetGo(t *testing.T) {
	fakeResolver(t, map[string][]string{"a.example.com": {"203.0.113.1"}, "b.example.com": {"203.0.113.2"}})
	k := newVMKeeper(t)
	k.disk(t, "ath_a", "vlt_a1", "vlt_a2")
	k.session(t, "s1", "ath_a", "vlt_a1", []string{"a.example.com"})
	m := k.machineOfAthanor("ath_a")
	k.place(t, "p-s2", "ath_a")
	g := gate(k)
	k.guard.mu.Lock()
	k.guard.changes = []error{errors.New("the guard refuses this change")}
	k.guard.mu.Unlock()
	go k.s.handleSpawn(k.c, k.spawnReq("s2", "p-s2", "vlt_a2", []string{"b.example.com"}))
	select {
	case <-g.held:
	case <-time.After(20 * time.Second):
		t.Fatal("the refused start's widening never reached the guard")
	}
	refused := func() bool {
		for _, sp := range m.sessions {
			if sp.keptHome == "vlt_a2" {
				return true
			}
		}
		return false
	}
	k.s.mu.Lock()
	close(g.release)
	for i := 0; i < 200; i++ {
		if m.reachMu.TryLock() {
			still := refused()
			m.reachMu.Unlock()
			if still {
				k.s.mu.Unlock()
				t.Fatal("the route's lock was let go with the refused start's session still among the VM's sessions")
			}
			break
		}
		time.Sleep(time.Millisecond) // sleep-ok: a bounded look at the route's lock while the keeper's is held
	}
	k.s.mu.Unlock()
	// With the keeper's lock let go, the first time the route's lock is
	// free the refused session is gone, before its own retirement would
	// take it out.
	for deadline := time.Now().Add(20 * time.Second); ; runtime.Gosched() {
		if m.reachMu.TryLock() {
			k.s.mu.Lock()
			still := refused()
			k.s.mu.Unlock()
			m.reachMu.Unlock()
			if still {
				t.Fatal("the route's lock was free with the refused start's session still among the VM's sessions")
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the route's lock was never free")
		}
	}
	if r := k.next(t); r["type"] != "error" || r["code"] != protocol.CodeGuardUnavailable {
		t.Fatalf("a start whose widening the guard refused answered %v", r)
	}
	k.expect(t, "released")
	k.s.mu.Lock()
	still := refused()
	k.s.mu.Unlock()
	if still {
		t.Fatal("the refused start's session is still among the VM's sessions")
	}
}
