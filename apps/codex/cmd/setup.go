// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/setup"
	"github.com/spf13/cobra"
)

func init() {
	setupCmd.Flags().Int("port", 0, "The port on 127.0.0.1 the setup pages are served on (a free one when 0)")
	setupCmd.Flags().Bool("no-pull", false, "Do not pull the stack's images")
	setupCmd.Flags().Bool("no-open", false, "Do not open the pages in the default browser (a device's launcher opens them)")
	rootCmd.AddCommand(setupCmd)
}

var setupCmd = &cobra.Command{
	Use:     "setup",
	Short:   "Set up a new CYFR from pages on this device's screen, for a device with no keyboard",
	GroupID: "server",
	Long: `Set up a new CYFR in the current directory from pages shown on this device's own screen, for a device with a touch screen and no keyboard; 'cyfr init' sets one up at a terminal. The pages ask nothing, as 'cyfr init' asks nothing: their one button, Set up CYFR, runs what 'cyfr init' runs, the same steps in the same order, then what 'cyfr up' runs, then shows the setup link. The CYFR they set up is reached from this device, at http://localhost:<CYFR_PORT>; 'cyfr access' changes how it is reached.

cyfr setup serves the pages on 127.0.0.1, at a port of its own, before anything of the stack runs, prints their address and writes it to .cyfr/setup.url while it serves them, then, on a machine with a display, opens them in the default browser as 'cyfr open' does. --no-open leaves that to a device's launcher, which reads the address from .cyfr/setup.url. A Linux machine with neither DISPLAY nor WAYLAND_DISPLAY set has no display, and there cyfr setup without --no-open refuses before it serves anything. Nothing off this machine reaches the pages: the address carries a token of this run, and every request must come from the pages themselves.

A step that fails shows why, in the command line's own sentence; a start that fails offers to try it again. Once CYFR is up, the pages show its setup link, <CYFR address>/setup#<token>, the token being CYFR_SETUP_TOKEN from .env, with a Copy button, and move the browser there: the link sets up CYFR's first person, who administers it, with a passkey. The program stops serving the pages once they have read that, or a minute after. Run in a project whose .env exists, it refuses as 'cyfr init' refuses to change how an existing CYFR is reached, serving nothing. One cyfr setup serves a project's pages: a second, while the first runs, is refused.

Exit status 1: CYFR was not set up and started, the message saying why.`,
	Example: `  cyfr setup
  cyfr setup --port 4040
  cyfr setup --no-open`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		port, _ := cmd.Flags().GetInt("port")
		noPull, _ := cmd.Flags().GetBool("no-pull")
		noOpen, _ := cmd.Flags().GetBool("no-open")
		if port < 0 || port > 65535 {
			return fmt.Errorf("--port takes a port from 1 to 65535, or 0 for a free one; %d is none", port)
		}
		return runSetup(ctx, setupOptions{port: port, noPull: noPull, noOpen: noOpen}, cmd.OutOrStdout())
	},
}

// setupOptions are cyfr setup's flags.
type setupOptions struct {
	port           int
	noPull, noOpen bool
}

// setupURLFile is where cyfr setup writes the address of its pages, for
// the launcher that opens them, while it serves them; setupLockFile is the
// lock the one setup of a project holds meanwhile.
const (
	setupURLFile  = ".cyfr/setup.url"
	setupLockFile = ".cyfr/setup.lock"
)

// setupLinger is how long the pages are served past the run's end when
// no page reads it.
var setupLinger = time.Minute

// The step a run of setup begins after init's.
const setupStepStart = "start"

// runSetup is `cyfr setup` in the working directory: the pages served
// until the run they drive ends, or ctx does.
func runSetup(ctx context.Context, o setupOptions, out io.Writer) error {
	if !o.noOpen && !hasDisplay() {
		return errors.New("cyfr setup serves pages for a device whose launcher opens them, and this machine has no browser to open them. Run cyfr init here.")
	}
	if err := refuseExistingHome(".env"); err != nil {
		return err
	}
	// One setup serves a project's pages: a second would race the first
	// for .env and for the address file. The lock is the setup's own, as
	// the run takes the stack's lock for each step it runs.
	if err := os.MkdirAll(".cyfr", 0o700); err != nil {
		return fmt.Errorf("cyfr setup cannot make .cyfr (%v). Nothing was changed", err)
	}
	release, busy, err := access.LockFile(setupLockFile)
	switch {
	case err != nil:
		return fmt.Errorf("cyfr setup cannot take %s (%v). Nothing was changed", setupLockFile, err)
	case busy:
		return errors.New("Another cyfr setup is serving this project's pages, at the address in .cyfr/setup.url. Nothing was changed. Use those pages, or stop that cyfr setup and run this again")
	}
	defer release()
	token, err := setup.NewToken()
	if err != nil {
		return err
	}
	l, err := setup.Listen(o.port)
	if err != nil {
		return fmt.Errorf("cyfr setup cannot serve its pages on 127.0.0.1:%d (%v). Nothing was changed", o.port, err)
	}
	out = &syncWriter{w: out}
	s := newSetupSession(ctx, o, out)
	srv := setup.NewServer(s, token, l.Addr().(*net.TCPAddr).Port)
	hs := &http.Server{Handler: srv, ReadHeaderTimeout: 10 * time.Second}
	served := make(chan error, 1)
	go func() { served <- hs.Serve(l) }()
	defer func() {
		stop, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		if hs.Shutdown(stop) != nil {
			hs.Close()
		}
	}()

	// The address is this run's while it holds the setup's lock, so it
	// goes with this run.
	address := setup.Address(l, token)
	defer os.Remove(setupURLFile)
	if err := writeFileAtomic(setupURLFile, []byte(address+"\n"), 0o600); err != nil {
		return fmt.Errorf("cyfr setup cannot write %s (%v). Nothing was changed", setupURLFile, err)
	}
	fmt.Fprintf(out, "Setup is at %s\n", hyperlink(out, address))
	if openOnDisplay(address, o.noOpen, out) {
		fmt.Fprintln(out, "Opened it in your browser. It stops once CYFR is up.")
	} else {
		fmt.Fprintln(out, "Open it in a browser on this machine. It stops once CYFR is up.")
	}

	select {
	case <-s.finished:
		select {
		case <-srv.Final():
		case <-time.After(setupLinger):
		case <-ctx.Done():
		}
		return s.result()
	case <-ctx.Done():
		if !s.begun() {
			return errors.New("cyfr setup was interrupted before the start; nothing of the new CYFR was written")
		}
		// The run sees ctx too: a problem's wait ends, and a start runs to
		// its end under its lock.
		<-s.finished
		if s.State().Phase == setup.PhaseDone {
			return s.result()
		}
		return fmt.Errorf("cyfr setup was interrupted. %s", s.result())
	case err := <-served:
		return fmt.Errorf("cyfr setup stopped serving its pages: %w", err)
	}
}

// refuseExistingHome refuses a project whose .env exists, as cyfr setup
// sets up a new home alone: with existingAccess's refusals, or the
// sentence init refuses changing an existing home with.
func refuseExistingHome(path string) error {
	if !fileExists(path) {
		return nil
	}
	current, err := existingAccess(path)
	if err != nil {
		return err
	}
	return existingHomeRefusal("cyfr setup", current)
}

// setupSession is the run the pages drive (setup.Session): cyfr init's
// sequence, then cyfr up's start.
type setupSession struct {
	ctx      context.Context
	o        setupOptions
	out      io.Writer
	finished chan struct{}

	mu      sync.Mutex
	st      setup.State
	started bool
	err     error
	// choice takes the offer a problem waits on, nil when none waits.
	choice chan string
}

func newSetupSession(ctx context.Context, o setupOptions, out io.Writer) *setupSession {
	return &setupSession{ctx: ctx, o: o, out: out, finished: make(chan struct{}), st: setup.State{Phase: setup.PhaseReady}}
}

func (s *setupSession) State() setup.State {
	s.mu.Lock()
	defer s.mu.Unlock()
	st := s.st
	st.Steps = slices.Clone(st.Steps)
	st.Offers = slices.Clone(st.Offers)
	return st
}

func (s *setupSession) begun() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.started
}

// result is how the ended run ends the process: nil for CYFR up, else the
// failure.
func (s *setupSession) result() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.err
}

// Start begins the run, refusing a project whose .env exists by now.
func (s *setupSession) Start() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.started || s.ctx.Err() != nil {
		return fmt.Errorf("%w: setup has begun already, or is stopping", setup.ErrNotNow)
	}
	if err := refuseExistingHome(".env"); err != nil {
		return err
	}
	s.started = true
	s.st = setup.State{Phase: setup.PhaseRunning, Steps: setupSteps(s.o.noPull), Step: initStepFiles}
	go s.run()
	return nil
}

// setupSteps are the steps of a run: init's, then the start.
func setupSteps(noPull bool) []string {
	steps := []string{initStepFiles, initStepSettings}
	if !noPull {
		steps = append(steps, initStepImages)
	}
	return append(steps, setupStepStart)
}

// Choose takes one of the offers the problem shown waits on.
func (s *setupSession) Choose(offer string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.st.Phase != setup.PhaseProblem || s.choice == nil || !slices.Contains(s.st.Offers, offer) {
		return fmt.Errorf("%w: %q is not offered", setup.ErrNotNow, offer)
	}
	s.st.Phase, s.st.Sentence, s.st.Offers = setup.PhaseRunning, "", nil
	s.choice <- offer
	s.choice = nil
	return nil
}

// step begins the step name.
func (s *setupSession) step(name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.st.Phase, s.st.Step = setup.PhaseRunning, name
}

// decide shows sentence with offers and waits for the pages' choice, ""
// when ctx ends first.
func (s *setupSession) decide(sentence string, offers ...string) string {
	choice := make(chan string, 1)
	s.mu.Lock()
	s.st.Phase, s.st.Sentence, s.st.Offers = setup.PhaseProblem, sentence, offers
	s.choice = choice
	s.mu.Unlock()
	select {
	case offer := <-choice:
		return offer
	case <-s.ctx.Done():
		return ""
	}
}

// run is the run: init's sequence, then the start.
func (s *setupSession) run() {
	defer close(s.finished)
	// The settings step is init's writing of the new .env.
	wroteEnv := false
	err := initProject(s.ctx, initOptions{noPull: s.o.noPull}, func(name string) {
		wroteEnv = wroteEnv || name == initStepSettings
		s.step(name)
	}, s.out, s.out)
	switch {
	case err == nil && !wroteEnv:
		// init wrote no .env: another command wrote one since the
		// start's check, or there is no template.
		if err = refuseExistingHome(".env"); err == nil {
			err = errors.New("There is no .env.example to write .env from, so nothing was set up: a released cyfr downloads it, and a cyfr built from source needs it copied from a checkout")
		}
		s.fail(err)
		return
	case err != nil:
		s.fail(err)
		return
	}
	if s.ctx.Err() != nil {
		s.fail(errors.New(".env is written, and CYFR was not started: `cyfr up` starts it"))
		return
	}
	s.start()
}

// start is cyfr up's start, again as the pages choose when it fails.
func (s *setupSession) start() {
	for {
		s.step(setupStepStart)
		err := runUp(s.ctx, s.out)
		if err == nil {
			s.done()
			return
		}
		if s.ctx.Err() != nil || s.decide(err.Error(), setup.OfferRetry) != setup.OfferRetry {
			s.fail(err)
			return
		}
	}
}

// currentHead is the head .env holds.
func currentHead() (access.Head, error) {
	e, err := openEngine(".")
	if err != nil {
		return access.Head{}, err
	}
	return e.Head()
}

// done ends the run with CYFR up at its address, with the setup link at
// that address from .env's setup token.
func (s *setupSession) done() {
	st := setup.State{Phase: setup.PhaseDone}
	if h, herr := currentHead(); herr == nil {
		st.Address = access.Describe(h).Address
	}
	if values, verr := access.ReadEnvValues(".env"); verr == nil && st.Address != "" && strings.TrimSpace(values[setupTokenVar]) != "" {
		st.SetupURL = setupLink(st.Address, values)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.st, s.err = st, nil
}

// fail ends the run without the home up, err why.
func (s *setupSession) fail(err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.st, s.err = setup.State{Phase: setup.PhaseFailed, Sentence: err.Error()}, err
}

// syncWriter is a writer the pages' run and the command write to at once.
type syncWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (w *syncWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.w.Write(p)
}
