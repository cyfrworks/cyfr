// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package hostapi

import (
	"encoding/json"
	"fmt"
	"reflect"
	"testing"

	"github.com/cyfr/locus/keeper/internal/wire/macenvelope"
	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
	"github.com/cyfr/locus/keeper/internal/wire/wiretest"
	"github.com/cyfr/locus/keeper/internal/wire/workerauth"
)

// hostSections are the sections of tests/fixtures/host_api.json this test reads.
type hostSections struct {
	Version            json.RawMessage `json:"version"`
	Routes             json.RawMessage `json:"routes"`
	Retries            json.RawMessage `json:"retries"`
	TimeoutsMs         json.RawMessage `json:"timeouts_ms"`
	MaxBodyBytes       json.RawMessage `json:"max_body_bytes"`
	MaxAnswerBytes     json.RawMessage `json:"max_answer_bytes"`
	Keys               json.RawMessage `json:"keys"`
	Calls              json.RawMessage `json:"calls"`
	AnswerOutcomes     json.RawMessage `json:"answer_outcomes"`
	FramesContentTypes json.RawMessage `json:"frames_content_types"`
	AnswerBounds       json.RawMessage `json:"answer_bounds"`
}

func hostVectors(t *testing.T) hostSections {
	t.Helper()
	var s hostSections
	wiretest.Load(t, "host_api.json", &s)
	return s
}

func load(t *testing.T) hostSections {
	t.Helper()
	top := hostVectors(t)
	var version int
	if err := json.Unmarshal(top.Version, &version); err != nil || version != 3 {
		t.Fatalf("the vector file's version: %d, %v", version, err)
	}
	return top
}

func member(t *testing.T, raw json.RawMessage, v any) {
	t.Helper()
	if err := json.Unmarshal(raw, v); err != nil {
		t.Fatalf("%s: %v", raw, err)
	}
}

func TestEveryCallbacksRouteRetryAndTimeoutAreTheVectors(t *testing.T) {
	top := load(t)
	var routes, retries map[string]string
	var timeouts map[string]int
	var maxBody, maxAnswer int
	member(t, top.Routes, &routes)
	member(t, top.Retries, &retries)
	member(t, top.TimeoutsMs, &timeouts)
	member(t, top.MaxBodyBytes, &maxBody)
	member(t, top.MaxAnswerBytes, &maxAnswer)
	if len(retries) == 0 || !reflect.DeepEqual(retries, Retries()) || len(routes) != len(retries) || len(timeouts) != len(retries) {
		t.Fatalf("the vector's retries %v, the package's %v", retries, Retries())
	}
	for callback, route := range routes {
		if got, ok := Route(callback); !ok || got != route || timeouts[callback] != TimeoutMs {
			t.Errorf("%s: route %q, %v, timeout %d", callback, got, ok, timeouts[callback])
		}
	}
	if maxBody != MaxBodyBytes || maxAnswer != MaxAnswerBytes {
		t.Errorf("bounds %d and %d", maxBody, maxAnswer)
	}
	Retries()["renew"] = "never"
	if Retries()["renew"] != retries["renew"] {
		t.Error("a caller changed the retry classes")
	}
}

// A callback the host API has not has no route and is never tried, as
// Prima refuses its name; and a Result no call made says nothing came of
// it (the review's probes).
func TestAnUnknownCallbackIsNeverTriedAndNoResultIsAnAnswer(t *testing.T) {
	for _, callback := range []string{"no_such_callback", "storagee", "", "Renew"} {
		if route, ok := Route(callback); ok {
			t.Errorf("%q has the route %q", callback, route)
		}
		tries := 0
		r, err := Call(callback, macenvelope.Key{}, func() (macenvelope.Message, Sent) {
			tries++
			return nil, Sent{}
		})
		if err != ErrUnknownCallback || tries != 0 || r.Outcome == Answered || r.Posted != 0 {
			t.Errorf("%q: %+v, %v, tried %d times", callback, r, err, tries)
		}
	}
	var zero Result
	for _, o := range []Outcome{Answered, Lost, Uncertain, TooLarge} {
		if zero.Outcome == o {
			t.Errorf("the zero Result's outcome is %d, a real one", o)
		}
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
	top := load(t)
	var keys map[string]string
	member(t, top.Keys, &keys)
	var calls []struct {
		Fields map[string]json.RawMessage `json:"fields"`
	}
	member(t, top.Calls, &calls)
	seal, _ := macenvelope.DecodeRoot(keys["attempt_seal_hex"])
	base := message(t, calls[0].Fields)
	names := map[Outcome]string{Answered: "answer", Lost: "lost", Uncertain: "uncertain", TooLarge: "too_large"}
	for _, raw := range wiretest.Cases(t, top.AnswerOutcomes, 49) {
		var c struct {
			Why      string                     `json:"why"`
			Callback string                     `json:"callback"`
			Answers  []json.RawMessage          `json:"answers"`
			Outcome  string                     `json:"outcome"`
			Posted   int                        `json:"posted"`
			Reading  map[string]json.RawMessage `json:"reading"`
		}
		wiretest.Decode(t, raw, &c, []string{"why", "callback", "answers", "outcome", "posted"})
		type answer struct {
			Status *int   `json:"status"`
			Answer string `json:"answer"`
			Plain  string `json:"plain"`
		}
		answers := make([]answer, len(c.Answers))
		for i, a := range c.Answers {
			wiretest.Decode(t, a, &answers[i], []string{"status"}, "status")
		}
		if (c.Outcome == "answer") != (c.Reading != nil) {
			t.Fatalf("%s: an answer and its reading go together", c.Why)
		}
		tries := 0
		r, err := Call(c.Callback, seal, func() (macenvelope.Message, Sent) {
			call := macenvelope.Message{}
			for k, val := range base {
				call[k] = val
			}
			call["nonce"] = fmt.Sprintf("n_try_%d", tries)
			if tries >= len(answers) {
				t.Fatalf("%s: posted past its answers", c.Why)
			}
			a := answers[tries]
			tries++
			switch {
			case a.Status == nil:
				return call, Sent{}
			case *a.Status == 200:
				sealed, err := workerauth.SealCall(seal, workerauth.Answer, call, []byte(a.Answer))
				if err != nil {
					t.Fatal(err)
				}
				return call, Sent{Arrived: true, Status: 200, Body: []byte(sealed)}
			default:
				return call, Sent{Arrived: true, Status: *a.Status, Body: []byte(a.Plain)}
			}
		})
		if err != nil || names[r.Outcome] != c.Outcome || r.Posted != c.Posted {
			t.Errorf("%s: %s posted %d, %v; want %s posted %d", c.Why, names[r.Outcome], r.Posted, err, c.Outcome, c.Posted)
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
	for _, raw := range wiretest.Cases(t, load(t).FramesContentTypes, 12) {
		var c struct {
			ContentTypes []string `json:"content_types"`
			Frames       bool     `json:"frames"`
		}
		wiretest.Decode(t, raw, &c, []string{"content_types", "frames"})
		if Frames(c.ContentTypes) != c.Frames {
			t.Errorf("%q: %v", c.ContentTypes, !c.Frames)
		}
	}
}

// An answer past the answer bound: a 200 is no answer at all, and any other
// status keeps its status with no body; what is kept is compared whatever
// arrived.
func TestAnAnswerIsKeptToItsBound(t *testing.T) {
	for _, raw := range wiretest.Cases(t, load(t).AnswerBounds, 6) {
		var c struct {
			Why       string `json:"why"`
			Status    int    `json:"status"`
			BodyBytes int    `json:"body_bytes"`
			Arrived   bool   `json:"arrived"`
			KeptBytes int    `json:"kept_bytes"`
		}
		wiretest.Decode(t, raw, &c, []string{"why", "status", "body_bytes", "arrived", "kept_bytes"})
		s := Bounded(c.Status, make([]byte, c.BodyBytes), MaxAnswerBytes)
		status := c.Status
		if !c.Arrived {
			status = 0
		}
		if s.Arrived != c.Arrived || s.Status != status || len(s.Body) != c.KeptBytes {
			t.Errorf("%s: %v %d %d", c.Why, s.Arrived, s.Status, len(s.Body))
		}
	}
}
