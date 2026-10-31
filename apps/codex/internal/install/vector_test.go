// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package install_test

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/cyfr/codex/internal/install"
)

// vectors is tests/fixtures/install_prerequisites.json, the decisions the
// install script's tests read too.
type vectors struct {
	Version int `json:"version"`
	Systems []struct {
		Name      string `json:"name"`
		OSRelease string `json:"os_release"`
		Arch      string `json:"arch"`
		Supported bool   `json:"supported"`
		System    string `json:"system"`
	} `json:"systems"`
	Universe []struct {
		Name         string `json:"name"`
		Codename     string `json:"codename"`
		IndexTargets string `json:"indextargets"`
		Enabled      bool   `json:"enabled"`
	} `json:"universe"`
	Bootstrap json.RawMessage `json:"bootstrap"`
	Init      []struct {
		Name  string        `json:"name"`
		Facts install.Facts `json:"facts"`
		Want  struct {
			Outcome  install.Outcome  `json:"outcome"`
			Actions  []install.Action `json:"actions"`
			Cause    install.Cause    `json:"cause"`
			Continue bool             `json:"continue"`
		} `json:"want"`
	} `json:"init"`
	About string `json:"about"`
}

func readVectors(t *testing.T) vectors {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "tests", "fixtures", "install_prerequisites.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v vectors
	dec := json.NewDecoder(bytesReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&v); err != nil {
		t.Fatalf("the vector file does not parse as the decisions' shape: %v", err)
	}
	if v.Version != 1 || len(v.Systems) == 0 || len(v.Universe) == 0 || len(v.Init) == 0 {
		t.Fatalf("the vector file holds version %d with %d systems, %d universe and %d init cases", v.Version, len(v.Systems), len(v.Universe), len(v.Init))
	}
	return v
}

func TestSystemVectors(t *testing.T) {
	p := install.Load()
	for _, c := range readVectors(t).Systems {
		t.Run(c.Name, func(t *testing.T) {
			s := install.ParseSystem(c.OSRelease, c.Arch)
			if got := p.Supports(s); got != c.Supported {
				t.Errorf("supported = %t, want %t (%+v)", got, c.Supported, s)
			}
			if s.Name != c.System {
				t.Errorf("system = %q, want %q", s.Name, c.System)
			}
		})
	}
}

func TestUniverseVectors(t *testing.T) {
	p := install.Load()
	for _, c := range readVectors(t).Universe {
		t.Run(c.Name, func(t *testing.T) {
			if got := install.UniverseEnabled(c.IndexTargets, c.Codename, p.Universe.Component); got != c.Enabled {
				t.Errorf("enabled = %t, want %t", got, c.Enabled)
			}
		})
	}
}

func TestInitVectors(t *testing.T) {
	p := install.Load()
	for _, c := range readVectors(t).Init {
		t.Run(c.Name, func(t *testing.T) {
			d := install.Decide(p, c.Facts)
			if d.Outcome != c.Want.Outcome || d.Cause != c.Want.Cause || d.Continue != c.Want.Continue {
				t.Errorf("decision = %s %s continue=%t (%s), want %s %s continue=%t", d.Outcome, d.Cause, d.Continue, d.Detail, c.Want.Outcome, c.Want.Cause, c.Want.Continue)
			}
			if !reflect.DeepEqual(d.Actions, c.Want.Actions) && (len(d.Actions) > 0 || len(c.Want.Actions) > 0) {
				t.Errorf("actions = %+v, want %+v", d.Actions, c.Want.Actions)
			}
			if d.Outcome == install.Refuse && d.Detail == "" {
				t.Error("a refusal names no unmet requirement")
			}
		})
	}
}

func bytesReader(b []byte) *bytes.Reader { return bytes.NewReader(b) }
