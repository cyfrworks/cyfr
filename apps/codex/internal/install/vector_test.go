// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package install_test

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
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
	Sudo      []struct {
		Name    string `json:"name"`
		Printed string `json:"printed"`
		Cause   string `json:"cause"`
	} `json:"sudo"`
	Init []struct {
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

// TestSudoVectors reads each refusal as the policy's sudo words read it,
// the same cases the install script's tests read.
func TestSudoVectors(t *testing.T) {
	p := install.Load()
	causes := map[string]install.SudoCause{
		"needs-password": install.SudoNeedsPassword,
		"wrong-password": install.SudoWrongPassword,
		"not-allowed":    install.SudoNotAllowed,
		"unknown":        install.SudoUnknown,
	}
	v := readVectors(t)
	if len(v.Sudo) == 0 {
		t.Fatal("the vector file holds no sudo case")
	}
	for _, c := range v.Sudo {
		t.Run(c.Name, func(t *testing.T) {
			want, ok := causes[c.Cause]
			if !ok {
				t.Fatalf("cause %q", c.Cause)
			}
			if got := install.ReadSudoCause(p, c.Printed); got != want {
				t.Errorf("ReadSudoCause(%q) = %d, want %s", c.Printed, got, c.Cause)
			}
		})
	}
}

// TestSudoWordsAreLowercaseAndNotEmpty holds the policy's sudo words to
// what ReadSudoCause matches: an empty word would match every refusal.
func TestSudoWordsAreLowercaseAndNotEmpty(t *testing.T) {
	p := install.Load()
	for name, words := range map[string][]string{
		"wrong_password": p.Sudo.WrongPassword,
		"needs_password": p.Sudo.NeedsPassword,
		"not_allowed":    p.Sudo.NotAllowed,
	} {
		if len(words) == 0 {
			t.Errorf("%s names no word", name)
		}
		for _, w := range words {
			if strings.TrimSpace(w) == "" || w != strings.ToLower(w) {
				t.Errorf("%s word %q is empty or not lowercase", name, w)
			}
		}
	}
}
