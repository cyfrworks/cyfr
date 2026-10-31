// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/cyfr/codex/internal/install"
	"github.com/cyfr/codex/internal/version"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

// initCommand is the command the requirements' sentences tell the person
// to run again.
const initCommand = "`cyfr init`"

// installCommand is the documented install script command, which puts the
// root entry at the policy's install path.
const installCommand = "curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh"

// machine is how cyfr init observes this machine and runs the root entry
// on it. Tests stand in for all three.
var machine = struct {
	// observe answers the machine's facts for the account running cyfr.
	observe func(ctx context.Context, p install.Policy) (install.Facts, error)
	// entry answers the root entry's argv, sudo's included, or why there
	// is none to run.
	entry func(p install.Policy, root, interactive bool) ([]string, error)
	// forget invalidates sudo's cached login, on every way out of an
	// elevation.
	forget func()
}{
	observe: install.ObserveSelf,
	entry:   rootEntry,
	forget: func() {
		if path, err := exec.LookPath("sudo"); err == nil {
			_ = exec.Command(path, "-k").Run()
		}
	},
}

// errNoSudo is a machine with no sudo to elevate through.
var errNoSudo = errors.New("no sudo")

// rootEntry is the root entry's argv: this program itself for root, else
// sudo running the installed program at the policy's path, which must be
// root's, writable by root alone, and this very version, so the program
// that changes the machine is the one the person agreed with. sudo's -k
// keeps no cached login; -n asks for no password where nobody can type
// one.
func rootEntry(p install.Policy, root, interactive bool) ([]string, error) {
	apply := []string{"internal", "install-apply"}
	if root {
		self, err := os.Executable()
		if err != nil {
			return nil, err
		}
		return append([]string{self}, apply...), nil
	}
	sudo, err := exec.LookPath("sudo")
	if err != nil {
		return nil, errNoSudo
	}
	info, err := os.Lstat(p.InstallPath)
	switch {
	case err != nil:
		return nil, fmt.Errorf("there is no %s", p.InstallPath)
	case !info.Mode().IsRegular() || info.Mode().Perm()&0o022 != 0 || !ownedByRoot(info):
		return nil, fmt.Errorf("%s is not a program only root can change", p.InstallPath)
	}
	out, err := exec.Command(p.InstallPath, "--version").Output()
	fields := strings.Fields(string(out))
	if err != nil || len(fields) == 0 || fields[len(fields)-1] != version.Version {
		return nil, fmt.Errorf("%s is not cyfr %s", p.InstallPath, version.Version)
	}
	argv := []string{sudo, "-k"}
	if !interactive {
		argv = append(argv, "-n")
	}
	return append(append(argv, "--", p.InstallPath), apply...), nil
}

// prepareMachine is cyfr init's first step: what this machine lacks of
// CYFR's requirements, shown, agreed and installed through one elevation.
// It answers true when a continued init, in a process carrying the docker
// group, did the rest of the run; false when this process goes on to
// prepare the project. A system automatic preparation does not support,
// or one that has everything, shows and asks nothing.
func prepareMachine(ctx context.Context, yes bool, args []string, out, errOut io.Writer) (bool, error) {
	p := install.Load()
	before, err := machine.observe(ctx, p)
	if err != nil {
		return false, err
	}
	d := install.Decide(p, before)
	switch d.Outcome {
	case install.Other, install.Satisfied:
		return false, nil
	case install.Refuse:
		return false, errors.New(install.Refusal(p, d, "Nothing was installed.", initCommand))
	}

	requirements := install.Requirements(p, d.Actions)
	fmt.Fprintf(out, "CYFR needs %s on this machine. These commands make the changes, as root:\n", requirements)
	for _, a := range d.Actions {
		fmt.Fprintf(out, "  %s\n", a.Command(p).Display())
	}
	if slices.ContainsFunc(d.Actions, func(a install.Action) bool { return a.Kind == install.GroupAdd }) {
		fmt.Fprintf(out, "Members of the %s group control Docker, and so have root's power over this machine.\n", p.Docker.Group)
	}
	interactive := askTerminal()
	if !yes {
		if !interactive {
			return false, errors.New(install.NoAgreement(requirements, initCommand))
		}
		answer, err := ask(ctx, bufio.NewReader(askInput), out, "Install these requirements? (yes/no)", "no")
		if err != nil {
			return false, interruption{errQuestionInterrupted}
		}
		if !strings.EqualFold(answer, "yes") && !strings.EqualFold(answer, "y") {
			return false, errors.New(install.Declined(requirements, initCommand))
		}
	}

	argv, err := machine.entry(p, before.Account.Root, interactive)
	switch {
	case errors.Is(err, errNoSudo):
		return false, errors.New(install.NoSudo(requirements, "Nothing was installed.", initCommand))
	case err != nil:
		return false, fmt.Errorf("CYFR installs %s through %s, and %v. Nothing was installed. Run the install script (%s), then run %s again", requirements, p.InstallPath, err, installCommand, initCommand)
	}

	plan := install.Plan{Version: install.PlanVersion, Account: before.Account.Name, UID: before.Account.UID, Actions: d.Actions}
	if d.Continue {
		dir, err := os.Getwd()
		if err != nil {
			return false, err
		}
		plan.Continue = &install.Continuation{Dir: dir, Args: args, Terminal: interactive}
	}

	defer machine.forget()
	res := runEntry(argv, entryEnv(before.Account.Root), plan, out, errOut)
	after, err := machine.observe(context.WithoutCancel(ctx), p)
	if err != nil {
		after = before
	}
	completed := install.Completed(p, before, after)
	switch {
	case ctx.Err() != nil && !res.continued:
		return false, interruption{fmt.Errorf("Interrupted while installing %s. %s Run %s again to finish", requirements, completed, initCommand)}
	case res.failure != nil:
		return false, errors.New(install.Failure(p, res.failure.Err(), completed, initCommand))
	case res.continued:
		if !after.Account.Process {
			fmt.Fprintf(out, "\nThis terminal started before %s joined the %s group. Run `newgrp %s` here, or log out and in again, before `cyfr up`.\n", after.Account.Name, p.Docker.Group, p.Docker.Group)
		}
		if res.status != 0 {
			return true, handedOver{res.status}
		}
		return true, nil
	case !res.started:
		return false, errors.New(install.NoSudo(requirements, completed, initCommand))
	case res.err != nil:
		return false, errors.New(install.Failure(p, res.err, completed, initCommand))
	}
	switch again := install.Decide(p, after); again.Outcome {
	case install.Refuse:
		return false, errors.New(install.Refusal(p, again, completed, initCommand))
	case install.Install:
		return false, fmt.Errorf("CYFR still needs %s. %s Run %s again", install.Requirements(p, again.Actions), completed, initCommand)
	}
	return false, nil
}

// entryResult is how a run of the root entry ended: whether it started
// (it wrote an event), the failure it reported, whether it continued init
// and that run's exit status, or why it could not be run or read.
type entryResult struct {
	started, continued bool
	failure            *install.Failed
	status             int
	err                error
}

// runEntry runs the root entry with the plan on its standard input and
// reads its events from its standard output, showing each action as it
// starts; after "continue" the output is the continued init's, copied to
// out as it arrives. Its standard error is the terminal's, where sudo
// asks for the password and apt shows its progress.
func runEntry(argv, env []string, plan install.Plan, out, errOut io.Writer) entryResult {
	body, err := json.Marshal(plan)
	if err != nil {
		return entryResult{err: err}
	}
	// The plan goes through a FIFO in a directory only this account can
	// enter; the entry's standard input stays the terminal, which sudo
	// relays to it and to the init it continues.
	dir, err := os.MkdirTemp("", "cyfr-install-")
	if err != nil {
		return entryResult{err: err}
	}
	defer os.RemoveAll(dir)
	fifo := filepath.Join(dir, "plan")
	if err := makeFIFO(fifo); err != nil {
		return entryResult{err: err}
	}
	argv = append(slices.Clone(argv), "--plan", fifo)
	p := install.Load()
	// The entry's standard error is copied while its events are shown;
	// one writer given for both is written by one goroutine at a time.
	if out == errOut {
		shared := &lockedWriter{w: out}
		out, errOut = shared, shared
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Env = env
	cmd.Stdin = os.Stdin
	cmd.Stderr = errOut
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return entryResult{err: err}
	}
	if err := cmd.Start(); err != nil {
		return entryResult{err: err}
	}
	// The write waits for the entry to open the FIFO; an entry that ends
	// without opening it (sudo refused, say) is stood in for below.
	written := make(chan struct{})
	go func() {
		defer close(written)
		if f, err := os.OpenFile(fifo, os.O_WRONLY, 0); err == nil {
			_, _ = f.Write(append(body, '\n'))
			_ = f.Close()
		}
	}()
	var res entryResult
	r := bufio.NewReader(stdout)
	for {
		line, err := r.ReadBytes('\n')
		if len(line) > 0 {
			var ev install.Event
			if json.Unmarshal(line, &ev) != nil {
				continue
			}
			res.started = true
			switch ev.Event {
			case install.EventStart:
				if ev.Action != nil {
					fmt.Fprintf(out, "→ %s\n", ev.Action.Command(p).Display())
				}
			case install.EventFailed:
				res.failure = ev.Failure
			case install.EventContinue:
				res.continued = true
				_, _ = io.Copy(out, r)
			}
		}
		if err != nil || res.continued {
			break
		}
	}
	// The terminal's Ctrl-C reaches the entry and its children itself, so
	// the entry is waited for, not killed: nothing it started outlives this
	// run, and an apt step it stops ends as apt ends it.
	werr := cmd.Wait()
	select {
	case <-written:
	default:
		if f, err := os.OpenFile(fifo, os.O_RDONLY|openNonBlock, 0); err == nil {
			<-written
			_ = f.Close()
		}
	}
	var exit *exec.ExitError
	switch {
	case errors.As(werr, &exit):
		res.status = exit.ExitCode()
		if !res.continued && res.failure == nil && res.started {
			res.err = fmt.Errorf("the installer exited with status %d", res.status)
		}
	case werr != nil:
		res.err = werr
	}
	return res
}

// entryEnv is the root entry's environment. Run by root itself, it carries
// no SUDO_ variable: those of a `sudo cyfr init` name the account sudo was
// run from, and the entry would take that account for the plan's. Through
// sudo, sudo sets them.
func entryEnv(root bool) []string {
	env := os.Environ()
	if root {
		env = slices.DeleteFunc(env, func(kv string) bool { return strings.HasPrefix(kv, "SUDO_") })
	}
	return env
}

// lockedWriter serializes writes to w.
type lockedWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (l *lockedWriter) Write(b []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.w.Write(b)
}

// continuationArgs are the arguments of the init run a continuation
// starts: init and each flag the person gave, as --name=value.
func continuationArgs(c *cobra.Command) []string {
	var args []string
	c.Flags().Visit(func(f *pflag.Flag) {
		args = append(args, "--"+f.Name+"="+f.Value.String())
	})
	return args
}

// initFlag reports whether name is a flag cyfr init takes.
func initFlag(name string) bool {
	return initCmd.Flags().Lookup(name) != nil || initCmd.InheritedFlags().Lookup(name) != nil
}

func init() {
	installApplyCmd.Flags().String("plan", "", "The FIFO cyfr init writes the agreed plan to")
	internalCmd.AddCommand(installApplyCmd)
}

// installApplyCmd is the root entry: run as root through sudo -k by cyfr
// init, it reads one plan from the FIFO --plan names (openPlan), applies it
// (install.Apply)
// and writes its events on its standard output, then continues init as
// the account when the plan says so. It takes no arguments and no
// environment beyond sudo's caller variables.
var installApplyCmd = &cobra.Command{
	Use:    "install-apply",
	Short:  "Apply the requirements cyfr init agreed to install, as root",
	Hidden: true,
	Args:   cobra.NoArgs,
	Run: func(cmd *cobra.Command, args []string) {
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		path, _ := cmd.Flags().GetString("plan")
		emit := install.Emitter{W: os.Stdout}
		uid, _, err := sudoCaller()
		if err != nil {
			emit.Failed(fmt.Errorf("%w: %v", install.ErrInvalidPlan, err))
			os.Exit(applyRefused)
		}
		plan, err := openPlan(path, uid)
		if err != nil {
			emit.Failed(fmt.Errorf("%w: %v", install.ErrInvalidPlan, err))
			os.Exit(applyRefused)
		}
		status := installApply(ctx, install.NewHost(install.Load(), os.Stderr), plan, os.Stdin, os.Stdout, os.Stderr)
		_ = plan.Close()
		os.Exit(status)
	},
}

// planWait bounds how long the root entry waits for cyfr init to open the
// plan's FIFO for writing.
var planWait = 60 * time.Second

// openPlan opens the plan cyfr init writes for the account uid: a FIFO of
// that account's, alone in a directory of its own that only it can enter,
// opened without following a link, and the same file the checks read.
func openPlan(path string, uid int) (*os.File, error) {
	dir, err := os.Lstat(filepath.Dir(path))
	if err != nil || !dir.IsDir() || dir.Mode().Perm() != 0o700 || !ownedBy(dir, uid) {
		return nil, fmt.Errorf("the plan's directory %s is not a private directory of the caller's", filepath.Dir(path))
	}
	info, err := os.Lstat(path)
	if err != nil || info.Mode().Type() != os.ModeNamedPipe || !ownedBy(info, uid) {
		return nil, fmt.Errorf("%s is not the caller's FIFO", path)
	}
	// Opening a FIFO waits for its writer; one that never comes (cyfr init
	// ended first) ends the wait at planWait.
	type open struct {
		f   *os.File
		err error
	}
	opening := make(chan open, 1)
	go func() {
		f, err := os.OpenFile(path, os.O_RDONLY|openNoFollow, 0)
		opening <- open{f, err}
	}()
	var f *os.File
	select {
	case o := <-opening:
		if o.err != nil {
			return nil, o.err
		}
		f = o.f
	case <-time.After(planWait):
		return nil, fmt.Errorf("no plan arrived on %s within %s", path, planWait)
	}
	if opened, err := f.Stat(); err != nil || !os.SameFile(info, opened) {
		_ = f.Close()
		return nil, fmt.Errorf("%s changed while it was opened", path)
	}
	return f, nil
}

// effectiveUID and continueProgram are the root entry's own identity and
// the sudo it continues init through; tests stand in for both.
var (
	effectiveUID    = os.Geteuid
	continueProgram = "/usr/bin/sudo"
)

// The root entry's exit statuses apart from a continuation's own.
const (
	applyRefused = 3
	applyFailed  = 4
)

// installApply is the root entry over h.
func installApply(ctx context.Context, h install.Host, planIn, stdin io.Reader, out, errOut io.Writer) int {
	emit := install.Emitter{W: out}
	if effectiveUID() != 0 {
		emit.Failed(fmt.Errorf("%w: not run as root", install.ErrInvalidPlan))
		return applyRefused
	}
	uid, name, err := sudoCaller()
	if err != nil {
		emit.Failed(fmt.Errorf("%w: %v", install.ErrInvalidPlan, err))
		return applyRefused
	}
	p := install.Load()
	plan, err := install.ReadPlan(planIn, p, uid, name, initFlag)
	if err != nil {
		emit.Failed(err)
		return applyRefused
	}
	if c := plan.Continue; c != nil {
		info, err := os.Stat(c.Dir)
		if err != nil || !info.IsDir() || !ownedBy(info, plan.UID) {
			emit.Failed(fmt.Errorf("%w: %s is not a directory of %s's", install.ErrInvalidPlan, c.Dir, plan.Account))
			return applyRefused
		}
	}
	if err := install.Apply(ctx, p, h, plan, emit); err != nil {
		emit.Failed(err)
		return applyFailed
	}
	if plan.Continue == nil {
		return 0
	}
	return continueInit(p, plan, emit, stdin, out, errOut)
}

// sudoCaller is the account sudo ran this process for, from the variables
// sudo itself sets, its name checked against the user database; root
// itself when sudo did not run it.
func sudoCaller() (int, string, error) {
	raw, ok := os.LookupEnv("SUDO_UID")
	if !ok {
		return 0, "root", nil
	}
	uid, err := strconv.Atoi(raw)
	if err != nil {
		return 0, "", fmt.Errorf("SUDO_UID %q", raw)
	}
	u, err := user.LookupId(raw)
	if err != nil || u.Username != os.Getenv("SUDO_USER") {
		return 0, "", fmt.Errorf("SUDO_USER does not name uid %d", uid)
	}
	return uid, u.Username, nil
}

// continueInit runs cyfr init as the plan's account in a process whose
// groups are read afresh, so it carries the docker group the plan added:
// sudo run by root asks no password. Its standard output follows the
// "continue" event; its exit status is the entry's.
func continueInit(p install.Policy, plan install.Plan, emit install.Emitter, in io.Reader, out, errOut io.Writer) int {
	c := plan.Continue
	// A run at a terminal continues at that terminal: its standard input,
	// the terminal sudo relays, and its output drawn there, so it asks its
	// questions as the run it continues would. Any other run reads nothing,
	// and its output follows the "continue" event.
	stdin, stdout := in, out
	if tty, err := os.OpenFile("/dev/tty", os.O_WRONLY, 0); c.Terminal && err == nil {
		defer tty.Close()
		stdout = tty
	} else {
		if err == nil {
			tty.Close()
		}
		stdin = nil
	}
	argv := append([]string{"-n", "-k", "-u", plan.Account, "-H", "--", p.InstallPath, "init"}, c.Args...)
	if !c.Terminal {
		argv = append(argv, "--no-interactive")
	}
	emit.Continue()
	cmd := exec.Command(continueProgram, argv...)
	cmd.Dir = c.Dir
	cmd.Env = []string{"PATH=/usr/local/bin:/usr/bin:/bin", "TERM=" + os.Getenv("TERM")}
	cmd.Stdin, cmd.Stdout, cmd.Stderr = stdin, stdout, errOut
	err := cmd.Run()
	var exit *exec.ExitError
	switch {
	case errors.As(err, &exit):
		return exit.ExitCode()
	case err != nil:
		fmt.Fprintf(errOut, "cyfr init could not continue as %s (%v). Run %s again.\n", plan.Account, err, initCommand)
		return applyFailed
	}
	return 0
}
