// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package assignment

import (
	"encoding/json"
	"errors"
	"reflect"
	"testing"

	"github.com/cyfr/locus/keeper/internal/wire/authority"
	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
	"github.com/cyfr/locus/keeper/internal/wire/wiretest"
)

// authSections are the sections of tests/fixtures/worker_auth.json this test reads.
type authSections struct {
	Assignment struct {
		Token string `json:"token"`
		// The token's MAC, the clock it was made at and its payload,
		// which Prima's test reads.
		MAC     json.RawMessage `json:"mac"`
		Now     json.RawMessage `json:"now"`
		Payload json.RawMessage `json:"payload"`
	} `json:"assignment"`
	AssignmentReads struct {
		Valid   json.RawMessage `json:"valid"`
		Invalid json.RawMessage `json:"invalid"`
	} `json:"assignment_reads"`
	AssignmentServiceReads struct {
		Refused json.RawMessage `json:"refused"`
		Read    json.RawMessage `json:"read"`
		Carried json.RawMessage `json:"carried"`
	} `json:"assignment_service_reads"`
}

func authVectors(t *testing.T) authSections {
	t.Helper()
	var s authSections
	wiretest.Load(t, "worker_auth.json", &s)
	return s
}

type tokenCase struct {
	Why     string          `json:"why"`
	Token   string          `json:"token"`
	Payload json.RawMessage `json:"payload"`
	Reason  string          `json:"reason"`
	// Go is the Go reader's own answer where the two ends differ: on a
	// read case alone.
	Go *struct {
		Error string `json:"error"`
	} `json:"go"`
}

// cases are a section's token cases, each with exactly its kind's members:
// a marker a reader does not know, or one on a case of another kind, fails.
func cases(t *testing.T, raw json.RawMessage, least int, required []string, marked bool) []tokenCase {
	t.Helper()
	var out []tokenCase
	for _, r := range wiretest.Cases(t, raw, least) {
		var members map[string]json.RawMessage
		if err := json.Unmarshal(r, &members); err != nil {
			t.Fatal(err)
		}
		for name := range members {
			known := name == "go" && marked
			for _, k := range required {
				known = known || k == name
			}
			if !known {
				t.Fatalf("a case with a member its kind has not, %s: %s", name, r)
			}
		}
		var c tokenCase
		wiretest.Decode(t, r, &c, required)
		if c.Go != nil && c.Go.Error != ErrMalformed.Error() {
			t.Fatalf("a marked case whose go.error is no refusal of the reader's: %s", r)
		}
		out = append(out, c)
	}
	return out
}

// payloadOf is every member of the payload a worker service reads, as the
// payload spells it: all of them but the version, the actor and the
// authority, which the token alone carries on.
func payloadOf(a Assignment) map[string]any {
	p := map[string]any{
		"generation": a.Generation, "service": a.Service, "boot": a.Boot, "member": a.Member,
		"issued_at": a.IssuedAt, "claim_by": a.ClaimBy, "execution_id": a.ExecutionID,
		"attempt": a.Attempt, "fence": a.Fence, "root_execution_id": a.RootExecutionID, "athanor_id": a.AthanorID,
		"input_digest": a.InputDigest, "timeout_ms": a.TimeoutMs, "deadline": a.Deadline, "lease_until": a.LeaseUntil,
	}
	if a.HostURL != "" {
		p["host_url"] = a.HostURL
	}
	if a.ParentExecutionID != "" {
		p["parent_execution_id"] = a.ParentExecutionID
	}
	if a.Step != nil {
		p["step"] = map[string]any{"id": a.Step.ID, "generation": a.Step.Generation}
	}
	needs := []any{}
	for _, n := range a.Component.DeclaredNeeds {
		needs = append(needs, n)
	}
	component := map[string]any{"ref": a.Component.Ref, "type": a.Component.Type, "digest": a.Component.Digest, "declared_needs": needs}
	if a.Component.ActivationDigest != "" {
		component["activation_digest"] = a.Component.ActivationDigest
	}
	p["component"] = component
	intercepted := []any{}
	for _, n := range a.Intercepted {
		intercepted = append(intercepted, n)
	}
	p["intercepted"] = intercepted
	return p
}

// read reads a token and holds what it read to the token's own payload,
// and to the case's payload where it gives one: every member the service
// reads, the token kept as given, and the authority's limits and egress as
// the authority's own read of them.
func read(t *testing.T, why, token string, casePayload json.RawMessage) error {
	t.Helper()
	a, err := Read(token)
	if err != nil {
		return err
	}
	payload, ok := split(token)
	if !ok {
		t.Fatalf("%s: read, and its payload no payload", why)
	}
	wire, err := wirejson.Object(payload)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{}
	for name, value := range wire {
		if name != "v" && name != "actor" && name != "authority" {
			want[name] = value
		}
	}
	got, _ := wirejson.Write(payloadOf(a))
	wanted, _ := wirejson.Write(want)
	if string(got) != string(wanted) {
		t.Errorf("%s: read as %s\nits payload %s", why, got, wanted)
	}
	if casePayload != nil {
		given, err := wirejson.Read(casePayload)
		if err != nil {
			t.Fatal(err)
		}
		stated := map[string]any{}
		for name, value := range given.(map[string]any) {
			if name != "v" && name != "actor" && name != "authority" {
				stated[name] = value
			}
		}
		if s, _ := wirejson.Write(stated); string(s) != string(got) {
			t.Errorf("%s: read as %s\nthe case's payload %s", why, got, s)
		}
	}
	auth, err := authority.Read(wire["authority"])
	if err != nil || !reflect.DeepEqual(a.Authority, auth) || a.Token != token {
		t.Errorf("%s: its authority %+v, its token kept %v", why, a.Authority, a.Token == token)
	}
	return nil
}

// Every token the vectors give reads, or is refused with its reason, as
// Prima reads it, a read one held to its payload; a token Prima refuses
// for its actor, or for a part of its authority the service does not
// read, is read and carried, the token as given.
func TestEveryAssignmentReadsAsTheServiceReadsIt(t *testing.T) {
	top := authVectors(t)
	reads, service := top.AssignmentReads, top.AssignmentServiceReads
	all := append([]tokenCase{{Why: "the signed token", Token: top.Assignment.Token}},
		cases(t, reads.Valid, 6, []string{"why", "token", "payload"}, false)...)
	all = append(all, cases(t, service.Read, 4, []string{"why", "token"}, true)...)
	all = append(all, cases(t, service.Carried, 8, []string{"why", "token"}, false)...)
	differences := 0
	for _, c := range all {
		err := read(t, c.Why, c.Token, c.Payload)
		switch {
		case c.Go != nil:
			differences++
			if err == nil || err.Error() != c.Go.Error {
				t.Errorf("%s: %v; Go refuses it %s", c.Why, err, c.Go.Error)
			}
		case err != nil:
			t.Errorf("%s: %v", c.Why, err)
		}
	}
	if differences == 0 {
		t.Error("no token states the depth the two ends differ at")
	}
	for _, c := range cases(t, reads.Invalid, 50, []string{"why", "token", "reason"}, false) {
		if _, err := Read(c.Token); err == nil || err.Error() != c.Reason {
			t.Errorf("%s: %v, want %s", c.Why, err, c.Reason)
		}
	}
	for _, c := range cases(t, service.Refused, 12, []string{"why", "token"}, false) {
		if _, err := Read(c.Token); !errors.Is(err, ErrMalformed) {
			t.Errorf("%s: %v, want malformed", c.Why, err)
		}
	}
}
