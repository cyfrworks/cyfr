// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package workerapi

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
)

// vectors is the part of tests/fixtures/worker_api.json, the vector file
// of Prima.WorkerAPI, that a worker service's side reproduces.
type vectors struct {
	Version    int               `json:"version"`
	Routes     map[string]string `json:"routes"`
	Retries    map[string]string `json:"retries"`
	TimeoutsMs map[string]int    `json:"timeouts_ms"`
	Status     struct {
		Valid []struct {
			Why  string          `json:"why"`
			Wire json.RawMessage `json:"wire"`
		} `json:"valid"`
		Invalid []struct {
			Why  string          `json:"why"`
			Wire json.RawMessage `json:"wire"`
		} `json:"invalid"`
	} `json:"status"`
	KeeperRefusals []struct {
		Why        string          `json:"why"`
		Code       *string         `json:"code"`
		Reason     string          `json:"reason"`
		Message    string          `json:"message"`
		Held       json.RawMessage `json:"held"`
		ElixirOnly bool            `json:"elixir_only"`
	} `json:"keeper_refusals"`
	ReportRefusals struct {
		Carried    []string `json:"carried"`
		NotCarried []string `json:"not_carried"`
	} `json:"report_refusals"`
}

func load(t *testing.T) vectors {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "tests", "fixtures", "worker_api.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v vectors
	if err := json.Unmarshal(data, &v); err != nil || v.Version != 3 {
		t.Fatalf("the vector file: %v, version %d", err, v.Version)
	}
	return v
}

func TestEveryCallbacksRetryAndTimeoutAreTheVectors(t *testing.T) {
	v := load(t)
	if len(v.Retries) != len(Callbacks()) || !reflect.DeepEqual(v.Retries, Retry) || !reflect.DeepEqual(v.TimeoutsMs, TimeoutMs) {
		t.Fatalf("the vector's retries %v and timeouts %v, the package's %v and %v", v.Retries, v.TimeoutsMs, Retry, TimeoutMs)
	}
	for _, c := range Callbacks() {
		if v.Routes[c] != "/worker/v1/"+c {
			t.Errorf("%s's route %q", c, v.Routes[c])
		}
	}
}

// status builds the Status a wire spells, when Go's type can hold it.
func status(t *testing.T, raw json.RawMessage) (Status, bool) {
	t.Helper()
	var w struct {
		Service     *string           `json:"service"`
		Boot        *string           `json:"boot"`
		Runners     map[string]uint64 `json:"runners"`
		Attempts    *[]string         `json:"attempts"`
		MemoryBytes *uint64           `json:"memory_bytes"`
		Refusal     *struct {
			Reason  *string         `json:"reason"`
			Message *string         `json:"message"`
			Held    json.RawMessage `json:"held"`
		} `json:"refusal"`
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var members map[string]json.RawMessage
	if json.Unmarshal(raw, &members) != nil || len(members) != 6 || dec.Decode(&w) != nil ||
		w.Service == nil || w.Boot == nil || w.Runners == nil || w.Attempts == nil {
		return Status{}, false
	}
	s := Status{Service: *w.Service, Boot: *w.Boot, Runners: w.Runners, Attempts: *w.Attempts}
	if w.MemoryBytes != nil {
		if *w.MemoryBytes == 0 {
			return Status{}, false
		}
		s.MemoryBytes = *w.MemoryBytes
	}
	if w.Refusal != nil {
		if w.Refusal.Reason == nil || w.Refusal.Message == nil {
			return Status{}, false
		}
		s.Refusal = &Refusal{Reason: *w.Refusal.Reason, Message: *w.Refusal.Message}
		if len(w.Refusal.Held) > 0 {
			s.Refusal.Held = map[string]any{}
		}
	}
	return s, true
}

// A status is written as CYFR reads it: every valid status of the vectors,
// built from its members, writes back to its wire, and every invalid one
// Go's type can hold is refused, as status_to_wire/1 refuses it.
func TestEveryStatusIsWrittenAsItsWireAndNoneElse(t *testing.T) {
	v := load(t)
	if len(v.Status.Valid) < 5 || len(v.Status.Invalid) < 30 {
		t.Fatalf("%d valid, %d invalid", len(v.Status.Valid), len(v.Status.Invalid))
	}
	for _, c := range v.Status.Valid {
		s, ok := status(t, c.Wire)
		if !ok {
			t.Fatalf("%s: no status", c.Why)
		}
		w, err := s.Wire()
		got, werr := wirejson.Write(w)
		want, _ := wirejson.Read(c.Wire)
		wantBytes, _ := wirejson.Write(want)
		if err != nil || werr != nil || string(got) != string(wantBytes) {
			t.Errorf("%s: %s, %v %v; want %s", c.Why, got, err, werr, wantBytes)
		}
	}
	refused := 0
	for _, c := range v.Status.Invalid {
		s, ok := status(t, c.Wire)
		if !ok {
			continue
		}
		refused++
		if w, err := s.Wire(); err == nil {
			t.Errorf("%s: written as %v; Prima refuses it", c.Why, w)
		}
	}
	if refused < 8 {
		t.Errorf("only %d invalid statuses were Go's to refuse", refused)
	}
	for _, bad := range []string{"", "\x00", "a\x7fb", string(make([]byte, MaxMessageBytes+1)), "\xff"} {
		if ValidRefusalMessage(bad) {
			t.Errorf("%q is a refusal's sentence", bad)
		}
	}
}

func TestTheKeepersRefusalsAreHeldInTheVectorsWords(t *testing.T) {
	v := load(t)
	if len(v.KeeperRefusals) < 9 {
		t.Fatalf("%d refusals", len(v.KeeperRefusals))
	}
	held := 0
	for _, c := range v.KeeperRefusals {
		if c.ElixirOnly {
			continue
		}
		var h map[string]any
		if len(c.Held) > 0 {
			held++
			decoded, err := wirejson.Read(c.Held)
			if err != nil {
				t.Fatal(err)
			}
			h = decoded.(map[string]any)
		}
		// The held expected is taken before the call, and the case's own
		// read again after it: a refusal that changes the keeper's held in
		// place differs from both.
		wantHeld, _ := wirejson.Write(h)
		got := KeeperRefusal(*c.Code, h)
		gotHeld, _ := wirejson.Write(got.Held)
		var again map[string]any
		if len(c.Held) > 0 {
			read, _ := wirejson.Read(c.Held)
			again = read.(map[string]any)
		}
		caseHeld, _ := wirejson.Write(again)
		if got.Reason != c.Reason || got.Message != c.Message || string(gotHeld) != string(wantHeld) || string(gotHeld) != string(caseHeld) {
			t.Errorf("%s: %+v", c.Why, got)
		}
	}
	if held == 0 {
		t.Error("no refusal carries the keeper's held")
	}
	if !reflect.DeepEqual(v.ReportRefusals.Carried, ReportRefusals) || len(v.ReportRefusals.NotCarried) == 0 {
		t.Errorf("a report carries %v, the vector's %v", ReportRefusals, v.ReportRefusals.Carried)
	}
	for _, c := range v.ReportRefusals.NotCarried {
		if Reported(c) {
			t.Errorf("a report carries %s", c)
		}
	}
}
