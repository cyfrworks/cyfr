// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package workerapi

import (
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
	} `json:"status"`
	KeeperRefusals []struct {
		Why        string  `json:"why"`
		Code       *string `json:"code"`
		Reason     string  `json:"reason"`
		Message    string  `json:"message"`
		ElixirOnly bool    `json:"elixir_only"`
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
	if len(v.Retries) != len(Callbacks) || !reflect.DeepEqual(v.Retries, Retry) || !reflect.DeepEqual(v.TimeoutsMs, TimeoutMs) {
		t.Fatalf("the vector's retries %v and timeouts %v, the package's %v and %v", v.Retries, v.TimeoutsMs, Retry, TimeoutMs)
	}
	for _, c := range Callbacks {
		if v.Routes[c] != "/worker/v1/"+c {
			t.Errorf("%s's route %q", c, v.Routes[c])
		}
	}
}

// A status is written as CYFR reads it: every valid status of the vectors,
// built from its members, writes back to its wire.
func TestEveryStatusIsWrittenAsItsWire(t *testing.T) {
	v := load(t)
	if len(v.Status.Valid) < 5 {
		t.Fatalf("%d statuses", len(v.Status.Valid))
	}
	for _, c := range v.Status.Valid {
		var w struct {
			Service     string            `json:"service"`
			Boot        string            `json:"boot"`
			Runners     map[string]uint64 `json:"runners"`
			Attempts    []string          `json:"attempts"`
			MemoryBytes uint64            `json:"memory_bytes"`
			Refusal     *struct {
				Reason  string `json:"reason"`
				Message string `json:"message"`
			} `json:"refusal"`
		}
		if err := json.Unmarshal(c.Wire, &w); err != nil {
			t.Fatal(err)
		}
		s := Status{Service: w.Service, Boot: w.Boot, Runners: w.Runners, Attempts: w.Attempts, MemoryBytes: w.MemoryBytes}
		if w.Refusal != nil {
			s.Refusal = &Refusal{Reason: w.Refusal.Reason, Message: w.Refusal.Message}
			if !ValidRefusalMessage(s.Refusal.Message) {
				t.Errorf("%s: its sentence", c.Why)
			}
		}
		got, err := wirejson.Write(s.Wire())
		want, _ := wirejson.Read(c.Wire)
		wantBytes, _ := wirejson.Write(want)
		if err != nil || string(got) != string(wantBytes) {
			t.Errorf("%s: %s, want %s", c.Why, got, wantBytes)
		}
	}
	for _, bad := range []string{"", "\x00", "a\x7fb", string(make([]byte, MaxMessageBytes+1)), "\xff"} {
		if ValidRefusalMessage(bad) {
			t.Errorf("%q is a refusal's sentence", bad)
		}
	}
}

func TestTheKeepersRefusalsAreHeldInTheVectorsWords(t *testing.T) {
	v := load(t)
	if len(v.KeeperRefusals) < 8 {
		t.Fatalf("%d refusals", len(v.KeeperRefusals))
	}
	for _, c := range v.KeeperRefusals {
		if c.ElixirOnly {
			continue
		}
		if got := KeeperRefusal(*c.Code); got != (Refusal{Reason: c.Reason, Message: c.Message}) {
			t.Errorf("%s: %+v", c.Why, got)
		}
	}
	if !reflect.DeepEqual(v.ReportRefusals.Carried, ReportRefusals) {
		t.Errorf("a report carries %v, the vector's %v", ReportRefusals, v.ReportRefusals.Carried)
	}
	for _, c := range v.ReportRefusals.NotCarried {
		if Reported(c) {
			t.Errorf("a report carries %s", c)
		}
	}
}
