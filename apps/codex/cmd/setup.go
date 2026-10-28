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
	Short:   "Set up CYFR from pages on this machine's screen: how it is reached, then the start",
	GroupID: "server",
	Long: `Set up a new CYFR in the current directory from pages shown on this machine's own screen, the face of 'cyfr init' for a device with a touch screen and no keyboard. It serves the pages on 127.0.0.1, at a port of its own, before anything of the stack runs, prints their address and writes it to .cyfr/setup.url while it serves them, then, on a machine with a display, opens them in the default browser as 'cyfr open' does. --no-open leaves that to a device's launcher, which reads the address from .cyfr/setup.url; a Linux machine with neither DISPLAY nor WAYLAND_DISPLAY set has no display. Nothing off this machine reaches them: the address carries a token of this run, and every request must come from the pages themselves.

The pages ask how CYFR is reached (your phone and laptop via Tailscale, the recommended choice; only this device; or, under Advanced, a public domain with an optional certificate email), then start: they run what 'cyfr init' runs, the same steps in the same order, then what 'cyfr up' runs. For tailnet access, the join shows its approval link as a QR code and as text with a Copy button, under it the machine's name (cyfr unless changed there), and waits for the approval; a join that fails, expires or is cancelled leaves CYFR reached from this device only, and the pages offer to try the join again or to start CYFR on this device only. A start that fails shows why, and offers to try again or, for CYFR reached from other devices, to start it on this device only. Each refusal is the command line's own sentence.

Once CYFR is up, the pages show its setup link, <CYFR address>/setup#<token>, the token being CYFR_SETUP_TOKEN from .env, with a Copy button: the link sets up CYFR's first person, who administers it, with a passkey. The pages move the browser there, apart from a tailnet address, which a browser on this device reaches only through CYFR's SOCKS5 proxy on 127.0.0.1:1055. A headless CYFR (CYFR_HEADLESS=on) serves no setup page, so the pages say instead that its first person runs 'cyfr login --setup' in its directory. The program stops serving the pages once they have read that, or a minute after. Run in a project whose .env exists, it refuses as 'cyfr init' refuses to change how an existing CYFR is reached, serving nothing; 'cyfr access <mode>' changes that. One cyfr setup serves a project's pages: a second, while the first runs, is refused.

Exit status 3: CYFR started, but on this machine only, because the tailnet machine is not ready to serve it (not the one .env names, not joined, or HTTPS off); Serve stays closed, and the message says what to do. Exit status 1: CYFR was not set up and started, the message saying why.`,
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

// The step a run of setup begins after init's (initFace.step).
const setupStepStart = "start"

// runSetup is `cyfr setup` in the working directory: the pages served
// until the run they drive ends, or ctx does.
func runSetup(ctx context.Context, o setupOptions, out io.Writer) error {
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
		// The run sees ctx too: a waiting join is cancelled, a problem's
		// wait ends, and a start runs to its end under its lock.
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

// stayLocal is a new home's mode left unapplied by its person's choice on
// the pages, the home reached from this device only, err why.
type stayLocal struct{ err error }

func (e stayLocal) Error() string { return e.err.Error() }
func (e stayLocal) Unwrap() error { return e.err }

// Why the pages cancelled a waiting join.
const (
	cancelledToRename = "rename"
	cancelledForLocal = "local"
)

// setupSession is the run the pages drive (setup.Session): cyfr init's
// sequence, with the pages' answers and the join's link shown on them,
// then cyfr up's start.
type setupSession struct {
	ctx      context.Context
	o        setupOptions
	out      io.Writer
	finished chan struct{}

	mu      sync.Mutex
	st      setup.State
	started bool
	err     error
	// cancelJoin cancels the join attempt under way, nil when none is;
	// cancelled says why the pages cancelled it, and rename the name
	// they asked for.
	cancelJoin func()
	cancelled  string
	rename     string
	// choice takes the offer a problem waits on, nil when none waits.
	choice chan string
}

func newSetupSession(ctx context.Context, o setupOptions, out io.Writer) *setupSession {
	return &setupSession{ctx: ctx, o: o, out: out, finished: make(chan struct{}), st: setup.State{Phase: setup.PhaseAnswering}}
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

// result is how the ended run ends the process: nil for a home up as
// asked, startedLocally for one up on this machine only, else the failure.
func (s *setupSession) result() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.err
}

// check refuses answers the start would refuse: a mode outside the three,
// and a public home's domain or certificate email that is not one.
func (s *setupSession) check(a setup.Answers) error {
	switch a.Mode {
	case access.ModeLocal, access.ModeTailnet:
		if a.Domain != "" || a.ACMEEmail != "" {
			return errors.New("A domain and a certificate email are for public access alone")
		}
		return nil
	case access.ModePublic:
		if a.Domain == "" {
			return errors.New("Type the domain CYFR is reached at; its DNS must name this machine")
		}
		return checkTarget(access.Target{Mode: a.Mode, Domain: a.Domain, ACMEEmail: a.ACMEEmail})
	}
	return fmt.Errorf("Access is local, tailnet or public; %q is none of them", a.Mode)
}

// Start begins the run with a, refusing what it would refuse before
// anything is written, and a project whose .env exists by now.
func (s *setupSession) Start(a setup.Answers) error {
	if err := s.check(a); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.started || s.ctx.Err() != nil {
		return fmt.Errorf("%w: setup has begun already, or is stopping", setup.ErrNotNow)
	}
	if err := refuseExistingHome(".env"); err != nil {
		return err
	}
	s.started = true
	s.st = setup.State{Phase: setup.PhaseRunning, Mode: a.Mode, Steps: setupSteps(a.Mode, s.o.noPull), Step: initStepFiles}
	go s.run(a)
	return nil
}

// setupSteps are the steps of a run for mode: init's, then the start.
func setupSteps(mode string, noPull bool) []string {
	steps := []string{initStepFiles, initStepSettings}
	if mode != access.ModeLocal {
		steps = append(steps, initStepAccess)
	}
	if !noPull {
		steps = append(steps, initStepImages)
	}
	return append(steps, setupStepStart)
}

// Rename joins again under name while the join waits for its approval,
// refusing a name the join would refuse before cancelling anything.
func (s *setupSession) Rename(name string) error {
	name, err := access.CheckHostname(name)
	if err != nil {
		return engineFailure(err)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.st.Phase != setup.PhaseApproval || s.cancelJoin == nil {
		return fmt.Errorf("%w: no join waits for its approval", setup.ErrNotNow)
	}
	if name == s.st.Name {
		return nil
	}
	s.cancelled, s.rename = cancelledToRename, name
	s.st.Phase, s.st.AuthURL, s.st.Name = setup.PhaseRunning, "", name
	s.cancelJoin()
	return nil
}

// Cancel cancels the waiting join, the home reached from this device only.
func (s *setupSession) Cancel() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.st.Phase != setup.PhaseApproval || s.cancelJoin == nil {
		return fmt.Errorf("%w: no join waits for its approval", setup.ErrNotNow)
	}
	s.cancelled = cancelledForLocal
	s.st.Phase, s.st.AuthURL = setup.PhaseRunning, ""
	s.cancelJoin()
	return nil
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

// run is the run with answers a: init's sequence, then the start.
func (s *setupSession) run(a setup.Answers) {
	defer close(s.finished)
	choice := accessChoice{mode: a.Mode, accessOptions: accessOptions{domain: a.Domain, acmeEmail: a.ACMEEmail}}
	// The settings step is init's writing of the new .env.
	wroteEnv := false
	err := initProject(s.ctx, initOptions{noPull: s.o.noPull}, initFace{
		answers: func(context.Context) (accessChoice, error) {
			return choice, nil
		},
		apply: s.apply,
		step: func(name string) {
			wroteEnv = wroteEnv || name == initStepSettings
			s.step(name)
		},
	}, s.out, s.out)
	var stay stayLocal
	switch local := (startedLocally{}); {
	case err == nil && !wroteEnv:
		// init wrote no .env: another command wrote one since the
		// start's check, or there is no template.
		if err = refuseExistingHome(".env"); err == nil {
			err = errors.New("There is no .env.example to write .env from, so nothing was set up: a released cyfr downloads it, and a cyfr built from source needs it copied from a checkout")
		}
		s.fail(err)
		return
	case err == nil, errors.As(err, &stay), errors.As(err, &local):
	default:
		s.fail(err)
		return
	}
	if s.ctx.Err() != nil {
		s.fail(errors.New(".env is written, and CYFR was not started: `cyfr up` starts it"))
		return
	}
	s.start()
}

// apply is init's apply step on the pages: the switch, a tailnet join's
// link and machine shown on them, its name changed or the join cancelled
// from them, and a failure that leaves the home local offering the join
// again or the home on this device only.
func (s *setupSession) apply(ctx context.Context, c accessChoice, key []byte) (access.Head, error) {
	for {
		attempt, cancel := context.WithCancel(ctx)
		s.mu.Lock()
		s.cancelJoin, s.cancelled, s.st.Joined = cancel, "", ""
		if c.mode == access.ModeTailnet {
			s.st.Name = joinName(c.accessOptions)
		}
		s.mu.Unlock()
		head, err := applyMode(attempt, c, key, joinChoice{onAuthURL: s.waiting, onJoined: s.joined}, s.out)
		s.mu.Lock()
		cancelled, name := s.cancelled, s.rename
		s.cancelJoin, s.cancelled, s.st.AuthURL = nil, "", ""
		if s.st.Phase == setup.PhaseApproval {
			s.st.Phase = setup.PhaseRunning
		}
		s.mu.Unlock()
		cancel()
		// A switch that was made stands, whatever the pages asked
		// meanwhile.
		switch local := (startedLocally{}); {
		case err == nil, errors.As(err, &local), ctx.Err() != nil:
			return head, err
		case cancelled == cancelledToRename:
			// A join cancelled before its machine joined leaves the
			// waiting machine's state, its name among it, in the tailnet
			// state's volume: the new name joins as a new machine. One
			// that joined meanwhile is taken as it is.
			var r *access.Refusal
			c.hostname = name
			c.newNode = errors.As(err, &r) && r.Code == "tailnet_join_cancelled"
			continue
		case cancelled == cancelledForLocal:
			return s.thisDeviceOnly(ctx, err)
		}
		// The page claims the home local only while .env holds it local: a
		// switch can fail after it changed .env, which recovery decides.
		sentence := err.Error()
		if h, herr := currentHead(); herr == nil && h.Mode == access.ModeLocal {
			sentence += "\n" + leftLocal(c.mode)
		}
		switch s.decide(sentence, setup.OfferRetry, setup.OfferLocal) {
		case setup.OfferRetry:
			c.newNode = false
			continue
		case setup.OfferLocal:
			return s.thisDeviceOnly(ctx, err)
		}
		return head, stayLocal{err}
	}
}

// thisDeviceOnly makes the home reached from this device only, as the
// pages chose after the mode's apply failed (why): through the engine,
// whose recovery first establishes what the failed attempt left, a switch
// that changed .env among it, then a switch to local unless .env holds
// local already. A switch that fails shows its sentence and offers the
// choice again.
func (s *setupSession) thisDeviceOnly(ctx context.Context, why error) (access.Head, error) {
	for {
		s.step(initStepAccess)
		head, err := applyMode(ctx, accessChoice{mode: access.ModeLocal}, nil, joinChoice{}, s.out)
		if err == nil {
			return head, stayLocal{why}
		}
		if ctx.Err() != nil || s.decide(err.Error(), setup.OfferLocal) != setup.OfferLocal {
			return head, stayLocal{why}
		}
	}
}

// applyMode is applyInitAccess, whose lock first runs the engine's
// recovery of an attempt an earlier failure left unfinished: a home that
// recovery leaves already as c asks is that head, the change made.
func applyMode(ctx context.Context, c accessChoice, key []byte, choice joinChoice, out io.Writer) (access.Head, error) {
	head, err := applyInitAccess(ctx, c, key, choice, out)
	if r := (*access.Refusal)(nil); errors.As(err, &r) && r.Code == "access_unchanged" {
		return currentHead()
	}
	return head, err
}

// waiting shows the join's approval link.
func (s *setupSession) waiting(url string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cancelled == "" {
		s.st.Phase, s.st.AuthURL = setup.PhaseApproval, url
	}
}

// joined shows the machine's name on the tailnet.
func (s *setupSession) joined(name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.st.Phase, s.st.AuthURL, s.st.Joined = setup.PhaseRunning, "", name
}

// start is cyfr up's start, again or on this device only as the pages
// choose when it fails.
func (s *setupSession) start() {
	for {
		s.step(setupStepStart)
		if h, herr := currentHead(); herr == nil {
			s.mu.Lock()
			s.st.Starting = h.Mode
			s.mu.Unlock()
		}
		err := runUp(s.ctx, s.out)
		if local := (startedLocally{}); err == nil || errors.As(err, &local) {
			s.done(err)
			return
		}
		for {
			if s.ctx.Err() != nil {
				s.fail(err)
				return
			}
			offers := []string{setup.OfferRetry}
			if h, herr := currentHead(); herr == nil && h.Mode != access.ModeLocal {
				offers = append(offers, setup.OfferLocal)
			}
			switch s.decide(err.Error(), offers...) {
			case setup.OfferRetry:
			case setup.OfferLocal:
				s.step(setupStepStart)
				if _, err = applyMode(s.ctx, accessChoice{mode: access.ModeLocal}, nil, joinChoice{}, s.out); err != nil {
					continue
				}
			default:
				s.fail(err)
				return
			}
			break
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

// done ends the run with the home up: at its address, or at this
// machine's own for a start that left it there (err, its sentence shown,
// the browser not moved past it), with the setup link at that address
// from .env's setup token. A tailnet address is not moved to, since a
// browser on this device reaches it only through CYFR's SOCKS5 proxy.
func (s *setupSession) done(err error) {
	st := setup.State{Phase: setup.PhaseDone}
	if h, herr := currentHead(); herr == nil {
		st.Mode, st.Address = h.Mode, access.Describe(h).Address
		if err != nil {
			st.Address = access.Describe(access.Head{Mode: access.ModeLocal, Port: h.Port}).Address
		}
	}
	// A headless CYFR serves no setup page: its first person runs
	// `cyfr login --setup` in this directory instead.
	if values, verr := access.ReadEnvValues(".env"); verr == nil && headless(values) {
		st.Headless = true
	} else if verr == nil && st.Address != "" && strings.TrimSpace(values[setupTokenVar]) != "" {
		st.SetupURL = setupLink(st.Address, values)
	}
	if err != nil {
		st.Sentence = err.Error()
	}
	st.Moves = st.Address != "" && err == nil && st.Mode != access.ModeTailnet
	s.mu.Lock()
	defer s.mu.Unlock()
	s.st, s.err = st, err
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
