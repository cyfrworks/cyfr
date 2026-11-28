// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package pinned

import (
	"encoding/json"
	"reflect"
	"testing"

	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
	"github.com/cyfr/locus/keeper/internal/wire/wiretest"
)

// hostSections are the sections of tests/fixtures/host_api.json this test reads.
type hostSections struct {
	PinAnswerRefusals json.RawMessage `json:"pin_answer_refusals"`
	PinExpiry         json.RawMessage `json:"pin_expiry"`
	PinRequests       json.RawMessage `json:"pin_requests"`
	PinPurposes       []string        `json:"pin_purposes"`
	PinRefusalNames   []string        `json:"pin_refusal_names"`
}

func hostVectors(t *testing.T) hostSections {
	t.Helper()
	var s hostSections
	wiretest.Load(t, "host_api.json", &s)
	return s
}

type pinCase struct {
	Why string          `json:"why"`
	Pin json.RawMessage `json:"pin"`
}

func decoded(t *testing.T, raw json.RawMessage) any {
	t.Helper()
	v, err := wirejson.Read(raw)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func pinCases(t *testing.T, raw json.RawMessage, least int) []pinCase {
	t.Helper()
	var out []pinCase
	for _, r := range wiretest.Cases(t, raw, least) {
		var c pinCase
		wiretest.Decode(t, r, &c, []string{"why", "pin"})
		out = append(out, c)
	}
	return out
}

// Every pin reads, or is refused, as Prima.PinnedTarget.read/1 reads it:
// its address and bracketed host as Prima reads an address, zones and
// all and no sign in it, its family an integer, and an ip that is no
// address refused whatever family it declares.
func TestEveryPinReadsOrIsRefusedAsPrimaReadsIt(t *testing.T) {
	top := hostVectors(t)
	var section struct {
		Pin      json.RawMessage `json:"pin"`
		Reads    json.RawMessage `json:"reads"`
		Refusals json.RawMessage `json:"refusals"`
	}
	wiretest.Decode(t, top.PinAnswerRefusals, &section, []string{"pin", "reads", "refusals"})
	reads := append([]pinCase{{Why: "the pin", Pin: section.Pin}}, pinCases(t, section.Reads, 12)...)
	for _, c := range reads {
		if _, ok := Read(decoded(t, c.Pin)); !ok {
			t.Errorf("%s: refused", c.Why)
		}
	}
	for _, c := range pinCases(t, section.Refusals, 36) {
		if p, ok := Read(decoded(t, c.Pin)); ok {
			t.Errorf("%s: read as %+v", c.Why, p)
		}
	}
}

// A pin whose ip is no address is refused whatever family it declares,
// 0 and -0 among them (the review's probe).
func TestAPinWithNoAddressIsRefused(t *testing.T) {
	for _, raw := range []string{
		`{"expires_at":1789305280602,"family":0,"host":"api.example.test","id":"pin_Vx1","ip":"metadata.google.internal","port":443,"scheme":"https"}`,
		`{"expires_at":1789305280602,"family":0,"host":"api.example.test","id":"pin_Vx1","ip":"","port":443,"scheme":"https"}`,
		`{"expires_at":1789305280602,"family":-0,"host":"api.example.test","id":"pin_Vx1","ip":"169.254.169.254:80","port":443,"scheme":"https"}`,
		`{"expires_at":1789305280602,"family":0,"host":"[fe80::1%0x]","id":"pin_Vx1","ip":"203.0.113.10","port":443,"scheme":"https"}`,
	} {
		if p, ok := Read(decoded(t, json.RawMessage(raw))); ok {
			t.Errorf("read as %+v: %s", p, raw)
		}
	}
	for _, ip := range []string{"", "metadata.google.internal", "169.254.169.254:80", "1.2.3.+4"} {
		if family, ok := Family(ip); ok {
			t.Errorf("%q has the family %d", ip, family)
		}
	}
}

func TestAPinExpiresPastItsExpiry(t *testing.T) {
	top := hostVectors(t)
	for _, raw := range wiretest.Cases(t, top.PinExpiry, 6) {
		var c struct {
			ExpiresAt uint64 `json:"expires_at"`
			Now       int64  `json:"now"`
			Expired   bool   `json:"expired"`
		}
		wiretest.Decode(t, raw, &c, []string{"expires_at", "now", "expired"})
		if got := (Pin{ExpiresAt: c.ExpiresAt}).Expired(c.Now); got != c.Expired {
			t.Errorf("expiring at %d, at %d: %v", c.ExpiresAt, c.Now, got)
		}
	}
}

func TestEveryPinRequestReadsAsPrimaReadsIt(t *testing.T) {
	top := hostVectors(t)
	for _, raw := range wiretest.Cases(t, top.PinRequests, 15) {
		var c struct {
			Why  string          `json:"why"`
			Args json.RawMessage `json:"args"`
			Read bool            `json:"read"`
		}
		wiretest.Decode(t, raw, &c, []string{"why", "args", "read"})
		args, _ := decoded(t, c.Args).(map[string]any)
		if got := ReadRequest(args); got != c.Read {
			t.Errorf("%s: %v", c.Why, got)
		}
		url, _ := args["url"].(string)
		purpose, _ := args["purpose"].(string)
		from, _ := args["from"].(string)
		if built, ok := RequestArgs(url, purpose, from); c.Read && (!ok || !reflect.DeepEqual(built, args)) {
			t.Errorf("%s: built as %v, %v", c.Why, built, ok)
		}
	}
}

// The purposes and refusals are the vector's, and each call answers a
// list of its own.
func TestThePurposesAndRefusalsArePrimas(t *testing.T) {
	top := hostVectors(t)
	purposes, refusals := top.PinPurposes, top.PinRefusalNames
	if len(purposes) == 0 || !reflect.DeepEqual(Purposes(), purposes) || len(refusals) == 0 || !reflect.DeepEqual(Refusals(), refusals) {
		t.Errorf("purposes %v, refusals %v; the vector's %v, %v", Purposes(), Refusals(), purposes, refusals)
	}
	Purposes()[0], Refusals()[0] = "changed", "changed"
	if Purposes()[0] != purposes[0] || Refusals()[0] != refusals[0] {
		t.Error("a caller changed the rosters")
	}
}
