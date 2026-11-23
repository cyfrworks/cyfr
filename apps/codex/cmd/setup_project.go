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
	case !answers && olderThanGroup():
		return false, "Docker does not answer this account until you log out and in again"
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

// workProcess is setup's work begun: its stdin, its stdout and its end.
type workProcess struct {
	in   io.WriteCloser
	out  io.Reader
	wait func() error
}

// startWork begins setup's work. A test stands in for it.
var startWork = startWorkProcess

// startWorkProcess begins setup's work as a process of its own: through sg
// with the docker group where this one is older than it (throughGroup),
// and with no environment but workKeeps', since the work runs init and up
// in a folder and compose would put this process's environment over that
// folder's .env.
func startWorkProcess(args []string) (*workProcess, error) {
	self, err := os.Executable()
	if err != nil {
		return nil, fmt.Errorf("cyfr could not find its own program (%w)", err)
	}
	argv := append([]string{self, internalCmd.Name(), setupProjectCmd.Name()}, args...)
	cmd := exec.Command(argv[0], argv[1:]...)
	if throughGroup() {
		cmd = exec.Command(sgProgram, dockerGroup, "-c", "exec "+shellQuote(argv))
	}
	cmd.Env = workEnvironment(os.Environ())
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
	return &workProcess{in: in, out: out, wait: cmd.Wait}, nil
}

// setupWork asks setup's work args and answers its end, reporting each
// step it begins to step. ctx's end closes the work's stdin and kills
// nothing: sg is the work's parent on some systems, so killing what was
// started would leave the work running, and a start must finish under its
// lock. A run is waited for to its end. Anything else is not waited for
// past ctx.
func setupWork(ctx context.Context, step func(string), args ...string) (workMessage, error) {
	work, err := startWork(args)
	if err != nil {
		return workMessage{}, fmt.Errorf("setup's work could not begin (%w)", err)
	}
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
			ended <- ending{err: fmt.Errorf("setup's work ended before it finished (%v)", err)}
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
		work.in.Close()
		if args[0] != workRun {
			return workMessage{}, ctx.Err()
		}
		e := <-ended
		return e.m, e.err
	}
}

// throughGroup is whether setup's work needs sg to reach Docker: on
// Linux, an account in the docker group from a process older than that.
// Which Linux it is makes no difference here.
func throughGroup() bool {
	if _, err := os.Stat(sgProgram); err != nil {
		return false
	}
	return olderThanGroup()
}

// olderThanGroup is whether this process lacks the docker group its
// account is in, on the one system that has that group.
func olderThanGroup() bool {
	if machine.system() != "linux" {
		return false
	}
	account, err := user.Current()
	return err == nil && staleGroup(account.Username)
}

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

// workEnvironment is environ as setup's work gets it: what workKeeps
// keeps, and on macOS and Windows Docker Desktop's own docker after PATH.
func workEnvironment(environ []string) []string {
	system := machine.system()
	desktop := system == "darwin" || system == "windows"
	kept, path := []string{}, ""
	for _, entry := range environ {
		name, value, _ := strings.Cut(entry, "=")
		if !workKeeps(name) {
			continue
		}
		if desktop && strings.EqualFold(name, "PATH") {
			path = value
			continue
		}
		kept = append(kept, entry)
	}
	if desktop {
		kept = append(kept, "PATH="+withDockerDesktop(path, system))
	}
	return kept
}
