// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package account

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Every request reads back to its map, each sign_in and confirm request's
// digest is reproduced, every device answer to one is re-signed byte for
// byte, and each malformed request is refused with its reason and field.
func TestSignIn_RequestsDigestsAndDeviceAnswers(t *testing.T) {
	var v struct {
		Keys     map[string]vectorKey `json:"keys"`
		Requests map[string]struct {
			Digest  string         `json:"digest"`
			Request map[string]any `json:"request"`
		} `json:"requests"`
		Answers map[string]struct {
			Answer  map[string]any `json:"answer"`
			Kind    string         `json:"kind"`
			Request string         `json:"request"`
			Signer  *string        `json:"signer"`
		} `json:"answers"`
		Refusals []struct {
			Name, Error, Field string
			Request            map[string]any
		} `json:"request_refusals"`
	}
	fixture(t, "sign_in.json", &v)
	digests := 0
	for name, c := range v.Requests {
		r, err := ReadRequest(c.Request)
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		a, _ := JCS(r.Map)
		b, _ := JCS(c.Request)
		if !bytes.Equal(a, b) {
			t.Errorf("%s: read back %s", name, a)
		}
		if c.Digest != "" {
			digests++
			if d, err := r.Digest(); err != nil || B64(d) != c.Digest {
				t.Errorf("%s: digest %s %v", name, B64(d), err)
			}
		}
	}
	answered := 0
	for name, c := range v.Answers {
		purpose := v.Requests[c.Request].Request["purpose"]
		if c.Kind != "device" || c.Signer == nil || purpose == "registry" {
			continue
		}
		r, _ := ReadRequest(v.Requests[c.Request].Request)
		key := v.Keys[*c.Signer].priv(t)
		got, err := r.Answer(c.Answer["kid"].(string), func(m []byte) []byte { return ed25519.Sign(key, m) })
		a, _ := JCS(got)
		b, _ := JCS(c.Answer)
		if err != nil || !bytes.Equal(a, b) {
			t.Errorf("%s: %s", name, a)
		}
		answered++
	}
	for _, c := range v.Refusals {
		_, err := ReadRequest(c.Request)
		r, ok := err.(*Refusal)
		if !ok || r.Reason != c.Error || r.Field != c.Field {
			t.Errorf("%s: %v, want %s %s", c.Name, err, c.Error, c.Field)
		}
	}
	if digests < 2 || answered < 3 || len(v.Refusals) < 10 {
		t.Fatalf("the vectors held %d digests, %d device answers, %d refusals", digests, answered, len(v.Refusals))
	}
}

// Every request an Ed25519 key signed is re-signed to its bytes, but one
// whose bytes pass the bound, which its signer refuses; every handle
// answer reaches its result or refusal, every envelope its refusal, and
// every handle spelling its grammar.
func TestRegistry_RequestsAnswersAndEnvelopes(t *testing.T) {
	var v struct {
		Keys     map[string]vectorKey `json:"keys"`
		Requests map[string]struct {
			Request map[string]any `json:"request"`
			Signer  *string        `json:"signer"`
		} `json:"requests"`
		Answers []struct {
			Bytes, Error, Handle, Name, Registry string
			Result                               map[string]string
		} `json:"answers"`
		Envelopes []struct{ Bytes, Error, Name, Refusal string } `json:"envelopes"`
		Slugs     struct {
			Handles struct{ Valid, Invalid []string } `json:"handles"`
		} `json:"slugs"`
	}
	fixture(t, "registry_wire.json", &v)
	signed := 0
	for name, c := range v.Requests {
		if c.Signer == nil || v.Keys[*c.Signer].Alg != "ed25519" {
			continue
		}
		if _, isText := c.Request["sig"].(string); !isText {
			continue
		}
		want, _ := JCS(c.Request)
		got, err := SignRegistryRequest(clone(c.Request, "sig"), v.Keys[*c.Signer].priv(t))
		switch {
		case len(want) > maxRequestBytes:
			if err == nil {
				t.Errorf("%s: signed past the bound", name)
			}
		case err != nil || !bytes.Equal(got, want):
			t.Errorf("%s: %v", name, err)
		default:
			signed++
		}
		if _, err := ReadToSign(clone(c.Request, "sig", "signer")); err != nil && len(want) <= maxRequestBytes {
			t.Errorf("%s: not read to sign: %v", name, err)
		}
	}
	for _, c := range v.Answers {
		got, err := ReadHandle([]byte(c.Bytes), c.Handle, c.Registry)
		if c.Error != "" {
			if r, ok := err.(*Refusal); !ok || r.Reason != c.Error {
				t.Errorf("%s: %v, want %s", c.Name, err, c.Error)
			}
			continue
		}
		want := HandleAnswer{c.Result["registry"], c.Result["handle"], c.Result["identifier"], c.Result["directory"]}
		if err != nil || got != want {
			t.Errorf("%s: %+v %v", c.Name, got, err)
		}
	}
	for _, c := range v.Envelopes {
		want := c.Refusal
		if c.Error != "" {
			want = c.Error
		}
		if got := RegistryRefusal([]byte(c.Bytes)); got != want {
			t.Errorf("%s: %s, want %s", c.Name, got, want)
		}
	}
	for _, h := range v.Slugs.Handles.Valid {
		if !IsHandle(h) {
			t.Errorf("handle %q refused", h)
		}
	}
	for _, h := range v.Slugs.Handles.Invalid {
		if IsHandle(h) {
			t.Errorf("handle %q taken", h)
		}
	}
	if signed < 10 || len(v.Answers) < 10 || len(v.Envelopes) < 20 {
		t.Fatalf("the vectors held %d signed requests, %d answers, %d envelopes", signed, len(v.Answers), len(v.Envelopes))
	}
}

// Every valid code reads to its identifier and secret and is composed
// back from them; every spelling reads as its code; every refused text is
// refused with its reason.
func TestRecoveryCode_ReadsAndComposesTheFixture(t *testing.T) {
	var v struct {
		Valid     []struct{ Code, Identifier, Secret, Name string } `json:"valid"`
		Spellings []struct{ Code, Text, Name string }               `json:"spellings"`
		Refused   []struct{ Error, Text, Name string }              `json:"refused"`
	}
	fixture(t, "recovery_code.json", &v)
	for _, c := range v.Valid {
		id, secret, err := DecodeRecoveryCode(c.Code)
		if err != nil || id != c.Identifier || B64(secret) != c.Secret {
			t.Errorf("%s: %s %s %v", c.Name, id, B64(secret), err)
		}
		if code, err := EncodeRecoveryCode(id, secret); err != nil || code != c.Code {
			t.Errorf("%s: composed %s", c.Name, code)
		}
	}
	for _, c := range v.Spellings {
		id, secret, err := DecodeRecoveryCode(c.Text)
		wid, wsecret, _ := DecodeRecoveryCode(c.Code)
		if err != nil || id != wid || !bytes.Equal(secret, wsecret) {
			t.Errorf("spelling %s: %v", c.Name, err)
		}
	}
	for _, c := range v.Refused {
		if _, _, err := DecodeRecoveryCode(c.Text); err == nil || err.Error() != c.Error {
			t.Errorf("refused %s: %v, want %s", c.Name, err, c.Error)
		}
	}
	if len(v.Valid) == 0 || len(v.Refused) == 0 {
		t.Fatal("the vectors held no codes")
	}
}

// The directory client against every scenario of directory_wire.json it
// sends: each write it makes is the scenario's request, byte for byte as
// JCS, and it reads each answer as the scenario names it (created,
// exists, accepted, or the refusal and the head it names); each log the
// scenario reads whole walks to the head and length it answers.
func TestDirectory_ScenariosAsTheClientMeetsThem(t *testing.T) {
	var v struct {
		Scenarios []struct {
			Name  string `json:"name"`
			Steps []struct {
				Request *struct {
					Method string            `json:"method"`
					Path   string            `json:"path"`
					Query  map[string]string `json:"query"`
					Body   map[string]any    `json:"body"`
				} `json:"request"`
				Expect struct {
					Status int            `json:"status"`
					Body   map[string]any `json:"body"`
				} `json:"expect"`
			} `json:"steps"`
		} `json:"scenarios"`
	}
	fixture(t, "directory_wire.json", &v)
	writes, reads := 0, 0
	for _, sc := range v.Scenarios {
		for i, step := range sc.Steps {
			r := step.Request
			if r == nil {
				continue
			}
			want := step.Expect
			answer := func(w http.ResponseWriter) {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(want.Status)
				raw, _ := json.Marshal(want.Body)
				w.Write(raw)
			}
			switch {
			case r.Method == http.MethodPost && want.Status >= 500:
				srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) { answer(w) }))
				_, err := Directory{URL: srv.URL}.Register(context.Background(), r.Body)
				srv.Close()
				if !errors.Is(err, ErrUnreachable) {
					t.Errorf("%s step %d: a %d is %v, not unreachable", sc.Name, i, want.Status, err)
				}
			case r.Method == http.MethodPost && want.Status != http.StatusRequestEntityTooLarge && want.Status != http.StatusTooManyRequests:
				sent, err := JCS(r.Body)
				if err != nil {
					continue
				}
				var got []byte
				var path string
				srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
					got, _ = io.ReadAll(req.Body)
					path = req.URL.Path
					answer(w)
				}))
				d := Directory{URL: srv.URL}
				var written Written
				if r.Path == "/directory/v1/register" {
					written, err = d.Register(context.Background(), r.Body)
				} else {
					id := strings.Split(strings.TrimPrefix(r.Path, "/directory/v1/"), "/")[0]
					written, err = d.Append(context.Background(), id, r.Body)
				}
				srv.Close()
				if !bytes.Equal(got, sent) || path != r.Path {
					t.Errorf("%s step %d: sent %s to %s", sc.Name, i, got, path)
				}
				if want.Status == http.StatusOK {
					if err != nil || written.Result != want.Body["result"] || (want.Body["head"] != nil && written.Head != want.Body["head"]) {
						t.Errorf("%s step %d: %+v %v", sc.Name, i, written, err)
					}
				} else {
					ref, ok := err.(*DirectoryRefusal)
					if !ok || ref.Code != want.Body["error"] || ref.Status != want.Status ||
						(want.Body["head"] != nil && ref.Head != want.Body["head"]) ||
						(want.Body["reason"] != nil && ref.Reason != want.Body["reason"]) {
						t.Errorf("%s step %d: %v, want %v", sc.Name, i, err, want.Body)
					}
				}
				writes++
			case r.Method == http.MethodGet && !strings.Contains(r.Path, "/from/") && want.Status == http.StatusOK &&
				want.Body["next"] == nil && want.Body["from"] == json.Number("0"):
				srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) { answer(w) }))
				id := strings.TrimPrefix(r.Path, "/directory/v1/")
				s, err := Directory{URL: srv.URL}.Read(context.Background(), id)
				srv.Close()
				length, _ := ms(want.Body["length"])
				if err != nil || s.Head != want.Body["head"] || s.Seq+1 != length {
					t.Errorf("%s step %d: read %+v %v", sc.Name, i, s, err)
				}
				reads++
			case r.Method == http.MethodGet && want.Status == http.StatusGone && !strings.Contains(r.Path, "/from/"):
				srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) { answer(w) }))
				_, err := Directory{URL: srv.URL}.Read(context.Background(), strings.TrimPrefix(r.Path, "/directory/v1/"))
				srv.Close()
				if ref, ok := err.(*DirectoryRefusal); !ok || ref.Code != "gone" {
					t.Errorf("%s step %d: %v", sc.Name, i, err)
				}
				reads++
			}
		}
	}
	if writes < 20 || reads < 3 {
		t.Fatalf("the scenarios gave %d writes and %d reads", writes, reads)
	}
}

// A log that spans pages is read page by page from after=-1, each page
// following the last, and walked whole.
func TestDirectory_ReadsEveryPage(t *testing.T) {
	var v struct {
		Scenarios []struct {
			Name  string `json:"name"`
			Steps []struct {
				Request *struct {
					Method string            `json:"method"`
					Path   string            `json:"path"`
					Query  map[string]string `json:"query"`
				} `json:"request"`
				Expect struct {
					Body map[string]any `json:"body"`
				} `json:"expect"`
			} `json:"steps"`
		} `json:"scenarios"`
	}
	fixture(t, "directory_wire.json", &v)
	pages := map[string]map[string]any{}
	var id string
	for _, sc := range v.Scenarios {
		if sc.Name != "bounded pages and the last page" {
			continue
		}
		for _, s := range sc.Steps {
			if s.Request != nil && s.Request.Method == http.MethodGet && s.Request.Query["after"] != "" {
				pages[s.Request.Query["after"]] = s.Expect.Body
				id = strings.TrimPrefix(s.Request.Path, "/directory/v1/")
			}
		}
	}
	var asked []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		after := r.URL.Query().Get("after")
		asked = append(asked, after)
		raw, _ := json.Marshal(pages[after])
		w.Write(raw)
	}))
	defer srv.Close()
	s, err := Directory{URL: srv.URL}.Read(context.Background(), id)
	if err != nil || s.Seq != 8 || s.Head != pages["-1"]["head"] || strings.Join(asked, ",") != "-1,5" {
		t.Fatalf("read %+v %v, asked %v", s, err, asked)
	}
}
