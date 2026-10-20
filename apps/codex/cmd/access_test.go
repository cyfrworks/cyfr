// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/spf13/cobra"
)

// newAccessProject makes the working directory a project whose .env is the
// shipped template written for a local home, as init writes it.
func newAccessProject(t *testing.T) *fakeStack {
	t.Helper()
	newInitProject(t)
	s := useFakeEngine(t)
	if err := runInit(context.Background(), initOptions{noPull: true}, &bytes.Buffer{}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	s.locks, s.switches = 0, nil
	return s
}

// `cyfr access <mode>` shows the change before it makes it: each of the
// four sentences as before → after, then what changes with the address,
// and makes it only once confirmed, as a switch bound to both digests the
// preview showed, under the lock.
func TestAccessShowsTheChangeAndSwitchesOnceConfirmed(t *testing.T) {
	s := newAccessProject(t)
	s.addressChanges = []string{"Passkeys at the old address stop working.", "Pair every device again."}
	askTerminal = func() bool { return true }
	askInput = strings.NewReader("yes\n")
	var out bytes.Buffer
	if err := runAccess(context.Background(), access.ModePublic, accessOptions{domain: "cyfr.example.com", acmeEmail: "ops@example.com"}, false, "", &out); err != nil {
		t.Fatalf("cyfr access public: %v\n%s", err, out.String())
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
	before := access.Head{Mode: "local", Host: "localhost", Port: 4000, BuildsURL: defaultBuildsURL, Profiles: []string{buildsProfile}}
	if !requestIDPattern.MatchString(sw.ID) || sw.OldDigest != before.Digest() || sw.NewDigest == "" || sw.Target != (access.Target{Mode: "public", Domain: "cyfr.example.com", ACMEEmail: "ops@example.com"}) {
		t.Errorf("the switch was %+v", sw)
	}
	if got := accessOf(t); got != access.ModePublic {
		t.Errorf("the home is %s after the switch", got)
	}
	if holder := s.held(); holder != "" {
		t.Errorf("the lock is still held, by %s", holder)
	}
}

// Unconfirmed, nothing changes: an answer other than yes, and no terminal
// to ask on without --yes, which refuses before the lock.
func TestAccessChangesNothingUnconfirmed(t *testing.T) {
	s := newAccessProject(t)
	before := read(t, ".env")
	askTerminal = func() bool { return true }
	askInput = strings.NewReader("no\n")
	err := runAccess(context.Background(), access.ModePublic, accessOptions{domain: "cyfr.example.com"}, false, "", &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "not confirmed. Nothing was changed") {
		t.Errorf("an unconfirmed change answered %v", err)
	}
	askTerminal = func() bool { return false }
	locks := s.locks
	err = runAccess(context.Background(), access.ModePublic, accessOptions{domain: "cyfr.example.com"}, false, "", &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "Nothing was changed. Run it again with --yes") || s.locks != locks {
		t.Errorf("a change with no terminal and no --yes answered %v (locks %d → %d)", err, locks, s.locks)
	}
	if len(s.switches) != 0 || read(t, ".env") != before {
		t.Errorf("an unconfirmed change switched %+v", s.switches)
	}
	if err := runAccess(context.Background(), access.ModePublic, accessOptions{domain: "cyfr.example.com"}, true, "", &bytes.Buffer{}); err != nil || accessOf(t) != access.ModePublic {
		t.Errorf("--yes did not make the change: %v", err)
	}
}

// noInput is a terminal's input no test may read from.
type noInput struct{ t *testing.T }

func (r noInput) Read([]byte) (int, error) {
	r.t.Error("the command read its input")
	return 0, io.EOF
}

// With no terminal to confirm on and no --yes, `cyfr access <mode>` shows the
// change when its preview needs no join, and refuses it, without the lock,
// any change or a read of its input; a change that needs the machine
// joined first is refused before the join.
func TestAccessWithoutAConfirmationShowsTheChangeAndMakesNone(t *testing.T) {
	s := newAccessProject(t)
	before := read(t, ".env")
	askTerminal = func() bool { return false }
	askInput = noInput{t}
	var out bytes.Buffer
	err := runAccess(context.Background(), access.ModePublic, accessOptions{domain: "cyfr.example.com"}, false, "", &out)
	if err == nil || !strings.Contains(err.Error(), "shown, not made") || !strings.Contains(err.Error(), "Nothing was changed. Run it again with --yes") || ExitStatus(err) != exitFailure {
		t.Errorf("an unconfirmed change answered %v", err)
	}
	if !strings.Contains(out.String(), "  Address: http://localhost:4000 → https://cyfr.example.com\n") {
		t.Errorf("the change was not shown:\n%s", out.String())
	}
	for name, o := range map[string]accessOptions{"a machine not joined": {}, "a new node": {newNode: true}} {
		out.Reset()
		err := runAccess(context.Background(), access.ModeTailnet, o, false, "", &out)
		if err == nil || !strings.Contains(err.Error(), "joins your tailnet before the change can be shown") || !strings.Contains(err.Error(), "Nothing was changed") {
			t.Errorf("%s: an unconfirmed tailnet change answered %v", name, err)
		}
		if out.Len() != 0 {
			t.Errorf("%s: an unconfirmed tailnet change printed %q", name, out.String())
		}
	}
	if s.locks != 0 || len(s.switches) != 0 || len(s.joins) != 0 || read(t, ".env") != before {
		t.Errorf("an unconfirmed change took the lock (%d), switched (%v) or joined (%v)", s.locks, s.switches, s.joins)
	}
}

// For tailnet the machine joins first, printing the approval link, under a
// join request id derived from the switch's, so a resent request resends
// its join; the switch takes the joined machine. A machine already joined
// is not joined again, and --new-node always joins.
func TestAccessTailnetJoinsFirstUnlessJoined(t *testing.T) {
	s := newAccessProject(t)
	const id = "0123456789abcdef0123456789abcdef"
	var out bytes.Buffer
	if err := runAccess(context.Background(), access.ModeTailnet, accessOptions{hostname: "home"}, true, id, &out); err != nil {
		t.Fatalf("cyfr access tailnet: %v\n%s", err, out.String())
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
	s = newAccessProject(t)
	s.joined[""] = access.Join{Name: "cyfr.tail1234.ts.net", NodeID: "nTESTNODE1CNTRL"}
	if err := runAccess(context.Background(), access.ModeTailnet, accessOptions{}, true, "", &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	if len(s.joins) != 0 || len(s.switches) != 1 || s.switches[0].JoinID != "" {
		t.Errorf("a joined machine was joined again: joins %+v, switches %+v", s.joins, s.switches)
	}

	// --new-node replaces the identity, so it joins.
	s = newAccessProject(t)
	s.joined[""] = access.Join{Name: "cyfr.tail1234.ts.net", NodeID: "nTESTNODE1CNTRL"}
	if err := runAccess(context.Background(), access.ModeTailnet, accessOptions{newNode: true}, true, "", &bytes.Buffer{}); err != nil {
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
func TestAccessRefusalsAreTheirSentences(t *testing.T) {
	rolled := access.Receipt{Op: "switch", State: "completed", Outcome: "rolled_back", Code: "access_rolled_back", Payload: map[string]string{"new": "public", "old": "local", "reason": "cyfr did not become healthy"}}
	cases := []struct {
		name    string
		prepare func(s *fakeStack)
		mode    string
		o       accessOptions
		want    string
	}{
		{"a rolled-back switch", func(s *fakeStack) { s.switchReceipt = &rolled }, access.ModePublic, accessOptions{domain: "cyfr.example.com"}, access.Refuse(rolled.Code, rolled.Payload).Message()},
		{"no change", nil, access.ModeLocal, accessOptions{}, access.Refuse("access_unchanged", map[string]string{"address": "http://localhost:4000"}).Message()},
		{"an option of another mode", nil, access.ModeLocal, accessOptions{domain: "cyfr.example.com"}, access.Refuse("access_option_outside_mode", map[string]string{"option": "--domain", "mode": "local"}).Message()},
		{"the lock held", func(s *fakeStack) { s.holder = "update" }, access.ModePublic, accessOptions{domain: "cyfr.example.com"}, "Another cyfr command holds this home (`update`)"},
		{"COMPOSE_* in .env", func(*fakeStack) {
			f, _ := os.OpenFile(".env", os.O_APPEND|os.O_WRONLY, 0)
			f.WriteString("COMPOSE_PROFILES=public,tailnet\n")
			f.Close()
		}, access.ModeLocal, accessOptions{}, access.Refuse("compose_env_refused", map[string]string{"key": "COMPOSE_PROFILES"}).Message()},
		{"HTTPS off", func(s *fakeStack) {
			s.join = func(ctx context.Context, r access.JoinRequest) (access.Receipt, error) {
				return access.Receipt{Op: "join", State: "completed", Outcome: "failed", Code: "tailnet_https_off", Payload: map[string]string{"name": "cyfr.tail1234.ts.net"}}, nil
			}
		}, access.ModeTailnet, accessOptions{}, access.Refuse("tailnet_https_off", map[string]string{"name": "cyfr.tail1234.ts.net"}).Message()},
		{"a tailnet option for public", nil, access.ModePublic, accessOptions{domain: "cyfr.example.com", newNode: true}, "`--new-node` is for joining a tailnet, and this command chooses `public`"},
		{"a mode that is none", nil, "tls", accessOptions{}, `cyfr access takes local, tailnet or public; "tls" is none of them`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newAccessProject(t)
			if c.prepare != nil {
				c.prepare(s)
			}
			err := runAccess(context.Background(), c.mode, c.o, true, "", &bytes.Buffer{})
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("cyfr access answered %v, want %q", err, c.want)
			}
			var r *access.Refusal
			if strings.Contains(c.want, "Nothing") && errors.As(err, &r) && err.Error() != r.Message() {
				t.Errorf("the failure %q is not the refusal's sentence %q", err, r.Message())
			}
		})
	}
	s := newAccessProject(t)
	if err := runAccess(context.Background(), access.ModeLocal, accessOptions{}, true, "NOT-HEX", &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "--request-id") || s.locks != 0 {
		t.Errorf("a request id that is none answered %v", err)
	}
}

// `cyfr access status` reads without the lock, so it answers while another
// command holds it, and prints how the home is reached, what runs, the
// unfinished change and the last one.
func TestAccessStatusTakesNoLock(t *testing.T) {
	s := newAccessProject(t)
	s.holder = "update"
	last := access.Receipt{RequestID: strings.Repeat("a", 32), Op: "switch", State: "completed", Outcome: "ok", At: time.Date(2026, 10, 19, 8, 0, 0, 0, time.UTC)}
	unfinished := access.Receipt{RequestID: strings.Repeat("b", 32), Op: "switch", State: "accepted", Phase: "stopped"}
	head := access.Head{Mode: "local", Host: "localhost", Port: 4000, Profiles: []string{}}
	s.status = access.Status{Head: head, Words: access.Describe(head), Containers: []access.Container{{Service: "cyfr", Name: "p-cyfr-1", State: "running"}}, Health: []string{"cyfr: healthy"}, Unfinished: &unfinished, Last: &last}
	var out bytes.Buffer
	if err := runAccessStatus(context.Background(), &out); err != nil {
		t.Fatalf("cyfr access status: %v", err)
	}
	for _, line := range []string{
		"  Who can reach this home: only this computer\n",
		"  Address: http://localhost:4000\n",
		"  cyfr (p-cyfr-1): running\n",
		"  cyfr: healthy\n",
		"Unfinished: The change of how this home is reached (request " + strings.Repeat("b", 32) + ") is unfinished (stopped). Run `cyfr access --resume` to finish it.\n",
		"Last change, 2026-10-19T08:00:00Z: The change of how this home is reached (request " + strings.Repeat("a", 32) + ") is done.\n",
	} {
		if !strings.Contains(out.String(), line) {
			t.Errorf("the status lacks %q:\n%s", line, out.String())
		}
	}
	if s.locks != 0 || s.holder != "update" {
		t.Errorf("status took the lock")
	}

	s.status = access.Status{HeadErr: access.Refuse("access_missing", nil)}
	out.Reset()
	if err := runAccessStatus(context.Background(), &out); err != nil || !strings.Contains(out.String(), access.Refuse("access_missing", nil).Message()) {
		t.Errorf("status of a .env without CYFR_ACCESS answered %v:\n%s", err, out.String())
	}
}

// `cyfr access --resume` takes the lock, runs recovery and reports each
// receipt it wrote; a change recovery could not finish is a failure whose
// sentence says what to do next.
func TestAccessResumeReportsRecovery(t *testing.T) {
	s := newAccessProject(t)
	var out bytes.Buffer
	if err := runAccessResume(context.Background(), &out); err != nil || !strings.Contains(out.String(), "Nothing was unfinished") || s.locks != 1 {
		t.Errorf("a resume with nothing unfinished answered %v:\n%s", err, out.String())
	}
	s.resume = []access.Receipt{
		{RequestID: strings.Repeat("c", 32), Op: "switch", State: "completed", Outcome: "not_applied"},
		{RequestID: strings.Repeat("d", 32), Op: "switch", State: "accepted", Phase: "uncertain", Code: "access_uncertain", Payload: map[string]string{"observed": "caddy, cyfr"}},
	}
	out.Reset()
	err := runAccessResume(context.Background(), &out)
	want := access.Refuse("access_uncertain", map[string]string{"observed": "caddy, cyfr"}).Message()
	if err == nil || err.Error() != want {
		t.Errorf("a resume that leaves a change unfinished answered %v, want %q", err, want)
	}
	if !strings.Contains(out.String(), "Recovered: The change of how this home is reached (request "+strings.Repeat("c", 32)+") is not applied.") {
		t.Errorf("the resume does not report what recovery finished:\n%s", out.String())
	}

	// A recovered switch whose start was on this machine only is that
	// start's refusal, and exits 3.
	s.resume = []access.Receipt{startedLocalReceipt("switch")}
	if err := runAccessResume(context.Background(), &bytes.Buffer{}); err == nil || err.Error() != access.Refuse("tailnet_node_mismatch", mismatch()).Message() || ExitStatus(err) != exitStartedLocally {
		t.Errorf("a resume that started the home on this machine only answered %v (exit %d)", err, ExitStatus(err))
	}

	// Recovery's finished changes answer as each finished: a failure, a
	// rollback and an edited .env exit 1 with their sentences, a change
	// not applied or done exits 0.
	for name, c := range map[string]struct {
		r    access.Receipt
		exit int
	}{
		"failed":      {access.Receipt{Op: "switch", State: "completed", Outcome: "failed", Code: "access_failed", Payload: map[string]string{"new": "public", "env": "local"}}, exitFailure},
		"rolled back": {access.Receipt{Op: "switch", State: "completed", Outcome: "rolled_back", Code: "access_rolled_back", Payload: map[string]string{"new": "public", "old": "local", "reason": "x"}}, exitFailure},
		"env edited":  {access.Receipt{Op: "switch", State: "completed", Outcome: "failed", Code: "access_env_edited", Payload: map[string]string{"then": "started", "env": "local"}}, exitFailure},
		"not applied": {access.Receipt{Op: "switch", State: "completed", Outcome: "not_applied"}, 0},
		"done":        {access.Receipt{Op: "switch", State: "completed", Outcome: "ok"}, 0},
	} {
		s.resume = []access.Receipt{c.r}
		err := runAccessResume(context.Background(), &bytes.Buffer{})
		status := 0
		if err != nil {
			status = ExitStatus(err)
		}
		if status != c.exit || c.r.Code != "" && (err == nil || err.Error() != c.r.Refusal().Message()) {
			t.Errorf("%s: a resume answered %v (exit %d), want exit %d with the receipt's sentence", name, err, status, c.exit)
		}
	}

	// An unfinished change with no refusal of its own says what to run, as
	// the refusals quote commands.
	s.resume = []access.Receipt{{RequestID: strings.Repeat("e", 32), Op: "join", State: "accepted", Phase: "waiting"}}
	if err := runAccessResume(context.Background(), &bytes.Buffer{}); err == nil || !strings.HasSuffix(err.Error(), "Nothing was done; run `cyfr access --resume` to finish it") {
		t.Errorf("a resume that leaves a join unfinished answered %v", err)
	}
	if holder := s.held(); holder != "" {
		t.Errorf("the lock is still held, by %s", holder)
	}
}

// answers is a terminal's input of one answer per line.
func answers(lines ...string) io.Reader { return strings.NewReader(strings.Join(lines, "\n") + "\n") }

// A tailnet change that needs this machine joined asks about the join
// before it starts, since the join changes the tailnet whether or not the
// change follows: declined, nothing runs; confirmed, the machine joins,
// and a switch then declined says the machine joined and the home's access mode
// is unchanged, never that nothing was changed. With --new-node it names
// the identity the join removes before anything runs.
func TestAccessConfirmsTheJoinBeforeItStarts(t *testing.T) {
	t.Run("declined", func(t *testing.T) {
		s := newAccessProject(t)
		askTerminal = func() bool { return true }
		askInput = answers("no")
		var out bytes.Buffer
		err := runAccess(context.Background(), access.ModeTailnet, accessOptions{hostname: "home"}, false, "", &out)
		if err == nil || !strings.Contains(err.Error(), "did not join your tailnet. Nothing was changed") || len(s.joins) != 0 {
			t.Fatalf("a declined join answered %v and joined %v", err, s.joins)
		}
		if !strings.Contains(out.String(), "This joins this machine to your tailnet as `home`") {
			t.Errorf("the join was not described before it was asked:\n%s", out.String())
		}
	})
	t.Run("joined, then the change declined", func(t *testing.T) {
		s := newAccessProject(t)
		askTerminal = func() bool { return true }
		askInput = answers("yes", "no")
		err := runAccess(context.Background(), access.ModeTailnet, accessOptions{}, false, "", &bytes.Buffer{})
		want := "The change was not confirmed. This machine joined your tailnet as `cyfr.tail1234.ts.net`, and how this home is reached was not changed"
		if err == nil || err.Error() != want || len(s.joins) != 1 || len(s.switches) != 0 {
			t.Fatalf("a declined change after a join answered %v (joins %d, switches %d), want %q", err, len(s.joins), len(s.switches), want)
		}
	})
	t.Run("a new node", func(t *testing.T) {
		s := newAccessProject(t)
		s.joined[""] = access.Join{Name: "old.tail1234.ts.net", NodeID: "nOLDNODECNTRL"}
		askTerminal = func() bool { return true }
		askInput = answers("no")
		var out bytes.Buffer
		err := runAccess(context.Background(), access.ModeTailnet, accessOptions{newNode: true}, false, "", &out)
		if err == nil || len(s.joins) != 0 || len(s.switches) != 0 {
			t.Fatalf("a declined new node answered %v, joined %v", err, s.joins)
		}
		if !strings.Contains(out.String(), "This joins this machine to your tailnet as `cyfr`, after removing its current tailnet identity, `old.tail1234.ts.net`, which the Tailscale admin console still lists") {
			t.Errorf("the identity --new-node removes was not named before anything ran:\n%s", out.String())
		}
	})
	// The join a new node makes removes the machine's identity before it
	// joins, so a change declined after it says so, naming the identity
	// the admin console still lists.
	t.Run("a new node joined, then the change declined", func(t *testing.T) {
		s := newAccessProject(t)
		s.joined[""] = access.Join{Name: "old.tail1234.ts.net", NodeID: "nOLDNODECNTRL"}
		askTerminal = func() bool { return true }
		askInput = answers("yes", "no")
		var out bytes.Buffer
		err := runAccess(context.Background(), access.ModeTailnet, accessOptions{newNode: true}, false, "", &out)
		want := "The change was not confirmed. This machine's tailnet identity `old.tail1234.ts.net` was removed, and the Tailscale admin console still lists it until you remove it there; the machine joined your tailnet as `cyfr.tail1234.ts.net`, and how this home is reached was not changed"
		if err == nil || err.Error() != want || len(s.joins) != 1 || len(s.switches) != 0 {
			t.Fatalf("a declined change after a new node answered %v (joins %d, switches %d), want %q\n%s", err, len(s.joins), len(s.switches), want, out.String())
		}
	})
}

// A change declined after a new node's join says a tailnet identity was
// removed only when the join replaced a machine the engine knew this home
// had and .env agrees with, and names that machine; the question before
// the join names it too. An identity .env names that no machine is known
// joined as, or that names another node than the machine known, is never
// said to be removed, before the join or after it.
func TestAccessSaysAnIdentityWasRemovedOnlyForTheMachineTheJoinReplaced(t *testing.T) {
	envHead := func(t *testing.T, name, node string) {
		t.Helper()
		if err := access.EditEnvFile(".env", map[string]string{"CYFR_ACCESS": access.ModeTailnet, "CYFR_HOST": name, "CYFR_TAILNET_NODE_ID": node, "CYFR_PUBLIC_URL": "https://" + name}, nil); err != nil {
			t.Fatal(err)
		}
	}
	unknown := "This joins this machine to your tailnet as `cyfr`, after removing its current tailnet identity, if it has one; certificate names are public.\n"
	joinedOnly := "The change was not confirmed. This machine joined your tailnet as `cyfr.tail1234.ts.net`, and how this home is reached was not changed"
	for name, c := range map[string]struct {
		prepare        func(t *testing.T, s *fakeStack)
		question, want string
	}{
		".env names a machine none is joined as": {
			prepare:  func(t *testing.T, s *fakeStack) { envHead(t, "snapshot-a.tail1234.ts.net", "nAAAAAAAAACNTRL") },
			question: unknown, want: joinedOnly,
		},
		"the machine joined as .env names it": {
			prepare: func(t *testing.T, s *fakeStack) {
				envHead(t, "old.tail1234.ts.net", "nOLDNODECNTRL")
				s.joined[""] = access.Join{Name: "old.tail1234.ts.net", NodeID: "nOLDNODECNTRL"}
			},
			question: "This joins this machine to your tailnet as `cyfr`, after removing its current tailnet identity, `old.tail1234.ts.net`, which the Tailscale admin console still lists until you remove it there; certificate names are public.\n",
			want:     "The change was not confirmed. This machine's tailnet identity `old.tail1234.ts.net` was removed, and the Tailscale admin console still lists it until you remove it there; the machine joined your tailnet as `cyfr.tail1234.ts.net`, and how this home is reached was not changed",
		},
		// A restore leaves the machine's state and its last join as they
		// were, so .env can name machine A while the engine knows B: the
		// preview moves A to B, and neither is said to be removed.
		".env names another node than the machine joined": {
			prepare: func(t *testing.T, s *fakeStack) {
				envHead(t, "a.tail1234.ts.net", "nAAAAAAAAACNTRL")
				s.joined[""] = access.Join{Name: "b.tail1234.ts.net", NodeID: "nBBBBBBBBBCNTRL"}
			},
			question: unknown, want: joinedOnly,
		},
		".env's head does not read": {
			prepare: func(t *testing.T, s *fakeStack) {
				s.headErr = access.Refuse("access_setting_invalid", map[string]string{"key": "CYFR_TAILNET_NODE_ID"})
				s.joined[""] = access.Join{Name: "b.tail1234.ts.net", NodeID: "nBBBBBBBBBCNTRL"}
			},
			question: unknown, want: joinedOnly,
		},
		"a join that kept the machine's node": {
			prepare: func(t *testing.T, s *fakeStack) {
				s.joined[""] = access.Join{Name: "cyfr.tail1234.ts.net", NodeID: "nTESTNODE1CNTRL"}
			},
			question: "This joins this machine to your tailnet as `cyfr`, after removing its current tailnet identity, `cyfr.tail1234.ts.net`, which the Tailscale admin console still lists until you remove it there; certificate names are public.\n",
			want:     joinedOnly,
		},
	} {
		t.Run(name, func(t *testing.T) {
			s := newAccessProject(t)
			c.prepare(t, s)
			askTerminal = func() bool { return true }
			askInput = answers("yes", "no")
			var out bytes.Buffer
			err := runAccess(context.Background(), access.ModeTailnet, accessOptions{newNode: true}, false, "", &out)
			if err == nil || err.Error() != c.want || len(s.joins) != 1 || len(s.switches) != 0 {
				t.Fatalf("a change declined after a new node's join answered %v (joins %d, switches %d), want %q\n%s", err, len(s.joins), len(s.switches), c.want, out.String())
			}
			if !strings.Contains(out.String(), c.question) {
				t.Errorf("the join was not asked as %q:\n%s", c.question, out.String())
			}
		})
	}
}

// The preview shows every field of the head that changes, in words: beside
// the four sentences, a line for each changed field they do not show, the
// tailnet machine (its name and id), the port on this computer and the
// builds service, so no change reads as none.
func TestAccessPreviewShowsEveryChangedField(t *testing.T) {
	tailnet := access.Head{Mode: access.ModeTailnet, Host: "cyfr.tail1234.ts.net", NodeID: "nAAAAAAAAACNTRL", PublicURL: "https://cyfr.tail1234.ts.net", Port: 4000, BuildsURL: defaultBuildsURL, Profiles: []string{buildsProfile, access.ModeTailnet}}
	for name, c := range map[string]struct {
		change func(h *access.Head)
		line   string
	}{
		"another node, the same name": {func(h *access.Head) { h.NodeID = "nBBBBBBBBBCNTRL" }, "  Tailnet machine: cyfr.tail1234.ts.net (nAAAAAAAAACNTRL) → cyfr.tail1234.ts.net (nBBBBBBBBBCNTRL)\n"},
		"the port on this computer":   {func(h *access.Head) { h.Port = 4123 }, "  Port on this computer: 4000 → 4123\n"},
		"builds turned off": {func(h *access.Head) {
			h.BuildsURL, h.Profiles = "", []string{access.ModeTailnet}
		}, "  Builds service: " + defaultBuildsURL + " → off\n"},
	} {
		t.Run(name, func(t *testing.T) {
			next := tailnet
			next.Profiles = slices.Clone(tailnet.Profiles)
			c.change(&next)
			if next.Digest() == tailnet.Digest() {
				t.Fatal("the change does not change the head")
			}
			var out bytes.Buffer
			printPreview(&out, access.Preview{Old: tailnet, New: next, OldDigest: tailnet.Digest(), NewDigest: next.Digest(), OldWords: access.Describe(tailnet), NewWords: access.Describe(next)})
			if !strings.Contains(out.String(), c.line) {
				t.Errorf("the preview lacks %q:\n%s", c.line, out.String())
			}
			changed := 0
			for _, line := range strings.Split(out.String(), "\n") {
				if _, change, ok := strings.Cut(line, ": "); ok {
					if before, after, ok := strings.Cut(change, " → "); ok && before != after {
						changed++
					}
				}
			}
			if changed != 1 {
				t.Errorf("the preview shows %d changed lines, want the one:\n%s", changed, out.String())
			}
		})
	}
	// A machine joined for the first time is a tailnet machine where there
	// was none.
	local := access.Head{Mode: access.ModeLocal, Host: "localhost", PublicURL: "http://localhost:4000", Port: 4000, BuildsURL: defaultBuildsURL, Profiles: []string{buildsProfile}}
	var out bytes.Buffer
	printPreview(&out, access.Preview{Old: local, New: tailnet, OldWords: access.Describe(local), NewWords: access.Describe(tailnet)})
	if want := "  Tailnet machine: none → cyfr.tail1234.ts.net (nAAAAAAAAACNTRL)\n"; !strings.Contains(out.String(), want) {
		t.Errorf("the preview lacks %q:\n%s", want, out.String())
	}
}

// A machine already on the tailnet refuses --hostname and
// --tailscale-auth-key-file, which apply to a new join, before anything
// changes, naming the machine and the --new-node that would use them.
func TestAccessRefusesJoinOptionsForAJoinedMachine(t *testing.T) {
	keyFile := filepath.Join(t.TempDir(), "authkey")
	if err := os.WriteFile(keyFile, []byte("tskey-auth-kTEST\n"), 0600); err != nil {
		t.Fatal(err)
	}
	for name, c := range map[string]struct {
		o    accessOptions
		want string
	}{
		"--hostname":                {accessOptions{hostname: "home"}, "`--hostname` is for a new join"},
		"--tailscale-auth-key-file": {accessOptions{keyFile: keyFile}, "`--tailscale-auth-key-file` is for a new join"},
	} {
		t.Run(name, func(t *testing.T) {
			s := newAccessProject(t)
			s.joined[""] = access.Join{Name: "cyfr.tail1234.ts.net", NodeID: "nTESTNODE1CNTRL"}
			before := read(t, ".env")
			err := runAccess(context.Background(), access.ModeTailnet, c.o, true, "", &bytes.Buffer{})
			if err == nil || !strings.Contains(err.Error(), "This machine is already on your tailnet as `cyfr.tail1234.ts.net`") || !strings.Contains(err.Error(), c.want) || !strings.Contains(err.Error(), "Run `cyfr access tailnet --new-node` with it") {
				t.Fatalf("cyfr access tailnet %s answered %v", name, err)
			}
			if len(s.joins) != 0 || len(s.switches) != 0 || read(t, ".env") != before {
				t.Errorf("the refusal changed something: joins %v, switches %v", s.joins, s.switches)
			}
			// With no terminal and no --yes, the same refusal, not a
			// preview that --yes would then refuse.
			if err := runAccess(context.Background(), access.ModeTailnet, c.o, false, "", &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "This machine is already on your tailnet as `cyfr.tail1234.ts.net`") {
				t.Errorf("cyfr access tailnet %s with no terminal answered %v", name, err)
			}
		})
	}
}

// A request id resent after its switch finished answers its receipt as the
// first send did, the same sentence and exit status, with no second
// switch; a receipt of another change under the id is access_request_reused.
func TestAccessAnswersAResentRequestFromItsReceipt(t *testing.T) {
	const id = "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f"
	s := newAccessProject(t)
	var first, second bytes.Buffer
	err1 := runAccess(context.Background(), access.ModePublic, accessOptions{domain: "cyfr.example.com"}, true, id, &first)
	err2 := runAccess(context.Background(), access.ModePublic, accessOptions{domain: "cyfr.example.com"}, true, id, &second)
	if err1 != nil || err2 != nil || first.String() == "" || !strings.HasSuffix(first.String(), second.String()) || len(s.switches) != 1 {
		t.Fatalf("resending %s answered %v then %v, %q then %q, with %d switches", id, err1, err2, first.String(), second.String(), len(s.switches))
	}
	if err := runAccess(context.Background(), access.ModePublic, accessOptions{domain: "other.example.com"}, true, id, &bytes.Buffer{}); err == nil || err.Error() != access.Refuse("access_request_reused", nil).Message() {
		t.Errorf("another change under the id answered %v", err)
	}

	const failed = "1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f"
	rolled := access.Receipt{Op: "switch", State: "completed", Outcome: "rolled_back", Code: "access_rolled_back", Payload: map[string]string{"new": "public", "old": "local", "reason": "cyfr did not become healthy"}}
	s.switchReceipt = &rolled
	err1 = runAccess(context.Background(), access.ModeLocal, accessOptions{}, true, failed, &bytes.Buffer{})
	s.switchReceipt = nil
	err2 = runAccess(context.Background(), access.ModeLocal, accessOptions{}, true, failed, &bytes.Buffer{})
	if err1 == nil || err2 == nil || err1.Error() != err2.Error() || ExitStatus(err1) != ExitStatus(err2) || len(s.switches) != 2 {
		t.Errorf("resending a rolled-back request answered %v (exit %d) then %v (exit %d), %d switches", err1, ExitStatus(err1), err2, ExitStatus(err2), len(s.switches))
	}
}

// Every rolled-back change is a failure, exit 1 with its sentence, the
// local form of a rollback whose old head answers on this machine only
// included, never the 3 of a start on this machine only.
func TestAccessRolledBackExitsOne(t *testing.T) {
	for name, payload := range map[string]map[string]string{
		"put back running":         {"new": "public", "old": "local", "reason": "cyfr did not become healthy"},
		"put back on this machine": {"new": "public", "old": "tailnet", "reason": "cyfr did not become healthy", "local": "tailnet_node_mismatch"},
	} {
		t.Run(name, func(t *testing.T) {
			s := newAccessProject(t)
			rolled := access.Receipt{Op: "switch", State: "completed", Outcome: "rolled_back", Code: "access_rolled_back", Payload: payload}
			s.switchReceipt = &rolled
			err := runAccess(context.Background(), access.ModePublic, accessOptions{domain: "cyfr.example.com"}, true, "", &bytes.Buffer{})
			if want := access.Refuse("access_rolled_back", payload).Message(); err == nil || err.Error() != want || ExitStatus(err) != exitFailure {
				t.Errorf("a rollback answered %v (exit %d), want %q and exit 1", err, ExitStatus(err), want)
			}
		})
	}
}

// A resent request id answers its receipt only for the same request: a
// different target or different join inputs under the id is
// access_request_reused, whatever the first request's outcome.
func TestAccessBindsAResentIDToItsRequest(t *testing.T) {
	reused := access.Refuse("access_request_reused", nil).Message()
	for name, first := range map[string]access.Receipt{
		"rejected":    {Op: "switch", State: "rejected", Code: "access_stale", Payload: map[string]string{"words": "local"}},
		"rolled back": {Op: "switch", State: "completed", Outcome: "rolled_back", Code: "access_rolled_back", Payload: map[string]string{"new": "public", "old": "local", "reason": "cyfr did not become healthy"}},
	} {
		t.Run(name, func(t *testing.T) {
			s := newAccessProject(t)
			const id = "f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0"
			s.switchReceipt = &first
			if err := runAccess(context.Background(), access.ModePublic, accessOptions{domain: "first.example.com"}, true, id, &bytes.Buffer{}); err == nil {
				t.Fatal("the first request succeeded")
			}
			s.switchReceipt = nil
			for target, o := range map[string]accessOptions{"local": {}, "public": {domain: "second.example.com"}} {
				if err := runAccess(context.Background(), target, o, true, id, &bytes.Buffer{}); err == nil || err.Error() != reused {
					t.Errorf("%s %+v under the %s id answered %v, want access_request_reused", target, o, name, err)
				}
			}
			// The same request answers as it first did.
			again := runAccess(context.Background(), access.ModePublic, accessOptions{domain: "first.example.com"}, true, id, &bytes.Buffer{})
			if want := first.Refusal().Message(); again == nil || again.Error() != want || len(s.switches) != 1 {
				t.Errorf("the same request under the %s id answered %v after %d switches, want %q from the first", name, again, len(s.switches), want)
			}
		})
	}
	t.Run("ok, other join inputs", func(t *testing.T) {
		s := newAccessProject(t)
		const id = "f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1"
		if err := runAccess(context.Background(), access.ModeTailnet, accessOptions{}, true, id, &bytes.Buffer{}); err != nil {
			t.Fatal(err)
		}
		keyFile := filepath.Join(t.TempDir(), "authkey")
		if err := os.WriteFile(keyFile, []byte("tskey-auth-kTEST\n"), 0600); err != nil {
			t.Fatal(err)
		}
		for _, o := range []accessOptions{{newNode: true, hostname: "replacement"}, {newNode: true}, {keyFile: keyFile, newNode: true}} {
			err := runAccess(context.Background(), access.ModeTailnet, o, true, id, &bytes.Buffer{})
			if err == nil || err.Error() != reused || len(s.joins) != 1 {
				t.Errorf("the id resent with %+v answered %v after %d joins, want access_request_reused", o, err, len(s.joins))
			}
		}
	})
}

// A tailnet home whose Serve is closed, its machine not ready when it
// started (HTTPS off, say), is served on the tailnet again by `cyfr access
// tailnet`, as tailnet_https_off's sentence says: the preview says so, the
// change is confirmed (or --yes), and the switch of the head .env holds
// runs only the start; the result says Serve is open, or answers
// started_local's sentence with exit 3.
func TestAccessTailnetServesAClosedHomeAgain(t *testing.T) {
	if !strings.Contains(access.Refuse("tailnet_https_off", httpsOff()).Message(), "then run `cyfr access tailnet` again, which uses this machine as it is") {
		t.Fatal("tailnet_https_off no longer says to run `cyfr access tailnet` again")
	}
	s := newAccessProject(t)
	s.joined[""] = access.Join{Name: "cyfr.tail1234.ts.net", NodeID: "nTESTNODE1CNTRL"}
	if err := runAccess(context.Background(), access.ModeTailnet, accessOptions{}, true, "", &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	s.switches, s.serveClosed = nil, true
	askTerminal = func() bool { return true }
	askInput = answers("yes")
	var out bytes.Buffer
	if err := runAccess(context.Background(), access.ModeTailnet, accessOptions{}, false, "", &out); err != nil {
		t.Fatalf("cyfr access tailnet answered %v\n%s", err, out.String())
	}
	for _, want := range []string{
		"Tailscale Serve is closed, so this home answers on this machine only. This checks the machine again and serves the home on your tailnet at https://cyfr.tail1234.ts.net:\n",
		"  Address: https://cyfr.tail1234.ts.net\n",
		"Make this change? (yes/no)",
		"Done. This home is reached as:\n",
		"Tailscale now:\n  Serve: open\n",
	} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("the reopen lacks %q:\n%s", want, out.String())
		}
	}
	if len(s.switches) != 1 || s.switches[0].OldDigest != s.switches[0].NewDigest {
		t.Errorf("the reopen switched %+v, want one switch to the head .env holds", s.switches)
	}

	// The machine still not ready: started_local's sentence, exit 3.
	s.serveClosed = true
	local := startedLocalFor("switch", "tailnet_https_off", httpsOff())
	s.reopenReceipt = &local
	err := runAccess(context.Background(), access.ModeTailnet, accessOptions{}, true, "", &bytes.Buffer{})
	if want := access.Refuse("tailnet_https_off", httpsOff()).Message(); err == nil || err.Error() != want || ExitStatus(err) != exitStartedLocally {
		t.Errorf("a reopen on a machine still not ready answered %v (exit %d), want %q and exit 3", err, ExitStatus(err), want)
	}
}

// The command tree is the contract's: `cyfr access <mode>` with its flags,
// the hidden --request-id and `cyfr access status`, and `cyfr setup` with
// no subcommand.
func TestAccessCommandsAreTheContractsSurface(t *testing.T) {
	for _, name := range []string{"domain", "acme-email", "tailscale-auth-key-file", "hostname", "new-node", "yes", "resume", "request-id"} {
		if accessCmd.Flags().Lookup(name) == nil {
			t.Errorf("cyfr access has no --%s", name)
		}
	}
	if f := accessCmd.Flags().Lookup("request-id"); f == nil || !f.Hidden {
		t.Errorf("--request-id is not hidden")
	}
	for _, name := range []string{"access", "domain", "acme-email", "tailscale-auth-key-file", "hostname", "no-pull", "force"} {
		if initCmd.Flags().Lookup(name) == nil {
			t.Errorf("cyfr init has no --%s", name)
		}
	}
	if subcommand(accessCmd, "status") == nil {
		t.Errorf("cyfr access status is missing")
	}
	if setup := subcommand(rootCmd, "setup"); setup == nil || setup.HasSubCommands() || setup.Flags().Lookup("port") == nil || setup.Flags().Lookup("no-pull") == nil {
		t.Errorf("cyfr setup is not the one command with --port and --no-pull")
	}
	internal := subcommand(rootCmd, "internal")
	if internal == nil || !internal.Hidden || subcommand(internal, "docker-run") == nil || !subcommand(internal, "docker-run").DisableFlagParsing {
		t.Errorf("cyfr internal docker-run is not the hidden, unparsed watchdog command")
	}
	if err := accessCmd.RunE(accessCmd, nil); err == nil || !strings.Contains(err.Error(), "name the mode") {
		t.Errorf("cyfr access with no mode answered %v", err)
	}
}

// The help says what each exit status means, and what 3 means for each
// command that starts the home.
func TestHelpNamesTheExitStatuses(t *testing.T) {
	for _, want := range []string{"Exit status: 0 on success; 1 on a failure; 3 when", "not ready to serve it (not the one .env names, not\njoined, or HTTPS off", "130 when interrupted at a prompt"} {
		if !strings.Contains(rootCmd.Long, want) {
			t.Errorf("cyfr's help lacks %q", want)
		}
	}
	for _, c := range []*cobra.Command{upCmd, updateCmd, restoreCmd, accessCmd, setupCmd} {
		if !strings.Contains(c.Long, "Exit status 3: ") || !strings.Contains(c.Long, "on this machine only, because the tailnet machine is not ready to serve it") {
			t.Errorf("cyfr %s's help does not say what exit status 3 means for it", c.Name())
		}
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

// `cyfr access tailnet` opens the join's approval link as init does: on a
// machine with a display, once it has printed it, unless --no-open; the
// join still waits and the change follows it.
func TestAccessOpensTheJoinLinkOnADisplay(t *testing.T) {
	const link = "https://login.tailscale.com/a/approve-test"
	for _, c := range []struct {
		name                 string
		display, noOpen, yes bool
	}{
		{"a display", true, false, false},
		{"a display, --yes", true, false, true},
		{"--no-open", true, true, false},
		{"no display", false, false, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := newAccessProject(t)
			l := stubLauncher(t, c.display, nil)
			askTerminal = func() bool { return true }
			askInput = answers("yes", "yes")
			var out bytes.Buffer
			if err := runAccess(context.Background(), access.ModeTailnet, accessOptions{noOpen: c.noOpen}, c.yes, "", &out); err != nil {
				t.Fatalf("access: %v\n%s", err, out.String())
			}
			opened := c.display && !c.noOpen
			between := ""
			var handed []string
			if opened {
				between, handed = "Opened it in your browser.\n", []string{link}
			}
			want := "open this link and approve the machine:\n  " + link + "\n" + between + "Waiting for the approval (Ctrl-C cancels the join)...\n"
			if !strings.Contains(out.String(), want) {
				t.Errorf("access printed:\n%s\nwant within it:\n%s", out.String(), want)
			}
			if got := l.all(); !slices.Equal(got, handed) {
				t.Errorf("the launcher was handed %v, want %v", got, handed)
			}
			if len(s.joins) != 1 || len(s.switches) != 1 || accessOf(t) != access.ModeTailnet {
				t.Errorf("joined %d times and switched %d times, the home %s", len(s.joins), len(s.switches), accessOf(t))
			}
		})
	}
}

// --no-open is a flag of init and of `cyfr access`, read into the options
// both apply.
func TestNoOpenIsAnAccessFlag(t *testing.T) {
	for _, c := range []*cobra.Command{initCmd, accessCmd} {
		f := c.Flags().Lookup("no-open")
		if f == nil || f.Value.Type() != "bool" {
			t.Fatalf("%s has no --no-open", c.Name())
		}
		t.Cleanup(func() { _ = f.Value.Set("false"); f.Changed = false })
		if err := f.Value.Set("true"); err != nil {
			t.Fatal(err)
		}
		if !accessFlags(c).noOpen {
			t.Errorf("%s --no-open is not read into its options", c.Name())
		}
	}
}
