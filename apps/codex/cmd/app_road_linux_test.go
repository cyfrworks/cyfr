// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package cmd

import (
	"bytes"
	"errors"
	"os/exec"
	"strconv"
	"strings"
	"testing"
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
		if !strings.HasPrefix(ran, "timeout --kill-after=10s 1200s 'sh' '-c' 'dpkg --configure -a && ( ") || !strings.Contains(ran, c.apt) ||
			!strings.Contains(ran, "install -m 0644 '\\''/tmp/cyfr-update-1/the.deb'\\''") || !strings.Contains(ran, "sha256sum --check --strict --quiet") {
			t.Errorf("the road ran as root %q, want the bounded check and %q", ran, c.apt)
		}
	}
}

// A root command its bound ended is errOverran, never its own status, and
// a refusal of apt says what apt answered.
func TestTheDebRoadSaysWhatItsInstallerAnswered(t *testing.T) {
	m := standInMachine(t)
	for _, c := range []struct {
		status int
		says   string
	}{
		{124, "apt could not install the CYFR app's package (it did not finish within 20m0s)"},
		{137, "apt could not install the CYFR app's package (it did not finish within 20m0s)"},
		{100, "apt could not install the CYFR app's package (exit status 100)"},
	} {
		m.applyErr = exec.Command("/bin/sh", "-c", "exit "+strconv.Itoa(c.status)).Run()
		if m.applyErr == nil {
			t.Fatal("the stand-in status did not fail")
		}
		err := (debRoad{}).replace(&bytes.Buffer{}, &staged{file: "f", sum: "s"}, false)
		if err == nil || err.Error() != c.says || (c.status != 100) != errors.Is(err, errOverran) {
			t.Errorf("status %d answered %v, want %q", c.status, err, c.says)
		}
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
