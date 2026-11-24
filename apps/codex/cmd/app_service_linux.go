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
	"sync"
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
	dpkgDebProgram   = "/usr/bin/dpkg-deb"
	dpkgQueryProgram = "/usr/bin/dpkg-query"
	// appUpdateEndedArg is cyfr-update@.service's ExecStopPost argument.
	appUpdateEndedArg = "--serve-app-update-ended"
	// screenStopped is there while a request has stopped the box's screen
	// and not started it again.
	screenStopped = "/run/cyfr-update.screen-stopped"
)

// serviceWait bounds the caller's whole wait on one request: the unit's
// own bound (RuntimeMaxSec), which ends the service, and its stop; a
// variable so tests shorten it.
var serviceWait = askWithin + fetchBinaryTimeout + goWithin + appQuitWithin + appReplaceWithin + boundGrace

// The service's answers, after serviceMark.
const (
	answerVerified    = "verified"
	answerRefused     = "refused"
	answerUnreachable = "unreachable"
	answerInstalled   = "installed"
	answerFailed      = "failed"
	// answerUnstarted is an install that succeeded with the box's screen
	// not started again.
	answerUnstarted = "unstarted"
)

// appUpdateService runs the service when args are its unit's ExecStart,
// or its ExecStopPost (appUpdateEndedArg), answering its status and true;
// any other command line is cyfr's own.
func appUpdateService(args []string) (int, bool) {
	if len(args) != 2 || (args[1] != appUpdateServiceArg && args[1] != appUpdateEndedArg) {
		return 0, false
	}
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "This is the CYFR app's update service, which systemd starts as root; run cyfr update instead")
		return 64, true
	}
	if args[1] == appUpdateEndedArg {
		screenBack(rootHost)
		return 0, true
	}
	// A write to a caller that hung up must not end the install.
	signal.Ignore(syscall.SIGPIPE)
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
	// identity is the package name and version a DEB's own control file
	// names.
	identity func(deb string) (name, version string, err error)
	// installed is whether dpkg holds the app's package installed and not
	// being removed.
	installed func() (bool, error)
	// screenRuns is whether the box's screen runs (machine.screenService).
	screenRuns func() (bool, error)
	// run runs one of the service's fixed commands, its output to out.
	run func(out io.Writer, name string, args ...string) error
	// stopped is the file that says this request stopped the box's screen
	// (screenStopped).
	stopped string
}

// rootEnv is the environment of every command root runs.
var rootEnv = []string{"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "DEBIAN_FRONTEND=noninteractive", "LANG=C.UTF-8"}

// rootOutput runs one of root's fixed commands and answers its output.
func rootOutput(name string, args ...string) (string, error) {
	c := exec.Command(name, args...)
	c.Env = rootEnv
	out, err := c.Output()
	return string(out), err
}

var rootHost = serviceHost{
	fetch: func(ctx context.Context, out io.Writer, target string) (*staged, error) {
		return fetchInstaller(ctx, out, target, "linux", machine.arch())
	},
	identity: func(deb string) (string, string, error) {
		said, err := rootOutput(dpkgDebProgram, "--field", deb, "Package", "Version")
		if err != nil {
			return "", "", err
		}
		fields := map[string]string{}
		for _, line := range strings.Split(said, "\n") {
			if k, v, ok := strings.Cut(line, ": "); ok {
				fields[k] = v
			}
		}
		return fields["Package"], fields["Version"], nil
	},
	installed: func() (bool, error) {
		said, err := rootOutput(dpkgQueryProgram, "--show", "--showformat", "${Status}", appPackage)
		if err != nil {
			return false, err
		}
		return said == "install ok installed", nil
	},
	screenRuns: func() (bool, error) {
		_, active, err := machine.screenService()
		return active, err
	},
	run: func(out io.Writer, name string, args ...string) error {
		c := exec.Command(name, args...)
		c.Env = rootEnv
		c.Stdout, c.Stderr = out, out
		return c.Run()
	},
	stopped: screenStopped,
}

// debVersion is release version v as the app's DEB names it: electron-
// builder writes a pre-release's hyphen as a tilde, which dpkg orders
// before the release.
func debVersion(v string) string { return strings.ReplaceAll(v, "-", "~") }

// unheld writes to the caller only what it takes at once (unheldWithin):
// one write it does not take and the caller is taken for gone, nothing
// more is sent, and the request goes on as it would with no caller.
type unheld struct {
	conn net.Conn
	gone bool
}

// unheldWithin is how long one write to the caller may wait.
const unheldWithin = 100 * time.Millisecond

func (u *unheld) Write(p []byte) (int, error) {
	if !u.gone {
		_ = u.conn.SetWriteDeadline(time.Now().Add(unheldWithin))
		if _, err := u.conn.Write(p); err != nil {
			u.gone = true
		}
	}
	return len(p), nil
}

// screenBack starts the box's screen again where a request stopped it and
// did not start it: the unit's ExecStopPost runs it on every way the
// request ends, its bound's kill included.
func screenBack(host serviceHost) {
	if err := os.Remove(host.stopped); err == nil {
		_ = host.run(io.Discard, systemctlProgram, "start", "--no-block", screenName)
	}
}

// serveUpdate answers one request on conn as the package whose cyfr is
// release own.
func serveUpdate(ctx context.Context, conn net.Conn, own string, host serviceHost) {
	var mu sync.Mutex
	caller := &unheld{conn: conn}
	out := writerFunc(func(p []byte) (int, error) {
		mu.Lock()
		defer mu.Unlock()
		return caller.Write(p)
	})
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
	// What is installed is what the bytes are: the app's package at exactly
	// the release asked, whatever the release's files call it.
	switch name, v, err := host.identity(s.file); {
	case err != nil:
		answer(answerRefused, fmt.Sprintf("The CYFR app of release %s could not be read as a package (%v); nothing was changed and CYFR runs as it did", target, err))
		return
	case name != appPackage || v != debVersion(target):
		answer(answerRefused, fmt.Sprintf("The CYFR app of release %s is package %s %s, not %s %s; nothing was changed and CYFR runs as it did", target, name, v, appPackage, debVersion(target)))
		return
	}
	answer(answerVerified, target)
	if said, err := line(goWithin); err != nil || said != "go" {
		return
	}

	// The caller said go: from here the install runs to its end, whatever
	// the caller does. The file has a name of root's own: nothing the
	// caller sent reaches apt.
	switch ok, err := host.installed(); {
	case err != nil || !ok:
		answer(answerFailed, "The CYFR app's package is being removed or is not installed, so CYFR's update service installed nothing")
		return
	}
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
		// Written before the stop: however the request ends from here,
		// the unit's stop step starts the screen again (screenBack).
		if err := os.WriteFile(host.stopped, nil, 0o600); err != nil {
			answer(answerFailed, fmt.Sprintf("CYFR's update service could not note that it stops the screen (%v); nothing was replaced", err))
			return
		}
		defer screenBack(host)
		fmt.Fprintln(out, "Stopping this machine's screen, so its launcher does not start the old CYFR app again while it is replaced...")
		if err := host.run(out, systemctlProgram, "stop", screenName); err != nil {
			answer(answerFailed, fmt.Sprintf("The screen could not be stopped (%v); nothing was replaced", err))
			return
		}
	}
	fmt.Fprintln(out, "Installing the CYFR app's package with apt...")
	installed := host.run(out, aptProgram, "install", "-y", deb)
	unstarted := ""
	if screen {
		_ = os.Remove(host.stopped)
		if err := host.run(out, systemctlProgram, "start", screenName); err != nil {
			unstarted = fmt.Sprintf("the screen could not be started again (%v): start it with 'sudo systemctl start %s'", err, screenName)
		}
	}
	switch {
	case installed != nil && unstarted != "":
		answer(answerFailed, fmt.Sprintf("apt could not install the CYFR app's package (%v), and %s", installed, unstarted))
	case installed != nil:
		answer(answerFailed, fmt.Sprintf("apt could not install the CYFR app's package (%v)", installed))
	case unstarted != "":
		answer(answerUnstarted, unstarted)
	default:
		answer(answerInstalled, target)
	}
}

// writerFunc is a function as an io.Writer.
type writerFunc func(p []byte) (int, error)

func (f writerFunc) Write(p []byte) (int, error) { return f(p) }

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
	// The wait has the service's own bound, and a cancelled update stops
	// waiting: the service then installs nothing, as it never got go.
	_ = conn.SetDeadline(time.Now().Add(serviceWait))
	served := &staged{target: target, service: conn}
	stop := context.AfterFunc(ctx, func() { _ = conn.SetDeadline(time.Now()) })
	_, err = fmt.Fprintf(conn, "%s\n", target)
	what, said := "", ""
	if err == nil {
		what, said, err = relay(conn, out, served)
	}
	if !stop() {
		served.remove()
		return nil, errors.New("cyfr update was interrupted before the CYFR app was closed; nothing was changed and CYFR runs as it did")
	}
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
	case what == answerUnstarted:
		return screenUnstarted(said)
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
