// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package setup

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

const statusTestToken = "5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e"

// statusVectors is tests/fixtures/setup_status.json, the vectors the
// application's controller test reads too.
type statusVectors struct {
	Path         string `json:"path"`
	Version      int    `json:"version"`
	MaxBodyBytes int    `json:"max_body_bytes"`
	Request      string `json:"request"`
	Exchanges    []struct {
		Name    string          `json:"name"`
		Status  int             `json:"status"`
		Answer  json.RawMessage `json:"answer"`
		Refusal string          `json:"refusal"`
		Reading string          `json:"reading"`
	} `json:"exchanges"`
	Answers []statusAnswer `json:"answers"`
}

type statusAnswer struct {
	Name    string `json:"name"`
	Status  int    `json:"status"`
	Body    string `json:"body"`
	Reading string `json:"reading"`
}

func readStatusVectors(t *testing.T) statusVectors {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "tests", "fixtures", "setup_status.json"))
	if err != nil {
		t.Fatal(err)
	}
	var vectors statusVectors
	if err := json.Unmarshal(raw, &vectors); err != nil {
		t.Fatal(err)
	}
	return vectors
}

// allAnswers is every answer the vectors give the client: each exchange's,
// as the application sends it, and those only the client meets.
func allAnswers(vectors statusVectors) []statusAnswer {
	answers := append([]statusAnswer{}, vectors.Answers...)
	for _, exchange := range vectors.Exchanges {
		body := string(exchange.Answer)
		if exchange.Refusal != "" {
			body = `{"code":"` + exchange.Refusal + `","message":"refused"}`
		}
		answers = append(answers, statusAnswer{exchange.Name, exchange.Status, body, exchange.Reading})
	}
	return answers
}

// reading is what ReadStatus's result reads as, in the vectors' words.
func reading(status Status, err error) string {
	switch {
	case errors.Is(err, ErrUpdateRequired):
		return "update_required"
	case err != nil:
		return "refused"
	}
	return string(status)
}

func TestStatusConstantsAreTheVectors(t *testing.T) {
	vectors := readStatusVectors(t)
	if vectors.Path != statusPath || vectors.Version != statusVersion || vectors.Request != statusRequest {
		t.Errorf("the vectors say %s %d %s, the client %s %d %s", vectors.Path, vectors.Version, vectors.Request, statusPath, statusVersion, statusRequest)
	}
	if len(statusRequest) > vectors.MaxBodyBytes {
		t.Errorf("the request is %d bytes, past the wire's %d", len(statusRequest), vectors.MaxBodyBytes)
	}
}

func TestReadStatusReadsEveryAnswer(t *testing.T) {
	for _, answer := range allAnswers(readStatusVectors(t)) {
		t.Run(answer.Name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(answer.Status)
				io.WriteString(w, answer.Body)
			}))
			defer server.Close()

			status, err := ReadStatus(context.Background(), server.URL, statusTestToken)
			if got := reading(status, err); got != answer.Reading {
				t.Fatalf("read %q (status %q, error %v), want %q", got, status, err, answer.Reading)
			}
			if err != nil && strings.Contains(err.Error(), statusTestToken) {
				t.Errorf("the error carries the token: %v", err)
			}
		})
	}
}

func TestReadStatusSendsTheWiresRequest(t *testing.T) {
	var got struct{ method, path, authorization, contentType, body string }
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		got.method, got.path, got.body = r.Method, r.URL.RequestURI(), string(body)
		got.authorization, got.contentType = r.Header.Get("Authorization"), r.Header.Get("Content-Type")
		io.WriteString(w, `{"version":1,"state":"open"}`)
	}))
	defer server.Close()

	if _, err := ReadStatus(context.Background(), server.URL+"/", statusTestToken); err != nil {
		t.Fatal(err)
	}
	vectors := readStatusVectors(t)
	if got.method != http.MethodPost || got.path != vectors.Path || got.body != vectors.Request {
		t.Errorf("sent %s %s %q", got.method, got.path, got.body)
	}
	if got.authorization != "Bearer "+statusTestToken || got.contentType != "application/json" {
		t.Errorf("sent authorization %q, content type %q", got.authorization, got.contentType)
	}
}

// A redirect's target never sees the token: the client reads the redirect
// as an answer that is not the wire's.
func TestReadStatusFollowsNoRedirect(t *testing.T) {
	var followed bool
	target := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { followed = true }))
	defer target.Close()
	for _, code := range []int{http.StatusFound, http.StatusTemporaryRedirect, http.StatusPermanentRedirect} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			http.Redirect(w, r, target.URL+statusPath, code)
		}))
		_, err := ReadStatus(context.Background(), server.URL, statusTestToken)
		server.Close()
		if err == nil || errors.Is(err, ErrUpdateRequired) {
			t.Errorf("a %s read as %v", strconv.Itoa(code), err)
		}
	}
	if followed {
		t.Error("the client followed a redirect, with the token")
	}
}

func TestReadStatusRefusesAnAnswerPastItsBound(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		io.WriteString(w, `{"version":1,"state":"open"}`+strings.Repeat(" ", statusMaxAnswer))
	}))
	defer server.Close()
	if status, err := ReadStatus(context.Background(), server.URL, statusTestToken); err == nil {
		t.Errorf("read %q from an answer past the bound", status)
	}
}

// A stopped application and a token Go cannot send are errors, each
// without the token, and never closed.
func TestReadStatusFailuresCarryNoToken(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	stopped := server.URL
	server.Close()

	for name, token := range map[string]string{"stopped": statusTestToken, "unsendable": statusTestToken + "\n"} {
		t.Run(name, func(t *testing.T) {
			status, err := ReadStatus(context.Background(), stopped, token)
			if err == nil || status != "" {
				t.Fatalf("read %q, error %v", status, err)
			}
			if strings.Contains(err.Error(), statusTestToken) {
				t.Errorf("the error carries the token: %v", err)
			}
		})
	}
}

func TestReadStatusHonoursItsContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if status, err := ReadStatus(ctx, "http://127.0.0.1:1", statusTestToken); !errors.Is(err, context.Canceled) {
		t.Errorf("read %q, error %v", status, err)
	}
}
