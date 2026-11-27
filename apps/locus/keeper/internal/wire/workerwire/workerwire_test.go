// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package workerwire

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
	"github.com/cyfr/locus/keeper/internal/wire/workerapi"
)

// vectors is the part of tests/fixtures/worker_api.json that holds
// Prima.WorkerWire at a function's boundary.
type vectors struct {
	Version           int               `json:"version"`
	Routes            map[string]string `json:"routes"`
	MaxBodyBytes      int               `json:"max_body_bytes"`
	MaxReportAttempts int               `json:"max_report_attempts"`
	Requests          []struct {
		Callback string `json:"callback"`
		Body     string `json:"body"`
		Answer   string `json:"answer"`
	} `json:"requests"`
	RequestBodies []struct {
		Why      string          `json:"why"`
		Body     string          `json:"body"`
		Callback string          `json:"callback"`
		Args     json.RawMessage `json:"args"`
		Error    *string         `json:"error"`
		// Go is the Go reader's own answer where the two ends differ.
		Go *struct {
			Error string `json:"error"`
		} `json:"go"`
	} `json:"request_bodies"`
	Answers []struct {
		Why     string          `json:"why"`
		Answer  string          `json:"answer"`
		Reading string          `json:"reading"`
		Ok      json.RawMessage `json:"ok"`
		Error   string          `json:"error"`
		Fields  json.RawMessage `json:"fields"`
	} `json:"answers"`
	AnswerWrites []struct {
		Why    string          `json:"why"`
		Write  string          `json:"write"`
		Ok     json.RawMessage `json:"ok"`
		Error  string          `json:"error"`
		Fields json.RawMessage `json:"fields"`
		Op     string          `json:"op"`
		Args   json.RawMessage `json:"args"`
		Bytes  string          `json:"bytes"`
	} `json:"answer_writes"`
	BaseURLs []struct {
		Text string  `json:"text"`
		Base *string `json:"base"`
	} `json:"base_urls"`
}

func load(t *testing.T) vectors {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "tests", "fixtures", "worker_api.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v vectors
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func read(t *testing.T, raw []byte) any {
	t.Helper()
	v, err := wirejson.Read(raw)
	if err != nil {
		t.Fatalf("%s: %v", raw, err)
	}
	return v
}

func written(t *testing.T, v any) string {
	t.Helper()
	b, err := wirejson.Write(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestTheWiresFiguresAreTheVectors(t *testing.T) {
	v := load(t)
	if v.Version != Version || v.MaxBodyBytes != MaxBodyBytes || v.MaxReportAttempts != MaxReportAttempts {
		t.Fatalf("version %d, body bound %d, report attempts %d; the package's %d, %d, %d",
			v.Version, v.MaxBodyBytes, v.MaxReportAttempts, Version, MaxBodyBytes, MaxReportAttempts)
	}
	for callback, route := range v.Routes {
		if WorkerRoute(callback) != route {
			t.Errorf("%s's route %q", callback, WorkerRoute(callback))
		}
		if c, ok := WorkerCallback(route); !ok || c != callback {
			t.Errorf("%s reads as %q", route, c)
		}
	}
	if _, ok := WorkerCallback("/worker/v1/attach"); ok {
		t.Error("attach is no worker route")
	}
}

// Every body reads as its callback, or is refused with its error, the
// version first; and every request of the vectors reads and writes back
// to its bytes.
func TestEveryRequestBodyReadsAsPrimaReadsIt(t *testing.T) {
	v := load(t)
	if len(v.RequestBodies) < 20 {
		t.Fatalf("%d bodies", len(v.RequestBodies))
	}
	differences := 0
	for _, c := range v.RequestBodies {
		if c.Go != nil {
			differences++
			if _, err := wirejson.Read([]byte(c.Body)); err == nil || err.Error() != c.Go.Error {
				t.Errorf("%s: read with %v; Go refuses it %s", c.Why, err, c.Go.Error)
			}
			continue
		}
		callback, args, err := ReadRequestBody(workerapi.Callbacks(), read(t, []byte(c.Body)))
		switch {
		case c.Error != nil:
			if err == nil || err.Error() != *c.Error {
				t.Errorf("%s: %v, want %s", c.Why, err, *c.Error)
			}
		case err != nil || callback != c.Callback || written(t, args) != written(t, read(t, c.Args)):
			t.Errorf("%s: %s %v, %v", c.Why, callback, args, err)
		}
	}
	if differences == 0 {
		t.Error("no body states the depth the two ends differ at")
	}
	for _, r := range v.Requests {
		callback, args, err := ReadRequestBody(workerapi.Callbacks(), read(t, []byte(r.Body)))
		if err != nil || callback != r.Callback || written(t, RequestBody(callback, args)) != r.Body {
			t.Errorf("%s: %s, %v", r.Callback, written(t, RequestBody(callback, args)), err)
		}
	}
	if _, _, err := ReadRequestBody(workerapi.Callbacks(), nil); !errors.Is(err, ErrMalformed) {
		t.Error("null")
	}
}

func TestEveryAnswerReadsAsPrimaReadsIt(t *testing.T) {
	v := load(t)
	if len(v.Answers) < 15 {
		t.Fatalf("%d answers", len(v.Answers))
	}
	for _, c := range v.Answers {
		r, value, name, fields := ReadAnswer(read(t, []byte(c.Answer)))
		switch c.Reading {
		case "ok":
			if r != Answered || written(t, value) != written(t, read(t, c.Ok)) {
				t.Errorf("%s: %v %v", c.Why, r, value)
			}
		case "error":
			if r != Refused || name != c.Error || written(t, fields) != written(t, read(t, c.Fields)) {
				t.Errorf("%s: %v %q %v", c.Why, r, name, fields)
			}
		case "lost":
			if r != Lost {
				t.Errorf("%s: %v", c.Why, r)
			}
		default:
			t.Errorf("%s: no reading %q", c.Why, c.Reading)
		}
	}
	for _, r := range v.Requests {
		reading, value, name, fields := ReadAnswer(read(t, []byte(r.Answer)))
		var back wirejson.Ordered
		switch reading {
		case Answered:
			back = Ok(value)
		case Refused:
			back = Error(name, fields)
		default:
			t.Fatalf("%s's answer is lost", r.Callback)
		}
		if written(t, back) != r.Answer {
			t.Errorf("%s's answer writes back as %s", r.Callback, written(t, back))
		}
	}
}

func TestEveryAnswerAndBodyIsWrittenAsPrimaWritesIt(t *testing.T) {
	v := load(t)
	if len(v.AnswerWrites) < 5 {
		t.Fatalf("%d writes", len(v.AnswerWrites))
	}
	for _, c := range v.AnswerWrites {
		var w wirejson.Ordered
		switch c.Write {
		case "ok":
			w = Ok(read(t, c.Ok))
		case "error":
			w = Error(c.Error, read(t, c.Fields).(map[string]any))
		case "request":
			w = RequestBody(c.Op, read(t, c.Args))
		default:
			t.Fatalf("%s: no writer %q", c.Why, c.Write)
		}
		if got := written(t, w); got != c.Bytes {
			t.Errorf("%s: %s, want %s", c.Why, got, c.Bytes)
		}
	}
}

func TestEveryBaseURLReadsAsPrimaReadsIt(t *testing.T) {
	v := load(t)
	if len(v.BaseURLs) < 30 {
		t.Fatalf("%d base URLs", len(v.BaseURLs))
	}
	for _, c := range v.BaseURLs {
		base, ok := BaseURL(c.Text)
		switch {
		case c.Base == nil && ok:
			t.Errorf("%q reads as %q", c.Text, base)
		case c.Base != nil && (!ok || base != *c.Base):
			t.Errorf("%q reads as %q, %v; want %q", c.Text, base, ok, *c.Base)
		}
	}
}
