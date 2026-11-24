// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package cmd

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/cyfr/codex/internal/release"
	"github.com/cyfr/codex/internal/version"
)

// The CYFR app's update service: the one thing on Linux that installs a
// release of the app as root with no password. Its two units ship in the
// app's package (desktop/linux/), which enables the socket at install and
// removes both with the package. systemd holds the socket, root's and
// the sudo group's alone, and starts the package's own cyfr as root once
// per request (appUpdateServiceArg), one at a time, in a unit of its own
// bounded by RuntimeMaxSec, killing everything it started at the bound,
// with systemd's environment and none of the caller's.
//
// A request is one line, the release to install. Root takes nothing else
// from the caller: it refuses a release that is not strictly newer than
// its own, the installed package's, fetches the release's installer
// itself and verifies it against the release's signed checksums, as cyfr
// update does (fetchInstaller), refusing one that does not verify, and
// answers verified. A refusal is the update's answer; a release root
// cannot download is answered unreachable, which the caller takes the
// sudo road for. Once the caller has
// closed the app it sends go, and root installs the file it fetched with
// apt, stopping the box's screen for the install where it runs and
// starting it again whatever apt answered. A caller gone before go
// installs nothing; one gone after it changes nothing of the install.
const (
	// appUpdateSocket is cyfr-update.socket's ListenStream.
	appUpdateSocket = "/run/cyfr-update.sock"
	// appUpdateServiceArg is cyfr-update@.service's ExecStart argument,
	// read before the command line (appUpdateService).
	appUpdateServiceArg = "--serve-app-update"
	// serviceMark begins each line of the service's answer that says where
	// the request stands; every other line is the install's progress.
	serviceMark = "\x1e"
	// askWithin bounds the wait for the request's first line and goWithin
	// the wait for go: the caller closes the app between the two
	// (appQuitWithin, the box's screen stopped).
	askWithin = 30 * time.Second
	goWithin  = 2 * time.Minute
	// maxRequest bounds both lines of a request together.
	maxRequest = 256
	// screenName is the box's screen's unit, which the service alone may
	// stop and start.
	screenName = "cyfr-screen"
	// The programs the service runs, by their paths alone.
	systemctlProgram = "/usr/bin/systemctl"
	aptProgram       = "/usr/bin/apt-get"
)

// The service's answers, after serviceMark.
const (
	answerVerified    = "verified"
	answerRefused     = "refused"
	answerUnreachable = "unreachable"
	answerInstalled = "installed"
	answerFailed    = "failed"
)

// appUpdateService runs the service when args are its unit's ExecStart,
// answering its status and true; any other command line is cyfr's own.
func appUpdateService(args []string) (int, bool) {
	if len(args) != 2 || args[1] != appUpdateServiceArg {
		return 0, false
	}
	// A write to a caller that hung up must not end the install.
	signal.Ignore(syscall.SIGPIPE)
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "This is the CYFR app's update service, which systemd starts as root; run cyfr update instead")
		return 64, true
	}
	conn, err := net.FileConn(os.Stdin)
	if err == nil {
		if _, ok := conn.(*net.UnixConn); !ok {
			conn.Close()
			err = errors.New("its input is not the update socket")
		}
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "The CYFR app's update service has no request to answer (%v)\n", err)
		return 64, true
	}
	defer conn.Close()
	serveUpdate(context.Background(), conn, version.Version, rootHost)
	return 0, true
}

// serviceHost is what the service does as root, a variable so tests stand
// in for the machine.
type serviceHost struct {
	// fetch is fetchInstaller for this machine.
	fetch func(ctx context.Context, out io.Writer, target string) (*staged, error)
	// screenRuns is whether the box's screen runs (machine.screenService).
	screenRuns func() (bool, error)
	// run runs one of the service's fixed commands, its output to out.
	run func(out io.Writer, name string, args ...string) error
}

var rootHost = serviceHost{
	fetch: func(ctx context.Context, out io.Writer, target string) (*staged, error) {
		return fetchInstaller(ctx, out, target, "linux", machine.arch())
	},
	screenRuns: func() (bool, error) {
		_, active, err := machine.screenService()
		return active, err
	},
	run: func(out io.Writer, name string, args ...string) error {
		c := exec.Command(name, args...)
		c.Env = []string{"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "DEBIAN_FRONTEND=noninteractive", "LANG=C.UTF-8"}
		c.Stdout, c.Stderr = out, out
		return c.Run()
	},
}

// heedless writes to the caller and ignores its failure: the caller may
// be gone, the install goes on.
type heedless struct{ w io.Writer }

func (h heedless) Write(p []byte) (int, error) {
	_, _ = h.w.Write(p)
	return len(p), nil
}

// serveUpdate answers one request on conn as the package whose cyfr is
// release own.
func serveUpdate(ctx context.Context, conn net.Conn, own string, host serviceHost) {
	out := heedless{conn}
	answer := func(what, sentence string) {
		fmt.Fprintf(out, "%s%s %s\n", serviceMark, what, sentence)
	}
	in := bufio.NewReader(io.LimitReader(conn, maxRequest))
	line := func(within time.Duration) (string, error) {
		_ = conn.SetReadDeadline(time.Now().Add(within))
		s, err := in.ReadString('\n')
		return strings.TrimSuffix(s, "\n"), err
	}
	target, err := line(askWithin)
	switch {
	case err != nil:
		return
	case !release.IsVersion(target):
		answer(answerRefused, fmt.Sprintf("CYFR's update service refused %q, which is not a release version; nothing was changed", target))
		return
	case !release.IsNewer(target, own):
		answer(answerRefused, fmt.Sprintf("CYFR's update service installs only a release newer than the installed CYFR app's %s, and %s is not; nothing was changed", own, target))
		return
	}
	s, err := host.fetch(ctx, out, target)
	switch {
	case errors.Is(err, release.ErrUnverified):
		answer(answerRefused, err.Error())
		return
	case err != nil:
		answer(answerUnreachable, fmt.Sprintf("could not download release %s itself (%v)", target, err))
		return
	}
	defer s.remove()
	answer(answerVerified, target)
	if said, err := line(goWithin); err != nil || said != "go" {
		return
	}

	// The caller said go: from here the install runs to its end, whatever
	// the caller does. The file has a name of root's own: nothing the
	// caller sent reaches apt.
	deb := filepath.Join(s.dir, appPackage+".deb")
	if err := os.Rename(s.file, deb); err != nil {
		answer(answerFailed, fmt.Sprintf("CYFR's update service could not keep the installer it verified (%v); nothing was replaced", err))
		return
	}
	screen, err := host.screenRuns()
	if err != nil {
		answer(answerFailed, fmt.Sprintf("CYFR's update service could not tell whether this machine's screen runs (%v); nothing was replaced", err))
		return
	}
	if screen {
		fmt.Fprintln(out, "Stopping this machine's screen, so its launcher does not start the old CYFR app again while it is replaced...")
		if err := host.run(out, systemctlProgram, "stop", screenName); err != nil {
			// A stop that failed may have stopped it: it is started again.
			_ = host.run(out, systemctlProgram, "start", screenName)
			answer(answerFailed, fmt.Sprintf("The screen could not be stopped (%v); nothing was replaced", err))
			return
		}
	}
	fmt.Fprintln(out, "Installing the CYFR app's package with apt...")
	installed := host.run(out, aptProgram, "install", "-y", deb)
	if screen {
		if err := host.run(out, systemctlProgram, "start", screenName); err != nil {
			fmt.Fprintf(out, "The screen could not be started again (%v): start it with 'sudo systemctl start %s'.\n", err, screenName)
		}
	}
	if installed != nil {
		answer(answerFailed, fmt.Sprintf("apt could not install the CYFR app's package (%v)", installed))
		return
	}
	answer(answerInstalled, target)
}

// dialAppUpdate connects to the update service; a variable so tests stand
// in for it.
var dialAppUpdate = func() (net.Conn, error) { return net.Dial("unix", appUpdateSocket) }

// serviceRoad updates the cyfr-desktop package through the update service,
// and takes the DEB's sudo road (debRoad), saying why, before anything
// closes, only where the service cannot be used: absent, refusing this
// account, unable to download the release, or ending without an answer,
// and for a release that is not newer than the installed app, which the
// service never installs. Its refusal of the release is the update's.
type serviceRoad struct {
	// sudo is whether this update took the sudo road.
	sudo bool
}

// tookSudo says why the service did not take the update and takes the
// sudo road.
func (r *serviceRoad) tookSudo(ctx context.Context, out io.Writer, before, target, why string) (*staged, error) {
	fmt.Fprintf(out, "CYFR's update service %s, so the update goes through sudo instead.\n", why)
	r.sudo = true
	return debRoad{}.fetch(ctx, out, before, target)
}

func (r *serviceRoad) fetch(ctx context.Context, out io.Writer, before, target string) (*staged, error) {
	if !release.IsNewer(target, before) {
		return r.tookSudo(ctx, out, before, target, fmt.Sprintf("installs only a release newer than the installed app's, and %s is not", target))
	}
	conn, err := dialAppUpdate()
	switch {
	case errors.Is(err, syscall.EACCES):
		return r.tookSudo(ctx, out, before, target, "serves the sudo group's accounts alone")
	case err != nil:
		return r.tookSudo(ctx, out, before, target, fmt.Sprintf("is not on this machine (%v)", err))
	}
	fmt.Fprintln(out, "Asking CYFR's update service to install the CYFR app, with no password...")
	served := &staged{target: target, service: conn}
	if _, err := fmt.Fprintf(conn, "%s\n", target); err != nil {
		served.remove()
		return r.tookSudo(ctx, out, before, target, fmt.Sprintf("could not be asked (%v)", err))
	}
	what, said, err := relay(conn, out, served)
	switch {
	case err == nil && what == answerVerified:
		return served, nil
	case err == nil && what == answerUnreachable:
		served.remove()
		return r.tookSudo(ctx, out, before, target, said)
	case err == nil:
		served.remove()
		return nil, errors.New(said)
	default:
		served.remove()
		return r.tookSudo(ctx, out, before, target, fmt.Sprintf("ended without an answer (%v)", err))
	}
}

// relay copies the service's progress to out up to its next answer, and
// answers it.
func relay(conn net.Conn, out io.Writer, s *staged) (what, said string, err error) {
	if s.answers == nil {
		s.answers = bufio.NewReader(conn)
	}
	for {
		line, err := s.answers.ReadString('\n')
		if text, ok := strings.CutPrefix(line, serviceMark); ok {
			what, said, _ = strings.Cut(strings.TrimSuffix(text, "\n"), " ")
			return what, said, nil
		}
		if line != "" {
			io.WriteString(out, line)
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				err = errors.New("it closed the connection")
			}
			return "", "", err
		}
	}
}

func (r *serviceRoad) elevate(out io.Writer, again string) (func(), error) {
	if r.sudo {
		return debRoad{}.elevate(out, again)
	}
	return func() {}, nil
}

func (r *serviceRoad) replace(out io.Writer, s *staged, older bool) error {
	if r.sudo {
		return debRoad{}.replace(out, s, older)
	}
	if _, err := io.WriteString(s.service, "go\n"); err != nil {
		return fmt.Errorf("CYFR's update service could not be told to install (%v); nothing was replaced", err)
	}
	what, said, err := relay(s.service, out, s)
	switch {
	case err != nil:
		return fmt.Errorf("CYFR's update service ended without saying whether it installed the CYFR app (%v)", err)
	case what != answerInstalled:
		return errors.New(said)
	}
	return nil
}

func (r *serviceRoad) finish(out io.Writer, s *staged, confirmed bool) error {
	return debRoad{}.finish(out, s, confirmed)
}

// closesTheBox is the sudo road's commands where it took the sudo road;
// the service stops and starts the box's screen itself.
func (r *serviceRoad) closesTheBox() ([]string, []string) {
	if r.sudo {
		return debRoad{}.closesTheBox()
	}
	return []string{}, []string{}
}
