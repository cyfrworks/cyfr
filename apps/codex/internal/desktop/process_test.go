// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package desktop

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

type processVectors struct {
	Version  int `json:"version"`
	GoToMain []struct {
		Name    string         `json:"name"`
		Message map[string]any `json:"message"`
	} `json:"go_to_main"`
	MainToGo []struct {
		Name    string          `json:"name"`
		Message json.RawMessage `json:"message"`
	} `json:"main_to_go"`
	Refused []struct {
		Name   string `json:"name"`
		To     string `json:"to"`
		Line   string `json:"line"`
		Reason string `json:"reason"`
	} `json:"refused"`
}

func readProcessVectors(t *testing.T) processVectors {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "tests", "fixtures", "desktop-process.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v processVectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	if v.Version != Version {
		t.Fatalf("the vectors are version %d; cyfr speaks %d", v.Version, Version)
	}
	return v
}

func str(o map[string]any, k string) string { s, _ := o[k].(string); return s }

// Each message cyfr sends is written exactly as the vector spells it.
func TestCyfrWritesEachMessageAsPinned(t *testing.T) {
	for _, c := range readProcessVectors(t).GoToMain {
		t.Run(c.Name, func(t *testing.T) {
			o := c.Message
			attempt, _ := o["attempt"].(float64)
			m := Message{Type: str(o, "type"), Attempt: uint64(attempt), URL: str(o, "url"), Home: str(o, "home"), Account: str(o, "account"),
				Proxy: str(o, "proxy"), Resolver: str(o, "resolver"), ID: str(o, "id"), Suggested: str(o, "suggested")}
			var out bytes.Buffer
			if err := NewWriter(&out).Send(m); err != nil {
				t.Fatal(err)
			}
			line := out.String()
			if strings.Count(line, "\n") != 1 || !strings.HasSuffix(line, "\n") {
				t.Fatalf("not one line: %q", line)
			}
			var got map[string]any
			if err := json.Unmarshal([]byte(line), &got); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, o) {
				t.Fatalf("wrote %v; the vector is %v", got, o)
			}
		})
	}
}

// Each message main sends is read with its fields, and nothing else.
func TestCyfrReadsEachMessageFromMain(t *testing.T) {
	for _, c := range readProcessVectors(t).MainToGo {
		t.Run(c.Name, func(t *testing.T) {
			m, err := ReadFromMain(c.Message)
			if err != nil {
				t.Fatal(err)
			}
			var o map[string]any
			_ = json.Unmarshal(c.Message, &o)
			attempt, _ := o["attempt"].(float64)
			if m.Type != o["type"] || m.Home != str(o, "home") || m.ID != str(o, "id") || m.Attempt != uint64(attempt) {
				t.Fatalf("read %+v from %s", m, c.Message)
			}
			path, has := o["path"]
			switch {
			case has && path == nil && m.Path != nil:
				t.Fatalf("a cancelled pick read as %q", *m.Path)
			case has && path != nil && (m.Path == nil || *m.Path != path):
				t.Fatalf("the folder read as %v", m.Path)
			}
		})
	}
}

func TestCyfrRefusesEachRefusedLine(t *testing.T) {
	read := 0
	for _, c := range readProcessVectors(t).Refused {
		if c.To != "go" {
			continue
		}
		read++
		t.Run(c.Name, func(t *testing.T) {
			_, err := ReadFromMain([]byte(c.Line))
			var r *Refusal
			if !errors.As(err, &r) || r.Reason != c.Reason {
				t.Fatalf("got %v; want refused for %s", err, c.Reason)
			}
		})
	}
	if read == 0 {
		t.Fatal("no refusal addressed to cyfr")
	}
	if _, err := ReadFromMain(bytes.Repeat([]byte(" "), MaxLine+1)); !errors.Is(err, ErrRefused) {
		t.Fatalf("a line past the bound was read: %v", err)
	}
}

// cyfr sends only its own messages, each whole.
func TestCyfrSendsNothingMainSends(t *testing.T) {
	for _, typ := range append([]string{"unlock"}, fromMain...) {
		if err := NewWriter(&bytes.Buffer{}).Send(Message{Type: typ, Home: "https://x"}); err == nil {
			t.Errorf("sent %s", typ)
		}
	}
	if err := NewWriter(&bytes.Buffer{}).Send(Message{Type: TypeHome, Home: "https://x", Account: "https://y"}); err == nil {
		t.Error("sent home without its attempt")
	}
	if err := NewWriter(&bytes.Buffer{}).Send(Message{Type: TypeHome, Home: "https://x", Attempt: 1}); err == nil {
		t.Error("sent home without its account service")
	}
}
