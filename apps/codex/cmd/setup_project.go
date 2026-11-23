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
	"os/signal"
	"os/user"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/spf13/cobra"
)

// Setup's work is every local Docker call and project change the CYFR app
// and the screen make, always in a process of its own, cyfr internal
// setup-project (setupWork starts it). init and up act on their working
// directory and take their process's signals; the app's cyfr keeps its
// stdout for main's messages alone; the docker group reaches only a new
// process; and an app's PATH lacks Docker Desktop's docker. The process
// serves nothing. The end of its stdin is the one cancel.
//
// What it is asked:
//
//	probe             whether a Docker on this computer answers
//	run DIR           set CYFR up in DIR and start it (setupProject)
//	look DIR          one reading of DIR and Docker's word of it (lookInFolder)
//	token DIR HOLDER  that, and the setup token while no one is set up
//	                  (lookForToken), HOLDER named in the stack's lock
//
// It answers on stdout a JSON object a line (workMessage): a step begun,
// then one end, done or failed. What else a shell prints there as it
// starts the work is no message and is passed over.
const (
	workProbe = "probe"
	workRun   = "run"
	workLook  = "look"
	workToken = "token"

	workStep   = "step"
	workDone   = "done"
	workFailed = "failed"
)

type workMessage struct {
	Type string `json:"type"`
	Step string `json:"step,omitempty"`
	// Ready is probe's answer, Sentence why it is not or why the work
	// failed.
	Ready    bool        `json:"ready,omitempty"`
	Sentence string      `json:"sentence,omitempty"`
	Look     *folderLook `json:"look,omitempty"`
}

// maxWorkLine bounds one line the work writes.
const maxWorkLine = 1 << 20

var setupProjectCmd = &cobra.Command{
	Use:    "setup-project probe | run DIR | look DIR | token DIR HOLDER",
	Short:  "Do setup's work in a folder",
	Hidden: true,
	Args: func(_ *cobra.Command, args []string) error {
		switch {
		case len(args) == 1 && args[0] == workProbe:
		case len(args) == 2 && (args[0] == workRun || args[0] == workLook) && filepath.IsAbs(args[1]):
		case len(args) == 3 && args[0] == workToken && filepath.IsAbs(args[1]) && args[2] != "":
		default:
			return errors.New("setup-project takes probe, run or look and a folder's whole path, or token, that path and who asks")
		}
		return nil
	},
	RunE: func(cmd *cobra.Command, args []string) error {
		return runSetupWork(cmd.Context(), os.Stdin, os.Stdout, args)
	},
}

func runSetupWork(ctx context.Context, in io.Reader, out io.Writer, args []string) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		_, _ = io.Copy(io.Discard, in)
		cancel()
	}()
	// The app may go while a start runs: a write to its closed pipe then
	// fails rather than end this process inside the start. It is handled,
	// not ignored, so that no program started here inherits that.
	broken := make(chan os.Signal, 1)
	signal.Notify(broken, syscall.SIGPIPE)
	defer signal.Stop(broken)

	to := json.NewEncoder(out)
	say := func(m workMessage) { _ = to.Encode(m) }
	end := workMessage{Type: workDone}
	var err error
	switch args[0] {
	case workProbe:
		end.Ready, end.Sentence = dockerReady(ctx)
	case workLook:
		end.Look, err = lookInFolder(ctx, args[1])
	case workToken:
		end.Look, err = lookForToken(ctx, args[1], args[2])
	case workRun:
		err = setupProject(ctx, args[1], func(step string) { say(workMessage{Type: workStep, Step: step}) })
	}
	if err != nil {
		say(workMessage{Type: workFailed, Sentence: err.Error()})
		return err
	}
	say(end)
	return nil
}

// dockerReady is whether a Docker that runs containers on this computer
// answers this process, and the sentence why not. Work still older than
// the docker group had no sg to come through (an optional package on
// Ubuntu 26.04), and only a new login gives it the group. A cancel ends a
// docker that hangs.
func dockerReady(ctx context.Context) (bool, string) {
	answers := machine.reachable(ctx)
	switch {
	case ctx.Err() != nil:
		return false, "Docker was not waited for"
	case !answers && olderThanGroup(ctx):
		return false, loginAgain
	case !answers:
		return false, "Docker does not answer this account"
	}
	switch here, err := machine.dockerHere(ctx); {
	case err != nil:
		return false, "Docker did not say where it runs containers"
	case !here:
		return false, "Docker here runs containers on another computer, so CYFR cannot be set up on this one with it"
	}
	return true, ""
}

var errSetupCancelled = errors.New("Setup was stopped before CYFR was started")

// setupProject is the one setup action, for every folder: init's sequence
// where dir holds no .env, then up's start. Asked again it mints nothing
// again and repeats what is left. Before anything is written it refuses
// the account's home directory, whose .cyfr is the account's own, a folder
// Docker cannot name a project after, and a Docker that does not answer
// here. Under the setup lock the folder is read again before it is
// written. A cancel stops it up to the start, and a start once begun runs
// to its end.
func setupProject(ctx context.Context, dir string, step func(string)) error {
	dir = filepath.Clean(dir)
	if err := setupFolder(dir); err != nil {
		return err
	}
	ready, why := dockerReady(ctx)
	if ctx.Err() != nil {
		return errSetupCancelled
	}
	if !ready {
		return fmt.Errorf("%s. Nothing was written", why)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("CYFR cannot make the folder %s (%v). Nothing was changed", dir, err)
	}
	if err := os.Chdir(dir); err != nil {
		return fmt.Errorf("CYFR cannot use the folder %s (%v). Nothing was changed", dir, err)
	}
	// The working directory keeps the name it was chosen by, through a
	// link too (os.Getwd): compose names the project after it, and what
	// opens the folder later looks for the project by that name.
	if err := os.Setenv("PWD", dir); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(setupLockFile), 0o700); err != nil {
		return fmt.Errorf("CYFR cannot write in %s (%v). Nothing was changed", dir, err)
	}
	release, busy, err := access.LockFile(setupLockFile)
	switch {
	case err != nil:
		return fmt.Errorf("CYFR cannot lock its setup in %s (%v). Nothing was changed", dir, err)
	case busy:
		return fmt.Errorf("Another setup of the CYFR in %s is still running. Nothing was changed. Wait until it ends, then try again", dir)
	}
	defer release()
	if ctx.Err() != nil {
		return errSetupCancelled
	}
	if !fileExists(".env") {
		// init's printing is for a terminal, and its setup link for no
		// pipe or log. What it warned is said if it wrote no .env.
		var warned bytes.Buffer
		err := initProject(ctx, initOptions{}, step, io.Discard, &warned)
		switch {
		case err != nil && ctx.Err() != nil:
			return errSetupCancelled
		case err != nil:
			return err
		case !fileExists(".env"):
			why := "There is no .env.example to write .env from, so CYFR was not set up"
			if w := strings.TrimSpace(warned.String()); w != "" {
				why += ". " + w
			}
			return errors.New(why)
		}
	}
	if ctx.Err() != nil {
		return errSetupCancelled
	}
	step(setupStepStart)
	return runUp(context.WithoutCancel(ctx), io.Discard)
}

// setupFolder refuses a folder no CYFR is set up in, writing nothing.
func setupFolder(dir string) error {
	own, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("CYFR cannot tell which folder is your account's own (%v). Nothing was changed", err)
	}
	ownInfo, err := os.Stat(own)
	if err != nil {
		return fmt.Errorf("CYFR cannot read your account's own folder %s (%v). Nothing was changed", own, err)
	}
	if info, err := os.Stat(dir); err == nil && os.SameFile(info, ownInfo) {
		return fmt.Errorf("CYFR cannot be set up in %s itself, because your account keeps its own CYFR files there, so choose a folder inside it, such as %s. Nothing was changed",
			dir, filepath.Join(dir, "cyfr"))
	}
	return projectNamed(dir)
}

// workFailure is the work's own failed end, in its sentence.
type workFailure struct{ sentence string }

func (f workFailure) Error() string { return f.sentence }

// workProcess is setup's work begun: its stdin, its stdout, its end, and
// kill, which ends it and everything it started in its process group.
type workProcess struct {
	in   io.WriteCloser
	out  io.Reader
	wait func() error
	kill func()
}

// workEndsWithin bounds how long a reading's work may run on after its
// stdin closed: then it is killed with its process group. A run, setup a
// person started, is never ended so.
const workEndsWithin = 5 * time.Second

// startWork stands in for the launcher (workLauncher) in a test; nil is
// the launcher.
var startWork func(ctx context.Context, args []string) (*workProcess, error)

// workLauncher begins setup's work as a process of its own. It holds what
// it reads of this program's settings from when it was made: a reading in
// flight can outlive whatever opened its folder, and reads nothing of the
// program's after that.
type workLauncher struct {
	system  string
	groups  func(context.Context, string) []string
	sg      string
	keeps   func(string) bool
	desktop func(string) (string, string)
}

func newWorkLauncher() *workLauncher {
	return &workLauncher{system: machine.system(), groups: machine.groups, sg: sgProgram, keeps: workKeeps, desktop: dockerDesktop}
}

// starter is what begins setup's work now: a test's stand-in, or a
// launcher made now.
func starter() func(context.Context, []string) (*workProcess, error) {
	if startWork != nil {
		return startWork
	}
	return newWorkLauncher().start
}

// start begins setup's work as a process of its own, in a process group of
// its own: through sg with the docker group where this one is older than
// it (throughGroup), and with no environment but what keeps keeps, since
// the work runs init and up in a folder and compose would put this
// process's environment over that folder's .env. What it asks of this
// computer first ends with ctx.
func (l *workLauncher) start(ctx context.Context, args []string) (*workProcess, error) {
	self, err := os.Executable()
	if err != nil {
		return nil, fmt.Errorf("cyfr could not find its own program (%w)", err)
	}
	argv := append([]string{self, internalCmd.Name(), setupProjectCmd.Name()}, args...)
	cmd := exec.Command(argv[0], argv[1:]...)
	if l.throughGroup(ctx) {
		cmd = exec.Command(l.sg, dockerGroup, "-c", "exec "+shellQuote(argv))
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	cmd.Env = l.environment(os.Environ())
	workGroup(cmd)
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return &workProcess{in: in, out: out, wait: cmd.Wait, kill: func() { killWorkGroup(cmd) }}, nil
}

// setupWork asks setup's work args and answers its end, reporting each
// step it begins to step (workBegunBy).
func setupWork(ctx context.Context, step func(string), args ...string) (workMessage, error) {
	return workBegunBy(ctx, starter(), step, args...)
}

// workBegunBy is setupWork with the work begun by begin. A caller whose
// ctx has ended starts nothing, and its starting and its work end with
// ctx: what begin asks first takes ctx, and the caller does not wait for
// begin past it. ctx's end closes the work's stdin, the work's one cancel:
// sg is the work's parent on some systems, so a kill of what was started
// alone would leave the work running. A run, setup a person started, is
// waited for to its end, since a start must finish under its lock.
// Anything else is not waited for past ctx, and its work, begun or still
// beginning, is ended with its process group if it has not ended
// workEndsWithin after its stdin closed.
func workBegunBy(ctx context.Context, begin func(context.Context, []string) (*workProcess, error), step func(string), args ...string) (workMessage, error) {
	if err := ctx.Err(); err != nil {
		return workMessage{}, err
	}
	run := args[0] == workRun
	type launch struct {
		work *workProcess
		err  error
	}
	launched := make(chan launch, 1)
	go func() {
		work, err := begin(ctx, args)
		launched <- launch{work, err}
	}()
	var l launch
	select {
	case l = <-launched:
	case <-ctx.Done():
		if !run {
			go func() {
				if l := <-launched; l.err == nil {
					l.work.abandon()
				}
			}()
			return workMessage{}, ctx.Err()
		}
		l = <-launched
	}
	if l.err != nil {
		if ctx.Err() != nil && !run {
			return workMessage{}, ctx.Err()
		}
		return workMessage{}, fmt.Errorf("setup's work could not begin (%w)", l.err)
	}
	work := l.work
	type ending struct {
		m   workMessage
		err error
	}
	ended := make(chan ending, 1)
	go func() {
		var end *workMessage
		lines := bufio.NewScanner(work.out)
		lines.Buffer(nil, maxWorkLine)
		for lines.Scan() {
			var m workMessage
			if json.Unmarshal(lines.Bytes(), &m) != nil {
				continue
			}
			switch m.Type {
			case workStep:
				if step != nil {
					step(m.Step)
				}
			case workDone, workFailed:
				end = &m
			}
		}
		work.in.Close()
		_, _ = io.Copy(io.Discard, work.out)
		err := work.wait()
		switch {
		case end == nil:
			why := "setup's work ended before it finished"
			if err != nil {
				why += fmt.Sprintf(" (%v)", err)
			}
			ended <- ending{err: errors.New(why)}
		case end.Type == workFailed:
			ended <- ending{err: workFailure{end.Sentence}}
		default:
			ended <- ending{m: *end}
		}
	}()
	select {
	case e := <-ended:
		return e.m, e.err
	case <-ctx.Done():
		if !run {
			work.in.Close()
			// Ended at the bound unless its end came first.
			kill := time.AfterFunc(workEndsWithin, work.kill)
			go func() {
				<-ended
				kill.Stop()
			}()
			return workMessage{}, ctx.Err()
		}
		work.in.Close()
		e := <-ended
		return e.m, e.err
	}
}

// abandon ends work nobody waits for: its stdin closed, it is killed with
// its process group if it has not ended within workEndsWithin, and reaped.
func (w *workProcess) abandon() {
	w.in.Close()
	kill := time.AfterFunc(workEndsWithin, w.kill)
	_, _ = io.Copy(io.Discard, w.out)
	_ = w.wait()
	kill.Stop()
}

// throughGroup is whether setup's work needs sg to reach Docker: on
// Linux, an account in the docker group from a process older than that.
// Which Linux it is makes no difference here.
func (l *workLauncher) throughGroup(ctx context.Context) bool {
	if _, err := os.Stat(l.sg); err != nil {
		return false
	}
	return l.olderThanGroup(ctx)
}

// olderThanGroup is whether this process lacks the docker group its
// account is in, on the one system that has that group.
func (l *workLauncher) olderThanGroup(ctx context.Context) bool {
	if l.system != "linux" {
		return false
	}
	account, err := user.Current()
	return err == nil && slices.Contains(l.groups(ctx, account.Username), dockerGroup) && !slices.Contains(l.groups(ctx, ""), dockerGroup)
}

// olderThanGroup is the launcher's, as this program's settings are now.
func olderThanGroup(ctx context.Context) bool { return newWorkLauncher().olderThanGroup(ctx) }

// workKept are the names setup's work keeps of this process's environment:
// which account and system it runs on and that system's way to the
// network. None is a setting of a CYFR.
var workKept = []string{
	"PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LANGUAGE", "TMPDIR", "TMP", "TEMP",
	"XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "DBUS_SESSION_BUS_ADDRESS", "DISPLAY", "WAYLAND_DISPLAY", "GNUPGHOME", "PASSWORD_STORE_DIR",
	"HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR",
	// Windows' own.
	"SYSTEMROOT", "SYSTEMDRIVE", "WINDIR", "COMSPEC", "PATHEXT", "OS", "COMPUTERNAME", "USERNAME", "USERDOMAIN", "USERPROFILE",
	"HOMEDRIVE", "HOMEPATH", "APPDATA", "LOCALAPPDATA", "PROGRAMDATA", "PROGRAMFILES", "PROGRAMFILES(X86)", "PROGRAMW6432",
	"COMMONPROGRAMFILES", "COMMONPROGRAMFILES(X86)", "COMMONPROGRAMW6432", "NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE",
}

// workKeeps is whether setup's work keeps name: one of workKept, a locale
// (LC_*), or which Docker (DOCKER_*, as the engine keeps it). A test adds
// its own controls.
var workKeeps = func(name string) bool {
	upper := strings.ToUpper(name)
	return slices.Contains(workKept, upper) || strings.HasPrefix(upper, "LC_") || strings.HasPrefix(upper, "DOCKER_")
}

// workEnvironment is environ as setup's work gets it now (environment).
func workEnvironment(environ []string) []string { return newWorkLauncher().environment(environ) }

// environment is environ as setup's work gets it: what keeps keeps, and on
// macOS and Windows Docker Desktop's own docker after PATH.
func (l *workLauncher) environment(environ []string) []string {
	system := l.system
	desktop := system == "darwin" || system == "windows"
	kept, path := []string{}, ""
	for _, entry := range environ {
		name, value, _ := strings.Cut(entry, "=")
		if !l.keeps(name) {
			continue
		}
		if desktop && strings.EqualFold(name, "PATH") {
			path = value
			continue
		}
		kept = append(kept, entry)
	}
	if desktop {
		_, bin := l.desktop(system)
		kept = append(kept, "PATH="+path+string(os.PathListSeparator)+bin)
	}
	return kept
}
