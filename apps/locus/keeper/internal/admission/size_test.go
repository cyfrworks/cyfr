// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package admission

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// The pool's numbers are Prima.LocusPool's, by its vector file, which
// names none the keeper does not hold.
func TestThePoolsNumbersArePrimasLocusPools(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "tests", "fixtures", "locus_pool.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Comment        string            `json:"comment"`
		FloorBytes     uint64            `json:"floor_bytes"`
		FloorRunners   int               `json:"floor_runners"`
		RoomWaitMs     int64             `json:"room_wait_ms"`
		AllowanceMs    int64             `json:"allowance_ms"`
		StaleMs        int64             `json:"stale_ms"`
		Kinds          map[string]string `json:"kinds"`
		AllowanceBytes map[string]uint64 `json:"allowance_bytes"`
		CapBytes       map[string]uint64 `json:"cap_bytes"`
		Processors     map[string]uint64 `json:"processors"`
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&v); err != nil {
		t.Fatal(err)
	}
	names := map[string]Class{"runner": Runner, "build": Build, "session": Session}
	ms := func(d time.Duration) int64 { return d.Milliseconds() }
	if v.FloorBytes != FloorBytes || v.FloorRunners != FloorRunners || v.RoomWaitMs != ms(RoomWait) ||
		v.AllowanceMs != ms(AllowanceFor) || v.StaleMs != ms(StaleAfter) {
		t.Fatalf("the vector's numbers %+v differ from the keeper's", v)
	}
	if len(v.Kinds) != len(Kinds) {
		t.Fatalf("the vector's kinds %v, the keeper's %v", v.Kinds, Kinds)
	}
	for kind, class := range v.Kinds {
		if c, ok := Kinds[kind]; !ok || names[class] != c {
			t.Errorf("kind %s: the vector's class %s, the keeper's %v", kind, class, c)
		}
	}
	if len(v.AllowanceBytes) != len(names) || len(v.Processors) != len(names) {
		t.Fatalf("the vector's allowances %v and processors %v name other classes", v.AllowanceBytes, v.Processors)
	}
	for name, class := range names {
		if v.AllowanceBytes[name] != Allowance(class) || v.Processors[name] != Processors[class] {
			t.Errorf("class %s: the vector's allowance %d and processors %d, the keeper's %d and %d", name,
				v.AllowanceBytes[name], v.Processors[name], Allowance(class), Processors[class])
		}
	}
	if len(v.CapBytes) != 2 || v.CapBytes["runner"] != RunnerCapBytes || v.CapBytes["build"] != BuildCapBytes {
		t.Errorf("the vector's caps %v, the keeper's %d and %d", v.CapBytes, RunnerCapBytes, BuildCapBytes)
	}
}

const mib = 1 << 20

// The sizing rule, at the machines the plan names, beside core (a reserve
// of 2,304 MiB and a share of 800): at 8 GiB W is 4,832 and rest 4,668; at
// 4 GiB 608 and 444; at 3,104 MiB and under no work at all. A container's
// own limit below the machine's less the reserve is the budget, and a
// keeper with no floor's role keeps no F.
func TestTheSizingRule(t *testing.T) {
	for name, c := range map[string]struct {
		total, limit    uint64
		limited, floor  bool
		budget, w, rest uint64
	}{
		"8 GiB":                   {7936 * mib, 0, false, true, 5632 * mib, 4832 * mib, 4668 * mib},
		"4 GiB":                   {3712 * mib, 0, false, true, 1408 * mib, 608 * mib, 444 * mib},
		"3,104 MiB":               {3104 * mib, 0, false, true, 800 * mib, 0, 0},
		"under the reserve":       {2048 * mib, 0, false, true, 0, 0, 0},
		"a smaller container":     {7936 * mib, 2048 * mib, true, true, 2048 * mib, 1248 * mib, 1084 * mib},
		"a larger container":      {7936 * mib, 16384 * mib, true, true, 5632 * mib, 4832 * mib, 4668 * mib},
		"W under F":               {3104*mib + 100*mib, 0, false, true, 900 * mib, 100 * mib, 0},
		"no role keeps the floor": {3712 * mib, 0, false, false, 1408 * mib, 608 * mib, 608 * mib},
	} {
		got := Size(c.total, c.limit, c.limited, 2304*mib, 800*mib, c.floor)
		if want := (Sizes{Budget: c.budget, Work: c.w, Rest: c.rest}); got != want {
			t.Errorf("%s: %+v, want %+v", name, got, want)
		}
	}
	if got := Size(2048*mib, 2016*mib, true, 0, 0, false); got != (Sizes{Budget: 2016 * mib, Work: 2016 * mib, Rest: 2016 * mib}) {
		t.Errorf("no reserve and no share: %+v", got)
	}
}
