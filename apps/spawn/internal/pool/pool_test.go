// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package pool

import (
	"reflect"
	"testing"
)

func TestParseSpec(t *testing.T) {
	spec, err := ParseSpec("backends:20001-20032")
	if err != nil {
		t.Fatal(err)
	}
	if spec != (Spec{Name: "backends", First: 20001, Last: 20032}) || spec.Size() != 32 {
		t.Fatalf("spec = %+v size %d", spec, spec.Size())
	}

	for _, bad := range []string{
		"",
		"backends",
		"backends:20001",
		"Backends:1-2",
		"backends:0-10",
		"backends:10-9",
		"backends:+1-2",
		"backends:1-99999999999",
		"backends:1-5000",
		"backends:a-b",
		":1-2",
	} {
		if _, err := ParseSpec(bad); err == nil {
			t.Errorf("%q was accepted", bad)
		}
	}
}

func TestSpecRanges(t *testing.T) {
	a := Spec{Name: "a", First: 10, Last: 20}
	if !a.Contains(10) || !a.Contains(20) || a.Contains(21) || a.Contains(9) {
		t.Fatal("Contains is not inclusive of exactly the range")
	}
	if !a.Overlaps(Spec{First: 20, Last: 30}) || a.Overlaps(Spec{First: 21, Last: 30}) {
		t.Fatal("Overlaps misjudges adjacent ranges")
	}
}

func TestAllocateInOrderUntilExhausted(t *testing.T) {
	p := New(Spec{Name: "p", First: 1, Last: 3})
	var got []int
	for {
		uid, ok := p.Allocate(nil)
		if !ok {
			break
		}
		got = append(got, uid)
	}
	if !reflect.DeepEqual(got, []int{1, 2, 3}) {
		t.Fatalf("allocated %v", got)
	}
	if st := p.Stats(); st != (Stats{Size: 3, InUse: 3}) {
		t.Fatalf("stats %+v", st)
	}
}

func TestReleasedUidIsReusedLast(t *testing.T) {
	p := New(Spec{Name: "p", First: 1, Last: 3})
	first, _ := p.Allocate(nil)
	if err := p.Release(first); err != nil {
		t.Fatal(err)
	}
	var order []int
	for i := 0; i < 3; i++ {
		uid, _ := p.Allocate(nil)
		order = append(order, uid)
	}
	if !reflect.DeepEqual(order, []int{2, 3, 1}) {
		t.Fatalf("order after release %v", order)
	}
}

func TestBusyCandidateIsQuarantinedAndSkipped(t *testing.T) {
	p := New(Spec{Name: "p", First: 1, Last: 3})
	uid, ok := p.Allocate(func(uid int) bool { return uid == 1 })
	if !ok || uid != 2 {
		t.Fatalf("allocated %d %v", uid, ok)
	}
	if !reflect.DeepEqual(p.Quarantined(), []int{1}) {
		t.Fatalf("quarantined %v", p.Quarantined())
	}
	if st := p.Stats(); st != (Stats{Size: 3, Free: 1, InUse: 1, Quarantined: 1}) {
		t.Fatalf("stats %+v", st)
	}
}

func TestQuarantineHoldsUntilReleased(t *testing.T) {
	p := New(Spec{Name: "p", First: 1, Last: 1})
	uid, _ := p.Allocate(nil)
	if err := p.Quarantine(uid); err != nil {
		t.Fatal(err)
	}
	if _, ok := p.Allocate(nil); ok {
		t.Fatal("a quarantined uid was allocated")
	}
	if err := p.Release(uid); err != nil {
		t.Fatal(err)
	}
	if got, ok := p.Allocate(nil); !ok || got != uid {
		t.Fatalf("released quarantined uid not reusable: %d %v", got, ok)
	}
}

func TestInvalidTransitionsAreRefused(t *testing.T) {
	p := New(Spec{Name: "p", First: 1, Last: 2})
	if err := p.Release(1); err == nil {
		t.Error("releasing a free uid was accepted")
	}
	if err := p.Quarantine(1); err == nil {
		t.Error("quarantining a free uid was accepted")
	}
	if err := p.Release(99); err == nil {
		t.Error("releasing a uid outside the pool was accepted")
	}
	if err := p.Quarantine(99); err == nil {
		t.Error("quarantining a uid outside the pool was accepted")
	}
	if st := p.Stats(); st.Free != 2 {
		t.Fatalf("refused transitions changed state: %+v", st)
	}
}
