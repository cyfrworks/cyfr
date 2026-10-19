// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/setup"
)

// newSetupRun makes a new project with the fake engine and a session of
// cyfr setup over them, its images not pulled, ended with the test.
func newSetupRun(t *testing.T) (*fakeStack, *setupSession, *bytes.Buffer) {
	t.Helper()
	newInitProject(t)
	s := useFakeEngine(t)
	ctx, cancel := context.WithCancel(context.Background())
	out := &bytes.Buffer{}
	sess := newSetupSession(ctx, setupOptions{noPull: true}, &syncWriter{w: out})
	t.Cleanup(func() {
		cancel()
		if sess.begun() {
			<-sess.finished
		}
	})
	return s, sess, out
}

// awaitPhase waits for the session to reach phase, failing past a bound.
func awaitPhase(t *testing.T, sess *setupSession, phase string) setup.State {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		st := sess.State()
		if st.Phase == phase {
			return st
		}
		if st.Final() || time.Now().After(deadline) {
			t.Fatalf("the run is %+v, want the phase %s", st, phase)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// ended waits for the run's end and answers its state.
func ended(t *testing.T, sess *setupSession) setup.State {
	t.Helper()
	select {
	case <-sess.finished:
	case <-time.After(10 * time.Second):
		t.Fatalf("the run did not end: %+v", sess.State())
	}
	return sess.State()
}

// approvedJoins makes each join the stack is asked for show its approval
// link, named for its machine, then wait for the test to approve it
// (approve) or for its cancellation; a join answered fail first ends with
// that receipt instead.
func approvedJoins(s *fakeStack, approve <-chan struct{}, fail ...access.Receipt) {
	s.join = func(ctx context.Context, r access.JoinRequest) (access.Receipt, error) {
		machine := joinName(accessOptions{hostname: r.Hostname})
		r.OnAuthURL("https://login.tailscale.com/a/approve-" + machine)
		if len(s.joins) <= len(fail) {
			rec := fail[len(s.joins)-1]
			rec.RequestID = r.ID
			return rec, nil
		}
		select {
		case <-approve:
		case <-ctx.Done():
			return access.Receipt{}, ctx.Err()
		}
		name := machine + ".tail1234.ts.net"
		s.joined["join-"+r.ID] = access.Join{Name: name, NodeID: "nTESTNODE1CNTRL"}
		rec := okReceipt("join")
		rec.RequestID = r.ID
		rec.Payload = map[string]string{"join_id": "join-" + r.ID, "name": name, "node_id": "nTESTNODE1CNTRL"}
		return rec, nil
	}
}

// A local home: the pages' answers are written into .env as init writes
// them, the email the administrators' setting, and the home started; the
// pages move to its address.
func TestSetupWritesTheAnswersAndStartsALocalHome(t *testing.T) {
	s, sess, out := newSetupRun(t)
	if err := sess.Start(setup.Answers{Mode: access.ModeLocal, Email: "me@example.com"}); err != nil {
		t.Fatal(err)
	}
	st := ended(t, sess)
	want := setup.State{Phase: setup.PhaseDone, Mode: access.ModeLocal, Address: "http://localhost:4000", Moves: true}
	if st.Phase != want.Phase || st.Mode != want.Mode || st.Address != want.Address || st.Moves != want.Moves || st.Sentence != "" {
		t.Fatalf("the run ended %+v, want %+v\n%s", st, want, out)
	}
	if err := sess.result(); err != nil {
		t.Errorf("a home up as asked ends the process with %v", err)
	}
	if admins, _ := projectEnv(t).value(adminEmailVar); admins != "me@example.com" || accessOf(t) != access.ModeLocal {
		t.Errorf(".env names %q as administrators and is reached as %s", admins, accessOf(t))
	}
	if s.starts != 1 || len(s.switches) != 0 || len(s.joins) != 0 {
		t.Errorf("%d starts, %d switches and %d joins, want one start alone", s.starts, len(s.switches), len(s.joins))
	}
	if holder := s.held(); holder != "" {
		t.Errorf("the run left the lock held by %s", holder)
	}
	if err := sess.Start(setup.Answers{Mode: access.ModeLocal, Email: "me@example.com"}); !errors.Is(err, setup.ErrNotNow) {
		t.Errorf("a second start answered %v", err)
	}
}

// The steps a run shows are init's, in its order, then the start: the
// access step for a home reached from other devices, the images unless
// --no-pull; a run shows them from its start.
func TestSetupNamesItsSteps(t *testing.T) {
	for _, c := range []struct {
		mode   string
		noPull bool
		want   []string
	}{
		{access.ModeLocal, true, []string{"files", "settings", "start"}},
		{access.ModeLocal, false, []string{"files", "settings", "images", "start"}},
		{access.ModeTailnet, true, []string{"files", "settings", "access", "start"}},
		{access.ModePublic, false, []string{"files", "settings", "access", "images", "start"}},
	} {
		if got := setupSteps(c.mode, c.noPull); !slices.Equal(got, c.want) {
			t.Errorf("%s (no pull %v) has the steps %v, want %v", c.mode, c.noPull, got, c.want)
		}
	}
	_, sess, _ := newSetupRun(t)
	if err := sess.Start(setup.Answers{Mode: access.ModeTailnet, Email: "me@example.com"}); err != nil {
		t.Fatal(err)
	}
	if st := sess.State(); !slices.Equal(st.Steps, setupSteps(access.ModeTailnet, true)) || st.Mode != access.ModeTailnet {
		t.Errorf("the run began %+v", st)
	}
	ended(t, sess)
}

// A tailnet home's join shows its approval link and the machine's name;
// a new name cancels the waiting join and joins again under it, a new
// request, and a name the join refuses is refused before anything is
// cancelled. The approved machine's home is switched, started, and not
// moved to: this device does not reach its tailnet address.
func TestSetupShowsTheJoinAndTakesANewName(t *testing.T) {
	s, sess, out := newSetupRun(t)
	approve := make(chan struct{})
	approvedJoins(s, approve)
	if err := sess.Start(setup.Answers{Mode: access.ModeTailnet, Email: "me@example.com"}); err != nil {
		t.Fatal(err)
	}
	st := awaitPhase(t, sess, setup.PhaseApproval)
	if st.AuthURL != "https://login.tailscale.com/a/approve-cyfr" || st.Name != "cyfr" || st.Step != initStepAccess {
		t.Fatalf("the waiting join shows %+v", st)
	}
	refusal := access.Refuse("access_invalid", map[string]string{"input": "home_1", "kind": "tailnet_name", "rule": "a machine name is 1 to 63 lowercase letters, digits and hyphens, beginning and ending with a letter or a digit"}).Message()
	if err := sess.Rename("home_1"); err == nil || err.Error() != refusal {
		t.Fatalf("a name the join refuses answered %v, want %q", err, refusal)
	}
	if st := sess.State(); st.Phase != setup.PhaseApproval || s.cancels != 0 {
		t.Fatalf("a refused name cancelled the join: %+v, %d cancels", st, s.cancels)
	}
	// The name is the one the join asks for, as the join reads it.
	if err := sess.Rename(" Home "); err != nil {
		t.Fatal(err)
	}
	for sess.State().AuthURL != "https://login.tailscale.com/a/approve-home" {
		awaitPhase(t, sess, setup.PhaseApproval)
	}
	// The waiting machine never joined, so the new name joins as a new
	// machine: its state, which holds the old name, goes.
	if st := sess.State(); st.Name != "home" || s.cancels != 1 || len(s.joins) != 2 || s.joins[1].Hostname != "home" || !s.joins[1].NewNode || s.joins[0].NewNode || s.joins[0].ID == s.joins[1].ID {
		t.Fatalf("the new name: %+v, %d cancels, joins %+v", st, s.cancels, s.joins)
	}
	close(approve)
	st = ended(t, sess)
	if st.Phase != setup.PhaseDone || st.Address != "https://home.tail1234.ts.net" || st.Moves || st.Mode != access.ModeTailnet {
		t.Fatalf("the run ended %+v\n%s", st, out)
	}
	if host, _ := projectEnv(t).value("CYFR_HOST"); host != "home.tail1234.ts.net" || accessOf(t) != access.ModeTailnet || s.starts != 1 || len(s.switches) != 1 {
		t.Errorf(".env's host is %q as %s, after %d starts and %d switches", host, accessOf(t), s.starts, len(s.switches))
	}
	if !strings.Contains(out.String(), "This machine is on your tailnet as home.tail1234.ts.net.") {
		t.Errorf("the run's output does not name the machine:\n%s", out)
	}
}

// "Use only this device instead" cancels the waiting join: nothing is
// switched, and the home is started on this device and moved to.
func TestSetupCancelsTheJoinForThisDeviceOnly(t *testing.T) {
	s, sess, out := newSetupRun(t)
	approvedJoins(s, make(chan struct{}))
	if err := sess.Cancel(); !errors.Is(err, setup.ErrNotNow) {
		t.Errorf("a cancel before any join answered %v", err)
	}
	if err := sess.Start(setup.Answers{Mode: access.ModeTailnet, Email: "me@example.com"}); err != nil {
		t.Fatal(err)
	}
	awaitPhase(t, sess, setup.PhaseApproval)
	if err := sess.Cancel(); err != nil {
		t.Fatal(err)
	}
	st := ended(t, sess)
	if st.Phase != setup.PhaseDone || st.Address != "http://localhost:4000" || !st.Moves || st.Mode != access.ModeLocal {
		t.Fatalf("the run ended %+v\n%s", st, out)
	}
	if s.cancels != 1 || len(s.switches) != 0 || s.starts != 1 || accessOf(t) != access.ModeLocal {
		t.Errorf("%d cancels, %d switches, %d starts, the home %s", s.cancels, len(s.switches), s.starts, accessOf(t))
	}
	if err := sess.result(); err != nil {
		t.Errorf("a home started as chosen ends the process with %v", err)
	}
}

// A join that expires leaves the home local and says so, as init does,
// offering the join again or the home on this device only; the join again
// is a new request, and this device only starts the home unswitched.
func TestSetupOffersTheJoinAgainWhenItFails(t *testing.T) {
	expired := access.Receipt{Op: "join", State: "completed", Outcome: "failed", Code: "tailnet_join_expired"}
	for _, offer := range []string{setup.OfferRetry, setup.OfferLocal} {
		t.Run(offer, func(t *testing.T) {
			s, sess, out := newSetupRun(t)
			approve := make(chan struct{})
			close(approve)
			approvedJoins(s, approve, expired)
			if err := sess.Start(setup.Answers{Mode: access.ModeTailnet, Email: "me@example.com"}); err != nil {
				t.Fatal(err)
			}
			st := awaitPhase(t, sess, setup.PhaseProblem)
			want := access.Refuse("tailnet_join_expired", nil).Message() + "\n" + leftLocal(access.ModeTailnet)
			if st.Sentence != want || !slices.Equal(st.Offers, []string{setup.OfferRetry, setup.OfferLocal}) {
				t.Fatalf("the expired join shows %+v, want %q", st, want)
			}
			if err := sess.Choose("elsewhere"); !errors.Is(err, setup.ErrNotNow) {
				t.Errorf("an offer not made answered %v", err)
			}
			if err := sess.Choose(offer); err != nil {
				t.Fatal(err)
			}
			st = ended(t, sess)
			if offer == setup.OfferRetry {
				if st.Phase != setup.PhaseDone || st.Mode != access.ModeTailnet || len(s.joins) != 2 || s.joins[0].ID == s.joins[1].ID || s.joins[1].NewNode || len(s.switches) != 1 {
					t.Fatalf("the join again ended %+v after joins %+v\n%s", st, s.joins, out)
				}
				return
			}
			if st.Phase != setup.PhaseDone || st.Mode != access.ModeLocal || !st.Moves || len(s.joins) != 1 || len(s.switches) != 0 || s.starts != 1 {
				t.Fatalf("this device only ended %+v after %d joins and %d switches\n%s", st, len(s.joins), len(s.switches), out)
			}
		})
	}
}

// A start that fails shows why, offering it again, or for a home reached
// from other devices the home on this device only: a switch to local, then
// the start; once local, only the start again is offered.
func TestSetupOffersTheStartAgainOrThisDeviceOnly(t *testing.T) {
	for _, offer := range []string{setup.OfferRetry, setup.OfferLocal} {
		t.Run(offer, func(t *testing.T) {
			s, sess, out := newSetupRun(t)
			s.startErr = errors.New("cyfr did not become healthy")
			s.composeErr = errors.New("no compose here")
			if err := sess.Start(setup.Answers{Mode: access.ModeTailnet, Email: "me@example.com"}); err != nil {
				t.Fatal(err)
			}
			st := awaitPhase(t, sess, setup.PhaseProblem)
			if st.Sentence != "cyfr did not become healthy" || !slices.Equal(st.Offers, []string{setup.OfferRetry, setup.OfferLocal}) || st.Joined != "cyfr.tail1234.ts.net" {
				t.Fatalf("the failed start shows %+v", st)
			}
			if offer == setup.OfferRetry {
				s.startErr = nil
				if err := sess.Choose(setup.OfferRetry); err != nil {
					t.Fatal(err)
				}
				if st := ended(t, sess); st.Phase != setup.PhaseDone || st.Mode != access.ModeTailnet || s.starts != 2 {
					t.Fatalf("the start again ended %+v after %d starts\n%s", st, s.starts, out)
				}
				return
			}
			if err := sess.Choose(setup.OfferLocal); err != nil {
				t.Fatal(err)
			}
			// Choose ended the problem shown: the one awaited is the
			// local home's.
			if st := awaitPhase(t, sess, setup.PhaseProblem); !slices.Equal(st.Offers, []string{setup.OfferRetry}) || accessOf(t) != access.ModeLocal {
				t.Fatalf("the local home's failed start shows %+v, the home %s", st, accessOf(t))
			}
			s.startErr = nil
			if err := sess.Choose(setup.OfferRetry); err != nil {
				t.Fatal(err)
			}
			st = ended(t, sess)
			if st.Phase != setup.PhaseDone || st.Mode != access.ModeLocal || !st.Moves || len(s.switches) != 2 || s.switches[1].Target.Mode != access.ModeLocal {
				t.Fatalf("this device only ended %+v after switches %+v\n%s", st, s.switches, out)
			}
		})
	}
}

// A start that leaves the home on this machine only is done at this
// machine's own address, its sentence shown and the browser not moved past
// it; the process exits 3.
func TestSetupReportsAStartOnThisMachineOnly(t *testing.T) {
	s, sess, _ := newSetupRun(t)
	s.startReceipt = startedLocalReceipt("start")
	if err := sess.Start(setup.Answers{Mode: access.ModeTailnet, Email: "me@example.com"}); err != nil {
		t.Fatal(err)
	}
	st := ended(t, sess)
	want := access.Refuse("tailnet_node_mismatch", mismatch()).Message()
	if st.Phase != setup.PhaseDone || st.Address != "http://localhost:4000" || st.Sentence != want || st.Moves {
		t.Fatalf("the run ended %+v, want localhost with %q", st, want)
	}
	if err := sess.result(); ExitStatus(err) != exitStartedLocally {
		t.Errorf("the process exits %d (%v), want 3", ExitStatus(err), err)
	}
}

// The answers the start would refuse are refused before anything is
// written, each with its sentence: a mode that is none, a public home's
// domain that is not one, and anything but one email.
func TestSetupRefusesAnswersBeforeWriting(t *testing.T) {
	s, sess, _ := newSetupRun(t)
	emailRule := "Type the one email you sign in with, such as you@example.com: it makes you this home's administrator"
	for _, c := range []struct {
		a    setup.Answers
		want string
	}{
		{setup.Answers{Mode: "tls", Email: "me@example.com"}, `"tls" is none of them`},
		{setup.Answers{Mode: access.ModePublic, Domain: "localhost", Email: "me@example.com"}, "`localhost` is not a valid domain"},
		{setup.Answers{Mode: access.ModePublic, Email: "me@example.com"}, "Type the domain this home is reached at"},
		{setup.Answers{Mode: access.ModePublic, Domain: "cyfr.example.com", ACMEEmail: "nope", Email: "me@example.com"}, "`nope` is not a valid email address"},
		{setup.Answers{Mode: access.ModeLocal, Domain: "cyfr.example.com", Email: "me@example.com"}, "for a public home alone"},
		{setup.Answers{Mode: access.ModeLocal}, emailRule},
		{setup.Answers{Mode: access.ModeLocal, Email: "me@example.com, you@example.com"}, emailRule},
		{setup.Answers{Mode: access.ModeLocal, Email: "Me <me@example.com>"}, emailRule},
		{setup.Answers{Mode: access.ModeLocal, Email: "not-an-email"}, emailRule},
	} {
		if err := sess.Start(c.a); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("the start of %+v answered %v, want %q", c.a, err, c.want)
		}
	}
	if err := sess.Check(setup.Answers{Mode: access.ModePublic, Domain: "localhost"}); err == nil || !strings.Contains(err.Error(), "`localhost` is not a valid domain") {
		t.Errorf("the check answered %v", err)
	}
	if err := sess.Check(setup.Answers{Mode: access.ModePublic, Domain: "cyfr.example.com", ACMEEmail: "ops@example.com"}); err != nil {
		t.Errorf("the check of a valid domain answered %v", err)
	}
	if st := sess.State(); st.Phase != setup.PhaseAnswering || s.locks != 0 {
		t.Errorf("refused answers began %+v", st)
	}
	nothingWritten(t, ".env.example")
}

// A project whose .env exists is refused as init refuses changing an
// existing home, before anything is served or written, and so is a start
// once .env exists.
func TestSetupRefusesAnExistingHome(t *testing.T) {
	for _, c := range []struct{ env, want string }{
		{"CYFR_ACCESS=tailnet\n", ".env says this home is reached as tailnet, and cyfr setup leaves how an existing home is reached alone. Nothing was changed. Run `cyfr access <mode>` to change it"},
		{"CYFR_SECRET_KEY_BASE=kept\n", access.Refuse("access_missing", nil).Message()},
	} {
		newInitProject(t)
		useFakeEngine(t)
		if err := os.WriteFile(".env", []byte(c.env), 0600); err != nil {
			t.Fatal(err)
		}
		var out bytes.Buffer
		if err := runSetup(context.Background(), setupOptions{}, &out); err == nil || err.Error() != c.want {
			t.Errorf("setup over %q answered %v, want %q", c.env, err, c.want)
		}
		if out.Len() != 0 {
			t.Errorf("a refused setup printed %q", out.String())
		}
		nothingWritten(t, ".env", ".env.example")
	}

	_, sess, _ := newSetupRun(t)
	if err := os.WriteFile(".env", []byte("CYFR_ACCESS=local\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := sess.Start(setup.Answers{Mode: access.ModeLocal, Email: "me@example.com"}); err == nil || !strings.Contains(err.Error(), "cyfr setup leaves how an existing home is reached alone") {
		t.Errorf("a start once .env exists answered %v", err)
	}
	if st := sess.State(); st.Phase != setup.PhaseAnswering {
		t.Errorf("the refused start began %+v", st)
	}
}

// pagesClient drives a running cyfr setup over HTTP as its pages do.
type pagesClient struct {
	t     *testing.T
	base  string
	token string
}

// openPages waits for cyfr setup's address file and answers a client of
// the pages it names.
func openPages(t *testing.T) *pagesClient {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		data, err := os.ReadFile(setupURLFile)
		if err == nil {
			u, err := url.Parse(strings.TrimSpace(string(data)))
			if err != nil {
				t.Fatal(err)
			}
			return &pagesClient{t: t, base: u.Scheme + "://" + u.Host, token: u.Fragment}
		}
		if time.Now().After(deadline) {
			t.Fatalf("cyfr setup wrote no %s", setupURLFile)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func (c *pagesClient) do(method, path string, body any) (setup.State, int) {
	c.t.Helper()
	var r io.Reader
	if body != nil {
		data, _ := json.Marshal(body)
		r = bytes.NewReader(data)
	}
	req, err := http.NewRequest(method, c.base+path, r)
	if err != nil {
		c.t.Fatal(err)
	}
	req.Header.Set("X-Cyfr-Setup", c.token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Origin", c.base)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer res.Body.Close()
	var st setup.State
	json.NewDecoder(res.Body).Decode(&st)
	return st, res.StatusCode
}

// await reads the state as the pages do until its phase is phase.
func (c *pagesClient) await(phase string) setup.State {
	c.t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		st, _ := c.do(http.MethodGet, "/api/state", nil)
		if st.Phase == phase {
			return st
		}
		if time.Now().After(deadline) {
			c.t.Fatalf("the pages read %+v, want the phase %s", st, phase)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// runSetupInBackground runs cyfr setup under ctx, answering its end.
func runSetupInBackground(ctx context.Context, out io.Writer) <-chan error {
	done := make(chan error, 1)
	go func() { done <- runSetup(ctx, setupOptions{noPull: true}, out) }()
	return done
}

func awaitEnd(t *testing.T, done <-chan error) error {
	t.Helper()
	select {
	case err := <-done:
		return err
	case <-time.After(10 * time.Second):
		t.Fatal("cyfr setup did not stop")
		return nil
	}
}

// cyfr setup serves its pages on loopback, writing their address to
// .cyfr/setup.url and printing it, until the pages have read the home up;
// then it stops serving, removes the address and the .cyfr/ it made for it,
// and exits 0.
func TestSetupServesThePagesUntilTheyReadTheHomeUp(t *testing.T) {
	newInitProject(t)
	useFakeEngine(t)
	var out bytes.Buffer
	done := runSetupInBackground(context.Background(), &syncWriter{w: &out})
	c := openPages(t)
	if !strings.HasPrefix(c.base, "http://127.0.0.1:") || len(c.token) != 64 {
		t.Fatalf("the address is %s#%s", c.base, c.token)
	}
	if info, err := os.Stat(setupURLFile); err != nil || info.Mode().Perm() != 0o600 {
		t.Errorf("%s is %v (%v), want mode 0600", setupURLFile, info.Mode(), err)
	}
	if _, status := c.do(http.MethodPost, "/api/start", setup.Answers{Mode: access.ModeLocal, Email: "me@example.com"}); status != http.StatusOK {
		t.Fatalf("the start answered %d", status)
	}
	if st := c.await(setup.PhaseDone); st.Address != "http://localhost:4000" || !st.Moves {
		t.Errorf("the pages read %+v", st)
	}
	if err := awaitEnd(t, done); err != nil {
		t.Fatalf("cyfr setup ended with %v\n%s", err, out.String())
	}
	if _, err := http.Get(c.base + "/"); err == nil {
		t.Errorf("the pages are still served")
	}
	if fileExists(setupURLFile) || fileExists(".cyfr") {
		t.Errorf("cyfr setup left its address behind")
	}
	if !strings.Contains(out.String(), "Setup is at "+c.base+"/#"+c.token+"\n") {
		t.Errorf("cyfr setup did not print its address:\n%s", out.String())
	}
}

// With no page to read the end, cyfr setup stops serving a while after
// it.
func TestSetupStopsAWhileAfterAnEndNoPageReads(t *testing.T) {
	newInitProject(t)
	useFakeEngine(t)
	saved := setupLinger
	t.Cleanup(func() { setupLinger = saved })
	setupLinger = 50 * time.Millisecond
	done := runSetupInBackground(context.Background(), io.Discard)
	c := openPages(t)
	c.do(http.MethodPost, "/api/start", setup.Answers{Mode: access.ModeLocal, Email: "me@example.com"})
	if err := awaitEnd(t, done); err != nil {
		t.Fatalf("cyfr setup ended with %v", err)
	}
	if accessOf(t) != access.ModeLocal {
		t.Errorf("the home was not set up")
	}
}

// Interrupted before the start, cyfr setup writes nothing and leaves
// nothing; interrupted while the join waits, the join is cancelled and
// the home left local and unstarted, as init leaves it, and it says so.
func TestSetupInterrupted(t *testing.T) {
	t.Run("before the start", func(t *testing.T) {
		newInitProject(t)
		useFakeEngine(t)
		ctx, cancel := context.WithCancel(context.Background())
		done := runSetupInBackground(ctx, io.Discard)
		openPages(t)
		cancel()
		if err := awaitEnd(t, done); err == nil || err.Error() != "cyfr setup was interrupted before it began; nothing was written" {
			t.Errorf("cyfr setup answered %v", err)
		}
		nothingWritten(t, ".env.example")
	})
	t.Run("while the join waits", func(t *testing.T) {
		newInitProject(t)
		s := useFakeEngine(t)
		approvedJoins(s, make(chan struct{}))
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		done := runSetupInBackground(ctx, io.Discard)
		c := openPages(t)
		c.do(http.MethodPost, "/api/start", setup.Answers{Mode: access.ModeTailnet, Email: "me@example.com"})
		c.await(setup.PhaseApproval)
		cancel()
		err := awaitEnd(t, done)
		want := fmt.Sprintf("cyfr setup was interrupted. %s\n%s", access.Refuse("tailnet_join_cancelled", nil).Message(), leftLocal(access.ModeTailnet))
		if err == nil || err.Error() != want {
			t.Errorf("cyfr setup answered %v, want %q", err, want)
		}
		if s.cancels != 1 || s.starts != 0 || accessOf(t) != access.ModeLocal {
			t.Errorf("%d cancels, %d starts, the home %s", s.cancels, s.starts, accessOf(t))
		}
	})
}
