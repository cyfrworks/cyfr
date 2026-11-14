// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package account_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/account/accounttest"
)

// chainVectors is identity.json's chain "a passkey added by the device",
// with the keys and entries it names.
type chainVectors struct {
	Keys    map[string]map[string]string `json:"keys"`
	Entries map[string]struct {
		Entry map[string]any `json:"entry"`
	} `json:"entries"`
	Chains []struct {
		Name    string         `json:"name"`
		Entries []string       `json:"entries"`
		State   map[string]any `json:"state"`
	} `json:"chains"`
}

// passkeyChain is a directory holding that chain's account before its
// passkey: its genesis and its device, device_1. It answers the service,
// the identifier, the device's key, passkey_1 as ReadKey reads it, and
// the at of the add_key the chain holds.
func passkeyChain(t *testing.T) (*accounttest.Service, string, ed25519.PrivateKey, account.Key, int64) {
	t.Helper()
	svc, identifier, device, passkey, want, _ := readPasskeyChain(t)
	at, err := want["at"].(json.Number).Int64()
	if err != nil {
		t.Fatal(err)
	}
	return svc, identifier, device, passkey, at
}

func readPasskeyChain(t *testing.T) (*accounttest.Service, string, ed25519.PrivateKey, account.Key, map[string]any, map[string]any) {
	t.Helper()
	var v chainVectors
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "tests", "fixtures", "identity.json"))
	if err != nil {
		t.Fatal(err)
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&v); err != nil {
		t.Fatal(err)
	}
	i := slices.IndexFunc(v.Chains, func(c struct {
		Name    string         `json:"name"`
		Entries []string       `json:"entries"`
		State   map[string]any `json:"state"`
	}) bool {
		return c.Name == "a passkey added by the device"
	})
	if i < 0 || len(v.Chains[i].Entries) != 3 {
		t.Fatal("identity.json holds no chain of a passkey added by the device")
	}
	added := v.Chains[i]
	identifier := added.State["identifier"].(string)
	svc := accounttest.New(t)
	for _, name := range added.Entries[:2] {
		svc.Append(t, identifier, v.Entries[name].Entry)
	}
	seed, _ := account.UnB64(v.Keys["device_1"]["seed"], 32, 32)
	pk := v.Keys["passkey_1"]
	passkey, ok := account.ReadKey(map[string]any{"kid": pk["kid"], "alg": pk["alg"], "kind": "passkey",
		"pub": pk["public"], "credential_id": pk["credential_id"]})
	if !ok {
		t.Fatal("passkey_1's descriptor does not read")
	}
	return svc, identifier, ed25519.NewKeyFromSeed(seed), passkey, v.Entries[added.Entries[2]].Entry, added.State
}

// A device key adds a passkey to its account as identity.json's chain "a
// passkey added by the device" does: the entry kept is that chain's add_key
// byte for byte, the log walks to the chain's keys, and a second approval
// of the same passkey is ErrListed and keeps nothing more.
func TestApprove_AddsAPasskeyAsTheFixturesChainDoes(t *testing.T) {
	svc, identifier, device, passkey, want, chainState := readPasskeyChain(t)
	at, err := want["at"].(json.Number).Int64()
	if err != nil {
		t.Fatal(err)
	}
	d := account.Directory{URL: svc.URL()}
	sign := func(m []byte) []byte { return ed25519.Sign(device, m) }
	if err := account.Approve(context.Background(), d, identifier, device.Public().(ed25519.PublicKey), sign, passkey, at); err != nil {
		t.Fatal(err)
	}

	log := svc.Log(identifier)
	got, _ := account.JCS(log[len(log)-1])
	wanted, _ := account.JCS(want)
	if len(log) != 3 || !bytes.Equal(got, wanted) {
		t.Fatalf("the log kept %d entries, the last\n %s\nwant %s", len(log), got, wanted)
	}
	st := svc.State(t, identifier)
	keys := make([]any, len(st.Keys))
	for i, k := range st.Keys {
		keys[i] = k.Map()
	}
	gotKeys, _ := account.JCS(keys)
	wantKeys, _ := account.JCS(chainState["keys"])
	if !bytes.Equal(gotKeys, wantKeys) || st.Head != chainState["head"] {
		t.Fatalf("the log walks to head %s, keys\n %s\nwant %s, keys\n %s", st.Head, gotKeys, chainState["head"], wantKeys)
	}

	writes := svc.Writes
	err = account.Approve(context.Background(), d, identifier, device.Public().(ed25519.PublicKey), sign, passkey, at+1)
	if !errors.Is(err, account.ErrListed) || len(svc.Log(identifier)) != 3 || svc.Writes != writes {
		t.Fatalf("a second approval is %v, the log holds %d entries, %d writes after %d", err, len(svc.Log(identifier)), svc.Writes, writes)
	}
}

// step is what a scripted directory does with one request, in order.
type step func(base http.RoundTripper, r *http.Request) (*http.Response, error)

// forward passes the request on; lose passes it on and loses its answer;
// drop loses the request before it arrives; reply answers it itself.
func forward(base http.RoundTripper, r *http.Request) (*http.Response, error) {
	return base.RoundTrip(r)
}

func lose(base http.RoundTripper, r *http.Request) (*http.Response, error) {
	resp, err := base.RoundTrip(r)
	if err == nil {
		resp.Body.Close()
	}
	return nil, errors.New("the answer was lost")
}

func drop(http.RoundTripper, *http.Request) (*http.Response, error) {
	return nil, errors.New("the request was lost")
}

func reply(status int, body string) step {
	return func(_ http.RoundTripper, r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: status, Header: http.Header{"Content-Type": {"application/json"}},
			Body: io.NopCloser(strings.NewReader(body)), Request: r}, nil
	}
}

// scripted answers its requests by steps, one each, in order, and fails a
// request past its script.
type scripted struct {
	base  http.RoundTripper
	steps []step
	ran   int
}

func (s *scripted) RoundTrip(r *http.Request) (*http.Response, error) {
	if s.ran >= len(s.steps) {
		return nil, fmt.Errorf("request %d (%s %s) is past the script", s.ran+1, r.Method, r.URL.Path)
	}
	s.ran++
	return s.steps[s.ran-1](s.base, r)
}

// Once an add_key was sent and its answer lost, every way Approve ends is
// ErrUnanswered but an answer that shows the entry's state: the same bytes
// accepted or exists, duplicate_key, or a log read that succeeds after
// stale_head. The requests are, in order, the log read, the add_key, the
// same add_key again, then after a stale_head the next read and add_keys.
func TestApprove_AnUnansweredSendIsSettledOnlyByTheLogsState(t *testing.T) {
	stale := reply(http.StatusConflict, `{"error":"stale_head"}`)
	for _, c := range []struct {
		name   string
		steps  []step
		cancel bool
		want   error // nil for added; ErrListed; ErrUnanswered
		lands  bool  // whether the passkey is in the log at the end
	}{
		{"sent again: exists", []step{forward, lose, forward}, false, nil, true},
		{"sent again: duplicate_key", []step{forward, lose, reply(http.StatusConflict, `{"error":"duplicate_key"}`)}, false, account.ErrListed, true},
		{"sent again: stale_head, then a read listing it", []step{forward, lose, stale, forward}, false, account.ErrListed, true},
		{"sent again: stale_head, then a read not listing it", []step{forward, drop, stale, forward, forward}, false, nil, true},
		{"sent again: rate limited", []step{forward, lose, reply(http.StatusTooManyRequests, `{"error":"rate_limited","retry_after":60}`)}, false, account.ErrUnanswered, true},
		{"sent again: server error", []step{forward, lose, reply(http.StatusServiceUnavailable, `{"error":"unavailable"}`)}, false, account.ErrUnanswered, true},
		{"sent again: lost", []step{forward, lose, lose}, false, account.ErrUnanswered, true},
		{"sent again: refused otherwise", []step{forward, lose, reply(http.StatusUnprocessableEntity, `{"error":"unverified"}`)}, false, account.ErrUnanswered, true},
		{"sent again: stale_head, then a read that fails", []step{forward, lose, stale, reply(http.StatusServiceUnavailable, `{"error":"unavailable"}`)}, false, account.ErrUnanswered, true},
		{"sent again: stale_head, then a read whose answer is lost", []step{forward, lose, stale, lose}, false, account.ErrUnanswered, true},
		{"stale_head twice, the second send's answer lost", []step{forward, drop, stale, forward, lose, stale}, false, account.ErrUnanswered, true},
		{"after a read, the next send lost and rate limited", []step{forward, drop, stale, forward, lose, reply(http.StatusTooManyRequests, `{"error":"rate_limited"}`)}, false, account.ErrUnanswered, true},
		{"the context cancelled once sent", []step{forward, lose}, true, account.ErrUnanswered, true},
	} {
		t.Run(c.name, func(t *testing.T) {
			svc, identifier, device, passkey, at := passkeyChain(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			steps := c.steps
			if c.cancel {
				steps = append(steps[:len(steps)-1:len(steps)-1], func(base http.RoundTripper, r *http.Request) (*http.Response, error) {
					resp, err := lose(base, r)
					cancel()
					return resp, err
				})
			}
			transport := &scripted{base: http.DefaultTransport, steps: steps}
			d := account.Directory{URL: svc.URL(), Client: &http.Client{Transport: transport}}
			sign := func(m []byte) []byte { return ed25519.Sign(device, m) }
			err := account.Approve(ctx, d, identifier, device.Public().(ed25519.PublicKey), sign, passkey, at)
			_, landed := svc.State(t, identifier).Key(passkey.Kid)
			switch {
			case c.want == nil && err != nil, c.want != nil && !errors.Is(err, c.want):
				t.Fatalf("Approve answered %v, want %v", err, c.want)
			case c.want == account.ErrUnanswered && !errors.Is(err, account.ErrUnreachable):
				t.Fatalf("an unanswered send is not also unreachable: %v", err)
			case landed != c.lands || (!c.cancel && transport.ran != len(steps)):
				t.Fatalf("landed %v after %d of %d requests", landed, transport.ran, len(steps))
			}
		})
	}

	// A first send refused is answered: nothing was added, and it says so.
	svc, identifier, device, passkey, at := passkeyChain(t)
	transport := &scripted{base: http.DefaultTransport, steps: []step{forward, reply(http.StatusTooManyRequests, `{"error":"rate_limited"}`)}}
	d := account.Directory{URL: svc.URL(), Client: &http.Client{Transport: transport}}
	sign := func(m []byte) []byte { return ed25519.Sign(device, m) }
	err := account.Approve(context.Background(), d, identifier, device.Public().(ed25519.PublicKey), sign, passkey, at)
	var ref *account.DirectoryRefusal
	if !errors.As(err, &ref) || ref.Code != "rate_limited" || errors.Is(err, account.ErrUnreachable) {
		t.Fatalf("a refused first send answered %v", err)
	}
	if _, landed := svc.State(t, identifier).Key(passkey.Kid); landed {
		t.Fatal("a refused first send landed")
	}
}
