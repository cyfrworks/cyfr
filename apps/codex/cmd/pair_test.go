// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/prompt"
	"github.com/spf13/cobra"
)

// The answer pairing.begin gives: the home builds the link, and the secret
// rides its fragment.
const pairingAnswer = `{"invitation_url":"https://home.example/pair#code=q2mTb0yU7aKpXv1ZcR4n8w",` +
	`"invitation_secret":"q2mTb0yU7aKpXv1ZcR4n8w","client_id":"pcl_0192f4c1-8a2e-7d3b-9c41-5e6f7a8b9c0d",` +
	`"expires_at":"2026-10-01T12:05:00Z"}`

// runCLI runs the cyfr command line with args against srv, with a
// credential and no config file of the person's, and answers what it
// printed and the error main maps to its exit code.
func runCLI(t *testing.T, srv *cliServer, args ...string) (string, error) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CYFR_TOKEN", "cyfr-test-session")
	t.Cleanup(func() {
		flagJSON, flagURL, flagContext, flagNoInteractive, flagToken = false, "", "", false, ""
		rootCmd.SetArgs(nil)
	})

	// Cobra hands a command the context of its first execution and keeps
	// it unless it is nil; each run here is a process of its own, under its
	// own test's context.
	var forget func(c *cobra.Command)
	forget = func(c *cobra.Command) {
		c.SetContext(nil)
		for _, sub := range c.Commands() {
			forget(sub)
		}
	}
	forget(rootCmd)

	rootCmd.SetArgs(append(args, "--url", srv.URL))
	var err error
	out := captureStdout(t, func() { err = Execute(t.Context()) })
	return out, err
}

// exitsOne is whether main exits 1 for err: an error that is not the
// person's own Ctrl-C.
func exitsOne(err error) bool { return err != nil && !errors.Is(err, prompt.ErrAborted) }

func (s *cliServer) call(i int) (string, map[string]any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	name, _ := s.requests[i]["name"].(string)
	args, _ := s.requests[i]["arguments"].(map[string]any)
	return name, args
}

func (s *cliServer) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.requests)
}

// `cyfr pair` begins a pairing and prints the link the home answered, with
// its expiry and the client it reserves.
func TestPair_PrintsTheLinkAndItsExpiry(t *testing.T) {
	onTerminal(t, false)
	srv := newCLIServer(t, "pairing.begin", pairingAnswer)

	out, err := runCLI(t, srv, "pair")
	if err != nil {
		t.Fatalf("cyfr pair failed: %v\n%s", err, out)
	}

	if name, args := srv.call(0); name != "pairing" || len(args) != 1 || args["action"] != "begin" {
		t.Errorf("expected pairing.begin with no arguments, got %s %v", name, args)
	}
	for _, want := range []string{
		"https://home.example/pair#code=q2mTb0yU7aKpXv1ZcR4n8w",
		"2026-10-01T12:05:00Z",
		"pcl_0192f4c1-8a2e-7d3b-9c41-5e6f7a8b9c0d",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("the output lacks %q:\n%s", want, out)
		}
	}
}

// Under --json the link, its expiry and the client, and no second copy of
// the secret the link already carries.
func TestPair_JSONIsTheLinkItsExpiryAndTheClient(t *testing.T) {
	onTerminal(t, false)
	srv := newCLIServer(t, "pairing.begin", pairingAnswer)

	out, err := runCLI(t, srv, "pair", "--json")
	if err != nil {
		t.Fatalf("cyfr pair --json failed: %v\n%s", err, out)
	}

	var printed map[string]any
	if err := json.Unmarshal([]byte(out), &printed); err != nil {
		t.Fatalf("not JSON: %v\n%s", err, out)
	}
	if printed["invitation_url"] != "https://home.example/pair#code=q2mTb0yU7aKpXv1ZcR4n8w" ||
		printed["expires_at"] != "2026-10-01T12:05:00Z" ||
		printed["client_id"] != "pcl_0192f4c1-8a2e-7d3b-9c41-5e6f7a8b9c0d" {
		t.Errorf("unexpected JSON: %v", printed)
	}
	if _, ok := printed["invitation_secret"]; ok {
		t.Errorf("the secret is printed beside the link: %v", printed)
	}
}

// An answer with no link is a failure, never an empty success: the CLI
// builds no link of its own.
func TestPair_AnAnswerWithNoLinkFails(t *testing.T) {
	onTerminal(t, false)
	srv := newCLIServer(t, "pairing.begin",
		`{"invitation_secret":"q2mTb0yU7aKpXv1ZcR4n8w","expires_at":"2026-10-01T12:05:00Z"}`)

	out, err := runCLI(t, srv, "pair")
	if !exitsOne(err) {
		t.Fatalf("expected a failure, got %v\n%s", err, out)
	}
	if strings.Contains(out, "q2mTb0yU7aKpXv1ZcR4n8w") {
		t.Errorf("the CLI built a link from the secret:\n%s", out)
	}
}

// Pairing needs a fresh confirmation, met as every command meets it: on a
// terminal the CLI names the record by its ref, waits for Enter, repeats
// under the id and prints the link; the secret is never printed.
func TestPair_MeetsItsConfirmationOnATerminal(t *testing.T) {
	term := onTerminal(t, true)
	term.enter()
	srv := newCLIServer(t, "pairing.begin", pendingSecret, pairingAnswer)

	out, err := runCLI(t, srv, "pair")
	if err != nil {
		t.Fatalf("cyfr pair failed: %v\n%s", err, out)
	}

	if got := srv.repeats(); !sameIDs(got, []string{"", pendingSecret}) {
		t.Errorf("the first call carries no id and the repeat its id, got %q", got)
	}
	for _, want := range []string{pendingRef, "Press Enter once confirmed", "https://home.example/pair#code="} {
		if !strings.Contains(out, want) {
			t.Errorf("the output lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "cnf_") {
		t.Errorf("the output shows the secret:\n%s", out)
	}
}

// Off a terminal the CLI prints the sentence, naming the ref, and exits 1:
// one request, nothing repeated, no link, and no secret printed.
func TestPair_OffATerminalExitsNonZeroWithNothingChanged(t *testing.T) {
	onTerminal(t, false)
	srv := newCLIServer(t, "pairing.begin", pendingSecret, pairingAnswer)

	out, err := runCLI(t, srv, "pair")
	if !exitsOne(err) {
		t.Fatalf("expected exit 1, got %v\n%s", err, out)
	}

	if srv.count() != 1 {
		t.Errorf("nothing may be repeated off a terminal: %d requests", srv.count())
	}
	for _, want := range []string{pendingRef, "nothing was changed", "Prism"} {
		if !strings.Contains(out, want) {
			t.Errorf("the output lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "cnf_") || strings.Contains(out, "pair#code=") {
		t.Errorf("the output shows the secret or a link:\n%s", out)
	}
}

// `cyfr pair list` lists the paired devices.
func TestPairList_ListsThePairedDevices(t *testing.T) {
	onTerminal(t, false)
	srv := newCLIServer(t, "pairing.list",
		`{"clients":[{"client_id":"pcl_one","label":"Kitchen tablet","source":"local",`+
			`"paired_at":"2026-09-30T08:00:00Z","certificate_expires_at":"2026-10-01T08:00:00Z","current":false}]}`)

	out, err := runCLI(t, srv, "pair", "list")
	if err != nil {
		t.Fatalf("cyfr pair list failed: %v\n%s", err, out)
	}
	if name, args := srv.call(0); name != "pairing" || args["action"] != "list" {
		t.Errorf("expected pairing.list, got %s %v", name, args)
	}
	for _, want := range []string{"pcl_one", "Kitchen tablet", "2026-10-01T08:00:00Z"} {
		if !strings.Contains(out, want) {
			t.Errorf("the output lacks %q:\n%s", want, out)
		}
	}
}

func TestPairList_SaysWhenThereAreNone(t *testing.T) {
	onTerminal(t, false)
	srv := newCLIServer(t, "pairing.list", `{"clients":[]}`)

	out, err := runCLI(t, srv, "pair", "list")
	if err != nil {
		t.Fatalf("cyfr pair list failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "No paired devices") {
		t.Errorf("expected the empty message:\n%s", out)
	}
}

// `cyfr pair revoke <id>` revokes the one client it names.
func TestPairRevoke_RevokesTheNamedClient(t *testing.T) {
	onTerminal(t, false)
	srv := newCLIServer(t, "pairing.revoke", `{"client_id":"pcl_one","standing":"revoked"}`)

	out, err := runCLI(t, srv, "pair", "revoke", "pcl_one")
	if err != nil {
		t.Fatalf("cyfr pair revoke failed: %v\n%s", err, out)
	}
	if name, args := srv.call(0); name != "pairing" || args["action"] != "revoke" || args["client_id"] != "pcl_one" {
		t.Errorf("expected pairing.revoke of pcl_one, got %s %v", name, args)
	}
	if !strings.Contains(out, "pcl_one") || !strings.Contains(out, "revoked") {
		t.Errorf("expected the revocation reported:\n%s", out)
	}
}

// Revoking needs a fresh confirmation too: off a terminal, exit 1 and
// nothing repeated.
func TestPairRevoke_OffATerminalExitsNonZeroWithNothingChanged(t *testing.T) {
	onTerminal(t, false)
	srv := newCLIServer(t, "pairing.revoke", pendingSecret, `{"client_id":"pcl_one","standing":"revoked"}`)

	out, err := runCLI(t, srv, "pair", "revoke", "pcl_one")
	if !exitsOne(err) {
		t.Fatalf("expected exit 1, got %v\n%s", err, out)
	}
	if srv.count() != 1 {
		t.Errorf("nothing may be repeated off a terminal: %d requests", srv.count())
	}
	if !strings.Contains(out, pendingRef) || strings.Contains(out, "cnf_") {
		t.Errorf("expected the ref and no secret:\n%s", out)
	}
	if strings.Contains(out, "' revoked") {
		t.Errorf("reported a revocation that did not happen:\n%s", out)
	}
}
