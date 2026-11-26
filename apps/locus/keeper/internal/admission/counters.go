// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package admission

import (
	"cmp"
	"math/bits"
	"slices"
	"time"
)

// The counters' numbers, each Prima.LocusPool's (its counters), which
// tests/fixtures/locus_pool.json carries to this package's test.
const (
	// MaxCounters is the most counters the keeper holds at once.
	MaxCounters = 16384
	// ReportCounters is the most counters one report carries.
	ReportCounters = 256
	// CounterKeep is how long a counter is kept after its last change.
	CounterKeep = 48 * time.Hour
	// ReadingGap is the longest time between two readings of a place that
	// is counted as measured: a longer one is not counted at all.
	ReadingGap = 2 * time.Second
)

// Counter is what the keeper counted of one role's places of one kind,
// athanor and subject on one UTC day, as of its last change, Rev: the
// bytes its places' latest readings hold, the MiB-milliseconds and the
// milliseconds its readings measured, the most bytes it held at once, and
// the kills for memory at its places' releases.
type Counter struct {
	Rev                    uint64
	Day                    string
	Athanor, Kind, Subject string
	Bytes                  uint64
	MiBMs                  uint64
	MeasuredMs             uint64
	PeakBytes              uint64
	Cap, Machine, Either   uint64
}

// The memory kills a place's release may count, an `exited`'s `memory`.
const (
	KillCap     = "cap"
	KillMachine = "machine"
	KillEither  = "either"
)

// Report is a page of one role's counters past a rev, beside the machine's
// numbers: W, F where kept, else 0, and every charge outside the floor.
// Next is the page's last rev when more follow, else 0: every rev is at
// least 1.
type Report struct {
	Work, Floor, Used uint64
	Counters          []Counter
	Next              uint64
}

// counterKey is whose a counter counts: the role's name, the UTC day and
// whose its places were.
type counterKey struct {
	role, day, athanor, kind, subject string
}

type counter struct {
	Counter
	role    string
	changed time.Time
	// byteMs is what its readings measured below one MiB-millisecond, kept
	// so that no reading's share is lost to rounding.
	byteMs uint64
}

// counters is what the ledger counts of who used what, by role, for
// CounterKeep: every role's counters and each role's last rev, which a
// role's restart keeps, since both are by its name.
type counters struct {
	// max is the most counters held, MaxCounters but in a test.
	max  int
	held map[counterKey]*counter
	revs map[string]uint64
	// uncounted is how many uses went uncounted since the boot, with every
	// counter held and none of them free to go.
	uncounted uint64
}

func newCounters() counters {
	return counters{max: MaxCounters, held: map[counterKey]*counter{}, revs: map[string]uint64{}}
}

func dayOf(now time.Time) string { return now.UTC().Format(time.DateOnly) }

func (e *Entry) keyAt(now time.Time) counterKey {
	return counterKey{role: e.Role, day: dayOf(now), athanor: e.Athanor, kind: e.Kind, subject: e.Subject}
}

// at is the counter of key, made if it is not held; nil when it cannot be
// made, every counter held and none free to go. Making one at the most
// first lets the oldest counter of a past day that holds no bytes go:
// oldest by its last change, then by its role and rev, each unique.
func (cs *counters) at(key counterKey, now time.Time) *counter {
	if c := cs.held[key]; c != nil {
		return c
	}
	if len(cs.held) >= cs.max {
		var oldest *counter
		var oldestKey counterKey
		for k, c := range cs.held {
			if c.Day >= key.day || c.Bytes > 0 {
				continue
			}
			if oldest == nil || older(c, oldest) {
				oldest, oldestKey = c, k
			}
		}
		if oldest == nil {
			cs.uncounted++
			return nil
		}
		delete(cs.held, oldestKey)
	}
	c := &counter{Counter: Counter{Day: key.day, Athanor: key.athanor, Kind: key.kind, Subject: key.subject}, role: key.role}
	cs.held[key] = c
	return c
}

func older(a, b *counter) bool {
	if n := a.changed.Compare(b.changed); n != 0 {
		return n < 0
	}
	if n := cmp.Compare(a.role, b.role); n != 0 {
		return n < 0
	}
	return a.Rev < b.Rev
}

// change gives c its role's next rev at now if it changed since before, in
// any field, or was made since: a counter made has no rev yet.
func (cs *counters) change(c *counter, before Counter, now time.Time) {
	if before.Rev != 0 && c.Counter == before {
		return
	}
	cs.revs[c.role]++
	c.Rev, c.changed = cs.revs[c.role], now
}

// withdraw takes e's bytes out of the counter they are in.
func (cs *counters) withdraw(e *Entry, now time.Time) {
	if c := e.counted; c != nil {
		before := c.Counter
		c.Bytes -= e.countedBytes
		cs.change(c, before, now)
	}
	e.counted, e.countedBytes = nil, 0
}

// deposit puts bytes of e's in the counter of its key at now, made if it is
// not held, or counts them as uncounted.
func (cs *counters) deposit(e *Entry, bytes uint64, now time.Time) {
	c := cs.at(e.keyAt(now), now)
	if c == nil {
		return
	}
	before := c.Counter
	c.Bytes += bytes
	c.PeakBytes = max(c.PeakBytes, c.Bytes)
	e.counted, e.countedBytes = c, bytes
	cs.change(c, before, now)
}

// move moves e's bytes to the counter of its key at now, where they are not
// already.
func (cs *counters) move(e *Entry, now time.Time) {
	if e.counted == nil || e.counted == cs.held[e.keyAt(now)] {
		return
	}
	bytes := e.countedBytes
	cs.withdraw(e, now)
	cs.deposit(e, bytes, now)
}

// read counts a reading of e of bytes, gap after its last reading within
// ReadingGap (0 for none): the counter of its key at now holds the reading
// in place of e's last, and gains gap as measured and gap times bytes as
// MiB-milliseconds.
func (cs *counters) read(e *Entry, bytes uint64, gap time.Duration, now time.Time) {
	key := e.keyAt(now)
	if e.counted != nil && e.counted != cs.held[key] {
		cs.withdraw(e, now)
	}
	c := cs.at(key, now)
	if c == nil {
		return
	}
	before := c.Counter
	if e.counted == c {
		c.Bytes -= e.countedBytes
	}
	c.Bytes += bytes
	c.PeakBytes = max(c.PeakBytes, c.Bytes)
	e.counted, e.countedBytes = c, bytes
	ms := uint64(gap.Milliseconds())
	c.MeasuredMs += ms
	// gap * bytes in whole MiB-milliseconds, its remainder kept: ms is at
	// most ReadingGap's 2,000, so the product's high word is under 2^11 and
	// the sum with a remainder under 2^20 shifts into 64 bits exactly.
	hi, lo := bits.Mul64(ms, bytes)
	lo, carry := bits.Add64(lo, c.byteMs, 0)
	hi += carry
	c.MiBMs += hi<<44 | lo>>20
	c.byteMs = lo & (1<<20 - 1)
	cs.change(c, before, now)
}

// killed counts a kill for memory, cause, at e's release at now.
func (cs *counters) killed(e *Entry, cause string, now time.Time) {
	c := cs.at(e.keyAt(now), now)
	if c == nil {
		return
	}
	before := c.Counter
	switch cause {
	case KillCap:
		c.Cap++
	case KillMachine:
		c.Machine++
	case KillEither:
		c.Either++
	}
	cs.change(c, before, now)
}

// sweep lets every counter go CounterKeep after its last change, unless it
// holds bytes.
func (cs *counters) sweep(now time.Time) {
	for k, c := range cs.held {
		if c.Bytes == 0 && now.Sub(c.changed) >= CounterKeep {
			delete(cs.held, k)
		}
	}
}

// report is the role's counters past after, by rev, at most
// ReportCounters, and the last one's rev when more follow.
func (cs *counters) report(role string, after uint64) ([]Counter, uint64) {
	var page []Counter
	for _, c := range cs.held {
		if c.role == role && c.Rev > after {
			page = append(page, c.Counter)
		}
	}
	slices.SortFunc(page, func(a, b Counter) int { return cmp.Compare(a.Rev, b.Rev) })
	if len(page) <= ReportCounters {
		return page, 0
	}
	page = page[:ReportCounters]
	return page, page[len(page)-1].Rev
}
