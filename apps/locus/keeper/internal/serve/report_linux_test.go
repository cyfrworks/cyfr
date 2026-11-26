// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/internal/admission"
	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// spawnIn holds a spawn in the role's admitted place id, as one that
// claimed it and started: the reader reads it as readsAs says.
func (r *poolRole) spawnIn(t *testing.T, s *server, id string) *spawn {
	t.Helper()
	if got, _ := s.claimPlace(r.c, &protocol.Request{Place: id}); got != claimed {
		t.Fatalf("role %s's place %s cannot be claimed", r.c.role.spec.Name, id)
	}
	sp := &spawn{id: randomHex(16), client: r.c, retired: make(chan struct{})}
	s.madeIn(id, sp)
	s.mu.Lock()
	s.spawns[sp.id] = sp
	s.mu.Unlock()
	return sp
}

// report asks for the role's counters past after on its channel and
// answers the `reported`, which must be nothing more.
func (r *poolRole) report(t *testing.T, after uint64) protocol.Reported {
	t.Helper()
	r.write(t, fmt.Sprintf(`{"v":8,"type":"report","id":"rp","after":%d}`, after))
	line, _, err := r.channel.Next()
	if err != nil {
		t.Fatalf("role %s's report: %v", r.c.role.spec.Name, err)
	}
	var got protocol.Reported
	dec := json.NewDecoder(bytes.NewReader(line))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&got); err != nil || got.Type != protocol.TypeReported || got.ID != "rp" {
		t.Fatalf("role %s's report answered %s: %v", r.c.role.spec.Name, line, err)
	}
	return got
}

// programPlaced is the `placed` of a program's place on a pool of work W.
func programPlaced(id string, work uint64) protocol.Placed {
	return protocol.NewPlaced(id, admission.LimitsOf(protocol.KindProgram, work).MemoryBytes)
}

// reported is the `reported` of s's counters, its boot and its machine's
// numbers as poolKeeper makes them.
func reported(s *server, work, used uint64, next uint64, counters ...protocol.Counter) protocol.Reported {
	return protocol.NewReported("rp", protocol.Report{Boot: s.boot, Budget: 2 * work, Work: work, Floor: admission.FloorBytes,
		Used: used, Counters: counters, Next: next})
}

// A report on a role's channel holds that role's counters alone, each
// once: the floor's role's runner and the session's role's program, read
// twice a second apart, are each in their own role's report.
func TestAReportHoldsTheAskingRolesCountersAlone(t *testing.T) {
	const work = 4096 * mibs
	s, runtime, backends, clock := poolKeeper(t, work)
	readsAs(t, func(*cgroup.Group) (cgroup.Use, error) { return cgroup.Use{Bytes: 100 * mibs}, nil })
	runtime.write(t, placeLine("w", protocol.KindWarm, "", ""))
	runtime.expect(t, runnerPlaced("w", work))
	backends.write(t, placeLine("p", protocol.KindProgram, "ath_a", "mcp_1"))
	backends.expect(t, programPlaced("p", work))
	runtime.spawnIn(t, s, "w")
	backends.spawnIn(t, s, "p")
	s.read()()
	clock.advance(time.Second)
	s.read()()

	counter := protocol.Counter{Rev: 2, Day: "2026-11-26", Bytes: 100 * mibs, MiBMs: 100 * 1000, MeasuredMs: 1000, PeakBytes: 100 * mibs}
	warm, program := counter, counter
	warm.Kind = protocol.KindWarm
	program.Kind, program.Athanor, program.Subject = protocol.KindProgram, "ath_a", "mcp_1"
	// The program's place is charged its allowance for its first ten
	// seconds; the runner is the floor's, charged nothing outside it.
	used := admission.Allowance(admission.Session)
	if got, want := runtime.report(t, 0), reported(s, work, used, 0, warm); !reflect.DeepEqual(got, want) {
		t.Fatalf("the runtime's report %+v, want %+v", got, want)
	}
	if got, want := backends.report(t, 0), reported(s, work, used, 0, program); !reflect.DeepEqual(got, want) {
		t.Fatalf("the backends' report %+v, want %+v", got, want)
	}
	if got := backends.report(t, 2); len(got.Report.Counters) != 0 || got.Report.Next != 0 {
		t.Fatalf("the backends' report past their last rev: %+v", got)
	}
}

// A kill for memory its exit settled is counted once, at the spawn's
// release with its place: not while its group stays, once the retry
// removes it, and in a counter made then for a place never read.
func TestAKillIsCountedOnceAtItsSpawnsRelease(t *testing.T) {
	const work = 4096 * mibs
	s, _, backends, _ := poolKeeper(t, work)
	readsAs(t, func(*cgroup.Group) (cgroup.Use, error) { return cgroup.Use{Bytes: 50 * mibs}, nil })
	backends.write(t, placeLine("p1", protocol.KindProgram, "ath_a", "mcp_1"), placeLine("p2", protocol.KindProgram, "ath_a", "mcp_2"))
	backends.expect(t, programPlaced("p1", work), programPlaced("p2", work))
	read := backends.spawnIn(t, s, "p1")
	s.read()()
	never := backends.spawnIn(t, s, "p2")
	s.mu.Lock()
	read.killedFor, never.killedFor = protocol.MemoryCap, protocol.MemoryEither
	s.leave(read, false, removal{})
	s.mu.Unlock()

	first := protocol.Counter{Rev: 1, Day: "2026-11-26", Athanor: "ath_a", Kind: protocol.KindProgram, Subject: "mcp_1",
		Bytes: 50 * mibs, PeakBytes: 50 * mibs}
	used := 2 * admission.Allowance(admission.Session)
	if got, want := backends.report(t, 0), reported(s, work, used, 0, first); !reflect.DeepEqual(got, want) {
		t.Fatalf("with its group still standing %+v, want %+v", got, want)
	}
	s.retryRemoval(read, func(*cgroup.Group) error { return nil })
	s.retryRemovals()()
	s.mu.Lock()
	s.leave(never, true, removal{})
	s.mu.Unlock()

	first.Rev, first.Bytes, first.Cap = 3, 0, 1
	second := protocol.Counter{Rev: 4, Day: "2026-11-26", Athanor: "ath_a", Kind: protocol.KindProgram, Subject: "mcp_2", Either: 1}
	if got, want := backends.report(t, 0), reported(s, work, 0, 0, first, second); !reflect.DeepEqual(got, want) {
		t.Fatalf("after both releases %+v, want %+v", got, want)
	}
}

// A role's next start, a client of its own on a channel of its own, reports
// at the same boot the counters its last start's places left, their bytes
// gone with them, and its own changes take the revs after theirs.
func TestARolesNextStartReportsItsCountersOnAtTheSameBoot(t *testing.T) {
	const work = 4096 * mibs
	s, _, backends, _ := poolKeeper(t, work)
	readsAs(t, func(*cgroup.Group) (cgroup.Use, error) { return cgroup.Use{Bytes: 100 * mibs}, nil })
	backends.write(t, placeLine("p", protocol.KindProgram, "ath_a", "mcp_1"))
	backends.expect(t, programPlaced("p", work))
	sp := backends.spawnIn(t, s, "p")
	s.read()()
	before := backends.report(t, 0)

	// Its end releases its spawn with its place, as endClient's retirement
	// of each does, and its next start is another client of the role.
	s.mu.Lock()
	backends.c.ended = true
	s.leave(sp, true, removal{})
	s.mu.Unlock()
	next := served(t, s, "backends-again", func(channel *os.File) *client {
		return &client{role: backends.c.role, id: randomHex(16), channel: channel, places: map[string]*place{}, wake: make(chan struct{}, 1)}
	})

	left := protocol.Counter{Rev: 2, Day: "2026-11-26", Athanor: "ath_a", Kind: protocol.KindProgram, Subject: "mcp_1", PeakBytes: 100 * mibs}
	got := next.report(t, 0)
	if want := reported(s, work, 0, 0, left); !reflect.DeepEqual(got, want) || got.Report.Boot != before.Report.Boot {
		t.Fatalf("the next start's report %+v, want %+v at boot %s", got, want, before.Report.Boot)
	}
	next.write(t, placeLine("p", protocol.KindProgram, "ath_a", "mcp_1"))
	next.expect(t, programPlaced("p", work))
	next.spawnIn(t, s, "p")
	s.read()()
	left.Rev, left.Bytes = 3, 100*mibs
	if got, want := next.report(t, 2), reported(s, work, admission.Allowance(admission.Session), 0, left); !reflect.DeepEqual(got, want) {
		t.Fatalf("the next start's own change %+v, want %+v", got, want)
	}
}

// Each start of the keeper mints a boot id of its own, 32 lowercase hex
// digits, and counts afresh: a second start reports no counters and its
// first change takes rev 1.
func TestEachStartOfTheKeeperHasItsOwnBootAndCountsAfresh(t *testing.T) {
	const work = 4096 * mibs
	readsAs(t, func(*cgroup.Group) (cgroup.Use, error) { return cgroup.Use{Bytes: 10 * mibs}, nil })
	var boots []string
	for range 2 {
		s, _, backends, _ := poolKeeper(t, work)
		if got, want := backends.report(t, 0), reported(s, work, 0, 0); !reflect.DeepEqual(got, want) {
			t.Fatalf("a start's first report %+v, want %+v", got, want)
		}
		backends.write(t, placeLine("p", protocol.KindProgram, "ath_a", "mcp_1"))
		backends.expect(t, programPlaced("p", work))
		backends.spawnIn(t, s, "p")
		s.read()()
		if got := backends.report(t, 0).Report.Counters; len(got) != 1 || got[0].Rev != 1 {
			t.Fatalf("a start's first change: %+v", got)
		}
		boots = append(boots, s.boot)
	}
	hex := regexp.MustCompile(`^[0-9a-f]{32}$`)
	if !hex.MatchString(boots[0]) || !hex.MatchString(boots[1]) || boots[0] == boots[1] {
		t.Fatalf("the two starts' boots: %q", boots)
	}
}

// A report pages a role's counters by rev, at most admission's
// ReportCounters to a page, naming the page's last rev as next while more
// follow, each counter on one page alone.
func TestAReportPagesARolesCounters(t *testing.T) {
	const work = 1 << 50
	const places = admission.ReportCounters + 44
	s, _, backends, _ := poolKeeper(t, work)
	readsAs(t, func(*cgroup.Group) (cgroup.Use, error) { return cgroup.Use{Bytes: mibs}, nil })
	for i := range places {
		id := fmt.Sprintf("p%03d", i)
		backends.write(t, placeLine(id, protocol.KindProgram, "ath_a", "mcp_"+id))
		backends.expect(t, programPlaced(id, work))
		backends.spawnIn(t, s, id)
	}
	s.read()()
	first := backends.report(t, 0).Report
	if len(first.Counters) != admission.ReportCounters || first.Next != admission.ReportCounters {
		t.Fatalf("the first page: %d counters, next %d", len(first.Counters), first.Next)
	}
	second := backends.report(t, first.Next).Report
	if len(second.Counters) != places-admission.ReportCounters || second.Next != 0 {
		t.Fatalf("the second page: %d counters, next %d", len(second.Counters), second.Next)
	}
	subjects := map[string]bool{}
	for i, c := range append(first.Counters, second.Counters...) {
		if c.Rev != uint64(i+1) || subjects[c.Subject] || !strings.HasPrefix(c.Subject, "mcp_p") {
			t.Fatalf("counter %d of the pages: %+v", i, c)
		}
		subjects[c.Subject] = true
	}
}
