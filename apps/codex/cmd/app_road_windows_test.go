// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build windows

package cmd

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

// The MSI's version is its release's MAJOR.MINOR.PATCH, and Windows
// Installer refuses an older one over a newer: such a release is refused
// before anything is downloaded or closed. Consecutive pre-releases of one
// release, and an older pre-release of it, are not.
func TestTheMsiRoadRefusesWhatWindowsInstallerRefuses(t *testing.T) {
	_, err := (msiRoad{}).fetch(context.Background(), &bytes.Buffer{}, "0.6.0-alpha.2", "0.5.0")
	if err == nil || !strings.HasPrefix(err.Error(), "Windows Installer does not install release 0.5.0 over the newer 0.6.0-alpha.2; nothing was changed") {
		t.Errorf("an older release answered %v", err)
	}
	saved, savedFetch := appPackageSum, fetchAppPackage
	t.Cleanup(func() { appPackageSum, fetchAppPackage = saved, savedFetch })
	appPackageSum = func(context.Context, string, string, string) (string, error) { return "sum", nil }
	fetchAppPackage = func(context.Context, string, string, string, string) ([]byte, error) { return []byte("msi"), nil }
	for _, c := range [][2]string{{"0.6.0-alpha.1", "0.6.0-alpha.2"}, {"0.6.0-alpha.2", "0.6.0-alpha.1"}, {"0.6.0-alpha.2", "0.6.0"}, {"", "0.5.0"}} {
		s, err := (msiRoad{}).fetch(context.Background(), &bytes.Buffer{}, c[0], c[1])
		if err != nil {
			t.Errorf("%s over %s answered %v", c[1], c[0], err)
			continue
		}
		s.remove()
	}
}

// The app's cyfr running the update steps aside for Windows Installer,
// which would otherwise leave it for the next restart to remove. Once the release is
// confirmed it stays aside, removed by a later update; where the installer
// failed, or the installed app's cyfr does not answer the release, it goes
// back over whatever is at its place. The installer's status is said.
func TestTheMsiRoadStepsAsideForTheInstaller(t *testing.T) {
	for _, c := range []struct {
		name      string
		script    string
		says      string
		confirmed bool
		holds     string
		aside     bool
	}{
		{"a working installer", "copy /y \"%~dp0new\" \"%CYFR_TEST_CARRIED%\" >nul\r\nexit /b 0", "", true, "new", true},
		{"one that wants a restart", "copy /y \"%~dp0new\" \"%CYFR_TEST_CARRIED%\" >nul\r\nexit /b 3010", "", true, "new", true},
		{"another release installed", "copy /y \"%~dp0new\" \"%CYFR_TEST_CARRIED%\" >nul\r\nexit /b 0", "", false, "old", false},
		{"a failing installer", "exit /b 1603", "Windows Installer could not install the CYFR app (exit status 1603: the install failed and was undone)", false, "old", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			_, carried := appBundleLayout(t, filepath.Join(dir, "app"))
			writeFile(t, carried, "old")
			stale := carried + msiAside + "1"
			writeFile(t, stale, "an earlier update's")
			bin := filepath.Join(dir, "bin")
			writeFile(t, filepath.Join(bin, "new"), "new")
			writeFile(t, filepath.Join(bin, "msiexec.cmd"), "@echo off\r\n"+c.script+"\r\n")
			t.Setenv("CYFR_TEST_CARRIED", carried)
			savedProgram, savedSelf, savedCyfr := msiexecProgram, selfExecutable, appCyfr
			t.Cleanup(func() { msiexecProgram, selfExecutable, appCyfr = savedProgram, savedSelf, savedCyfr })
			msiexecProgram = filepath.Join(bin, "msiexec.cmd")
			selfExecutable = func() (string, error) { return carried, nil }
			appCyfr = func() (string, error) { return carried, nil }
			s := &staged{target: "1.1.0", dir: dir, file: filepath.Join(dir, "the.msi")}
			err := (msiRoad{}).replace(&bytes.Buffer{}, s, false)
			if (c.says == "") != (err == nil) || (err != nil && err.Error() != c.says) {
				t.Errorf("the road answered %v, want %q", err, c.says)
			}
			if err := (msiRoad{}).finish(&bytes.Buffer{}, s, c.confirmed); err != nil {
				t.Fatal(err)
			}
			if got := read(t, carried); got != c.holds {
				t.Errorf("the app's cyfr holds %q, want %q", got, c.holds)
			}
			aside := carried + msiAside + strconv.Itoa(os.Getpid())
			if _, err := os.Stat(aside); (err == nil) != c.aside {
				t.Errorf("the cyfr renamed aside is there: %v, want %v", err == nil, c.aside)
			}
			if _, err := os.Stat(stale); err == nil {
				t.Error("an earlier update's cyfr renamed aside stays")
			}
		})
	}
}

// The update installs only once no process runs the app's executable:
// one still ending is waited for, one still running at the bound refuses
// the update, and a program of the same name elsewhere (the app's own
// cyfr.exe runs the update) is not the app.
func TestTheMsiRoadWaitsForTheAppToEnd(t *testing.T) {
	ping := filepath.Join(os.Getenv("SystemRoot"), "System32", "PING.EXE")
	dir := t.TempDir()
	app := filepath.Join(dir, "app", "CYFR.exe")
	other := filepath.Join(dir, "resources", "cyfr.exe")
	for _, p := range []string{app, other} {
		data, err := os.ReadFile(ping)
		if err != nil {
			t.Fatal(err)
		}
		writeFile(t, p, string(data))
	}
	// start runs exe for about n seconds (ping waits a second between
	// two of its n echoes), answering whether it has ended.
	start := func(exe string, n int) (ended func() bool) {
		c := exec.Command(exe, "-n", strconv.Itoa(n), "127.0.0.1")
		if err := c.Start(); err != nil {
			t.Fatal(err)
		}
		h, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(c.Process.Pid))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = c.Process.Kill(); _ = c.Wait(); _ = windows.CloseHandle(h) })
		return func() bool { e, _ := windows.WaitForSingleObject(h, 0); return e == windows.WAIT_OBJECT_0 }
	}

	ended := start(other, 30)
	began := time.Now()
	if err := appGone(app, 10*time.Second); err != nil || time.Since(began) > 5*time.Second || ended() {
		t.Errorf("with only another cyfr.exe running the wait answered %v after %v", err, time.Since(began))
	}

	ended = start(app, 3)
	if err := appGone(app, 20*time.Second); err != nil || !ended() {
		t.Errorf("an app ending answered %v, ended: %v", err, ended())
	}

	ended = start(app, 30)
	err := appGone(app, 300*time.Millisecond)
	if want := "the CYFR app was still running 300ms after it was closed; nothing was replaced"; err == nil || err.Error() != want || ended() {
		t.Errorf("an app running past the bound answered %v, ended: %v, want %q", err, ended(), want)
	}
}
