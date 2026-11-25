// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package cmd

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/release"
)

// serviceStandIn is the update service as root answers it, on one end of a
// pipe, its machine stood in for: what it fetched and what it ran.
type serviceStandIn struct {
	t        *testing.T
	own      string
	screen   bool
	fetchErr error
	aptErr   error
	// installed is called once apt succeeds: the installed app is then
	// the release it installed.
	installed func(target string)
	// name and version are what the fetched DEB's control file names,
	// the app's package at the target where empty.
	name, version string
	// removing is the app's package being removed.
	removing bool
	// startErr is the screen's start refused.
	startErr error

	stopped string

	mu      sync.Mutex
	fetched []string
	dirs    []string
	ran     [][]string
	done    chan struct{}
}

func newServiceStandIn(t *testing.T, own string) *serviceStandIn {
	return &serviceStandIn{t: t, own: own, done: make(chan struct{}), stopped: filepath.Join(t.TempDir(), "screen-stopped")}
}

// buildDeb writes a DEB of package name at version to file, as dpkg-deb
// builds one, for the service's own reading of what a DEB is; it may run
// off the test's goroutine, so it answers its failure.
func buildDeb(t *testing.T, file, name, version string) error {
	root := t.TempDir()
	// dpkg-deb refuses a control folder narrower than 0755, whatever the
	// umask made of it.
	control := filepath.Join(root, "DEBIAN")
	if err := os.MkdirAll(control, 0o755); err != nil {
		return err
	}
	if err := os.Chmod(control, 0o755); err != nil {
		return err
	}
	fields := fmt.Sprintf("Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: CYFR\nDescription: a stand-in\n", name, version)
	if err := os.WriteFile(filepath.Join(control, "control"), []byte(fields), 0o644); err != nil {
		return err
	}
	c := exec.Command(dpkgDebProgram, "--root-owner-group", "--build", root, file)
	c.Env = rootEnv
	if out, err := c.CombinedOutput(); err != nil {
		return fmt.Errorf("dpkg-deb could not build a stand-in package (%v): %s", err, out)
	}
	return nil
}

func (f *serviceStandIn) host() serviceHost {
	return serviceHost{
		fetch: func(_ context.Context, out io.Writer, target string) (*staged, error) {
			f.mu.Lock()
			defer f.mu.Unlock()
			f.fetched = append(f.fetched, target)
			if f.fetchErr != nil {
				return nil, f.fetchErr
			}
			fmt.Fprintf(out, "Downloading the CYFR app, release %s...\n", target)
			dir := f.t.TempDir()
			file := filepath.Join(dir, "cyfr-desktop_"+target+"_linux_amd64.deb")
			name, version := appPackage, debVersion(target)
			if f.name != "" {
				name, version = f.name, f.version
			}
			if err := buildDeb(f.t, file, name, version); err != nil {
				f.t.Error(err)
				return nil, err
			}
			f.dirs = append(f.dirs, dir)
			return &staged{target: target, dir: dir, file: file}, nil
		},
		identity:   rootHost.identity,
		installed:  func() (bool, error) { return !f.removing, nil },
		screenRuns: func() (bool, error) { return f.screen, nil },
		stopped:    f.stopped,
		run: func(out io.Writer, name string, args ...string) error {
			f.mu.Lock()
			f.ran = append(f.ran, append([]string{name}, args...))
			f.mu.Unlock()
			if name == systemctlProgram && args[0] == "start" {
				return f.startErr
			}
			if name == aptProgram {
				if _, err := os.Stat(f.stopped); f.screen && err != nil {
					f.t.Error("apt ran with the screen stopped and nothing noting it")
				}
				if f.aptErr != nil {
					return f.aptErr
				}
				if f.installed != nil {
					f.installed(f.fetched[len(f.fetched)-1])
				}
			}
			return nil
		},
	}
}

// dial is dialAppUpdate to this service: each connection is one request,
// answered as systemd starts the service for it.
func (f *serviceStandIn) dial() (net.Conn, error) {
	client, server := net.Pipe()
	go func() {
		defer close(f.done)
		defer server.Close()
		serveUpdate(context.Background(), server, f.own, f.host())
	}()
	return client, nil
}

// served waits for the request to end and answers what root ran.
func (f *serviceStandIn) served() [][]string {
	f.t.Helper()
	select {
	case <-f.done:
	case <-time.After(10 * time.Second):
		f.t.Fatal("the service did not end within 10 s")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.ran
}

// ask sends request and answers what the service said to it, up to its
// close; a request of one line hangs up once it is verified, as a caller
// gone before go does.
func (f *serviceStandIn) ask(request string) string {
	f.t.Helper()
	conn, _ := f.dial()
	go func() { _, _ = io.WriteString(conn, request) }()
	var said strings.Builder
	r := bufio.NewReader(conn)
	for {
		line, err := r.ReadString('\n')
		said.WriteString(line)
		if err != nil || (line == serviceMark+answerVerified+" "+strings.TrimSuffix(request, "\n")+"\n") {
			break
		}
	}
	conn.Close()
	f.served()
	return said.String()
}

// The service installs only a release strictly newer than its own: the
// same one, an older one and anything that is not a release version are
// refused before it fetches or runs anything.
func TestTheUpdateServiceInstallsOnlyANewerRelease(t *testing.T) {
	for _, c := range []struct{ request, says string }{
		{"1.0.0\n", "installs only a release newer than the installed CYFR app's 1.0.0, and 1.0.0 is not"},
		{"0.9.9\n", "installs only a release newer than the installed CYFR app's 1.0.0, and 0.9.9 is not"},
		{"1.0.0-alpha.9\n", "and 1.0.0-alpha.9 is not"},
		{"../../etc/passwd\n", `refused "../../etc/passwd", which is not a release version`},
		{"1.1.0 --allow-downgrades\n", `refused "1.1.0 --allow-downgrades", which is not a release version`},
		{"\n", `refused "", which is not a release version`},
	} {
		f := newServiceStandIn(t, "1.0.0")
		said := f.ask(c.request)
		if !strings.Contains(said, serviceMark+answerRefused+" ") || !strings.Contains(said, c.says) {
			t.Errorf("%q was answered %q, want a refusal saying %q", c.request, said, c.says)
		}
		if len(f.fetched) != 0 || len(f.ran) != 0 {
			t.Errorf("%q fetched %q and ran %q", c.request, f.fetched, f.ran)
		}
	}
	f := newServiceStandIn(t, "1.0.0")
	if said := f.ask("1.1.0\n"); !strings.Contains(said, serviceMark+answerVerified+" 1.1.0\n") {
		t.Errorf("a newer release was answered %q", said)
	}
}

// What the caller sends reaches no command: once told go, root runs apt
// with fixed arguments on a file of its own fetch, named by root, and
// stops and starts the box's screen around it where it runs, starting it
// again when apt fails.
func TestTheUpdateServiceRunsOnlyItsFixedCommands(t *testing.T) {
	for _, c := range []struct {
		name   string
		screen bool
		aptErr error
		want   func(deb string) [][]string
		answer string
	}{
		{"on a desktop", false, nil, func(deb string) [][]string {
			return [][]string{{aptProgram, "install", "-y", deb}}
		}, answerInstalled + " 1.1.0"},
		{"on the box", true, nil, func(deb string) [][]string {
			return [][]string{{systemctlProgram, "stop", "cyfr-screen"}, {aptProgram, "install", "-y", deb}, {systemctlProgram, "start", "cyfr-screen"}}
		}, answerInstalled + " 1.1.0"},
		{"on the box, apt failing", true, errors.New("exit status 100"), func(deb string) [][]string {
			return [][]string{{systemctlProgram, "stop", "cyfr-screen"}, {aptProgram, "install", "-y", deb}, {systemctlProgram, "start", "cyfr-screen"}}
		}, answerFailed + " apt could not install the CYFR app's package (exit status 100)"},
	} {
		f := newServiceStandIn(t, "1.0.0")
		f.screen, f.aptErr = c.screen, c.aptErr
		said := f.ask("1.1.0\ngo\n")
		ran := f.served()
		want := c.want(filepath.Join(f.dirs[0], "cyfr-desktop.deb"))
		if !slices.EqualFunc(ran, want, slices.Equal[[]string]) {
			t.Errorf("%s: root ran %q, want %q", c.name, ran, want)
		}
		if !strings.HasSuffix(said, serviceMark+c.answer+"\n") {
			t.Errorf("%s: the service answered %q, want it to end %q", c.name, said, c.answer)
		}
		if _, err := os.Stat(f.dirs[0]); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("%s: the folder the service fetched into is left (%v)", c.name, err)
		}
	}
}

// A caller gone before go, or one that says anything else, installs
// nothing, and what root fetched is removed.
func TestTheUpdateServiceInstallsNothingWithoutGo(t *testing.T) {
	for _, request := range []string{"1.1.0\n", "1.1.0\nyes\n", "1.1.0\ngo now\n"} {
		f := newServiceStandIn(t, "1.0.0")
		f.ask(request)
		if len(f.ran) != 0 {
			t.Errorf("%q ran %q", request, f.ran)
		}
		if _, err := os.Stat(f.dirs[0]); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("%q left the folder the service fetched into (%v)", request, err)
		}
	}
}

// A caller that leaves once it said go, as the box's own screen does when
// the service stops it, changes nothing of the install: the screen is
// started again.
func TestTheUpdateServiceFinishesWhenTheCallerLeaves(t *testing.T) {
	f := newServiceStandIn(t, "1.0.0")
	f.screen = true
	conn, _ := f.dial()
	if _, err := io.WriteString(conn, "1.1.0\n"); err != nil {
		t.Fatal(err)
	}
	r := bufio.NewReader(conn)
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		if line == serviceMark+answerVerified+" 1.1.0\n" {
			break
		}
	}
	if _, err := io.WriteString(conn, "go\n"); err != nil {
		t.Fatal(err)
	}
	conn.Close()
	if ran := f.served(); len(ran) != 3 || ran[2][1] != "start" {
		t.Errorf("root ran %q once its caller left, want the screen stopped, the install and the screen started", ran)
	}
}

// A release that does not verify is refused with fetchInstaller's own
// sentence, and one root cannot download is answered unreachable, which
// the caller takes the sudo road for; nothing runs either way.
func TestTheUpdateServiceRefusesWhatItCannotFetch(t *testing.T) {
	for _, c := range []struct {
		err  error
		want string
	}{
		{fmt.Errorf("The CYFR app of release 1.1.0 did not verify (%w); nothing was changed and CYFR runs as it did", release.ErrUnverified),
			serviceMark + answerRefused + " The CYFR app of release 1.1.0 did not verify ("},
		{errors.New("cyfr update could not download the CYFR app of release 1.1.0 (dial tcp: lookup github.com: no such host)"),
			serviceMark + answerUnreachable + " could not download release 1.1.0 itself (cyfr update could not download"},
	} {
		f := newServiceStandIn(t, "1.0.0")
		f.fetchErr = c.err
		said := f.ask("1.1.0\ngo\n")
		if !strings.Contains(said, c.want) || len(f.ran) != 0 {
			t.Errorf("%v was answered %q and ran %q, want %q", c.err, said, f.ran, c.want)
		}
	}
}

// The request is two short lines: a longer one, a release version however
// long, is read no further than its bound and starts nothing.
func TestTheUpdateServiceReadsABoundedRequest(t *testing.T) {
	f := newServiceStandIn(t, "1.0.0")
	f.ask("1.1.0-" + strings.Repeat("a", maxRequest) + "\n")
	if len(f.fetched) != 0 || len(f.ran) != 0 {
		t.Errorf("an unbounded line fetched %q and ran %q", f.fetched, f.ran)
	}
}

// The commands root runs see the service's own fixed environment, none of
// the process's.
func TestTheUpdateServiceRunsWithItsOwnEnvironment(t *testing.T) {
	t.Setenv("CYFR_CALLER_SAYS", "--allow-downgrades")
	var out bytes.Buffer
	if err := rootHost.run(&out, "/usr/bin/env"); err != nil {
		t.Fatal(err)
	}
	want := "PATH=/usr/sbin:/usr/bin:/sbin:/bin\nDEBIAN_FRONTEND=noninteractive\nLANG=C.UTF-8\n"
	if out.String() != want {
		t.Errorf("root's commands ran with %q, want %q", out.String(), want)
	}
}

// The service is reached only as its units say: their socket and
// argument are the code's, only root and the sudo group may connect, one
// request at a time, and the unit's bound holds every bound of a request.
func TestTheUpdateServiceUnitsAreTheCodes(t *testing.T) {
	read := func(name string) map[string]string {
		data, err := os.ReadFile(filepath.Join("..", "desktop", "linux", name))
		if err != nil {
			t.Fatal(err)
		}
		keys, section := map[string]string{}, ""
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "[") {
				section = strings.Trim(line, "[]")
			} else if k, v, ok := strings.Cut(line, "="); ok && !strings.HasPrefix(line, "#") {
				keys[section+"."+k] = v
			}
		}
		return keys
	}
	socket := read("cyfr-update.socket")
	for k, v := range map[string]string{"Socket.ListenStream": appUpdateSocket, "Socket.SocketMode": "0660", "Socket.SocketGroup": "sudo", "Socket.Accept": "yes", "Socket.MaxConnections": "1", "Socket.RemoveOnStop": "yes"} {
		if socket[k] != v {
			t.Errorf("cyfr-update.socket has %s=%q, want %q", k, socket[k], v)
		}
	}
	service := read("cyfr-update@.service")
	carried, _ := installedAppCyfr()
	for k, v := range map[string]string{"Service.ExecStart": carried + " " + appUpdateServiceArg, "Service.StandardInput": "socket", "Service.StandardOutput": "journal", "Service.KillSignal": "SIGKILL", "Service.ProtectHome": "yes", "Service.PrivateTmp": "yes", "Unit.CollectMode": "inactive-or-failed",
		"Service.ExecStopPost": "-" + carried + " " + appUpdateEndedArg} {
		if service[k] != v {
			t.Errorf("cyfr-update@.service has %s=%q, want %q", k, service[k], v)
		}
	}
	bound, err := strconv.Atoi(service["Service.RuntimeMaxSec"])
	need := askWithin + fetchBinaryTimeout + goWithin + appQuitWithin + appReplaceWithin
	if err != nil || time.Duration(bound)*time.Second < need {
		t.Errorf("cyfr-update@.service's RuntimeMaxSec is %q, want at least %v", service["Service.RuntimeMaxSec"], need)
	}
}

// The road takes the sudo road only where the service cannot be used,
// saying why before anything closes, and asks for a password there as it
// always has: no service, an account outside the sudo group, a release
// root cannot download, and an older release, which the service is never
// asked for.
func TestTheServiceRoadTakesTheSudoRoadSayingWhy(t *testing.T) {
	unreachable := newServiceStandIn(t, "1.0.0")
	unreachable.fetchErr = errors.New("cyfr update could not download the CYFR app of release 1.1.0 (proxyconnect tcp: no route)")
	for _, c := range []struct {
		name   string
		dial   func() (net.Conn, error)
		target string
		says   string
	}{
		{"no service", func() (net.Conn, error) {
			return nil, &net.OpError{Op: "dial", Net: "unix", Err: os.NewSyscallError("connect", syscall.ENOENT)}
		}, "1.1.0", "CYFR's update service is not on this machine (dial unix: connect: no such file or directory), so the update goes through sudo instead.\n"},
		{"an account outside the sudo group", func() (net.Conn, error) {
			return nil, &net.OpError{Op: "dial", Net: "unix", Err: os.NewSyscallError("connect", syscall.EACCES)}
		}, "1.1.0", "CYFR's update service serves the sudo group's accounts alone, so the update goes through sudo instead.\n"},
		{"a release root cannot download", unreachable.dial, "1.1.0",
			"CYFR's update service could not download release 1.1.0 itself (cyfr update could not download the CYFR app of release 1.1.0 (proxyconnect tcp: no route)), so the update goes through sudo instead.\n"},
		{"an older release", func() (net.Conn, error) {
			t.Error("the service was asked for an older release")
			return nil, errors.New("asked")
		}, "0.9.0", "CYFR's update service installs only a release newer than the installed app's, and 0.9.0 is not, so the update goes through sudo instead.\n"},
	} {
		m := standInMachine(t)
		saved, savedSum := dialAppUpdate, appPackageSum
		dialAppUpdate = c.dial
		appPackageSum = func(context.Context, string, string, string) (string, error) {
			return "", errors.New("the release is not read in this test")
		}
		var out bytes.Buffer
		r := &serviceRoad{}
		_, err := r.fetch(context.Background(), &out, "1.0.0", c.target)
		dialAppUpdate, appPackageSum = saved, savedSum
		if !strings.Contains(out.String(), c.says) || !r.sudo || err == nil {
			t.Errorf("%s: said %q (%v), took the sudo road %v", c.name, out.String(), err, r.sudo)
		}
		if _, err := r.elevate(&out, "cyfr update", true); err != nil || m.authenticated != 1 {
			t.Errorf("%s: the sudo road's elevation answered %v, asked %d times", c.name, err, m.authenticated)
		}
	}
}

// The service's refusal of the release is the update's answer: said once,
// with no sudo asked and the release not downloaded again by another road.
func TestAServiceRefusalIsTheUpdatesAnswer(t *testing.T) {
	for _, c := range []struct {
		name     string
		own      string
		fetchErr error
		says     string
	}{
		{"a release that does not verify", "1.0.0",
			fmt.Errorf("The CYFR app of release 1.1.0 did not verify (%w); nothing was changed and CYFR runs as it did", release.ErrUnverified),
			"The CYFR app of release 1.1.0 did not verify (release not verified); nothing was changed and CYFR runs as it did"},
		{"a release the installed app is already past", "1.2.0", nil,
			"CYFR's update service installs only a release newer than the installed CYFR app's 1.2.0, and 1.1.0 is not; nothing was changed"},
	} {
		m := standInMachine(t)
		f := newServiceStandIn(t, c.own)
		f.fetchErr = c.fetchErr
		fetched := 0
		saved, savedSum := dialAppUpdate, appPackageSum
		dialAppUpdate = f.dial
		appPackageSum = func(context.Context, string, string, string) (string, error) {
			fetched++
			return "", errors.New("the release is not read in this test")
		}
		var out bytes.Buffer
		r := &serviceRoad{}
		_, err := r.fetch(context.Background(), &out, "1.0.0", "1.1.0")
		dialAppUpdate, appPackageSum = saved, savedSum
		f.served()
		if err == nil || err.Error() != c.says {
			t.Errorf("%s: answered %v, want %q", c.name, err, c.says)
		}
		if r.sudo || fetched != 0 || m.authenticated != 0 || strings.Contains(out.String(), "sudo") {
			t.Errorf("%s: took the sudo road %v, downloaded again %d times, asked a password %d times: %q", c.name, r.sudo, fetched, m.authenticated, out.String())
		}
	}
}

// An update through the service asks no password and runs nothing as root
// through sudo: on a desktop the app is closed and opened again around
// the install, and on the box the service stops and starts its screen,
// which the update leaves alone.
func TestAnUpdateThroughTheServiceAsksNoPassword(t *testing.T) {
	for _, box := range []bool{false, true} {
		m := standInMachine(t)
		m.app = "1.0.0"
		f := newServiceStandIn(t, "1.0.0")
		f.screen = box
		f.installed = func(target string) { m.app = target }
		var steps []string
		saved, savedQuit, savedReopen, savedScreen, savedSum := dialAppUpdate, quitApp, reopenApp, machine.screenService, appPackageSum
		dialAppUpdate = f.dial
		appPackageSum = func(context.Context, string, string, string) (string, error) {
			return "", errors.New("the sudo road is not taken in this test")
		}
		quitApp = func() (bool, error) { steps = append(steps, "quit"); return true, nil }
		reopenApp = func(bool) error { steps = append(steps, "reopen"); return nil }
		machine.screenService = func() (bool, bool, error) { return box, box, nil }
		var out bytes.Buffer
		err := updateApp(context.Background(), &out, &serviceRoad{}, "1.0.0", "1.1.0", "cyfr update")
		dialAppUpdate, quitApp, reopenApp, machine.screenService, appPackageSum = saved, savedQuit, savedReopen, savedScreen, savedSum
		f.served()
		wantSteps := []string{"quit", "reopen"}
		if box {
			wantSteps = nil
		}
		if err != nil || !strings.HasSuffix(out.String(), "The CYFR app is release 1.1.0.\n") {
			t.Errorf("box %v: the update answered %v: %s", box, err, out.String())
		}
		if m.authenticated != 0 || len(m.applied) != 0 || !slices.Equal(steps, wantSteps) {
			t.Errorf("box %v: asked a password %d times, ran %q through sudo, and took %q, want %q", box, m.authenticated, m.applied, steps, wantSteps)
		}
		if len(f.ran) != map[bool]int{false: 1, true: 3}[box] {
			t.Errorf("box %v: the service ran %q", box, f.ran)
		}
	}
}

// A service that ends without saying it installed is a failed
// replacement, which the transaction reads the app's release after.
func TestTheServiceRoadSaysAnUnansweredInstall(t *testing.T) {
	client, server := net.Pipe()
	go func() {
		r := bufio.NewReader(server)
		_, _ = r.ReadString('\n')
		_, _ = io.WriteString(server, serviceMark+answerVerified+" 1.1.0\n")
		_, _ = r.ReadString('\n')
		_, _ = io.WriteString(server, "Installing the CYFR app's package with apt...\n")
		server.Close()
	}()
	saved := dialAppUpdate
	t.Cleanup(func() { dialAppUpdate = saved })
	dialAppUpdate = func() (net.Conn, error) { return client, nil }
	r := &serviceRoad{}
	var out bytes.Buffer
	s, err := r.fetch(context.Background(), &out, "1.0.0", "1.1.0")
	if err != nil {
		t.Fatal(err)
	}
	defer s.remove()
	err = r.replace(&out, s, false)
	if err == nil || err.Error() != "CYFR's update service ended without saying whether it installed the CYFR app (it closed the connection)" ||
		!strings.Contains(out.String(), "Installing the CYFR app's package with apt...\n") {
		t.Errorf("an unanswered install answered %v: %q", err, out.String())
	}
}

// Root installs what the bytes are: a release's DEB that is another
// package, or the app's package at another release (release A's package
// under B's name), is refused before verified and never reaches apt.
func TestTheUpdateServiceInstallsWhatTheBytesAre(t *testing.T) {
	for _, c := range []struct{ name, version, says string }{
		{"cyfr-desktop", "1.0.5", "The CYFR app of release 1.1.0 is package cyfr-desktop 1.0.5, not cyfr-desktop 1.1.0; nothing was changed and CYFR runs as it did"},
		{"cyfr-desktop", "1.1.0~rc.1", "is package cyfr-desktop 1.1.0~rc.1, not cyfr-desktop 1.1.0;"},
		{"another-package", "1.1.0", "is package another-package 1.1.0, not cyfr-desktop 1.1.0;"},
	} {
		f := newServiceStandIn(t, "1.0.0")
		f.name, f.version = c.name, c.version
		said := f.ask("1.1.0\ngo\n")
		if !strings.Contains(said, serviceMark+answerRefused+" ") || !strings.Contains(said, c.says) || strings.Contains(said, answerVerified) || len(f.ran) != 0 {
			t.Errorf("%s %s was answered %q and ran %q", c.name, c.version, said, f.ran)
		}
	}
	f := newServiceStandIn(t, "1.0.0-alpha.1")
	if said := f.ask("1.0.0-alpha.2\n"); !strings.Contains(said, serviceMark+answerVerified+" 1.0.0-alpha.2\n") {
		t.Errorf("a pre-release's own package was answered %q", said)
	}
}

// A request whose go comes once the app's package is being removed
// installs nothing and stops no screen.
func TestTheUpdateServiceRefusesGoOnceThePackageIsBeingRemoved(t *testing.T) {
	f := newServiceStandIn(t, "1.0.0")
	f.screen, f.removing = true, true
	said := f.ask("1.1.0\ngo\n")
	if !strings.HasSuffix(said, serviceMark+answerFailed+" The CYFR app's package is being removed or is not installed, so CYFR's update service installed nothing\n") || len(f.ran) != 0 {
		t.Errorf("a go during the package's removal was answered %q and ran %q", said, f.ran)
	}
}

// After go nothing waits on the caller: one that holds the connection and
// reads nothing more neither stalls the install nor keeps the box's screen
// down, and the request ends while the caller still holds on.
func TestTheUpdateServiceNeverWaitsOnItsCaller(t *testing.T) {
	f := newServiceStandIn(t, "1.0.0")
	f.screen = true
	host := f.host()
	run := host.run
	host.run = func(out io.Writer, name string, args ...string) error {
		if name == aptProgram {
			for range 50 {
				io.WriteString(out, "apt's progress, which nobody reads\n")
			}
		}
		return run(out, name, args...)
	}
	client, server := net.Pipe()
	defer client.Close()
	ended := make(chan struct{})
	go func() {
		defer close(ended)
		serveUpdate(context.Background(), server, "1.0.0", host)
	}()
	client.SetDeadline(time.Now().Add(5 * time.Second))
	io.WriteString(client, "1.1.0\n")
	r := bufio.NewReader(client)
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		if line == serviceMark+answerVerified+" 1.1.0\n" {
			break
		}
	}
	io.WriteString(client, "go\n")
	select {
	case <-ended:
	case <-time.After(3 * time.Second):
		t.Fatal("the request waited on a caller that reads nothing")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.ran) != 3 || f.ran[2][1] != "start" {
		t.Errorf("root ran %q, want the screen stopped, the install and the screen started", f.ran)
	}
}

// However a request ends once it stopped the box's screen, the screen
// starts again: the unit's stop step (screenBack) starts it where the
// request left it stopped, as when the bound killed the request, and
// leaves alone a screen the request started itself or never stopped.
func TestTheBoxsScreenStartsAgainHoweverTheRequestEnds(t *testing.T) {
	f := newServiceStandIn(t, "1.0.0")
	if err := os.WriteFile(f.stopped, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	screenBack(f.host())
	if want := [][]string{{systemctlProgram, "start", "--no-block", "cyfr-screen"}}; !slices.EqualFunc(f.ran, want, slices.Equal[[]string]) {
		t.Errorf("the stop step after a request killed with the screen stopped ran %q, want %q", f.ran, want)
	}
	if _, err := os.Stat(f.stopped); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("the note of the stopped screen is left (%v)", err)
	}
	f.ran = nil
	screenBack(f.host())
	if len(f.ran) != 0 {
		t.Errorf("the stop step with no screen stopped ran %q", f.ran)
	}
	g := newServiceStandIn(t, "1.0.0")
	g.screen = true
	g.ask("1.1.0\ngo\n")
	if _, err := os.Stat(g.stopped); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("a request that started the screen again left the note for the stop step (%v)", err)
	}
}

// A screen the service cannot start again after an install that succeeded
// fails the update before the stack, with part C's sentence: the app is
// at the new release, how to start the screen, and to run cyfr update
// again.
func TestAScreenThatDoesNotStartAgainStopsTheUpdate(t *testing.T) {
	m := standInMachine(t)
	m.app = "1.0.0"
	f := newServiceStandIn(t, "1.0.0")
	f.screen, f.startErr = true, errors.New("exit status 1")
	f.installed = func(target string) { m.app = target }
	saved, savedScreen := dialAppUpdate, machine.screenService
	t.Cleanup(func() { dialAppUpdate, machine.screenService = saved, savedScreen })
	dialAppUpdate = f.dial
	machine.screenService = func() (bool, bool, error) { return true, true, nil }
	err := updateApp(context.Background(), io.Discard, &serviceRoad{}, "1.0.0", "1.1.0", "cyfr update")
	f.served()
	want := "The CYFR app is release 1.1.0, but the screen could not be started again (exit status 1): start it with 'sudo systemctl start cyfr-screen', then run 'cyfr update' again to update CYFR here; your CYFR was not touched"
	if err == nil || err.Error() != want {
		t.Errorf("an unstarted screen answered %v, want %q", err, want)
	}
}

// A cancelled cyfr update stops waiting on the service before the app
// closes, and the wait has a bound of its own: an unanswered service is
// one that ended without an answer, which takes the sudo road.
func TestTheWaitOnTheServiceEnds(t *testing.T) {
	standInMachine(t)
	saved, savedWait, savedSum := dialAppUpdate, serviceWait, appPackageSum
	t.Cleanup(func() { dialAppUpdate, serviceWait, appPackageSum = saved, savedWait, savedSum })
	appPackageSum = func(context.Context, string, string, string) (string, error) {
		return "", errors.New("the release is not read in this test")
	}
	unanswered := func() (net.Conn, error) {
		client, server := net.Pipe()
		go func() { _, _ = io.Copy(io.Discard, server) }()
		t.Cleanup(func() { server.Close() })
		return client, nil
	}
	dialAppUpdate = unanswered
	ctx, cancel := context.WithCancel(context.Background())
	finished := make(chan error, 1)
	r := &serviceRoad{}
	go func() {
		_, err := r.fetch(ctx, io.Discard, "1.0.0", "1.1.0")
		finished <- err
	}()
	time.Sleep(100 * time.Millisecond) // sleep-ok: the request on its way before the cancel; a cancel before it ends the wait the same way
	cancel()
	select {
	case err := <-finished:
		if err == nil || err.Error() != "cyfr update was interrupted before the CYFR app was closed; nothing was changed and CYFR runs as it did" || r.sudo {
			t.Errorf("a cancelled wait answered %v, took the sudo road %v", err, r.sudo)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("cancelling the update did not end its wait on the service")
	}
	serviceWait = 100 * time.Millisecond
	var out bytes.Buffer
	r = &serviceRoad{}
	start := time.Now()
	if _, err := r.fetch(context.Background(), &out, "1.0.0", "1.1.0"); err == nil || !r.sudo || time.Since(start) > 2*time.Second ||
		!strings.Contains(out.String(), "CYFR's update service ended without an answer (") {
		t.Errorf("an unanswered service answered %v after %v, took the sudo road %v: %q", err, time.Since(start), r.sudo, out.String())
	}
}

// The service answers what the release's own fetch says, through
// fetchInstaller: a release it cannot reach (the trust root, the host, a
// timeout: no ErrUnverified) as unreachable, which its caller takes the
// sudo road for, and a release whose signature or digest does not match
// (ErrUnverified) as refused, for good.
func TestTheServiceTellsAReleaseItCannotReachFromOneThatDoesNotVerify(t *testing.T) {
	saved, savedFetch := appPackageSum, fetchAppPackage
	t.Cleanup(func() { appPackageSum, fetchAppPackage = saved, savedFetch })
	fetchAppPackage = func(context.Context, string, string, string, string) ([]byte, error) {
		return nil, errors.New("the installer is not read in this test")
	}
	for _, c := range []struct {
		name, want string
		err        error
	}{
		{"the trust root cannot be fetched", serviceMark + answerUnreachable + " could not download release 1.1.0 itself (cyfr update could not download the CYFR app of release 1.1.0 (fetch the Sigstore trusted root: dial tcp: i/o timeout)",
			errors.New("fetch the Sigstore trusted root: dial tcp: i/o timeout")},
		{"its signature does not match", serviceMark + answerRefused + " The CYFR app of release 1.1.0 did not verify (release not verified: not signed by the release workflow for 1.1.0",
			fmt.Errorf("%w: not signed by the release workflow for 1.1.0: no matching certificate", release.ErrUnverified)},
	} {
		appPackageSum = func(context.Context, string, string, string) (string, error) { return "", c.err }
		host := rootHost
		host.run = func(io.Writer, string, ...string) error {
			t.Errorf("%s: root ran a command", c.name)
			return nil
		}
		client, server := net.Pipe()
		go func() {
			defer server.Close()
			serveUpdate(context.Background(), server, "1.0.0", host)
		}()
		client.SetDeadline(time.Now().Add(5 * time.Second))
		go io.WriteString(client, "1.1.0\n")
		said, _ := io.ReadAll(client)
		client.Close()
		if !strings.Contains(string(said), c.want) {
			t.Errorf("%s: the service answered %q, want %q", c.name, said, c.want)
		}
	}
}

// Whether the service would take this account's request is read from its
// socket alone: there only while systemd listens, and writable by this
// account.
func TestTheServiceAnswersWhereItsSocketTakesThisAccount(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root may write any socket")
	}
	saved := appUpdateSocket
	t.Cleanup(func() { appUpdateSocket = saved })
	dir := t.TempDir()
	appUpdateSocket = filepath.Join(dir, "cyfr-update.sock")
	if why := serviceAnswers(); why != "is not on this machine" {
		t.Errorf("no socket answered %q", why)
	}
	if err := os.WriteFile(appUpdateSocket, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if why := serviceAnswers(); why != "is not on this machine" {
		t.Errorf("a file that is no socket answered %q", why)
	}
	os.Remove(appUpdateSocket)
	l, err := net.Listen("unix", appUpdateSocket)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	if why := serviceAnswers(); why != "" {
		t.Errorf("a socket this account may write answered %q", why)
	}
	if err := os.Chmod(appUpdateSocket, 0o440); err != nil {
		t.Fatal(err)
	}
	if why := serviceAnswers(); why != "serves the sudo group's accounts alone" {
		t.Errorf("a socket this account may not write answered %q", why)
	}
}

// Update CYFR's offer asks the road as its run meets it, never by
// connecting: where the service's socket takes this account the page
// offers the yes, saying the service makes the update and what happens
// where it then cannot; where not, why, and the sudo road's check, here
// a sudo that would ask for a password: no yes, the line to run instead.
func TestThePageOffersTheServiceWhereItsSocketAnswers(t *testing.T) {
	for _, c := range []struct {
		why, says string
		yes       bool
	}{
		{"", "CYFR's update service installs it, with no password; where the service cannot, the update says why and goes through sudo, which needs a terminal to ask for your password.", true},
		{"is not on this machine", "CYFR's update service is not on this machine, so the update goes through sudo.", false},
		{"serves the sudo group's accounts alone", "CYFR's update service serves the sudo group's accounts alone, so the update goes through sudo.", false},
	} {
		newAppScenario(t, "0.9.0", "0.10.0", "0.9.0")
		machine.passwordless = func() bool { return false }
		saved, savedAnswers, savedDial := appRoadHere, serviceAnswers, dialAppUpdate
		appRoadHere = func() appRoad { return &serviceRoad{} }
		serviceAnswers = func() string { return c.why }
		dialAppUpdate = func() (net.Conn, error) {
			t.Error("the offer connected to the service")
			return nil, errors.New("not here")
		}
		p := windowOffer(context.Background(), t.TempDir(), "")
		appRoadHere, serviceAnswers, dialAppUpdate = saved, savedAnswers, savedDial
		if !slices.Contains(p.Says, c.says) || (p.Step == "app") != c.yes || (p.Terminal == "") != c.yes {
			t.Errorf("with the socket %q the page offered %+v", c.why, p)
		}
	}
}
