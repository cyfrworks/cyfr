// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// refusalSection is reach_modes.json's refusals section, which
// `mix cyfr.gen.reach_refusals` renders from Prima.Refusal beside
// refusals_gen.go.
type refusalSection []struct {
	Code     string `json:"code"`
	Class    string `json:"class"`
	Variants []struct {
		Fixed    map[string]string `json:"fixed"`
		Slots    []string          `json:"slots"`
		Template string            `json:"template"`
		Example  struct {
			Payload  map[string]string `json:"payload"`
			Sentence string            `json:"sentence"`
		} `json:"example"`
	} `json:"variants"`
}

func readRefusalSection(t *testing.T) refusalSection {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "tests", "fixtures", "reach_modes.json"))
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Refusals refusalSection `json:"refusals"`
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	if len(file.Refusals) == 0 {
		t.Fatal("reach_modes.json has no refusals section")
	}
	return file.Refusals
}

// The generated rows are the section's, code for code and variant for
// variant, and nothing else.
func TestRefusalRowsAreTheVectorSection(t *testing.T) {
	section := readRefusalSection(t)
	want := map[string]refusalRow{}
	for _, row := range section {
		r := refusalRow{Class: row.Class}
		for _, v := range row.Variants {
			r.Variants = append(r.Variants, refusalVariant{Fixed: v.Fixed, Slots: v.Slots, Template: v.Template})
		}
		want[row.Code] = r
	}
	if !reflect.DeepEqual(refusalRows, want) {
		t.Errorf("refusals_gen.go is not reach_modes.json's refusals section: run `mix cyfr.gen.reach_refusals`")
	}
}

// Every variant renders its example to the sentence Prima.Refusal gives
// the same code and payload, with the row's class.
func TestRefusalsRenderPrimaRefusalsSentences(t *testing.T) {
	for _, row := range readRefusalSection(t) {
		for _, v := range row.Variants {
			r := Refuse(row.Code, v.Example.Payload)
			if r.Class != row.Class {
				t.Errorf("%s: class %q, want %q", row.Code, r.Class, row.Class)
			}
			if got := r.Message(); got != v.Example.Sentence {
				t.Errorf("%s %v:\n got  %q\n want %q", row.Code, v.Example.Payload, got, v.Example.Sentence)
			}
		}
	}
}

// A payload no variant takes reads as its code, never a sentence with a
// hole, and a boot refusal reads as the boot's sentence.
func TestRefusalMessageFallsBack(t *testing.T) {
	if got := Refuse("reach_busy", map[string]string{"holder": "x"}).Message(); got != "reach_busy" {
		t.Errorf("a partial reach_busy payload reads %q", got)
	}
	if got := Refuse("reach_option_outside_mode", map[string]string{"option": "--domain", "mode": "public"}).Message(); got != "reach_option_outside_mode" {
		t.Errorf("an option inside its mode reads %q", got)
	}
	missing := Refuse("reach_missing", nil)
	if missing.Message() != missing.Sentence() || missing.Class != "setup_required" {
		t.Errorf("reach_missing reads %q (%s)", missing.Message(), missing.Class)
	}
}
