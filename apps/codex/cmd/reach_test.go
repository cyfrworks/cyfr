// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/reach"
)

// newReachProject makes the working directory a project whose .env is the
// shipped template written for a local home, as init writes it.
func newReachProject(t *testing.T) *fakeStack {
	t.Helper()
	newInitProject(t)
	s := useFakeEngine(t)
	if err := runInit(context.Background(), initOptions{noPull: true}, &bytes.Buffer{}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	s.locks, s.switches = 0, nil
	return s
}

// `cyfr reach <mode>` shows the change before it makes it: each of the
// four sentences as before → after, then what changes with the address,
// and makes it only once confirmed, as a switch bound to both digests the
// preview showed, under the lock.
func TestReachShowsTheChangeAndSwitchesOnceConfirmed(t *testing.T) {
	s := newReachProject(t)
	s.addressChanges = []string{"Passkeys at the old address stop working.", "Pair every device again."}
	askTerminal = func() bool { return true }
	askInput = strings.NewReader("yes\n")
	var out bytes.Buffer
	if err := runReach(context.Background(), reach.ModePublic, reachOptions{domain: "cyfr.example.com", acmeEmail: "ops@example.com"}, false, "", &out); err != nil {
		t.Fatalf("cyfr reach public: %v\n%s", err, out.String())
	}
	text := out.String()
	for _, line := range []string{
		"  Who can reach this home: only this computer → anyone on the internet, who still has to sign in\n",
		"  Address: http://localhost:4000 → https://cyfr.example.com\n",
		"  Certificate email: none → ops@example.com\n",
		"  Ports opened on this machine: none → 80 and 443\n",
		"  1. Passkeys at the old address stop working.\n",
		"  2. Pair every device again.\n",
		"Your CYFR identity does not change.\n",
	} {
		if !strings.Contains(text, line) {
			t.Errorf("the preview lacks %q:\n%s", line, text)
		}
	}
	if strings.Index(text, "Make this change?") < strings.Index(text, "Ports opened on this machine") {
		t.Errorf("the confirmation is asked before the change is shown:\n%s", text)
	}
	if len(s.switches) != 1 || s.locks != 1 {
		t.Fatalf("%d switches under %d locks, want one under the lock", len(s.switches), s.locks)
	}
	sw := s.switches[0]
	before := reach.Head{Mode: "local", Host: "localhost", Port: 4000, BuildsURL: defaultBuildsURL, Profiles: []string{buildsProfile}}
	if !requestIDPattern.MatchString(sw.ID) || sw.OldDigest != before.Digest() || sw.NewDigest == "" || sw.Target != (reach.Target{Mode: "public", Domain: "cyfr.example.com", ACMEEmail: "ops@example.com"}) {
		t.Errorf("the switch was %+v", sw)
	}
	if got := reachOf(t); got != reach.ModePublic {
		t.Errorf("the home is %s after the switch", got)
	}
	if holder := s.held(); holder != "" {
		t.Errorf("the lock is still held, by %s", holder)
	}
}

// Unconfirmed, nothing changes: an answer other than yes, and no terminal
// to ask on without --yes, which refuses before the lock.
func TestReachChangesNothingUnconfirmed(t *testing.T) {
	s := newReachProject(t)
	before := read(t, ".env")
	askTerminal = func() bool { return true }
	askInput = strings.NewReader("no\n")
	err := runReach(context.Background(), reach.ModePublic, reachOptions{domain: "cyfr.example.com"}, false, "", &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "not confirmed. Nothing was changed") {
		t.Errorf("an unconfirmed change answered %v", err)
	}
	askTerminal = func() bool { return false }
	locks := s.locks
	err = runReach(context.Background(), reach.ModePublic, reachOptions{domain: "cyfr.example.com"}, false, "", &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "with --yes. Nothing was changed") || s.locks != locks {
		t.Errorf("a change with no terminal and no --yes answered %v (locks %d → %d)", err, locks, s.locks)
	}
	if len(s.switches) != 0 || read(t, ".env") != before {
		t.Errorf("an unconfirmed change switched %+v", s.switches)
	}
	if err := runReach(context.Background(), reach.ModePublic, reachOptions{domain: "cyfr.example.com"}, true, "", &bytes.Buffer{}); err != nil || reachOf(t) != reach.ModePublic {
		t.Errorf("--yes did not make the change: %v", err)
	}
}

// For tailnet the machine joins first, printing the approval link, under a
// join request id derived from the switch's, so a resent request resends
// its join; the switch takes the joined machine. A machine already joined
// is not joined again, and --new-node always joins.
func TestReachTailnetJoinsFirstUnlessJoined(t *testing.T) {
	s := newReachProject(t)
	const id = "0123456789abcdef0123456789abcdef"
	var out bytes.Buffer
	if err := runReach(context.Background(), reach.ModeTailnet, reachOptions{hostname: "home"}, true, id, &out); err != nil {
		t.Fatalf("cyfr reach tailnet: %v\n%s", err, out.String())
	}
	if !strings.Contains(out.String(), "open this link and approve the machine:\n  https://login.tailscale.com/a/approve-test\n") {
		t.Errorf("the approval link is not printed:\n%s", out.String())
	}
	if len(s.joins) != 1 || s.joins[0].ID != joinRequestID(id) || s.joins[0].Hostname != "home" || s.joins[0].NewNode {
		t.Fatalf("the join was %+v", s.joins)
	}
	if joinRequestID(id) == id || !requestIDPattern.MatchString(joinRequestID(id)) || joinRequestID(id) != joinRequestID(id) {
		t.Errorf("the join's request id %q is no request id of its own", joinRequestID(id))
	}
	if len(s.switches) != 1 || s.switches[0].ID != id || s.switches[0].JoinID != "join-"+joinRequestID(id) {
		t.Fatalf("the switch was %+v", s.switches)
	}
	if host, _ := projectEnv(t).value("CYFR_HOST"); host != "cyfr.tail1234.ts.net" {
		t.Errorf("CYFR_HOST is %q", host)
	}

	// Joined already: the preview takes the machine as it is.
	s = newReachProject(t)
	s.joined[""] = reach.Join{Name: "cyfr.tail1234.ts.net", NodeID: "nTESTNODE1CNTRL"}
	if err := runReach(context.Background(), reach.ModeTailnet, reachOptions{}, true, "", &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	if len(s.joins) != 0 || len(s.switches) != 1 || s.switches[0].JoinID != "" {
		t.Errorf("a joined machine was joined again: joins %+v, switches %+v", s.joins, s.switches)
	}

	// --new-node replaces the identity, so it joins.
	s = newReachProject(t)
	s.joined[""] = reach.Join{Name: "cyfr.tail1234.ts.net", NodeID: "nTESTNODE1CNTRL"}
	if err := runReach(context.Background(), reach.ModeTailnet, reachOptions{newNode: true}, true, "", &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	if len(s.joins) != 1 || !s.joins[0].NewNode {
		t.Errorf("--new-node did not join as a new node: %+v", s.joins)
	}
}

// Every refusal is its sentence, word for word the generated one, and a
// failure: from the switch's receipt, the preview, the lock, the
// engine's open and the join; a tailnet option for another mode and a
// request id that is none refuse before the lock.
func TestReachRefusalsAreTheirSentences(t *testing.T) {
	rolled := reach.Receipt{Op: "switch", State: "completed", Outcome: "rolled_back", Code: "reach_rolled_back", Payload: map[string]string{"new": "public", "old": "local", "reason": "cyfr did not become healthy"}}
	cases := []struct {
		name    string
		prepare func(s *fakeStack)
		mode    string
		o       reachOptions
		want    string
	}{
		{"a rolled-back switch", func(s *fakeStack) { s.switchReceipt = &rolled }, reach.ModePublic, reachOptions{domain: "cyfr.example.com"}, reach.Refuse(rolled.Code, rolled.Payload).Message()},
		{"no change", nil, reach.ModeLocal, reachOptions{}, reach.Refuse("reach_unchanged", map[string]string{"address": "http://localhost:4000"}).Message()},
		{"an option of another mode", nil, reach.ModeLocal, reachOptions{domain: "cyfr.example.com"}, reach.Refuse("reach_option_outside_mode", map[string]string{"option": "--domain", "mode": "local"}).Message()},
		{"the lock held", func(s *fakeStack) { s.holder = "update" }, reach.ModePublic, reachOptions{domain: "cyfr.example.com"}, "Another cyfr command holds this home (`update`)"},
		{"COMPOSE_* in .env", func(*fakeStack) {
			f, _ := os.OpenFile(".env", os.O_APPEND|os.O_WRONLY, 0)
			f.WriteString("COMPOSE_PROFILES=public,tailnet\n")
			f.Close()
		}, reach.ModeLocal, reachOptions{}, reach.Refuse("compose_env_refused", map[string]string{"key": "COMPOSE_PROFILES"}).Message()},
		{"HTTPS off", func(s *fakeStack) {
			s.join = func(ctx context.Context, r reach.JoinRequest) (reach.Receipt, error) {
				return reach.Receipt{Op: "join", State: "completed", Outcome: "failed", Code: "tailnet_https_off", Payload: map[string]string{"name": "cyfr.tail1234.ts.net"}}, nil
			}
		}, reach.ModeTailnet, reachOptions{}, reach.Refuse("tailnet_https_off", map[string]string{"name": "cyfr.tail1234.ts.net"}).Message()},
		{"a tailnet option for public", nil, reach.ModePublic, reachOptions{domain: "cyfr.example.com", newNode: true}, "`--new-node` is for joining a tailnet, and this command chooses `public`"},
		{"a mode that is none", nil, "tls", reachOptions{}, `cyfr reach takes local, tailnet or public; "tls" is none of them`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newReachProject(t)
			if c.prepare != nil {
				c.prepare(s)
			}
			err := runReach(context.Background(), c.mode, c.o, true, "", &bytes.Buffer{})
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("cyfr reach answered %v, want %q", err, c.want)
			}
			var r *reach.Refusal
			if strings.Contains(c.want, "Nothing") && errors.As(err, &r) && err.Error() != r.Message() {
				t.Errorf("the failure %q is not the refusal's sentence %q", err, r.Message())
			}
		})
	}
	s := newReachProject(t)
	if err := runReach(context.Background(), reach.ModeLocal, reachOptions{}, true, "NOT-HEX", &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "--request-id") || s.locks != 0 {
		t.Errorf("a request id that is none answered %v", err)
	}
}

// `cyfr reach status` reads without the lock, so it answers while another
// command holds it, and prints how the home is reached, what runs, the
// unfinished change and the last one.
func TestReachStatusTakesNoLock(t *testing.T) {
	s := newReachProject(t)
	s.holder = "update"
	last := reach.Receipt{RequestID: strings.Repeat("a", 32), Op: "switch", State: "completed", Outcome: "ok", At: time.Date(2026, 10, 19, 8, 0, 0, 0, time.UTC)}
	unfinished := reach.Receipt{RequestID: strings.Repeat("b", 32), Op: "switch", State: "accepted", Phase: "stopped"}
	head := reach.Head{Mode: "local", Host: "localhost", Port: 4000, Profiles: []string{}}
	s.status = reach.Status{Head: head, Words: reach.Describe(head), Containers: []reach.Container{{Service: "cyfr", Name: "p-cyfr-1", State: "running"}}, Health: []string{"cyfr: healthy"}, Unfinished: &unfinished, Last: &last}
	var out bytes.Buffer
	if err := runReachStatus(context.Background(), &out); err != nil {
		t.Fatalf("cyfr reach status: %v", err)
	}
	for _, line := range []string{
		"  Who can reach this home: only this computer\n",
		"  Address: http://localhost:4000\n",
		"  cyfr (p-cyfr-1): running\n",
		"  cyfr: healthy\n",
		"Unfinished: The change of how this home is reached (request " + strings.Repeat("b", 32) + ") is unfinished (stopped).\n",
		"Last change, 2026-10-19T08:00:00Z: The change of how this home is reached (request " + strings.Repeat("a", 32) + ") is done.\n",
	} {
		if !strings.Contains(out.String(), line) {
			t.Errorf("the status lacks %q:\n%s", line, out.String())
		}
	}
	if s.locks != 0 || s.holder != "update" {
		t.Errorf("status took the lock")
	}

	s.status = reach.Status{HeadErr: reach.Refuse("reach_missing", nil)}
	out.Reset()
	if err := runReachStatus(context.Background(), &out); err != nil || !strings.Contains(out.String(), reach.Refuse("reach_missing", nil).Message()) {
		t.Errorf("status of a .env without CYFR_REACH answered %v:\n%s", err, out.String())
	}
}

// `cyfr reach --resume` takes the lock, runs recovery and reports each
// receipt it wrote; a change recovery could not finish is a failure whose
// sentence says what to do next.
func TestReachResumeReportsRecovery(t *testing.T) {
	s := newReachProject(t)
	var out bytes.Buffer
	if err := runReachResume(context.Background(), &out); err != nil || !strings.Contains(out.String(), "Nothing was unfinished") || s.locks != 1 {
		t.Errorf("a resume with nothing unfinished answered %v:\n%s", err, out.String())
	}
	s.resume = []reach.Receipt{
		{RequestID: strings.Repeat("c", 32), Op: "switch", State: "completed", Outcome: "not_applied"},
		{RequestID: strings.Repeat("d", 32), Op: "switch", State: "accepted", Phase: "uncertain", Code: "reach_uncertain", Payload: map[string]string{"observed": "caddy, cyfr"}},
	}
	out.Reset()
	err := runReachResume(context.Background(), &out)
	want := reach.Refuse("reach_uncertain", map[string]string{"observed": "caddy, cyfr"}).Message()
	if err == nil || err.Error() != want {
		t.Errorf("a resume that leaves a change unfinished answered %v, want %q", err, want)
	}
	if !strings.Contains(out.String(), "Recovered: The change of how this home is reached (request "+strings.Repeat("c", 32)+") is not applied.") {
		t.Errorf("the resume does not report what recovery finished:\n%s", out.String())
	}
	if holder := s.held(); holder != "" {
		t.Errorf("the lock is still held, by %s", holder)
	}
}

// The command tree is the contract's: `cyfr reach <mode>` with its flags,
// the hidden --request-id, `cyfr reach status` and `cyfr setup link`.
func TestReachCommandsAreTheContractsSurface(t *testing.T) {
	for _, name := range []string{"domain", "acme-email", "tailscale-auth-key-file", "hostname", "new-node", "yes", "resume", "request-id"} {
		if reachCmd.Flags().Lookup(name) == nil {
			t.Errorf("cyfr reach has no --%s", name)
		}
	}
	if f := reachCmd.Flags().Lookup("request-id"); f == nil || !f.Hidden {
		t.Errorf("--request-id is not hidden")
	}
	for _, name := range []string{"reach", "domain", "acme-email", "tailscale-auth-key-file", "hostname", "no-pull", "force"} {
		if initCmd.Flags().Lookup(name) == nil {
			t.Errorf("cyfr init has no --%s", name)
		}
	}
	if subcommand(reachCmd, "status") == nil || subcommand(subcommand(rootCmd, "setup"), "link") == nil {
		t.Errorf("cyfr reach status or cyfr setup link is missing")
	}
	internal := subcommand(rootCmd, "internal")
	if internal == nil || !internal.Hidden || subcommand(internal, "docker-run") == nil || !subcommand(internal, "docker-run").DisableFlagParsing {
		t.Errorf("cyfr internal docker-run is not the hidden, unparsed watchdog command")
	}
	if err := reachCmd.RunE(reachCmd, nil); err == nil || !strings.Contains(err.Error(), "name the mode") {
		t.Errorf("cyfr reach with no mode answered %v", err)
	}
}

// readAuthKey reads one key from its file, trimmed; a file with none, or
// with more than one line, refuses.
func TestReadAuthKey(t *testing.T) {
	dir := t.TempDir()
	for text, want := range map[string]string{"tskey-auth-k1\n": "tskey-auth-k1", "  tskey-auth-k1  ": "tskey-auth-k1", "": "", "a\nb\n": ""} {
		path := filepath.Join(dir, "key")
		if err := os.WriteFile(path, []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
		key, err := readAuthKey(path)
		if string(key) != want || (want == "") != (err != nil) {
			t.Errorf("readAuthKey(%q) = %q, %v", text, key, err)
		}
		if err != nil && strings.Contains(err.Error(), "tskey") {
			t.Errorf("a refusal names the key: %v", err)
		}
	}
	if key, err := readAuthKey(""); key != nil || err != nil {
		t.Errorf("no key file answered %q, %v", key, err)
	}
}
