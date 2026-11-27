// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package hostapi

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/cyfr/locus/keeper/internal/wire/macenvelope"
	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
	"github.com/cyfr/locus/keeper/internal/wire/workerauth"
)

type vectors struct {
	Version        int               `json:"version"`
	Routes         map[string]string `json:"routes"`
	Retries        map[string]string `json:"retries"`
	TimeoutsMs     map[string]int    `json:"timeouts_ms"`
	MaxBodyBytes   int               `json:"max_body_bytes"`
	MaxAnswerBytes int               `json:"max_answer_bytes"`
	Keys           map[string]string `json:"keys"`
	Calls          []struct {
		Fields map[string]json.RawMessage `json:"fields"`
	} `json:"calls"`
	AnswerOutcomes []struct {
		Why      string `json:"why"`
		Callback string `json:"callback"`
		Answers  []struct {
			Status *int   `json:"status"`
			Answer string `json:"answer"`
			Plain  string `json:"plain"`
		} `json:"answers"`
		Outcome string                     `json:"outcome"`
		Posted  int                        `json:"posted"`
		Reading map[string]json.RawMessage `json:"reading"`
	} `json:"answer_outcomes"`
	FramesContentTypes []struct {
		ContentTypes []string `json:"content_types"`
		Frames       bool     `json:"frames"`
	} `json:"frames_content_types"`
	AnswerBounds []struct {
		Why       string `json:"why"`
		Status    int    `json:"status"`
		BodyBytes int    `json:"body_bytes"`
		Arrived   bool   `json:"arrived"`
		KeptBytes int    `json:"kept_bytes"`
	} `json:"answer_bounds"`
}

func load(t *testing.T) vectors {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "tests", "fixtures", "host_api.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v vectors
	if err := json.Unmarshal(data, &v); err != nil || v.Version != 3 {
		t.Fatalf("the vector file: %v", err)
	}
	return v
}

func TestEveryCallbacksRouteRetryAndTimeoutAreTheVectors(t *testing.T) {
	v := load(t)
	if !reflect.DeepEqual(v.Retries, Retry) || len(v.Routes) != len(Retry) {
		t.Fatalf("the vector's retries %v, the package's %v", v.Retries, Retry)
	}
	for callback, route := range v.Routes {
		if Route(callback) != route || v.TimeoutsMs[callback] != TimeoutMs {
			t.Errorf("%s: route %q, timeout %d", callback, Route(callback), v.TimeoutsMs[callback])
		}
	}
	if v.MaxBodyBytes != MaxBodyBytes || v.MaxAnswerBytes != MaxAnswerBytes {
		t.Errorf("bounds %d and %d", v.MaxBodyBytes, v.MaxAnswerBytes)
	}
}

func message(t *testing.T, raw map[string]json.RawMessage) macenvelope.Message {
	t.Helper()
	m := macenvelope.Message{}
	for _, f := range workerauth.Call.Fields {
		var err error
		if f.Type == macenvelope.Integer {
			var n uint64
			err = json.Unmarshal(raw[f.Name], &n)
			m[f.Name] = n
		} else {
			var s string
			err = json.Unmarshal(raw[f.Name], &s)
			m[f.Name] = s
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	return m
}

func written(t *testing.T, v any) string {
	t.Helper()
	b, err := wirejson.Write(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// The reading as the vectors write one.
func readingOf(t *testing.T, r Reading) map[string]any {
	switch r.Kind {
	case "ok":
		return map[string]any{"ok": r.Value}
	case "refused":
		return map[string]any{"refused": r.Name}
	case "guest_error":
		e := map[string]any{"type": r.Type, "message": r.Message}
		if r.Remediation != nil {
			e["remediation"] = r.Remediation
		}
		return map[string]any{"guest_error": e}
	case "setup_required":
		return map[string]any{"setup_required": r.Payload}
	case "failed":
		return map[string]any{"failed": r.Message}
	}
	t.Fatalf("no reading %q", r.Kind)
	return nil
}

// Every answer outcome of the vectors: what a call makes of what each try
// met, each try's answer sealed to that try's own header fields.
func TestEveryAnswerOutcomeIsTheCallersAsTheVectorsSay(t *testing.T) {
	v := load(t)
	if len(v.AnswerOutcomes) < 45 {
		t.Fatalf("%d outcomes", len(v.AnswerOutcomes))
	}
	seal, _ := macenvelope.DecodeRoot(v.Keys["attempt_seal_hex"])
	base := message(t, v.Calls[0].Fields)
	names := map[Outcome]string{Answered: "answer", Lost: "lost", Uncertain: "uncertain", TooLarge: "too_large"}
	for _, c := range v.AnswerOutcomes {
		tries := 0
		r := Call(c.Callback, seal, func() (macenvelope.Message, Sent) {
			call := macenvelope.Message{}
			for k, val := range base {
				call[k] = val
			}
			call["nonce"] = fmt.Sprintf("n_try_%d", tries)
			if tries >= len(c.Answers) {
				t.Fatalf("%s: posted past its answers", c.Why)
			}
			a := c.Answers[tries]
			tries++
			switch {
			case a.Status == nil:
				return call, Sent{}
			case *a.Status == 200:
				iv := make([]byte, 12)
				rand.Read(iv)
				sealed, err := workerauth.SealCall(seal, workerauth.Answer, call, []byte(a.Answer), iv)
				if err != nil {
					t.Fatal(err)
				}
				return call, Sent{Arrived: true, Status: 200, Body: []byte(sealed)}
			default:
				return call, Sent{Arrived: true, Status: *a.Status, Body: []byte(a.Plain)}
			}
		})
		if names[r.Outcome] != c.Outcome || r.Posted != c.Posted {
			t.Errorf("%s: %s posted %d; want %s posted %d", c.Why, names[r.Outcome], r.Posted, c.Outcome, c.Posted)
			continue
		}
		if r.Outcome != Answered {
			continue
		}
		want := map[string]any{}
		for k, raw := range c.Reading {
			val, err := wirejson.Read(raw)
			if err != nil {
				t.Fatal(err)
			}
			if k == "ok_json" {
				if val, err = wirejson.Read([]byte(val.(string))); err != nil {
					t.Fatal(err)
				}
				k = "ok"
			}
			want[k] = val
		}
		if got := written(t, readingOf(t, r.Reading)); got != written(t, want) {
			t.Errorf("%s: read as %.200s; want %.200s", c.Why, got, written(t, want))
		}
	}
}

func TestAnAnswerCarriesFramesByItsContentType(t *testing.T) {
	v := load(t)
	if len(v.FramesContentTypes) < 8 {
		t.Fatalf("%d cases", len(v.FramesContentTypes))
	}
	for _, c := range v.FramesContentTypes {
		if Frames(c.ContentTypes) != c.Frames {
			t.Errorf("%q: %v", c.ContentTypes, !c.Frames)
		}
	}
}

// An answer past the answer bound: a 200 is no answer at all, and any other
// status keeps its status with no body.
func TestAnAnswerIsKeptToItsBound(t *testing.T) {
	v := load(t)
	if len(v.AnswerBounds) < 6 {
		t.Fatalf("%d cases", len(v.AnswerBounds))
	}
	for _, c := range v.AnswerBounds {
		s := Bounded(c.Status, make([]byte, c.BodyBytes), MaxAnswerBytes)
		if s.Arrived != c.Arrived || (s.Arrived && (s.Status != c.Status || len(s.Body) != c.KeptBytes)) {
			t.Errorf("%s: %v %d %d", c.Why, s.Arrived, s.Status, len(s.Body))
		}
	}
}
