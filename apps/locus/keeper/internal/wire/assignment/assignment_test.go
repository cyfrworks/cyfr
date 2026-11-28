// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package assignment

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
)

type tokenCase struct {
	Why     string          `json:"why"`
	Token   string          `json:"token"`
	Payload json.RawMessage `json:"payload"`
	Reason  string          `json:"reason"`
}

type vectors struct {
	Assignment struct {
		Token   string `json:"token"`
		Payload string `json:"payload"`
	} `json:"assignment"`
	AssignmentReads struct {
		Valid   []tokenCase `json:"valid"`
		Invalid []tokenCase `json:"invalid"`
	} `json:"assignment_reads"`
	AssignmentServiceReads struct {
		Refused []tokenCase `json:"refused"`
		Read    []tokenCase `json:"read"`
		Carried []tokenCase `json:"carried"`
	} `json:"assignment_service_reads"`
}

func load(t *testing.T) vectors {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "tests", "fixtures", "worker_auth.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v vectors
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

// Every token the vectors give reads, or is refused with its reason, as
// Prima reads it; a token Prima refuses for its actor, or for a part of its
// authority the service does not read, is read and carried.
func TestEveryAssignmentReadsAsTheServiceReadsIt(t *testing.T) {
	v := load(t)
	sr := v.AssignmentServiceReads
	if len(v.AssignmentReads.Invalid) < 50 || len(v.AssignmentReads.Valid) < 6 || len(sr.Refused) < 12 || len(sr.Read) < 3 || len(sr.Carried) < 8 {
		t.Fatalf("%d invalid, %d refused, %d carried", len(v.AssignmentReads.Invalid), len(sr.Refused), len(sr.Carried))
	}
	reads := append(append([]tokenCase{{Why: "the signed token", Token: v.Assignment.Token}}, v.AssignmentReads.Valid...), sr.Read...)
	for _, c := range append(reads, sr.Carried...) {
		if _, err := Read(c.Token); err != nil {
			t.Errorf("%s: %v", c.Why, err)
		}
	}
	for _, c := range v.AssignmentReads.Invalid {
		if _, err := Read(c.Token); err == nil || err.Error() != c.Reason {
			t.Errorf("%s: %v, want %s", c.Why, err, c.Reason)
		}
	}
	for _, c := range sr.Refused {
		if _, err := Read(c.Token); !errors.Is(err, ErrMalformed) {
			t.Errorf("%s: %v, want malformed", c.Why, err)
		}
	}
}

// A read assignment is its payload: each member as the token carries it.
func TestTheSignedTokenReadsAsItsPayload(t *testing.T) {
	v := load(t)
	a, err := Read(v.Assignment.Token)
	if err != nil {
		t.Fatal(err)
	}
	p, err := wirejson.Object([]byte(v.Assignment.Payload))
	if err != nil {
		t.Fatal(err)
	}
	want := func(name string) string { b, _ := wirejson.Write(p[name]); return string(b) }
	got := func(v any) string { b, _ := wirejson.Write(v); return string(b) }
	for name, value := range map[string]any{
		"generation": a.Generation, "service": a.Service, "boot": a.Boot, "member": a.Member,
		"host_url": a.HostURL, "issued_at": a.IssuedAt, "claim_by": a.ClaimBy, "execution_id": a.ExecutionID,
		"attempt": a.Attempt, "fence": a.Fence, "root_execution_id": a.RootExecutionID, "athanor_id": a.AthanorID,
		"actor": a.Actor, "authority": a.AuthorityWire, "input_digest": a.InputDigest, "timeout_ms": a.TimeoutMs,
		"deadline": a.Deadline, "lease_until": a.LeaseUntil,
	} {
		if got(value) != want(name) {
			t.Errorf("%s: %s, want %s", name, got(value), want(name))
		}
	}
	if a.Component.Ref != p["component"].(map[string]any)["ref"] || a.Component.Digest != p["component"].(map[string]any)["digest"] {
		t.Errorf("the component: %+v", a.Component)
	}
}
