// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build darwin

package cmd

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// macApp makes a CYFR.app in dir whose own cyfr answers version, signed
// ad hoc as an unsigned build is, and answers its path.
func macApp(t *testing.T, dir, version string) string {
	t.Helper()
	app := filepath.Join(dir, "CYFR.app")
	plist := `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CYFR</string>
<key>CFBundleIdentifier</key><string>com.cyfrworks.cyfr.test</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
`
	writeFile(t, filepath.Join(app, "Contents", "Info.plist"), plist)
	writeFile(t, filepath.Join(app, "Contents", "MacOS", "CYFR"), "#!/bin/sh\nexit 0\n")
	writeFile(t, filepath.Join(app, "Contents", "Resources", "cyfr"), "#!/bin/sh\necho 'cyfr version "+version+"'\n")
	if out, err := exec.Command("codesign", "--force", "--deep", "-s", "-", app).CombinedOutput(); err != nil {
		t.Fatalf("codesign: %v: %s", err, out)
	}
	return app
}

// macDMG makes a disk image holding app, as the release's DMG holds the
// CYFR app, and answers it staged as the road's fetch stages it.
func macDMG(t *testing.T, app, target string) *staged {
	t.Helper()
	dir := t.TempDir()
	dmg := filepath.Join(dir, "cyfr-desktop.dmg")
	if out, err := exec.Command("hdiutil", "create", "-volname", "CYFR", "-srcfolder", filepath.Dir(app), "-format", "UDRO", "-ov", dmg).CombinedOutput(); err != nil {
		t.Fatalf("hdiutil create: %v: %s", err, out)
	}
	return &staged{target: target, dir: dir, file: dmg}
}

// macRoadOn is the road over a folder of applications of the test's own,
// holding the installed app at release installed, the machine reading the
// app's release from the cyfr inside it.
func macRoadOn(t *testing.T, installed string) (macRoad, string) {
	t.Helper()
	apps := t.TempDir()
	app := macApp(t, apps, installed)
	saved := machine.appRelease
	t.Cleanup(func() { machine.appRelease = saved })
	machine.appRelease = func() string {
		said, err := exec.Command(filepath.Join(app, "Contents", "Resources", "cyfr")).Output()
		if err != nil {
			return ""
		}
		return strings.TrimPrefix(strings.TrimSpace(string(said)), "cyfr version ")
	}
	return macRoad{apps: apps}, app
}

// macAnswers fails unless the app's own cyfr answers version and the folder
// holds the app alone.
func macAnswers(t *testing.T, r macRoad, version string) {
	t.Helper()
	if got := machine.appRelease(); got != version {
		t.Errorf("the installed app answers %q, want %q", got, version)
	}
	entries, _ := os.ReadDir(r.apps)
	if len(entries) != 1 || entries[0].Name() != "CYFR.app" {
		var names []string
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Errorf("the applications folder holds %v, want CYFR.app alone", names)
	}
}

// The new app from the verified DMG replaces the installed one whole, and
// what an earlier update's crash left hidden beside it is removed first.
func TestTheMacRoadSwapsTheWholeApp(t *testing.T) {
	r, _ := macRoadOn(t, "1.0.0")
	writeFile(t, filepath.Join(r.apps, macStaging, "Contents", "Info.plist"), "a crash's leftover")
	s := macDMG(t, macApp(t, t.TempDir(), "1.1.0"), "1.1.0")
	if err := r.replace(&bytes.Buffer{}, s, false); err != nil {
		t.Fatal(err)
	}
	macAnswers(t, r, "1.1.0")
}

// A new app whose own cyfr answers another release is swapped back: the
// app before it stays installed, whole; one whose signature does not
// verify, a file changed after signing, replaces nothing.
func TestTheMacRoadPutsTheAppBackOrReplacesNothing(t *testing.T) {
	r, _ := macRoadOn(t, "1.0.0")
	s := macDMG(t, macApp(t, t.TempDir(), "1.0.5"), "1.1.0")
	if err := r.replace(&bytes.Buffer{}, s, false); err == nil || !strings.Contains(err.Error(), `the new app's own cyfr answered "1.0.5", not 1.1.0, so the app before it was put back`) {
		t.Errorf("a new app of another release answered %v", err)
	}
	macAnswers(t, r, "1.0.0")

	changed := macApp(t, t.TempDir(), "1.1.0")
	writeFile(t, filepath.Join(changed, "Contents", "Resources", "cyfr"), "#!/bin/sh\necho 'cyfr version 6.6.6'\n")
	s = macDMG(t, changed, "1.1.0")
	if err := r.replace(&bytes.Buffer{}, s, false); err == nil || !strings.Contains(err.Error(), "the new app's signature was refused") {
		t.Errorf("a new app changed after signing answered %v", err)
	}
	macAnswers(t, r, "1.0.0")
}

// An account that may not write the applications folder, or a folder of
// the installed app, is refused before anything closes.
func TestTheMacRoadRefusesAnAppItMayNotReplace(t *testing.T) {
	r, app := macRoadOn(t, "1.0.0")
	if _, err := r.elevate(&bytes.Buffer{}, "cyfr update"); err != nil {
		t.Fatalf("a writable app was refused: %v", err)
	}
	resources := filepath.Join(app, "Contents", "Resources")
	if err := os.Chmod(resources, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(resources, 0o755) })
	if _, err := r.elevate(&bytes.Buffer{}, "cyfr update"); err == nil || err.Error() != "This account may not write "+resources+", so the CYFR app cannot be replaced; nothing was changed and CYFR runs as it did. Run 'sudo cyfr update'" {
		t.Errorf("an app folder it may not write answered %v", err)
	}
}
