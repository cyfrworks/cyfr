// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// vectors is tests/fixtures/reach_modes.json, which binds this package to
// Cyfr.RuntimeConfig: Elixir generated every canonical, digest and boot
// answer in it, and every section is read here.
type vectors struct {
	Derive   []deriveVector  `json:"derive"`
	Boot     []bootVector    `json:"boot"`
	Profiles []profileVector `json:"profiles"`
	Names    struct {
		TailnetNames []nameVector `json:"tailnet_names"`
		NodeIDs      []nameVector `json:"node_ids"`
		Domains      []nameVector `json:"domains"`
		BuildsURLs   []nameVector `json:"builds_urls"`
	} `json:"names"`
	Words []wordsVector `json:"words"`
}

type refusalVector struct {
	Code     string            `json:"code"`
	Class    string            `json:"class"`
	Payload  map[string]string `json:"payload"`
	Sentence string            `json:"sentence"`
}

type deriveVector struct {
	Name        string            `json:"name"`
	Target      map[string]string `json:"target"`
	Current     Current           `json:"current"`
	Join        *Join             `json:"join"`
	Head        *Head             `json:"head"`
	Canonical   string            `json:"canonical"`
	Digest      string            `json:"digest"`
	Assignments map[string]string `json:"assignments"`
	Removals    []string          `json:"removals"`
	Refusal     *refusalVector    `json:"refusal"`
}

type bootVector struct {
	Name  string `json:"name"`
	Input struct {
		File    map[string]string `json:"file"`
		Process map[string]string `json:"process"`
		Release bool              `json:"release?"`
	} `json:"input"`
	Reach   map[string]any `json:"reach"`
	Refusal *refusalVector `json:"refusal"`
}

type profileVector struct {
	Mode      string   `json:"mode"`
	BuildsURL string   `json:"builds_url"`
	Profiles  []string `json:"profiles"`
}

type nameVector struct {
	Value string `json:"value"`
	Valid bool   `json:"valid"`
	Why   string `json:"why"`
}

type wordsVector struct {
	Head      Head     `json:"head"`
	Sentences []string `json:"sentences"`
}

func (c *Current) UnmarshalJSON(b []byte) error {
	var raw struct {
		Port      int    `json:"port"`
		BuildsURL string `json:"builds_url"`
	}
	err := json.Unmarshal(b, &raw)
	c.Port, c.BuildsURL = raw.Port, raw.BuildsURL
	return err
}

func (j *Join) UnmarshalJSON(b []byte) error {
	var raw struct {
		Name   string `json:"name"`
		NodeID string `json:"node_id"`
	}
	err := json.Unmarshal(b, &raw)
	j.Name, j.NodeID = raw.Name, raw.NodeID
	return err
}

func readVectors(t *testing.T) vectors {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "tests", "fixtures", "reach_modes.json"))
	if err != nil {
		t.Fatalf("read reach_modes.json: %v", err)
	}
	var v vectors
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	if err := dec.Decode(&v); err != nil {
		t.Fatalf("decode reach_modes.json: %v", err)
	}
	if len(v.Derive) == 0 || len(v.Boot) == 0 || len(v.Profiles) == 0 || len(v.Words) == 0 ||
		len(v.Names.TailnetNames) == 0 || len(v.Names.NodeIDs) == 0 || len(v.Names.Domains) == 0 ||
		len(v.Names.BuildsURLs) == 0 {
		t.Fatal("reach_modes.json has an empty or missing section")
	}
	return v
}

func TestProfilesVectors(t *testing.T) {
	for _, v := range readVectors(t).Profiles {
		if got := Profiles(v.Mode, v.BuildsURL); !reflect.DeepEqual(got, v.Profiles) {
			t.Errorf("Profiles(%q, %q) = %v, want %v", v.Mode, v.BuildsURL, got, v.Profiles)
		}
	}
}

func TestNamesVectors(t *testing.T) {
	v := readVectors(t)
	for _, set := range []struct {
		name  string
		check func(string) bool
		cases []nameVector
	}{
		{"TailnetName", TailnetName, v.Names.TailnetNames},
		{"NodeID", NodeID, v.Names.NodeIDs},
		{"PublicDomain", PublicDomain, v.Names.Domains},
		{"BuildsURL", BuildsURL, v.Names.BuildsURLs},
	} {
		var valid, invalid int
		for _, c := range set.cases {
			if got := set.check(c.Value); got != c.Valid {
				t.Errorf("%s(%q) = %v, want %v (%s)", set.name, c.Value, got, c.Valid, c.Why)
			}
			if c.Valid {
				valid++
			} else {
				invalid++
			}
		}
		if valid == 0 || invalid == 0 {
			t.Errorf("%s has %d valid and %d invalid vectors; both are needed", set.name, valid, invalid)
		}
	}
}

// Every derived head's canonical bytes and digest are Elixir's, from
// Go's own derivation of the head.
func TestHeadCanonicalAgreesWithElixir(t *testing.T) {
	seen := map[string]string{}
	for _, v := range readVectors(t).Derive {
		if v.Head == nil {
			continue
		}
		if got := string(v.Head.Canonical()); got != v.Canonical {
			t.Errorf("%s: canonical\n got %s\nwant %s", v.Name, got, v.Canonical)
		}
		if got := v.Head.Digest(); got != v.Digest {
			t.Errorf("%s: digest %s, want %s", v.Name, got, v.Digest)
		}
		if other, ok := seen[v.Digest]; ok {
			t.Errorf("%s and %s share a digest", v.Name, other)
		}
		seen[v.Digest] = v.Name
	}
}

// A change to any one field of a head changes its digest, and the digest
// is over the bytes, not the struct.
func TestDigestBindsEveryField(t *testing.T) {
	base := Head{Mode: ModePublic, Host: "cyfr.example.com", PublicURL: "https://cyfr.example.com", Port: 4000,
		ACMEEmail: "ops@example.com", BuildsURL: "http://locus-builds:4100", Profiles: []string{"locus-builds", "public"}}
	changes := map[string]func(*Head){
		"mode":       func(h *Head) { h.Mode = ModeTailnet },
		"host":       func(h *Head) { h.Host = "other.example.com" },
		"node_id":    func(h *Head) { h.NodeID = "n1" },
		"public_url": func(h *Head) { h.PublicURL = "https://other.example.com" },
		"port":       func(h *Head) { h.Port = 4001 },
		"acme_email": func(h *Head) { h.ACMEEmail = "admin@example.com" },
		"builds_url": func(h *Head) { h.BuildsURL = "http://locus-builds:4200" },
		"profiles":   func(h *Head) { h.Profiles = []string{"public"} },
	}
	for field, change := range changes {
		h := base
		h.Profiles = append([]string(nil), base.Profiles...)
		change(&h)
		if h.Digest() == base.Digest() {
			t.Errorf("changing %s leaves the digest", field)
		}
	}
	if !strings.HasPrefix(base.Digest(), "sha256:") || len(base.Digest()) != len("sha256:")+64 {
		t.Errorf("digest %q is not sha256: and 64 hex digits", base.Digest())
	}
}

// RFC 8785 escapes only what JSON requires: HTML characters and U+2028
// stay as they are, unlike encoding/json's default.
func TestCanonicalEscapesOnlyWhatJSONRequires(t *testing.T) {
	h := Head{Mode: ModeLocal, Host: "localhost", Port: 4000, BuildsURL: "http://b/?a=1&b=< \"\\\x01>", Profiles: []string{}}
	want := `{"builds_url":"http://b/?a=1&b=<` + " " + `\"\\\u0001>","host":"localhost","mode":"local","port":4000,"profiles":[]}`
	if got := string(h.Canonical()); got != want {
		t.Errorf("canonical\n got %s\nwant %s", got, want)
	}
}
