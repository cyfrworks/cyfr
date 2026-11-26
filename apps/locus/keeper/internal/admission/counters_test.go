// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package admission

import (
	"fmt"
	"reflect"
	"testing"
	"time"
)

// atMs is t0 plus n milliseconds, exactly.
func atMs(n int64) time.Time { return t0.Add(time.Duration(n) * time.Millisecond) }

// counted says the role's counters are exactly these, by rev.
func counted(t *testing.T, l *Ledger, role string, want ...Counter) {
	t.Helper()
	got := l.Report(role, 0, t0).Counters
	if len(got) == 0 && len(want) == 0 {
		return
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("role %s's counters\n%+v\nwant\n%+v", role, got, want)
	}
}

// program is the counter of a backends program of ath_a and subject on
// the day, as made.
func program(rev uint64, day, subject string) Counter {
	return Counter{Rev: rev, Day: day, Athanor: "ath_a", Kind: "program", Subject: subject}
}

// A place's first reading makes its counter and measures nothing; each
// reading within two seconds of the last measures the time since it, and
// that time at the new reading's bytes, as MiB-milliseconds; a longer gap
// is not measured, and a reading that changes nothing takes no rev.
func TestAReadingMeasuresTheTimeSinceTheLast(t *testing.T) {
	l := New(4096*mib, false)
	a := session("ath_a", "p1")
	admitted(t, l.Place(a, atMs(0)), a)
	l.Spawned(a, atMs(0))
	l.Read(a, 100*mib, false, atMs(0))
	want := program(1, "2026-11-26", "p1")
	want.Bytes, want.PeakBytes = 100*mib, 100*mib
	counted(t, l, "backends", want)

	l.Read(a, 60*mib, false, atMs(1000))
	want.Rev, want.Bytes, want.MeasuredMs, want.MiBMs = 2, 60*mib, 1000, 60*1000
	counted(t, l, "backends", want)

	l.Read(a, 60*mib, false, atMs(3000))
	want.Rev, want.MeasuredMs, want.MiBMs = 3, 3000, 60*3000
	counted(t, l, "backends", want)

	l.Read(a, 60*mib, false, atMs(5001))
	counted(t, l, "backends", want)

	l.Read(a, 80*mib, false, atMs(5500))
	want.Rev, want.Bytes, want.MeasuredMs, want.MiBMs = 4, 80*mib, 3499, 60*3000+80*499
	counted(t, l, "backends", want)
}

// No reading's share is lost to rounding and none overflows: a place of 3
// bytes read every second for 400 seconds has measured 1,200,000
// byte-milliseconds, one MiB-millisecond, and one of 2^63 bytes and more
// read two seconds apart is measured exactly.
func TestNoReadingsShareIsLostToRoundingOrOverflow(t *testing.T) {
	l := New(4096*mib, false)
	small, huge := session("ath_a", "small"), session("ath_a", "huge")
	admitted(t, l.Place(small, atMs(0)), small)
	admitted(t, l.Place(huge, atMs(0)), huge)
	for i := int64(0); i <= 400; i++ {
		l.Read(small, 3, false, atMs(i*1000))
	}
	const big = 1<<63 + 12345
	l.Read(huge, big, false, atMs(398_000))
	l.Read(huge, big, false, atMs(400_000))
	got := l.Report("backends", 0, t0).Counters
	if len(got) != 2 {
		t.Fatalf("counters %+v", got)
	}
	bySubject := map[string]Counter{got[0].Subject: got[0], got[1].Subject: got[1]}
	if s := bySubject["small"]; s.MiBMs != 1 || s.MeasuredMs != 400_000 {
		t.Errorf("3 bytes for 400 s: %+v", s)
	}
	if h := bySubject["huge"]; h.MiBMs != 2000<<43+2000*12345>>20 || h.MeasuredMs != 2000 || h.Bytes != big {
		t.Errorf("2^63 bytes and more for 2 s: %+v", h)
	}
}

// A counter's bytes are its places' latest readings together, each new
// reading in place of its place's last, and its peak the most they held.
func TestACountersBytesAreItsPlacesLatestReadings(t *testing.T) {
	l := New(4096*mib, false)
	a, b := session("ath_a", "p1"), session("ath_a", "p1")
	spawned(t, l, a, 0, 100*mib)
	spawned(t, l, b, 0, 50*mib)
	l.Read(a, 20*mib, false, atMs(500))
	want := program(3, "2026-11-26", "p1")
	want.Bytes, want.PeakBytes, want.MeasuredMs, want.MiBMs = 70*mib, 150*mib, 500, 20*500
	counted(t, l, "backends", want)
}

// A place's bytes follow it: an assign to another athanor or subject moves
// them at once to that counter, a failed assign moves nothing, and its
// drop takes them out.
func TestAPlacesBytesFollowIt(t *testing.T) {
	l := New(4096*mib, true)
	r := runner("runtime")
	spawned(t, l, r, 0, 100*mib)
	if !l.Assign(r, "run", "ath_a", "run-1", atMs(1000)) {
		t.Fatal("the assign was refused")
	}
	warm := Counter{Rev: 2, Day: "2026-11-26", Kind: "warm", PeakBytes: 100 * mib}
	run := Counter{Rev: 3, Day: "2026-11-26", Athanor: "ath_a", Kind: "run", Subject: "run-1", Bytes: 100 * mib, PeakBytes: 100 * mib}
	counted(t, l, "runtime", warm, run)
	if l.Assign(r, "build", "ath_b", "", atMs(1500)) {
		t.Fatal("an assign to another class was applied")
	}
	counted(t, l, "runtime", warm, run)
	l.Drop(r, atMs(2000))
	run.Rev, run.Bytes = 4, 0
	counted(t, l, "runtime", warm, run)
}

// At a day's end the tick moves each place's bytes to its counter of the
// new day: the old day's counter holds none, a change of its own, and the
// next reading is measured on the new day.
func TestADaysEndMovesEachPlacesBytesToTheNewDay(t *testing.T) {
	l := New(4096*mib, false)
	a := session("ath_a", "p1")
	night := 12*time.Hour - 500*time.Millisecond
	admitted(t, l.Place(a, t0.Add(night)), a)
	l.Read(a, 100*mib, false, t0.Add(night))
	l.Tick(t0.Add(night + 700*time.Millisecond))
	l.Read(a, 100*mib, false, t0.Add(night+time.Second))
	old := program(2, "2026-11-26", "p1")
	old.PeakBytes = 100 * mib
	today := program(4, "2026-11-27", "p1")
	today.Bytes, today.PeakBytes, today.MeasuredMs, today.MiBMs = 100*mib, 100*mib, 1000, 100*1000
	counted(t, l, "backends", old, today)
}

// A kill for memory is counted at its place's release in the counter of
// its place's key that day, once for each kill; a place killed before any
// reading makes its counter then, holding no bytes.
func TestAKillIsCountedAtItsRelease(t *testing.T) {
	l := New(4096*mib, false)
	never := session("ath_a", "p1")
	admitted(t, l.Place(never, atMs(0)), never)
	l.Killed(never, KillCap, atMs(100))
	l.Drop(never, atMs(100))
	read := session("ath_a", "p2")
	spawned(t, l, read, 0, 10*mib)
	l.Killed(read, KillMachine, atMs(200))
	l.Drop(read, atMs(200))
	other := session("ath_a", "p2")
	admitted(t, l.Place(other, atMs(0)), other)
	l.Killed(other, KillEither, atMs(300))
	l.Drop(other, atMs(300))
	capped := program(1, "2026-11-26", "p1")
	capped.Cap = 1
	both := program(5, "2026-11-26", "p2")
	both.PeakBytes, both.Machine, both.Either = 10*mib, 1, 1
	counted(t, l, "backends", capped, both)
}

// Each role's changes take its own revs, from 1: another role's report
// never holds them, and a role's places all gone, as at its process's
// death, its counters and revs stay, so its next place's counter takes the
// rev after them.
func TestEachRolesChangesTakeItsOwnRevs(t *testing.T) {
	l := New(4096*mib, true)
	r := runner("runtime")
	a := session("ath_a", "p1")
	spawned(t, l, r, 0, 100*mib)
	spawned(t, l, a, 0, 200*mib)
	l.Read(r, 120*mib, false, atMs(1000))
	warm := Counter{Rev: 2, Day: "2026-11-26", Kind: "warm", Bytes: 120 * mib, PeakBytes: 120 * mib, MeasuredMs: 1000, MiBMs: 120 * 1000}
	mine := program(1, "2026-11-26", "p1")
	mine.Bytes, mine.PeakBytes = 200*mib, 200*mib
	counted(t, l, "runtime", warm)
	counted(t, l, "backends", mine)

	l.Drop(a, atMs(1500))
	next := session("ath_a", "p2")
	spawned(t, l, next, 2, 50*mib)
	mine.Rev, mine.Bytes = 2, 0
	again := program(3, "2026-11-26", "p2")
	again.Bytes, again.PeakBytes = 50*mib, 50*mib
	counted(t, l, "backends", mine, again)
	counted(t, l, "runtime", warm)
}

// A counter goes at the tick 48 hours after its last change and not
// before; a counter holding bytes is changed at every day's end, so it
// stays while its place does, and the old days' counters go 48 hours after
// the day's end that emptied them.
func TestACounterGoesFortyEightHoursAfterItsLastChange(t *testing.T) {
	l := New(4096*mib, false)
	gone, held := session("ath_a", "gone"), session("ath_a", "held")
	spawned(t, l, gone, 0, 10*mib)
	spawned(t, l, held, 0, 20*mib)
	l.Drop(gone, atMs(1000))
	l.Tick(atMs(1000).Add(CounterKeep - time.Millisecond))
	subjects := func() []string {
		var out []string
		for _, c := range l.Report("backends", 0, t0).Counters {
			out = append(out, c.Day+" "+c.Subject)
		}
		return out
	}
	want := []string{"2026-11-26 gone", "2026-11-26 held", "2026-11-28 held"}
	if got := subjects(); !reflect.DeepEqual(got, want) {
		t.Fatalf("a millisecond before 48 hours: %v, want %v", got, want)
	}
	l.Tick(atMs(1000).Add(CounterKeep))
	if got, want := subjects(), want[1:]; !reflect.DeepEqual(got, want) {
		t.Fatalf("at 48 hours: %v, want %v", got, want)
	}
	// The tick that moved held's bytes to the 28th emptied the 26th's; this
	// one moves them on to the 30th, emptying the 28th's.
	emptied := atMs(1000).Add(CounterKeep - time.Millisecond)
	l.Tick(emptied.Add(CounterKeep))
	if got, want := subjects(), []string{"2026-11-28 held", "2026-11-30 held"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("48 hours after the day's end that emptied it: %v, want %v", got, want)
	}
}

// At the most counters a new one first lets the oldest of a past day that
// holds no bytes go, oldest by its last change, then by its rev; one of
// today never goes, and with none free to go the use is not counted and
// the uncounted count grows.
func TestAtTheMostCountersTheOldestEmptyOfAPastDayGoes(t *testing.T) {
	l := New(4096*mib, false)
	l.counters.max = 3
	a, b, c := session("ath_a", "a"), session("ath_a", "b"), session("ath_a", "c")
	for _, e := range []*Entry{a, b, c} {
		spawned(t, l, e, 0, 10*mib)
	}
	l.Drop(b, atMs(1000))
	l.Drop(a, atMs(1000))
	day2 := t0.Add(13 * time.Hour)
	// c's move to the 27th lets b go: a and b emptied at once, b first.
	l.Tick(day2)
	days := func() []string {
		var out []string
		for _, k := range l.Report("backends", 0, day2).Counters {
			out = append(out, k.Day+" "+k.Subject)
		}
		return out
	}
	if got, want := days(), []string{"2026-11-26 a", "2026-11-26 c", "2026-11-27 c"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("after the day's end: %v, want %v", got, want)
	}
	d, e, f := session("ath_a", "d"), session("ath_a", "e"), session("ath_a", "f")
	for _, x := range []*Entry{d, e, f} {
		admitted(t, l.Place(x, day2), x)
	}
	l.Read(d, 1*mib, false, day2)
	l.Read(e, 1*mib, false, day2.Add(time.Millisecond))
	// d's counter, of today, holds no bytes once d goes, and still stays.
	l.Drop(d, day2.Add(2*time.Millisecond))
	l.Read(f, 1*mib, false, day2.Add(3*time.Millisecond))
	if got, want := days(), []string{"2026-11-27 c", "2026-11-27 e", "2026-11-27 d"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("today's three: %v, want %v", got, want)
	}
	if l.Uncounted() != 1 {
		t.Fatalf("uncounted %d after f's reading", l.Uncounted())
	}
	l.Killed(f, KillCap, day2.Add(time.Second))
	if l.Uncounted() != 2 {
		t.Fatalf("uncounted %d after f's kill", l.Uncounted())
	}
}

// A report is the role's counters past its after, by rev, a page of at most
// ReportCounters naming its last rev as next while more follow, beside W,
// F where a role keeps the floor, and every charge outside the floor.
func TestAReportPagesARolesCountersByRev(t *testing.T) {
	l := New(1<<50, true)
	floor := runner("runtime")
	spawned(t, l, floor, 0, 100*mib)
	for i := range ReportCounters + 44 {
		spawned(t, l, session("ath_a", fmt.Sprintf("p%03d", i)), 0, 1*mib)
	}
	first := l.Report("backends", 0, at(0))
	if len(first.Counters) != ReportCounters || first.Next != ReportCounters {
		t.Fatalf("the first page: %d counters, next %d", len(first.Counters), first.Next)
	}
	for i, c := range first.Counters {
		if c.Rev != uint64(i+1) || c.Subject != fmt.Sprintf("p%03d", i) {
			t.Fatalf("the first page's counter %d: %+v", i, c)
		}
	}
	second := l.Report("backends", first.Next, at(0))
	if len(second.Counters) != 44 || second.Next != 0 || second.Counters[0].Rev != ReportCounters+1 {
		t.Fatalf("the second page: %d counters from rev %d, next %d", len(second.Counters), second.Counters[0].Rev, second.Next)
	}
	if last := l.Report("backends", ReportCounters+44, at(0)); len(last.Counters) != 0 || last.Next != 0 {
		t.Fatalf("past the last rev: %+v", last)
	}
	runtime := l.Report("runtime", 0, at(0))
	if len(runtime.Counters) != 1 || runtime.Counters[0].Kind != "warm" {
		t.Fatalf("the runtime's report: %+v", runtime.Counters)
	}
	if runtime.Work != 1<<50 || runtime.Floor != FloorBytes || runtime.Used != (ReportCounters+44)*Allowance(Session) {
		t.Fatalf("the machine's numbers: work %d, floor %d, used %d", runtime.Work, runtime.Floor, runtime.Used)
	}
	if none := New(1<<30, false).Report("backends", 0, at(0)); none.Floor != 0 || none.Used != 0 || len(none.Counters) != 0 {
		t.Fatalf("a keeper keeping no floor: %+v", none)
	}
}
