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
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
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

	mu      sync.Mutex
	fetched []string
	dirs    []string
	ran     [][]string
	done    chan struct{}
}

func newServiceStandIn(t *testing.T, own string) *serviceStandIn {
	return &serviceStandIn{t: t, own: own, done: make(chan struct{})}
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
			if err := os.WriteFile(file, []byte("deb"), 0o600); err != nil {
				f.t.Fatal(err)
			}
			f.dirs = append(f.dirs, dir)
			return &staged{target: target, dir: dir, file: file}, nil
		},
		screenRuns: func() (bool, error) { return f.screen, nil },
		run: func(out io.Writer, name string, args ...string) error {
			f.mu.Lock()
			f.ran = append(f.ran, append([]string{name}, args...))
			f.mu.Unlock()
			if name == aptProgram {
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

// A release root cannot fetch itself is refused, saying why, and nothing
// runs: the caller takes the sudo road.
func TestTheUpdateServiceRefusesWhatItCannotFetch(t *testing.T) {
	f := newServiceStandIn(t, "1.0.0")
	f.fetchErr = errors.New("cyfr update could not download the CYFR app of release 1.1.0 (dial tcp: lookup github.com: no such host)")
	said := f.ask("1.1.0\ngo\n")
	if !strings.Contains(said, serviceMark+answerRefused+" could not fetch release 1.1.0 itself (cyfr update could not download") || len(f.ran) != 0 {
		t.Errorf("an unfetchable release was answered %q and ran %q", said, f.ran)
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
	for k, v := range map[string]string{"Service.ExecStart": carried + " " + appUpdateServiceArg, "Service.StandardInput": "socket", "Service.StandardOutput": "journal", "Service.KillSignal": "SIGKILL", "Service.ProtectHome": "yes", "Service.PrivateTmp": "yes", "Unit.CollectMode": "inactive-or-failed"} {
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

// The road takes the sudo road where the service does not take the
// update, saying why before anything closes, and asks for a password
// there as it always has.
func TestTheServiceRoadTakesTheSudoRoadSayingWhy(t *testing.T) {
	refusing := newServiceStandIn(t, "1.1.0")
	for _, c := range []struct {
		name string
		dial func() (net.Conn, error)
		says string
	}{
		{"no service", func() (net.Conn, error) {
			return nil, &net.OpError{Op: "dial", Net: "unix", Err: os.NewSyscallError("connect", syscall.ENOENT)}
		}, "CYFR's update service is not on this machine (dial unix: connect: no such file or directory), so the update goes through sudo instead.\n"},
		{"an account outside the sudo group", func() (net.Conn, error) {
			return nil, &net.OpError{Op: "dial", Net: "unix", Err: os.NewSyscallError("connect", syscall.EACCES)}
		}, "CYFR's update service serves the sudo group's accounts alone, so the update goes through sudo instead.\n"},
		{"a refusal", refusing.dial,
			"CYFR's update service installs only a release newer than the installed CYFR app's 1.1.0, and 1.1.0 is not, so the update goes through sudo instead.\n"},
	} {
		m := standInMachine(t)
		saved, savedSum := dialAppUpdate, appPackageSum
		dialAppUpdate = c.dial
		appPackageSum = func(context.Context, string, string, string) (string, error) {
			return "", errors.New("the release is not read in this test")
		}
		var out bytes.Buffer
		r := &serviceRoad{}
		_, err := r.fetch(context.Background(), &out, "1.0.0", "1.1.0")
		dialAppUpdate, appPackageSum = saved, savedSum
		if !strings.Contains(out.String(), c.says) || !r.sudo || err == nil {
			t.Errorf("%s: said %q (%v), took the sudo road %v", c.name, out.String(), err, r.sudo)
		}
		if _, err := r.elevate(&out, "cyfr update"); err != nil || m.authenticated != 1 {
			t.Errorf("%s: the sudo road's elevation answered %v, asked %d times", c.name, err, m.authenticated)
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
		saved, savedQuit, savedReopen, savedScreen := dialAppUpdate, quitApp, reopenApp, machine.screenService
		dialAppUpdate = f.dial
		quitApp = func() (bool, error) { steps = append(steps, "quit"); return true, nil }
		reopenApp = func() error { steps = append(steps, "reopen"); return nil }
		machine.screenService = func() (bool, bool, error) { return box, box, nil }
		var out bytes.Buffer
		err := updateApp(context.Background(), &out, &serviceRoad{}, "1.0.0", "1.1.0", "cyfr update")
		dialAppUpdate, quitApp, reopenApp, machine.screenService = saved, savedQuit, savedReopen, savedScreen
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
