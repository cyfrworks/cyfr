// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/admission"
	"github.com/cyfr/locus/keeper/internal/logx"
	"github.com/cyfr/locus/keeper/internal/pool"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

const mibs = 1 << 20

// poolRole is one role's channel on a pool keeper: its client and the
// test's end of its channel.
type poolRole struct {
	c       *client
	theirs  *os.File
	channel *protocol.LineReader
}

// poolKeeper is a keeper of work W, begun as a start of the keeper is, its
// budget twice W, with two roles, the floor's (runtime, runner pool) and a
// session's (backends), each channel read as serve reads it, its clock the
// test's: it needs no root and starts nothing. Its admission steps a
// second only when the test says (admitTick).
func poolKeeper(t *testing.T, work uint64) (*server, *poolRole, *poolRole, *fakeClock) {
	t.Helper()
	clock := clockAt(t, time.Date(2026, 11, 26, 12, 0, 0, 0, time.UTC))
	s := &server{
		log:       logx.NewWriter(os.Stderr, "cyfr-locus", false),
		pools:     map[string]*pool.Pool{},
		spawns:    map[string]*spawn{},
		unremoved: map[*spawn]*removal{},
		waiters:   map[int]*child{},
	}
	s.begin(admission.Sizes{Budget: 2 * work, Work: work}, true)
	role := func(name string, spec pool.Spec, floor bool) *poolRole {
		return served(t, s, name, func(channel *os.File) *client {
			c := testClient(channel, spec, Account{})
			c.role.spec.Name, c.role.spec.Floor = name, floor
			return c
		})
	}
	runtime := role("runtime", pool.Spec{Name: "runner"}, true)
	backends := role("backends", pool.Spec{Name: "backends", Reach: pool.ReachRouted}, false)
	return s, runtime, backends, clock
}

// served is the client newClient makes on a fresh channel, served as serve
// serves a role's, the test holding the channel's other end.
func served(t *testing.T, s *server, name string, newClient func(channel *os.File) *client) *poolRole {
	t.Helper()
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, fd := range fds {
		if err := unix.SetNonblock(fd, true); err != nil {
			t.Fatal(err)
		}
	}
	ours, theirs := os.NewFile(uintptr(fds[0]), name), os.NewFile(uintptr(fds[1]), name+"-client")
	if err := theirs.SetReadDeadline(time.Now().Add(10 * time.Second)); err != nil {
		t.Fatal(err)
	}
	c := newClient(ours)
	done := make(chan struct{})
	go func() { s.serveChannel(c); close(done) }()
	t.Cleanup(func() { theirs.Close(); <-done; ours.Close() })
	return &poolRole{c: c, theirs: theirs, channel: protocol.NewLineReader(theirs)}
}

func (r *poolRole) write(t *testing.T, lines ...string) {
	t.Helper()
	if _, err := r.theirs.Write([]byte(strings.Join(lines, "\n") + "\n")); err != nil {
		t.Fatal(err)
	}
}

// expect reads the role's next lines, each the one wanted, whole.
func (r *poolRole) expect(t *testing.T, want ...any) {
	t.Helper()
	for _, w := range want {
		line, tooLong, err := r.channel.Next()
		if err != nil || tooLong {
			t.Fatalf("reading role %s's channel for %+v: %v", r.c.role.spec.Name, w, err)
		}
		encoded, err := protocol.Encode(w)
		if err != nil {
			t.Fatal(err)
		}
		if got, want := string(line), strings.TrimSuffix(string(encoded), "\n"); got != want {
			t.Fatalf("role %s was sent %s, want %s", r.c.role.spec.Name, got, want)
		}
	}
}

// quiet says nothing more reaches the role within a tenth of a second.
func (r *poolRole) quiet(t *testing.T) {
	t.Helper()
	_ = r.theirs.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
	defer r.theirs.SetReadDeadline(time.Now().Add(10 * time.Second))
	if line, _, err := r.channel.Next(); err == nil {
		t.Fatalf("role %s was sent %s", r.c.role.spec.Name, line)
	}
}

// sync waits until the role's channel reader has applied every line sent
// before: a measure is answered in order behind them.
func (r *poolRole) sync(t *testing.T) {
	t.Helper()
	r.write(t, `{"v":9,"type":"measure","id":"sync","place":"none"}`)
	r.expect(t, protocol.NewError("sync", "", protocol.CodeUnmeasured))
}

func placeLine(id, kind, athanor, subject string) string {
	m := map[string]any{"v": 9, "type": "place", "id": id, "kind": kind}
	if athanor != "" {
		m["athanor"] = athanor
	}
	if subject != "" {
		m["subject"] = subject
	}
	line, _ := json.Marshal(m)
	return string(line)
}

func runnerPlaced(id string, work uint64) protocol.Placed {
	return protocol.NewPlaced(id, admission.LimitsOf(protocol.KindWarm, work).MemoryBytes)
}

func sessionPlaced(id string) protocol.Placed {
	return protocol.NewPlaced(id, admission.LimitsOf(protocol.KindProgram, 1200*mibs).MemoryBytes)
}

// Only the floor's role places and assigns a runner's kinds, and every
// other role only the others: a role naming another's kind is refused.
func TestARolePlacesOnlyItsOwnKinds(t *testing.T) {
	_, runtime, backends, _ := poolKeeper(t, 4096*mibs)
	runtime.write(t, placeLine("b", "build", "", ""), placeLine("p", "program", "ath_a", ""), placeLine("w", "warm", "", ""),
		`{"v":9,"type":"assign","id":"as","place":"w","kind":"terminal","athanor":"ath_a"}`)
	runtime.expect(t, protocol.NewError("b", "", protocol.CodeBadRequest), protocol.NewError("p", "", protocol.CodeBadRequest),
		runnerPlaced("w", 4096*mibs), protocol.NewError("as", "", protocol.CodeBadRequest))
	backends.write(t, placeLine("w", "warm", "", ""), placeLine("r", "run", "ath_a", ""), placeLine("p", "program", "ath_a", ""),
		`{"v":9,"type":"assign","id":"as","place":"p","kind":"run","athanor":"ath_a"}`)
	backends.expect(t, protocol.NewError("w", "", protocol.CodeBadRequest), protocol.NewError("r", "", protocol.CodeBadRequest),
		protocol.NewPlaced("p", admission.LimitsOf(protocol.KindProgram, 4096*mibs).MemoryBytes),
		protocol.NewError("as", "", protocol.CodeBadRequest))
}

// A place that finds no room waits unanswered: a spawn naming it is
// refused, and a drop takes it out, so the start behind it is admitted in
// its turn and the dropped one is never answered.
func TestAWaitingPlaceIsNeitherSpawnedNorKeptPastItsDrop(t *testing.T) {
	s, _, backends, _ := poolKeeper(t, 1200*mibs)
	// 1,036 for work beside F: two sessions hold 768, a third waits.
	backends.write(t, placeLine("p1", "program", "ath_a", ""), placeLine("p2", "program", "ath_a", ""),
		placeLine("p3", "program", "ath_a", ""), placeLine("p4", "program", "ath_b", ""))
	backends.expect(t, sessionPlaced("p1"), sessionPlaced("p2"))
	backends.write(t, `{"v":9,"type":"spawn","id":"s3","place":"p3","pool":"backends","argv":["true"],"attach":{"path":"/run/a.sock","token":"`+testToken+`"}}`)
	backends.expect(t, protocol.NewError("s3", "", protocol.CodeBadRequest))
	backends.write(t, `{"v":9,"type":"drop","place":"p3"}`, `{"v":9,"type":"drop","place":"p1"}`)
	backends.expect(t, sessionPlaced("p4"))
	backends.sync(t)
	s.mu.Lock()
	_, held := backends.c.places["p3"]
	s.mu.Unlock()
	if held {
		t.Fatal("a dropped waiting place is still held")
	}
	backends.quiet(t)
}

// A start that finds no room asks the floor's role, on its own channel, to
// give its idle runners way, each by its place; it is admitted once they
// are gone, and nothing reaches the role but the ask.
func TestAStartAsksIdleRunnersToGiveWayAndIsAdmittedAfter(t *testing.T) {
	s, runtime, backends, clock := poolKeeper(t, 1100*mibs)
	runtime.write(t, placeLine("floor", "warm", "", ""), placeLine("k1", "warm", "", ""), placeLine("k2", "warm", "", ""))
	runtime.expect(t, runnerPlaced("floor", 1100*mibs), runnerPlaced("k1", 1100*mibs), runnerPlaced("k2", 1100*mibs))
	runtime.write(t, `{"v":9,"type":"assign","id":"a1","place":"k1","kind":"warm","athanor":"ath_a"}`,
		`{"v":9,"type":"assign","id":"a2","place":"k2","kind":"warm","athanor":"ath_b"}`)
	runtime.expect(t, protocol.NewAssigned("a1"), protocol.NewAssigned("a2"))
	// 936 for work beside F, two kept runners of 164: a session's 384
	// fits, a second's is 160 short, which the older kept runner covers.
	backends.write(t, placeLine("p1", "program", "ath_c", ""), placeLine("p2", "program", "ath_c", ""))
	backends.expect(t, protocol.NewPlaced("p1", admission.LimitsOf(protocol.KindProgram, 1100*mibs).MemoryBytes))
	runtime.expect(t, protocol.NewGiveWay("k1"))
	// The ask lasts its tick: still standing at the next, k1 is asked again,
	// and no one else.
	clock.advance(time.Second)
	s.admitTick()
	runtime.expect(t, protocol.NewGiveWay("k1"))
	runtime.quiet(t)
	backends.quiet(t)
	s.mu.Lock()
	s.freePlace(runtime.c, "k1")
	s.mu.Unlock()
	backends.expect(t, protocol.NewPlaced("p2", admission.LimitsOf(protocol.KindProgram, 1100*mibs).MemoryBytes))
}

// A start that finds no room within 17 seconds is refused `no_memory`,
// with what holds the memory: its own athanor's places, each of its own
// role with its subject, and every other athanor's as one sum. No other
// athanor's name and no other role's subject reaches it.
func TestARefusalForRoomSaysWhatHoldsAndNothingOfOthers(t *testing.T) {
	s, runtime, backends, clock := poolKeeper(t, 1300*mibs)
	runtime.write(t, placeLine("floor", "warm", "", ""), placeLine("r1", "warm", "", ""))
	runtime.expect(t, runnerPlaced("floor", 1300*mibs), runnerPlaced("r1", 1300*mibs))
	runtime.write(t, `{"v":9,"type":"assign","id":"a1","place":"r1","kind":"run","athanor":"ath_mine","subject":"cmp_secret"}`)
	runtime.expect(t, protocol.NewAssigned("a1"))
	backends.write(t, placeLine("mine", "program", "ath_mine", "mcp_mine"), placeLine("theirs", "program", "ath_theirs", "mcp_theirs"),
		placeLine("next", "program", "ath_mine", "mcp_next"))
	cap := admission.LimitsOf(protocol.KindProgram, 1300*mibs).MemoryBytes
	backends.expect(t, protocol.NewPlaced("mine", cap), protocol.NewPlaced("theirs", cap))
	backends.sync(t)
	clock.advance(16 * time.Second)
	s.admitTick()
	backends.quiet(t)
	clock.advance(time.Second)
	s.admitTick()
	// 1,136 beside F: the run 164, two sessions 768; 204 free of 384.
	backends.expect(t, protocol.NewNoMemory("next", protocol.Held{Need: 384 * mibs, Free: 204 * mibs,
		Mine:   []protocol.Holding{{Kind: protocol.KindRun, Bytes: 164 * mibs}, {Kind: protocol.KindProgram, Subject: "mcp_mine", Bytes: 384 * mibs}},
		Others: 384 * mibs}))
	backends.write(t, placeLine("next", "program", "ath_mine", "mcp_next"))
	backends.sync(t)
}

// One role that stops reading its channel holds no other role's place and
// not the admission's second: the runtime's channel fills with `placed`
// lines it never reads, and backends' place in a pool with room is still
// answered at once, and the second still steps. The control, with nothing
// stalled, passes alike.
func TestAStalledRoleHoldsNoOtherRolesPlace(t *testing.T) {
	for name, lines := range map[string]int{"stalled": 40000, "control": 0} {
		t.Run(name, func(t *testing.T) {
			s, runtime, backends, _ := poolKeeper(t, 1<<50)
			// Runs first: unblocks the keeper's write so every reader ends.
			t.Cleanup(func() { runtime.theirs.Close() })
			go func() {
				for i := range lines {
					if _, err := runtime.theirs.Write([]byte(placeLine(fmt.Sprintf("w%d", i), "warm", "", "") + "\n")); err != nil {
						return
					}
				}
			}()
			// sleep-ok: the stall's fill has no event to wait on
			time.Sleep(2 * time.Second)
			backends.write(t, placeLine("p1", "program", "ath_a", ""))
			_ = backends.theirs.SetReadDeadline(time.Now().Add(3 * time.Second))
			backends.expect(t, protocol.NewPlaced("p1", admission.LimitsOf(protocol.KindProgram, 1<<50).MemoryBytes))
			ticked := make(chan struct{})
			go func() { s.admitTick(); close(ticked) }()
			select {
			case <-ticked:
			case <-time.After(2 * time.Second):
				t.Fatal("the admission's second did not step within 2 s while the runtime does not read")
			}
		})
	}
}
