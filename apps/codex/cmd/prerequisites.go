// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
	"slices"
	"strconv"
	"strings"
	"sync"

	"github.com/cyfr/codex/internal/install"
	"github.com/cyfr/codex/internal/version"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

// initCommand is the command the requirements' sentences tell the person
// to run again.
const initCommand = "`cyfr init`"

// installCommand is the documented install script command, which puts the
// root entry at the policy's install path: for this program's version when
// it is a pre-release, which the script installs only when named.
func installCommand() string {
	if strings.Contains(version.Version, "-") {
		return "curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | CYFR_VERSION=" + version.Version + " sh"
	}
	return "curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | sh"
}

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
	sudo, err := entryChecks.sudo()
	if err != nil {
		return nil, errNoSudo
	}
	if err := entryChecks.installed(p); err != nil {
		return nil, err
	}
	argv := []string{sudo, "-k"}
	if !interactive {
		argv = append(argv, "-n")
	}
	return append(append(argv, "--", p.InstallPath), apply...), nil
}

// entryChecks are rootEntry's two observations of the machine, which
// tests stand in for: where sudo is, and whether the policy's install path
// holds this very program, root's and writable by root alone.
var entryChecks = struct {
	sudo      func() (string, error)
	installed func(p install.Policy) error
}{
	sudo: func() (string, error) { return exec.LookPath("sudo") },
	installed: func(p install.Policy) error {
		info, err := os.Lstat(p.InstallPath)
		switch {
		case err != nil:
			return fmt.Errorf("there is no %s", p.InstallPath)
		case !info.Mode().IsRegular() || info.Mode().Perm()&0o022 != 0 || !ownedByRoot(info):
			return fmt.Errorf("%s is not a program only root can change", p.InstallPath)
		}
		out, err := exec.Command(p.InstallPath, "--version").Output()
		fields := strings.Fields(string(out))
		if err != nil || len(fields) == 0 || fields[len(fields)-1] != version.Version {
			return fmt.Errorf("%s is not cyfr %s", p.InstallPath, version.Version)
		}
		return nil
	},
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
	if before.Account.Root && before.Account.SudoUser != "" {
		return false, errors.New(install.UnderSudo(requirements, before.Account.SudoUser))
	}
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
		return false, fmt.Errorf("CYFR installs %s through %s, and %v. Nothing was installed. Run the install script (%s), then run %s again", requirements, p.InstallPath, err, installCommand(), initCommand)
	}

	plan := install.Plan{Version: install.PlanVersion, Account: before.Account.Name, UID: before.Account.UID, Actions: d.Actions}

	defer machine.forget()
	res := runEntry(argv, entryEnv(before.Account.Root), plan, out, errOut)
	after, err := machine.observe(context.WithoutCancel(ctx), p)
	if err != nil {
		after = before
	}
	completed := install.Completed(p, before, after)
	switch {
	case ctx.Err() != nil:
		return false, interruption{fmt.Errorf("Interrupted while installing %s. %s Run %s again to finish", requirements, completed, initCommand)}
	case res.failure != nil:
		return false, errors.New(install.Failure(p, res.failure.Err(), completed, initCommand))
	case !res.started:
		cause := install.ReadSudoCause(res.sudoSaid)
		if cause == install.SudoUnknown && !interactive {
			cause = install.SudoNeedsPassword
		}
		return false, errors.New(install.SudoRefused(cause, requirements, completed, initCommand))
	case res.err != nil:
		return false, errors.New(install.Failure(p, res.err, completed, initCommand))
	}
	if d.Continue && after.Account.Member && !after.Account.Process {
		return true, continueWithGroup(p, args, after.Account.Name, out, errOut)
	}
	switch again := install.Decide(p, after); again.Outcome {
	case install.Refuse:
		return false, errors.New(install.Refusal(p, again, completed, initCommand))
	case install.Install:
		return false, fmt.Errorf("CYFR still needs %s. %s Run %s again", install.Requirements(p, again.Actions), completed, initCommand)
	}
	return false, nil
}

// sgProgram runs a command with a group the account's processes do not
// carry yet, without a password when /etc/group lists the account in it;
// tests stand in for it.
var sgProgram = "/usr/bin/sg"

// continueWithGroup runs the rest of cyfr init, this same program with the
// flags the person gave, through sg with the docker group, which /etc/group
// now lists this account in and this process does not carry. It keeps this
// process's terminal, environment and directory, so it asks its questions
// and downloads as this run would; init's sudo cleanup runs after it. The
// terminal it was started from still lacks the group, and is told how to
// get it.
func continueWithGroup(p install.Policy, args []string, account string, out, errOut io.Writer) error {
	self, err := os.Executable()
	if err != nil {
		return fmt.Errorf("%s joined the %s group, and cyfr init could not find its own program to go on with it (%v). Run `newgrp %s`, then %s again", account, p.Docker.Group, err, p.Docker.Group, initCommand)
	}
	cmd := exec.Command(sgProgram, p.Docker.Group, "-c", shellQuote(append([]string{self, "init"}, args...)))
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, terminalOr(out), terminalOr(errOut)
	err = cmd.Run()
	fmt.Fprintf(out, "\nThis terminal started before %s joined the %s group. Run `newgrp %s` here, or log out and in again, before `cyfr up`.\n", account, p.Docker.Group, p.Docker.Group)
	var exit *exec.ExitError
	switch {
	case errors.As(err, &exit):
		return handedOver{exit.ExitCode()}
	case err != nil:
		return fmt.Errorf("%s joined the %s group, and cyfr init could not go on with it (%v). Run `newgrp %s`, then %s again", account, p.Docker.Group, err, p.Docker.Group, initCommand)
	}
	return nil
}

// terminalOr answers w's file when it is one, so a child writes to the
// terminal itself and sees one, else w.
func terminalOr(w io.Writer) io.Writer {
	if f, ok := w.(*os.File); ok {
		return f
	}
	return w
}

// shellQuote joins argv as one command line for sh -c: each word in single
// quotes, a single quote within it closed, escaped and reopened, so sh
// reads every word back as it is.
func shellQuote(argv []string) string {
	words := make([]string, len(argv))
	for i, w := range argv {
		words[i] = "'" + strings.ReplaceAll(w, "'", `'\''`) + "'"
	}
	return strings.Join(words, " ")
}

// entryResult is how a run of the root entry ended: whether it started
// (it wrote an event), the failure it reported, its exit status, or why it
// could not be run or read.
type entryResult struct {
	started bool
	failure *install.Failed
	status  int
	err     error
	// sudoSaid is the end of what the entry printed on standard error,
	// sudo's refusal among it.
	sudoSaid string
}

// runEntry runs the root entry with the plan on its standard input and
// reads its events from its standard output, showing each action as it
// starts. Its standard error is the terminal's, where sudo asks for the
// password and apt shows its progress.
func runEntry(argv, env []string, plan install.Plan, out, errOut io.Writer) entryResult {
	body, err := json.Marshal(plan)
	if err != nil {
		return entryResult{err: err}
	}
	p := install.Load()
	// The entry's standard error is copied while its events are shown;
	// one writer given for both is written by one goroutine at a time.
	if out == errOut {
		shared := &lockedWriter{w: out}
		out, errOut = shared, shared
	}
	said := &tailWriter{max: 4096}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Env = env
	cmd.Stdin = bytes.NewReader(append(body, '\n'))
	cmd.Stderr = io.MultiWriter(errOut, said)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return entryResult{err: err}
	}
	if err := cmd.Start(); err != nil {
		return entryResult{err: err}
	}
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
			}
		}
		if err != nil {
			break
		}
	}
	// The terminal's Ctrl-C reaches the entry and its children itself, so
	// the entry is waited for, not killed: nothing it started outlives this
	// run, and an apt step it stops ends as apt ends it.
	werr := cmd.Wait()
	res.sudoSaid = said.String()
	var exit *exec.ExitError
	switch {
	case errors.As(werr, &exit):
		res.status = exit.ExitCode()
		if res.failure == nil && res.started {
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

// tailWriter keeps the last max bytes written to it.
type tailWriter struct {
	mu  sync.Mutex
	max int
	buf []byte
}

func (t *tailWriter) Write(b []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.buf = append(t.buf, b...)
	if len(t.buf) > t.max {
		t.buf = t.buf[len(t.buf)-t.max:]
	}
	return len(b), nil
}

func (t *tailWriter) String() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return string(t.buf)
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

func init() {
	internalCmd.AddCommand(installApplyCmd)
}

// installApplyCmd is the root entry: run as root through sudo -k by cyfr
// init, it reads one plan on its standard input, applies it
// (install.Apply) and writes its events on its standard output. It takes
// no arguments and no environment beyond sudo's caller variables.
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
		os.Exit(installApply(ctx, install.NewHost(install.Load(), os.Stderr), os.Stdin, os.Stdout))
	},
}

// effectiveUID is the root entry's own identity; tests stand in for it.
var effectiveUID = os.Geteuid

// The root entry's exit statuses.
const (
	applyRefused = 3
	applyFailed  = 4
)

// installApply is the root entry over h.
func installApply(ctx context.Context, h install.Host, planIn io.Reader, out io.Writer) int {
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
	plan, err := install.ReadPlan(planIn, p, uid, name)
	if err != nil {
		emit.Failed(err)
		return applyRefused
	}
	if err := install.Apply(ctx, p, h, plan, emit); err != nil {
		emit.Failed(err)
		return applyFailed
	}
	return 0
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
