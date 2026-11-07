// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/holder"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/ops"
)

// registryAsked is sign_in.json's registry request, as a CYFR hands it to
// a terminal, and the record of a command line whose account it names.
func registryAsked(t *testing.T) (map[string]any, *holder.Record) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "tests", "fixtures", "sign_in.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Requests map[string]struct {
			Request map[string]any `json:"request"`
		} `json:"requests"`
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&v); err != nil {
		t.Fatal(err)
	}
	asked := v.Requests["registry"].Request
	rec, err := holder.NewSoftware([]byte(passphrase))
	if err != nil {
		t.Fatal(err)
	}
	rec.Identifier = asked["registry_request"].(map[string]any)["identifier"].(string)
	return asked, rec
}

// A registry request is signed only after the PIN or passphrase is asked
// again, for every signature, after what is signed is shown: the request
// the CYFR composed, its signer this key's kid and its sig this key's over
// its JCS bytes without sig. A second signature with no secret typed for
// it signs nothing, a wrong secret signs nothing, and a request for
// another account, another CYFR or another purpose is refused before
// anything is asked.
func TestSignRegistryRequest_AsksTheUnlockForEachSignature(t *testing.T) {
	asked, rec := registryAsked(t)
	home := asked["audience"].(string)
	c, out := typed(passphrase)
	got, err := signRegistryRequest(t.Context(), c, rec, home, asked)
	if err != nil {
		t.Fatal(err)
	}
	signed := got.(map[string]any)
	if signed["signer"] != account.Kid(rec.PublicKey) {
		t.Fatalf("signer %v", signed["signer"])
	}
	for k, v := range asked["registry_request"].(map[string]any) {
		if a, b := jcs(t, signed[k]), jcs(t, v); a != b {
			t.Errorf("%s: %s, composed %s", k, a, b)
		}
	}
	msg, _ := account.SigningBytes(signed)
	sig, _ := account.UnB64(signed["sig"], 64, 64)
	if !ed25519.Verify(rec.PublicKey, msg, sig) {
		t.Fatal("the signature does not verify under this key")
	}
	printed := out.String()
	words := strings.Index(printed, "Claim the name @alice at cyfr.run, signed by your account.")
	if words < 0 || words > strings.Index(printed, "passphrase: ") || strings.Contains(printed, "handle.claim") {
		t.Fatalf("what is signed was not said in words before the secret was asked:\n%s", printed)
	}

	if _, err := signRegistryRequest(t.Context(), c, rec, home, asked); !errors.Is(err, errInputEnded) {
		t.Fatalf("a second signature with no secret typed: %v", err)
	}
	if strings.Count(out.String(), "passphrase: ") != 2 {
		t.Fatalf("the second signature did not ask the passphrase again:\n%s", out)
	}
	c, _ = typed("abandon ability able about above zoo")
	if _, err := signRegistryRequest(t.Context(), c, rec, home, asked); err == nil || !strings.Contains(err.Error(), "Nothing was signed") {
		t.Fatalf("a wrong passphrase: %v", err)
	}

	other := *rec
	other.Identifier = "per_" + strings.Repeat("0", 64)
	signIn := map[string]any{}
	for k, v := range asked {
		signIn[k] = v
	}
	signIn["purpose"] = "sign_in"
	delete(signIn, "registry_request")
	for name, try := range map[string]func(*console) error{
		"another account": func(c *console) error { _, err := signRegistryRequest(t.Context(), c, &other, home, asked); return err },
		"another CYFR": func(c *console) error {
			_, err := signRegistryRequest(t.Context(), c, rec, "https://bob.example", asked)
			return err
		},
		"a sign-in": func(c *console) error { _, err := signRegistryRequest(t.Context(), c, rec, home, signIn); return err },
	} {
		c, out := typed(passphrase)
		if err := try(c); err == nil || strings.Contains(out.String(), "passphrase: ") {
			t.Errorf("%s: %v\n%s", name, err, out)
		}
	}
}

// A registry action the person signs is made twice: without an answer,
// which answers the CYFR's request, then with the same arguments and the
// signed request as its answer; an action that answers anything else is
// made once.
func TestSignedRegistry_AnswersTheRequestInASecondCall(t *testing.T) {
	asked, _ := registryAsked(t)
	saved := registrySigner
	t.Cleanup(func() { registrySigner = saved })
	var signedFor []string
	registrySigner = func(_ context.Context, address string, got any) (any, error) {
		signedFor = append(signedFor, address)
		return map[string]any{"signed": got.(map[string]any)["challenge"]}, nil
	}
	var answers []ops.Field[any]
	client := mcp.NewClient("https://alice.example")
	result, err := signedRegistry(t.Context(), client, func(answer ops.Field[any]) (map[string]any, error) {
		answers = append(answers, answer)
		if answer.IsZero() {
			return map[string]any{"request": asked}, nil
		}
		return map[string]any{"personal_namespace": "alice"}, nil
	})
	if err != nil || result["personal_namespace"] != "alice" || len(answers) != 2 || !answers[0].IsZero() || len(signedFor) != 1 {
		t.Fatalf("result %v (%v), %d calls", result, err, len(answers))
	}
	raw, _ := json.Marshal(ops.RegistrySyncArgs{Answer: answers[1]})
	if !strings.Contains(string(raw), `"answer":{"signed":"`+asked["challenge"].(string)+`"}`) || !strings.Contains(string(raw), `"action":"sync"`) {
		t.Fatalf("the second call's arguments: %s", raw)
	}

	calls := 0
	result, err = signedRegistry(t.Context(), client, func(ops.Field[any]) (map[string]any, error) {
		calls++
		return map[string]any{"slug": "acme.com", "token_stored": true}, nil
	})
	if err != nil || calls != 1 || result["slug"] != "acme.com" || len(signedFor) != 1 {
		t.Fatalf("an answer with no request: %v %v, %d calls", result, err, calls)
	}
}

// Each registry operation is said in the account pages' words, naming
// every field of its body and never the operation's name.
func TestRegistryWords_SayEachOperationAsTheAccountPagesDo(t *testing.T) {
	for _, c := range []struct {
		operation string
		body      map[string]any
		want      string
	}{
		{"handle.claim", map[string]any{"handle": "mira"}, "Claim the name @mira at cyfr.run"},
		{"policy.accept", map[string]any{"policy_version": "2026-10"}, "Accept the terms (version 2026-10) at cyfr.run"},
		{"tokens.mint", map[string]any{"label": "laptop"}, "Create a publishing token named “laptop” at cyfr.run"},
		{"appeal.file", map[string]any{"action_type": "takedown", "action_ref": "act_1", "argument": "It is mine."},
			"Appeal the takedown act_1 at cyfr.run, saying: “It is mine.”"},
		{"publisher.claim", map[string]any{"slug": "acme.com"}, "Claim the publisher name acme.com at cyfr.run"},
		{"publisher.verify", map[string]any{"slug": "acme.com", "label": "ci"},
			"Confirm the publisher name acme.com at cyfr.run, with a publishing token named “ci”"},
	} {
		got := registryWords(map[string]any{"registry": "cyfr.run", "operation": c.operation, "body": c.body})
		if got != c.want || strings.Contains(got, c.operation) {
			t.Errorf("%s: %q, want %q", c.operation, got, c.want)
		}
	}
}

func jcs(t *testing.T, v any) string {
	t.Helper()
	raw, _ := json.Marshal(v)
	d, _ := account.Decode(raw)
	out, err := account.JCS(d)
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}
