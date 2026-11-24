// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package cmd

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The DEB's road installs the verified copy through apt as one root
// command bounded by appReplaceWithin: it first finishes what a dpkg cut
// off part way left, then reinstalls, allowing an older release only where
// --version asks for one.
func TestTheDebRoadInstallsThroughApt(t *testing.T) {
	for _, c := range []struct {
		older bool
		apt   string
	}{
		{false, "apt-get install -y --reinstall \"$d/cyfr-desktop.deb\""},
		{true, "apt-get install -y --reinstall --allow-downgrades \"$d/cyfr-desktop.deb\""},
	} {
		m := standInMachine(t)
		var out bytes.Buffer
		if err := (debRoad{}).replace(&out, &staged{file: "/tmp/cyfr-update-1/the.deb", sum: "abc"}, c.older); err != nil {
			t.Fatal(err)
		}
		if len(m.applied) != 1 || len(m.applied[0]) != 1 {
			t.Fatalf("the road ran as root %q, want one command", m.applied)
		}
		ran := m.applied[0][0]
		account, _ := user.Current()
		if !strings.HasPrefix(ran, "'systemd-run' '--wait' '--pipe' '--collect' '--quiet' '-p' 'RuntimeMaxSec=1200' '-p' 'KillSignal=SIGKILL' '-p' 'TimeoutStopSec=10' '--' '/bin/sh' '-c' 'dpkg --configure -a && ( ") || !strings.Contains(ran, c.apt) ||
			!strings.Contains(ran, "runuser -u '\\''"+account.Username+"'\\'' -- cat -- '\\''/tmp/cyfr-update-1/the.deb'\\''") || !strings.Contains(ran, "sha256sum --check --strict --quiet") {
			t.Errorf("the road ran as root %q, want the bounded check and %q", ran, c.apt)
		}
	}
}

// A refusal of apt says what apt answered.
func TestTheDebRoadSaysWhatItsInstallerAnswered(t *testing.T) {
	m := standInMachine(t)
	m.applyErr = exec.Command("/bin/sh", "-c", "exit 100").Run()
	err := (debRoad{}).replace(&bytes.Buffer{}, &staged{file: "f", sum: "s"}, false)
	if err == nil || err.Error() != "apt could not install the CYFR app's package (exit status 100)" || errors.Is(err, errOverran) {
		t.Errorf("apt's refusal answered %v", err)
	}
}

// The root command's bound ends what root started, a child that ignores
// SIGTERM among them, before applyWithin answers errOverran: nothing of
// it finishes its work afterwards. Run as a transient unit of this
// account's own systemd where it runs one, else of the system's through a
// sudo that asks for no password, the way root runs it.
func TestApplyWithinEndsWhatRootStartedAtItsBound(t *testing.T) {
	run := func(command string) *exec.Cmd { return nil }
	switch {
	case exec.Command("systemd-run", "--user", "--wait", "--quiet", "--collect", "/bin/true").Run() == nil:
		run = func(command string) *exec.Cmd {
			return exec.Command("/bin/sh", "-c", strings.Replace(command, "'systemd-run' ", "'systemd-run' '--user' ", 1))
		}
	case exec.Command("sudo", "-n", "systemd-run", "--wait", "--quiet", "--collect", "/bin/true").Run() == nil:
		run = func(command string) *exec.Cmd { return exec.Command("sudo", "-n", "/bin/sh", "-c", command) }
	default:
		t.Skip("no systemd here runs a transient unit for this account, nor a sudo without a password for the system's")
	}
	marker := filepath.Join(t.TempDir(), "finished")
	saved := machine.apply
	t.Cleanup(func() { machine.apply = saved })
	machine.apply = func(commands []string) error {
		c := run(commands[0])
		c.Stdout, c.Stderr = os.Stderr, os.Stderr
		return c.Run()
	}
	start := time.Now()
	err := applyWithin(time.Second, []string{"(trap '' TERM; /bin/sleep 3; printf finished > " + shellQuote([]string{marker}) + ") & wait"})
	if !errors.Is(err, errOverran) {
		t.Fatalf("applyWithin answered %v, want errOverran", err)
	}
	took := time.Since(start)
	time.Sleep(4 * time.Second) // sleep-ok: longer than the child's own work, which a bound that ended it never finishes
	if _, err := os.Stat(marker); err == nil {
		t.Errorf("a child root started finished its work after the bound answered (in %v)", took)
	}
}

// The road's elevation refuses an account that may not administer the
// machine and a refused password before anything else runs, saying that
// CYFR runs as it did; a login it took is forgotten when the update ends.
func TestTheDebRoadElevatesBeforeAnythingCloses(t *testing.T) {
	m := standInMachine(t)
	m.administrator = nil
	var out bytes.Buffer
	if _, err := (debRoad{}).elevate(&out, "cyfr update"); err == nil || !strings.Contains(err.Error(), "Nothing was changed. Run `cyfr update` again once they have") {
		t.Errorf("an account outside sudo's groups answered %v", err)
	}
	m = standInMachine(t)
	m.authErr = errors.New("no")
	if _, err := (debRoad{}).elevate(&out, "cyfr update"); err == nil || err.Error() != "The password was not accepted, so nothing was changed and CYFR runs as it did. Run 'cyfr update' again to try again" {
		t.Errorf("a refused password answered %v", err)
	}
	m = standInMachine(t)
	let, err := (debRoad{}).elevate(&out, "cyfr update")
	if err != nil || m.authenticated != 1 || m.forgotten != 0 {
		t.Fatalf("the elevation answered %v, authenticated %d, forgot %d", err, m.authenticated, m.forgotten)
	}
	let()
	if m.forgotten != 1 || len(m.applied) != 0 {
		t.Errorf("the login was forgotten %d times, root ran %q", m.forgotten, m.applied)
	}
}
