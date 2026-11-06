// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"reflect"
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

// The pages ask nothing: the start writes .env as cyfr init writes it,
// reached from this device, and starts CYFR; the pages move to its setup
// link, the setup page at its address with .env's setup token in the
// fragment.
func TestSetupWritesEnvAndStartsCYFR(t *testing.T) {
	s, sess, out := newSetupRun(t)
	if err := sess.Start(); err != nil {
		t.Fatal(err)
	}
	st := ended(t, sess)
	want := setup.State{Phase: setup.PhaseDone, Address: "http://localhost:4000", SetupURL: "http://localhost:4000/setup#" + setupTokenOf(t)}
	if !reflect.DeepEqual(st, want) {
		t.Fatalf("the run ended %+v, want %+v\n%s", st, want, out)
	}
	if err := sess.result(); err != nil {
		t.Errorf("CYFR up ends the process with %v", err)
	}
	if accessOf(t) != access.ModeLocal {
		t.Errorf(".env is reached as %s", accessOf(t))
	}
	if s.starts != 1 || len(s.switches) != 0 || len(s.joins) != 0 {
		t.Errorf("%d starts, %d switches and %d joins, want one start alone", s.starts, len(s.switches), len(s.joins))
	}
	if holder := s.held(); holder != "" {
		t.Errorf("the run left the lock held by %s", holder)
	}
	if err := sess.Start(); !errors.Is(err, setup.ErrNotNow) {
		t.Errorf("a second start answered %v", err)
	}
}

// The steps a run shows are init's, in its order, then the start: the
// images unless --no-pull; a run shows them from its start.
func TestSetupNamesItsSteps(t *testing.T) {
	for noPull, want := range map[bool][]string{
		true:  {"files", "settings", "start"},
		false: {"files", "settings", "images", "start"},
	} {
		if got := setupSteps(noPull); !slices.Equal(got, want) {
			t.Errorf("no pull %v has the steps %v, want %v", noPull, got, want)
		}
	}
	_, sess, _ := newSetupRun(t)
	if err := sess.Start(); err != nil {
		t.Fatal(err)
	}
	if st := sess.State(); !slices.Equal(st.Steps, setupSteps(true)) {
		t.Errorf("the run began %+v", st)
	}
	ended(t, sess)
}

// A start that fails shows why and offers it again, the only offer; the
// start again that succeeds is done at the setup link.
func TestSetupOffersTheStartAgain(t *testing.T) {
	s, sess, out := newSetupRun(t)
	s.startErr = errors.New("cyfr did not become healthy")
	s.composeErr = errors.New("no compose here")
	if err := sess.Start(); err != nil {
		t.Fatal(err)
	}
	st := awaitPhase(t, sess, setup.PhaseProblem)
	if st.Sentence != "cyfr did not become healthy" || !slices.Equal(st.Offers, []string{setup.OfferRetry}) || st.Step != setupStepStart {
		t.Fatalf("the failed start shows %+v", st)
	}
	if err := sess.Choose("local"); !errors.Is(err, setup.ErrNotNow) {
		t.Errorf("an offer not made answered %v", err)
	}
	s.startErr = nil
	if err := sess.Choose(setup.OfferRetry); err != nil {
		t.Fatal(err)
	}
	if st := ended(t, sess); st.Phase != setup.PhaseDone || st.SetupURL != "http://localhost:4000/setup#"+setupTokenOf(t) || s.starts != 2 || len(s.switches) != 0 {
		t.Fatalf("the start again ended %+v after %d starts and switches %+v\n%s", st, s.starts, s.switches, out)
	}
}

// In a project whose .env exists, cyfr setup serves nothing and writes
// nothing: it says the next step of the CYFR set up there, read under the
// stack's lock as cyfr up reads it, and exits 0. While cyfr runs with no
// one set up, the setup link, opened on a machine with a display; with
// its first person, cyfr open; while it is stopped, cyfr up first, then
// the setup link when it never booted. A .env that says nothing of how
// CYFR is reached is refused with its sentence.
func TestSetupInASetUpProjectSaysTheNextStep(t *testing.T) {
	const startedAt = "2026-10-28T00:01:02.123456789Z"
	const marker = "[Cyfr] Not set up: no one is set up on this CYFR yet.\n"
	const token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	link := "https://cyfr.example.com/setup#" + token
	for _, c := range []struct {
		name, container, log string
		noDatabase           bool
		want                 string
		opened               []string
	}{
		{name: "running, no one set up", container: "c0ffee", log: "booting\n" + marker,
			want:   "Open " + link + " to set up its first person, or run cyfr login --setup here.\nOpened it in your browser.\n",
			opened: []string{link}},
		{name: "running, its first person set up", container: "c0ffee", log: "booting\n",
			want: "CYFR is set up and has its first person. cyfr open opens it.\n"},
		{name: "stopped", want: "CYFR is already set up here. Next: cyfr up.\n"},
		{name: "never booted", noDatabase: true,
			want: "CYFR is already set up here. Next: cyfr up. Then open " + link + " to set up its first person.\n"},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := newUpdateScenario(t, shippedCompose(t), nil)
			s.edit(".env", scenarioEnv+"CYFR_SETUP_TOKEN="+token+"\n")
			if c.noDatabase {
				for _, name := range []string{"cyfr.db", "cyfr.db-wal", "cyfr.db-shm"} {
					if err := os.Remove("data/" + name); err != nil {
						t.Fatal(err)
					}
				}
			}
			s.answer("ps.out", c.container+"\n")
			s.answer("inspect.out", startedAt+"\n")
			s.answer("logs.out", c.log)
			l := stubLauncher(t, true, nil)
			before := read(t, ".env")
			var out bytes.Buffer
			if err := runSetup(context.Background(), setupOptions{}, &out); err != nil {
				t.Fatalf("cyfr setup answered %v\n%s", err, out.String())
			}
			if out.String() != c.want {
				t.Errorf("cyfr setup printed\n%s\nwant\n%s", out.String(), c.want)
			}
			if got := l.all(); !slices.Equal(got, c.opened) {
				t.Errorf("cyfr setup opened %v, want %v", got, c.opened)
			}
			if read(t, ".env") != before || fileExists(setupURLFile) {
				t.Error("cyfr setup in a set-up project wrote .env or served its pages")
			}
			if holder := s.engine.held(); holder != "" || s.engine.locks != 1 {
				t.Errorf("the lock is held by %q after %d locks, want it taken once and released", holder, s.engine.locks)
			}
		})
	}

	t.Run("no CYFR_ACCESS", func(t *testing.T) {
		newInitProject(t)
		useFakeEngine(t)
		if err := os.WriteFile(".env", []byte("CYFR_SECRET_KEY_BASE=kept\n"), 0600); err != nil {
			t.Fatal(err)
		}
		var out bytes.Buffer
		if err := runSetup(context.Background(), setupOptions{noOpen: true}, &out); err == nil || err.Error() != access.Refuse("access_missing", nil).Message() {
			t.Errorf("setup over a .env without CYFR_ACCESS answered %v", err)
		}
		if out.Len() != 0 {
			t.Errorf("a refused setup printed %q", out.String())
		}
		nothingWritten(t, ".env", ".env.example")
	})
}

// A start of the pages' run once another command has written .env is
// refused, and nothing begins.
func TestSetupRefusesAStartOnceSetUpMeanwhile(t *testing.T) {
	s, sess, _ := newSetupRun(t)
	if err := os.WriteFile(".env", []byte("CYFR_ACCESS=local\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := sess.Start(); !errors.Is(err, errSetUpMeanwhile) {
		t.Errorf("a start once .env exists answered %v", err)
	}
	if st := sess.State(); st.Phase != setup.PhaseReady || s.locks != 0 {
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
	go func() { done <- runSetup(ctx, setupOptions{noPull: true, noOpen: true}, out) }()
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
// .cyfr/setup.url and printing it, until the pages have read CYFR up;
// then it stops serving, removes the address, keeping its lock's file,
// and exits 0.
func TestSetupServesThePagesUntilTheyReadCYFRUp(t *testing.T) {
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
	if _, status := c.do(http.MethodPost, "/api/start", struct{}{}); status != http.StatusOK {
		t.Fatalf("the start answered %d", status)
	}
	if st := c.await(setup.PhaseDone); st.Address != "http://localhost:4000" || st.SetupURL != "http://localhost:4000/setup#"+setupTokenOf(t) {
		t.Errorf("the pages read %+v", st)
	}
	if err := awaitEnd(t, done); err != nil {
		t.Fatalf("cyfr setup ended with %v\n%s", err, out.String())
	}
	if _, err := http.Get(c.base + "/"); err == nil {
		t.Errorf("the pages are still served")
	}
	if fileExists(setupURLFile) {
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
	c.do(http.MethodPost, "/api/start", struct{}{})
	if err := awaitEnd(t, done); err != nil {
		t.Fatalf("cyfr setup ended with %v", err)
	}
	if accessOf(t) != access.ModeLocal {
		t.Errorf("CYFR was not set up")
	}
}

// Interrupted before the start, cyfr setup writes nothing and leaves
// nothing; interrupted while a failed start waits for the person's choice,
// it ends with the start's failure, .env written and CYFR not started.
func TestSetupInterrupted(t *testing.T) {
	t.Run("before the start", func(t *testing.T) {
		newInitProject(t)
		useFakeEngine(t)
		ctx, cancel := context.WithCancel(context.Background())
		done := runSetupInBackground(ctx, io.Discard)
		openPages(t)
		cancel()
		if err := awaitEnd(t, done); err == nil || err.Error() != "cyfr setup was interrupted before the start; nothing of the new CYFR was written" {
			t.Errorf("cyfr setup answered %v", err)
		}
		nothingWritten(t, ".cyfr", ".env.example")
		if entries, _ := os.ReadDir(".cyfr"); len(entries) != 1 || entries[0].Name() != "setup.lock" {
			t.Errorf(".cyfr holds %v, want the setup's lock alone", entries)
		}
	})
	t.Run("while a failed start waits", func(t *testing.T) {
		newInitProject(t)
		s := useFakeEngine(t)
		s.startErr = errors.New("cyfr did not become healthy")
		s.composeErr = errors.New("no compose here")
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		done := runSetupInBackground(ctx, io.Discard)
		c := openPages(t)
		c.do(http.MethodPost, "/api/start", struct{}{})
		c.await(setup.PhaseProblem)
		cancel()
		if err := awaitEnd(t, done); err == nil || err.Error() != "cyfr setup was interrupted. cyfr did not become healthy" {
			t.Errorf("cyfr setup answered %v", err)
		}
		if s.starts != 1 || accessOf(t) != access.ModeLocal {
			t.Errorf("%d starts, CYFR reached as %s", s.starts, accessOf(t))
		}
	})
}

// One setup serves a project's pages: a second, started while the first
// serves, is refused before it binds or writes anything, and the first's
// address stays published until the first stops.
func TestSetupRefusesASecondSetupInTheProject(t *testing.T) {
	newInitProject(t)
	useFakeEngine(t)
	ctx, stop := context.WithCancel(context.Background())
	defer stop()
	first := runSetupInBackground(ctx, io.Discard)
	c := openPages(t)
	published, err := os.ReadFile(setupURLFile)
	if err != nil {
		t.Fatal(err)
	}
	// A second setup that serves is ended, and fails the test.
	secondCtx, stopSecond := context.WithCancel(context.Background())
	defer stopSecond()
	var out bytes.Buffer
	second := make(chan error, 1)
	go func() { second <- runSetup(secondCtx, setupOptions{noPull: true, noOpen: true}, &syncWriter{w: &out}) }()
	select {
	case err = <-second:
	case <-time.After(5 * time.Second):
		stopSecond()
		<-second
		t.Fatalf("a second setup served beside the first:\n%s", out.String())
	}
	want := "Another cyfr setup is serving this project's pages, at the address in .cyfr/setup.url. Nothing was changed. Use those pages, or stop that cyfr setup and run this again"
	if err == nil || err.Error() != want || out.Len() != 0 {
		t.Fatalf("a second setup answered %v and printed %q, want %q and nothing printed", err, out.String(), want)
	}
	if now, err := os.ReadFile(setupURLFile); err != nil || string(now) != string(published) {
		t.Errorf("the first setup's address is %q (%v), want %q", now, err, published)
	}
	if _, status := c.do(http.MethodGet, "/api/state", nil); status != http.StatusOK {
		t.Errorf("the first setup's pages answered %d", status)
	}
	stop()
	awaitEnd(t, first)
	if fileExists(setupURLFile) {
		t.Errorf("the first setup left its address behind")
	}
	// The lock goes with the setup that held it.
	again, stopAgain := context.WithCancel(context.Background())
	third := runSetupInBackground(again, io.Discard)
	openPages(t)
	stopAgain()
	awaitEnd(t, third)
}

// On a machine with a display cyfr setup opens its pages in the default
// browser after printing their address; with --no-open, or with no
// display, it opens nothing and asks the person to open them. A launcher
// that fails is said, and the pages are served all the same.
func TestSetupOpensItsPagesOnADisplay(t *testing.T) {
	for _, c := range []struct {
		name            string
		display, noOpen bool
		launchErr       error
		opened          bool
		want            string
	}{
		{"a display", true, false, nil, true, "Opened it in your browser. It stops once CYFR is up.\n"},
		{"--no-open", true, true, nil, false, "Open it in a browser on this machine. It stops once CYFR is up.\n"},
		{"no display, --no-open", false, true, nil, false, "Open it in a browser on this machine. It stops once CYFR is up.\n"},
		{"a launcher that fails", true, false, errors.New("no xdg-open to open it with"), false,
			"Could not open a browser here (no xdg-open to open it with); open the address above.\nOpen it in a browser on this machine. It stops once CYFR is up.\n"},
	} {
		t.Run(c.name, func(t *testing.T) {
			newInitProject(t)
			useFakeEngine(t)
			l := stubLauncher(t, c.display, c.launchErr)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			var out bytes.Buffer
			done := make(chan error, 1)
			go func() {
				done <- runSetup(ctx, setupOptions{noPull: true, noOpen: c.noOpen}, &syncWriter{w: &out})
			}()
			p := openPages(t)
			address := p.base + "/#" + p.token
			cancel()
			awaitEnd(t, done)
			if !strings.HasPrefix(out.String(), "Setup is at "+address+"\n"+c.want) {
				t.Errorf("cyfr setup printed:\n%s", out.String())
			}
			var want []string
			if c.display && !c.noOpen {
				want = []string{address}
			}
			if got := l.all(); !slices.Equal(got, want) {
				t.Errorf("the launcher was handed %v, want %v", got, want)
			}
		})
	}
}

// Without a display and without --no-open, cyfr setup refuses before it
// serves, writes or opens anything: its pages are for a device whose
// launcher opens them, and cyfr init sets CYFR up at a terminal.
func TestSetupRefusesWithoutADisplay(t *testing.T) {
	newInitProject(t)
	useFakeEngine(t)
	l := stubLauncher(t, false, nil)
	var out bytes.Buffer
	err := runSetup(context.Background(), setupOptions{noPull: true}, &out)
	if want := "This machine has no browser for cyfr setup's pages. Run cyfr init here instead."; err == nil || err.Error() != want {
		t.Fatalf("cyfr setup answered %v, want %q", err, want)
	}
	if out.Len() != 0 || len(l.all()) != 0 {
		t.Errorf("the refused setup printed %q and opened %v", out.String(), l.all())
	}
	nothingWritten(t, ".env.example")
}
