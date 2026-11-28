// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package pinned

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
)

type pinCase struct {
	Why string          `json:"why"`
	Pin json.RawMessage `json:"pin"`
}

type vectors struct {
	PinAnswerRefusals struct {
		Pin      json.RawMessage `json:"pin"`
		Reads    []pinCase       `json:"reads"`
		Refusals []pinCase       `json:"refusals"`
	} `json:"pin_answer_refusals"`
	PinExpiry []struct {
		ExpiresAt uint64 `json:"expires_at"`
		Now       int64  `json:"now"`
		Expired   bool   `json:"expired"`
	} `json:"pin_expiry"`
	PinRequests []struct {
		Why  string          `json:"why"`
		Args json.RawMessage `json:"args"`
		Read bool            `json:"read"`
	} `json:"pin_requests"`
}

func load(t *testing.T) vectors {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "tests", "fixtures", "host_api.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v vectors
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func decoded(t *testing.T, raw json.RawMessage) any {
	t.Helper()
	v, err := wirejson.Read(raw)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

// Every pin reads, or is refused, as Prima.PinnedTarget.read/1 reads it:
// its address and bracketed host as Erlang reads an address, zones and
// all, and its family an integer.
func TestEveryPinReadsOrIsRefusedAsPrimaReadsIt(t *testing.T) {
	v := load(t)
	reads := append([]pinCase{{Why: "the pin", Pin: v.PinAnswerRefusals.Pin}}, v.PinAnswerRefusals.Reads...)
	refusals := v.PinAnswerRefusals.Refusals
	if len(reads) < 12 || len(refusals) < 28 {
		t.Fatalf("%d reads, %d refusals", len(reads), len(refusals))
	}
	for _, c := range reads {
		if _, ok := Read(decoded(t, c.Pin)); !ok {
			t.Errorf("%s: refused", c.Why)
		}
	}
	for _, c := range refusals {
		if p, ok := Read(decoded(t, c.Pin)); ok {
			t.Errorf("%s: read as %+v", c.Why, p)
		}
	}
}

func TestAPinExpiresPastItsExpiry(t *testing.T) {
	cases := load(t).PinExpiry
	if len(cases) < 6 {
		t.Fatalf("%d cases", len(cases))
	}
	for _, c := range cases {
		if got := (Pin{ExpiresAt: c.ExpiresAt}).Expired(c.Now); got != c.Expired {
			t.Errorf("expiring at %d, at %d: %v", c.ExpiresAt, c.Now, got)
		}
	}
}

func TestEveryPinRequestReadsAsPrimaReadsIt(t *testing.T) {
	v := load(t)
	if len(v.PinRequests) < 15 {
		t.Fatalf("%d requests", len(v.PinRequests))
	}
	for _, c := range v.PinRequests {
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
	if !reflect.DeepEqual(Refusals, []string{"domain", "denied", "metadata", "resolution", "redirect_credentials", "malformed"}) ||
		!reflect.DeepEqual(Purposes, []string{"fetch", "stream", "redirect"}) {
		t.Fatal("the refusals and purposes")
	}
}
