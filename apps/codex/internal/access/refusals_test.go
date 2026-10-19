// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// refusalSection is access_modes.json's refusals section, which
// `mix cyfr.gen.access_refusals` renders from Prima.Refusal beside
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
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "tests", "fixtures", "access_modes.json"))
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
		t.Fatal("access_modes.json has no refusals section")
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
		t.Errorf("refusals_gen.go is not access_modes.json's refusals section: run `mix cyfr.gen.access_refusals`")
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
	if got := Refuse("access_busy", map[string]string{"pid": "1"}).Message(); got != "access_busy" {
		t.Errorf("a partial access_busy payload reads %q", got)
	}
	if got := Refuse("access_option_outside_mode", map[string]string{"option": "--domain", "mode": "public"}).Message(); got != "access_option_outside_mode" {
		t.Errorf("an option inside its mode reads %q", got)
	}
	missing := Refuse("access_missing", nil)
	if missing.Message() != missing.Sentence() || missing.Class != "setup_required" {
		t.Errorf("access_missing reads %q (%s)", missing.Message(), missing.Class)
	}
}

// The lock's refusal names what is known of its holder and never a
// placeholder for what is not: a watchdog and its deadline, else the
// holder's own pid, else the holder alone.
func TestBusyRefusalNamesOnlyWhatIsKnown(t *testing.T) {
	until := time.Date(2026, 10, 19, 14, 3, 0, 0, time.UTC)
	for _, c := range []struct {
		busy ErrBusy
		want map[string]string
	}{
		{ErrBusy{Holder: "cyfr up on host1", PID: 7, WatchdogPID: 9, Until: until}, map[string]string{"holder": "cyfr up on host1", "pid": "9", "until": "2026-10-19T14:03:00Z"}},
		{ErrBusy{Holder: "cyfr up on host1", PID: 7}, map[string]string{"holder": "cyfr up on host1", "pid": "7"}},
		{ErrBusy{Holder: "cyfr up on host1"}, map[string]string{"holder": "cyfr up on host1"}},
	} {
		r := c.busy.Refusal()
		if !reflect.DeepEqual(r.Payload, c.want) {
			t.Errorf("%+v: payload %v, want %v", c.busy, r.Payload, c.want)
		}
		if msg := r.Message(); msg == "access_busy" || strings.Contains(msg, "unknown") || strings.Contains(msg, "none") {
			t.Errorf("%+v reads %q", c.busy, msg)
		}
	}
}
