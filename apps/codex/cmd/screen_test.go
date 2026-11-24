// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"maps"
	"net/http"
	"os"
	"os/user"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/release"
	"github.com/cyfr/codex/internal/shell"
	"github.com/cyfr/codex/internal/version"
)

// screenProject is a project directory on a machine that can show it.
func screenProject(t *testing.T) *standIn {
	t.Helper()
	// The device folder is the account's own (shell.DeviceDir): each test
	// has a home of its own, which its subprocesses inherit.
	t.Setenv("HOME", t.TempDir())
	t.Setenv("USERPROFILE", os.Getenv("HOME"))
	s := standInMachine(t)
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)
	// The CYFR app of this cyfr's version is installed, unless a test
	// says otherwise, so screen on fetches nothing.
	s.installed, s.app = []string{appPackage}, version.Version
	for name, body := range map[string]string{"docker-compose.yml": "services: {}\n", ".env": "CYFR_ACCESS=local\nCYFR_PORT=4321\nCYFR_SETUP_TOKEN=the-token\n"} {
		if err := os.WriteFile(name, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return s
}

func screenCommandsIn(dir string, tail ...string) []string {
	files := shellQuote([]string{filepath.Join(dir, screenDir)})
	account, _ := user.Current()
	return append([]string{
		"{ ! getent group tss >/dev/null || usermod -aG tss " + shellQuote([]string{account.Username}) + "; }",
		"install -m 0644 " + files + "/cyfr-screen.service " + screenUnit,
		"systemctl daemon-reload",
		"systemctl disable getty@tty1",
		"systemctl enable cyfr-screen",
	}, tail...)
}

// appCommand is the command that installs the CYFR app's package fetched
// into dir, whose sha256 is sum: root's copy of it, checked, is what apt
// installs, in a folder the command's own exit removes.
func appCommand(dir, sum string) string {
	return `( trap 'rm -rf "$d"' EXIT && trap 'exit 1' INT TERM HUP && d=$(mktemp -d) && chmod 0755 "$d"` +
		" && install -m 0644 " + shellQuote([]string{filepath.Join(dir, screenAppFile)}) + ` "$d/cyfr-desktop.deb"` +
		" && echo '" + sum + `  '"$d/cyfr-desktop.deb" | sha256sum --check --strict --quiet` +
		` && apt-get install -y "$d/cyfr-desktop.deb" )`
}

// fetchesTheApp stands in for the release of version, its signed checksums
// naming the sum of "the app" for this machine's package, and its package
// being body, or err when downloaded; it answers how many downloads there
// were.
func fetchesTheApp(t *testing.T, release string, body []byte, err error) *int {
	t.Helper()
	savedVersion, savedSum, savedFetch := version.Version, appPackageSum, fetchAppPackage
	t.Cleanup(func() { version.Version, appPackageSum, fetchAppPackage = savedVersion, savedSum, savedFetch })
	version.Version = release
	named := sha256.Sum256([]byte("the app"))
	appPackageSum = func(_ context.Context, v, arch string) (string, error) {
		if v != release || arch != "amd64" {
			t.Errorf("read the sum of the app of %s for %s", v, arch)
		}
		return hex.EncodeToString(named[:]), nil
	}
	fetched := new(int)
	fetchAppPackage = func(_ context.Context, v, arch, want string) ([]byte, error) {
		*fetched++
		if v != release || arch != "amd64" || want != hex.EncodeToString(named[:]) {
			t.Errorf("fetched the app of %s for %s, its sum %s", v, arch, want)
		}
		return body, err
	}
	return fetched
}

// `cyfr screen on` shows the plain commands, asks once and runs them
// through one sudo, starting nothing, then forgets the login and says what
// is next. Where the machine lacks the CYFR app of this cyfr's release the
// commands install root's copy of its package, checked against the sum the
// release's signed checksums name; after the yes it downloads that
// package, says so, and the file is gone after. Packages it has are not
// installed again, and with none to install it reads no package lists.
func TestScreenOnRunsTheCommandsThroughOneSudo(t *testing.T) {
	s := screenProject(t)
	s.installed, s.app = []string{appPackage}, "0.5.0"
	fetched := fetchesTheApp(t, "0.6.0", []byte("the app"), nil)
	askInput = strings.NewReader("yes\n")
	dir, _ := os.Getwd()
	var out bytes.Buffer
	screenOnCmd.SetContext(context.Background())
	screenOnCmd.SetOut(&out)
	t.Cleanup(func() { screenOnCmd.SetContext(nil); screenOnCmd.SetOut(nil) })
	if err := screenOnCmd.RunE(screenOnCmd, nil); err != nil {
		t.Fatalf("%v\n%s", err, out.String())
	}
	sum := sha256.Sum256([]byte("the app"))
	want := append([]string{
		"apt-get update",
		appCommand(dir, hex.EncodeToString(sum[:])),
		"apt-get install -y --no-install-recommends labwc wvkbd swayidle",
	}, screenCommandsIn(dir)...)
	if len(s.applied) != 1 || !slices.Equal(s.applied[0], want) {
		t.Fatalf("applied %q, want one %q", s.applied, want)
	}
	if *fetched != 1 || !strings.Contains(out.String(), "(yes/no) [no]: Downloading the CYFR app, release 0.6.0 for amd64, and checking it against the release's signed checksums.\n") {
		t.Errorf("fetched %d times, saying:\n%s", *fetched, out.String())
	}
	if fileExists(screenAppFile) {
		t.Error("the fetched package stayed in the project")
	}
	if s.forgotten != 1 {
		t.Errorf("sudo's login was forgotten %d times", s.forgotten)
	}
	if !strings.HasSuffix(out.String(), "The screen starts at the next boot. Run `cyfr up`, then `sudo reboot`.\n") {
		t.Errorf("the output does not end on the next step:\n%s", out.String())
	}
	for _, c := range want {
		if !strings.Contains(out.String(), "\n  "+c+"\n") {
			t.Errorf("the preview lacks %q:\n%s", c, out.String())
		}
	}

	s.applied = nil
	s.installed, s.app = []string{"labwc", "wvkbd", "swayidle", appPackage}, "0.6.0"
	askInput = strings.NewReader("yes\n")
	if err := screenOn(context.Background(), true, &out); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(s.applied[0], screenCommandsIn(dir)) || *fetched != 1 {
		t.Errorf("applied %q, fetched %d times", s.applied, *fetched)
	}
}

// An app whose own cyfr answers this release, a pre-release with two
// hyphens among them, is not fetched again.
func TestScreenOnTakesTheAppThatAnswersThisRelease(t *testing.T) {
	s := screenProject(t)
	s.installed, s.app = []string{"labwc", "wvkbd", "swayidle", appPackage}, "0.6.0-alpha-test.15"
	fetched := fetchesTheApp(t, "0.6.0-alpha-test.15", []byte("the app"), nil)
	askInput = strings.NewReader("yes\n")
	var out bytes.Buffer
	if err := screenOn(context.Background(), true, &out); err != nil {
		t.Fatal(err)
	}
	if *fetched != 0 || strings.Contains(out.String(), "Downloading") {
		t.Fatalf("fetched the app %d times, saying:\n%s", *fetched, out.String())
	}
}

// On arm64 `screen on` runs as on amd64: it reads the sum of the app's
// package for arm64, which a release carries beside amd64's, and fetches
// that package after the yes.
func TestScreenOnRunsOnArm64(t *testing.T) {
	s := screenProject(t)
	s.arch, s.installed = "arm64", nil
	savedVersion, savedSum, savedFetch := version.Version, appPackageSum, fetchAppPackage
	t.Cleanup(func() { version.Version, appPackageSum, fetchAppPackage = savedVersion, savedSum, savedFetch })
	version.Version = "0.6.0"
	named := sha256.Sum256([]byte("the app"))
	var asked []string
	appPackageSum = func(_ context.Context, v, arch string) (string, error) {
		asked = append(asked, "sum "+v+" "+arch)
		return hex.EncodeToString(named[:]), nil
	}
	fetchAppPackage = func(_ context.Context, v, arch, want string) ([]byte, error) {
		asked = append(asked, "fetch "+v+" "+arch)
		return []byte("the app"), nil
	}
	askInput = strings.NewReader("yes\n")
	var out bytes.Buffer
	if err := screenOn(context.Background(), true, &out); err != nil {
		t.Fatalf("%v\n%s", err, out.String())
	}
	if !slices.Equal(asked, []string{"sum 0.6.0 arm64", "fetch 0.6.0 arm64"}) || len(s.applied) != 1 {
		t.Fatalf("asked %q, applied %q:\n%s", asked, s.applied, out.String())
	}
}

// The app's package is fetched only from a release: signed checksums that
// cannot be read, and a development build with no app installed at it, are
// refused before anything is asked, downloaded or written; a package that
// fails its check after the yes is refused before anything is installed,
// and leaves the project as it was.
func TestScreenOnInstallsOnlyAVerifiedApp(t *testing.T) {
	for name, c := range map[string]struct {
		release       string
		sumErr, err   error
		asks, fetches bool
		want          string
	}{
		"checksums that do not verify": {"0.6.0", fmt.Errorf("%w: checksums.txt for 0.6.0: no signature", release.ErrUnverified), nil, false, false,
			"The signed checksums of release 0.6.0 could not be read for the CYFR app, so nothing was installed"},
		"a package that fails its check": {"0.6.0", nil, fmt.Errorf("%w: cyfr-desktop_0.6.0_linux_amd64.deb does not match the release's signed checksums.txt", release.ErrUnverified), true, true,
			"The CYFR app could not be downloaded, so nothing was installed"},
		"a development build": {"dev", nil, nil, false, false, "This cyfr is a development build (dev), so there is no release of the CYFR app to download for it"},
	} {
		t.Run(name, func(t *testing.T) {
			s := screenProject(t)
			s.installed, s.app = nil, ""
			fetched := fetchesTheApp(t, c.release, []byte("the app"), c.err)
			if c.sumErr != nil {
				appPackageSum = func(context.Context, string, string) (string, error) { return "", c.sumErr }
			}
			askInput = strings.NewReader("yes\n")
			before := listing(t, ".")
			var out bytes.Buffer
			err := screenOn(context.Background(), true, &out)
			if err == nil || !strings.Contains(err.Error(), c.want) || s.applied != nil {
				t.Fatalf("screen on answered %v, applied %q:\n%s", err, s.applied, out.String())
			}
			if after := listing(t, "."); !maps.Equal(before, after) {
				t.Errorf("the project changed:\nbefore %v\nafter  %v", before, after)
			}
			if (*fetched != 0) != c.fetches {
				t.Errorf("downloaded the app %d times", *fetched)
			}
			if strings.Contains(out.String(), "(yes/no)") != c.asks {
				t.Errorf("asked %v, want %v:\n%s", !c.asks, c.asks, out.String())
			}
		})
	}
}

// Before the person answers yes nothing is downloaded and nothing is
// written: the commands shown, which install the package the release's
// signed checksums name, are the ones a yes runs, and a no has fetched no
// package and left no file.
func TestScreenOnDownloadsNothingBeforeTheYes(t *testing.T) {
	s := screenProject(t)
	s.installed, s.app = []string{"labwc", "wvkbd", "swayidle"}, ""
	fetched := fetchesTheApp(t, "0.6.0", []byte("the app"), nil)
	askInput = strings.NewReader("no\n")
	dir, _ := os.Getwd()
	before := listing(t, ".")
	var out bytes.Buffer
	if err := screenOn(context.Background(), true, &out); !errors.Is(err, errDeclined) {
		t.Fatalf("screen on answered %v:\n%s", err, out.String())
	}
	if *fetched != 0 || strings.Contains(out.String(), "Downloading") || s.applied != nil {
		t.Errorf("a no downloaded the app %d times, applied %q:\n%s", *fetched, s.applied, out.String())
	}
	if after := listing(t, "."); !maps.Equal(before, after) {
		t.Errorf("a no changed the project:\nbefore %v\nafter  %v", before, after)
	}
	sum := sha256.Sum256([]byte("the app"))
	if !strings.Contains(out.String(), "\n  "+appCommand(dir, hex.EncodeToString(sum[:]))+"\n") {
		t.Errorf("the commands shown do not install the package the checksums name:\n%s", out.String())
	}
}

// The checksum read before the question writes nothing on the machine:
// the release's verifier keeps its trust in memory. From a home that starts
// empty, with the release's checksums answered and everything else
// offline, so that the real verifier cannot reach its trust root, screen
// on refuses before it asks, and the home is still empty.
func TestScreenOnReadsTheChecksumWritingNothing(t *testing.T) {
	s := screenProject(t)
	s.installed, s.app = nil, ""
	saved := version.Version
	t.Cleanup(func() { version.Version = saved })
	version.Version = "0.6.0"
	savedTransport := http.DefaultTransport
	t.Cleanup(func() { http.DefaultTransport = savedTransport })
	http.DefaultTransport = roundTripper(func(r *http.Request) (*http.Response, error) {
		body := ""
		switch {
		case strings.HasSuffix(r.URL.Path, "/checksums.txt"):
			body = strings.Repeat("a", 64) + "  cyfr-desktop_0.6.0_linux_amd64.deb\n"
		case strings.HasSuffix(r.URL.Path, "/checksums.txt"+release.BundleSuffix):
			body = "{}"
		default:
			return nil, errors.New("offline")
		}
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body)), Request: r}, nil
	})
	home := os.Getenv("HOME")
	if held, _ := os.ReadDir(home); len(held) != 0 {
		t.Fatalf("the home holds %v before", held)
	}
	askInput = strings.NewReader("no\n")
	var out bytes.Buffer
	err := screenOn(context.Background(), true, &out)
	if err == nil || !strings.Contains(err.Error(), "The signed checksums of release 0.6.0 could not be read") || strings.Contains(out.String(), "(yes/no)") {
		t.Fatalf("screen on answered %v:\n%s", err, out.String())
	}
	var held []string
	_ = filepath.WalkDir(home, func(path string, _ os.DirEntry, _ error) error {
		if path != home {
			held = append(held, path)
		}
		return nil
	})
	if held != nil {
		t.Errorf("the checksum read wrote into the home: %v", held)
	}
}

// The machine holds the CYFR app of a release when dpkg holds its package
// installed for this machine's architecture and the app's own cyfr answers
// that release, as it spells it: a tag with two hyphens is answered as it
// is; a package of another architecture, an app that cannot run, one that
// answers no version and a package not installed hold none.
func TestTheMachineHoldsTheAppItsOwnCyfrAnswers(t *testing.T) {
	other := map[string]string{"amd64": "arm64"}[runtime.GOARCH]
	if other == "" {
		other = "amd64"
	}
	for _, c := range []struct{ name, dpkg, app, want string }{
		{"a tag with two hyphens", "printf 'installed " + runtime.GOARCH + "'", "echo 'cyfr version 0.6.0-alpha-test.15'", "0.6.0-alpha-test.15"},
		{"a package of another architecture", "printf 'installed " + other + "'", "echo 'cyfr version 0.6.0'", ""},
		{"an app that cannot run", "printf 'installed " + runtime.GOARCH + "'", "exit 126", ""},
		{"an app that answers no version", "printf 'installed " + runtime.GOARCH + "'", "echo 'not cyfr'", ""},
		{"a package not installed", "echo 'dpkg-query: no packages found matching cyfr-desktop' >&2; exit 1", "echo 'cyfr version 0.6.0'", ""},
	} {
		t.Run(c.name, func(t *testing.T) {
			bin := t.TempDir()
			t.Setenv("PATH", bin)
			if err := os.WriteFile(filepath.Join(bin, "dpkg-query"), []byte("#!/bin/sh\n"+c.dpkg+"\n"), 0o700); err != nil {
				t.Fatal(err)
			}
			saved := appCyfr
			t.Cleanup(func() { appCyfr = saved })
			appCyfr = filepath.Join(t.TempDir(), "cyfr")
			if err := os.WriteFile(appCyfr, []byte("#!/bin/sh\n"+c.app+"\n"), 0o700); err != nil {
				t.Fatal(err)
			}
			if got := realMachine.appRelease(); got != c.want {
				t.Errorf("appRelease = %q, want %q", got, c.want)
			}
		})
	}
}

// What `screen on` refuses, it refuses before it writes or runs anything.
func TestScreenOnRefuses(t *testing.T) {
	for name, c := range map[string]struct {
		set  func(s *standIn)
		want string
	}{
		"no terminal":     {func(*standIn) { askTerminal = func() bool { return false } }, "`cyfr screen` runs at a terminal"},
		"another system":  {func(s *standIn) { s.supported = false }, "`cyfr screen` runs at a terminal"},
		"riscv64":         {func(s *standIn) { s.arch = "riscv64" }, "`cyfr screen` runs at a terminal on Ubuntu 26.04 LTS on amd64 or arm64"},
		"a desktop":       {func(s *standIn) { s.displayManager = true }, "This machine's display manager has the screen."},
		"no project here": {func(*standIn) { _ = os.Remove("docker-compose.yml") }, "There is no CYFR in this directory."},
		"no .env":         {func(*standIn) { _ = os.Remove(".env") }, "There is no CYFR in this directory."},
	} {
		t.Run(name, func(t *testing.T) {
			s := screenProject(t)
			c.set(s)
			var out bytes.Buffer
			err := screenOn(context.Background(), true, &out)
			if err == nil || !strings.HasPrefix(err.Error(), c.want) {
				t.Fatalf("err = %v, want %q", err, c.want)
			}
			if s.applied != nil || fileExists(screenDir) {
				t.Errorf("applied %v, wrote %v", s.applied, fileExists(screenDir))
			}
		})
	}
}

// A project path goes into the service's unit as it is, so one that could
// carry a directive of its own refuses before anything is written or asked.
func TestScreenOnRefusesAPathTheUnitCouldNotHold(t *testing.T) {
	for name, dir := range map[string]string{
		"a line of its own": "project\nUser=root\n#",
		"a space":           "my project",
		"a percent":         "100%h",
	} {
		t.Run(name, func(t *testing.T) {
			s := screenProject(t)
			top, _ := os.Getwd()
			if err := os.Mkdir(dir, 0o755); err != nil {
				t.Fatal(err)
			}
			for _, f := range []string{"docker-compose.yml", ".env"} {
				if err := os.Rename(f, filepath.Join(dir, f)); err != nil {
					t.Fatal(err)
				}
			}
			t.Chdir(filepath.Join(top, dir))
			askInput = strings.NewReader("yes\n")
			var out bytes.Buffer
			err := screenOn(context.Background(), true, &out)
			if err == nil || !strings.HasPrefix(err.Error(), "`cyfr screen` needs a project path of letters, digits and / . _ - alone") {
				t.Fatalf("err = %v", err)
			}
			if s.applied != nil || fileExists(screenDir) || out.Len() != 0 {
				t.Errorf("applied %v, wrote %v, out %q", s.applied, fileExists(screenDir), out.String())
			}
		})
	}
}

// cyfr screen on and off take the machine's one root step: the sentence
// right before sudo's own prompt.
func TestScreenSaysWhosePasswordBeforeSudoAsks(t *testing.T) {
	for name, run := range map[string]func(out io.Writer) error{
		"on":  func(out io.Writer) error { return screenOn(context.Background(), true, out) },
		"off": screenOff,
	} {
		t.Run(name, func(t *testing.T) {
			s := screenProject(t)
			askInput = strings.NewReader("yes\n")
			var out bytes.Buffer
			s.prompt = func() { out.WriteString("[sudo's prompt]\n") }
			if err := run(&out); err != nil {
				t.Fatalf("%v\n%s", err, out.String())
			}
			if !strings.Contains(out.String(), passwordSentence+"[sudo's prompt]\n") || s.authenticated != 1 || len(s.applied) != 1 {
				t.Fatalf("authenticated %d, applied %d:\n%s", s.authenticated, len(s.applied), out.String())
			}
		})
	}
}

// A refusal of cyfr screen on or off, for an account outside the sudo and
// admin groups or for a refused password, leaves the project as it was,
// the screen files it already has included, and runs nothing as root. The
// account outside the groups is refused before anything is asked, in words
// alone: no command that grants it sudo is printed.
func TestScreenRefusalsChangeNothing(t *testing.T) {
	account := currentAccount(t)
	for _, c := range []struct {
		name, command string
		run           func(out io.Writer) error
		outside       bool
	}{
		{"on outside the groups", "on", func(out io.Writer) error { return screenOn(context.Background(), true, out) }, true},
		{"off outside the groups", "off", screenOff, true},
		{"on the password refused", "on", func(out io.Writer) error { return screenOn(context.Background(), true, out) }, false},
		{"off the password refused", "off", screenOff, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := screenProject(t)
			dir, _ := os.Getwd()
			// The screen files an earlier screen on wrote, one of them since
			// changed, so a rewrite shows.
			if err := writeScreenFiles(dir, account); err != nil {
				t.Fatal(err)
			}
			launcher := filepath.Join(screenDir, "launcher.sh")
			if err := os.WriteFile(launcher, []byte(read(t, launcher)+"# an earlier version\n"), 0o755); err != nil {
				t.Fatal(err)
			}
			before := folderState(t, dir)
			askInput = strings.NewReader("yes\n")
			var out bytes.Buffer
			var want string
			if c.outside {
				s.administrator = nil
				want = "Your account, " + account + ", is not in the sudo or admin group, so CYFR does not run commands as root for it. Nothing was changed. Whoever administers this machine can add your account to the sudo group; then run `cyfr screen " + c.command + "` again"
			} else {
				s.authErr = os.ErrPermission
				want = "The password was not accepted, so nothing was changed. Run `cyfr screen " + c.command + "` again to try again"
			}
			if err := c.run(&out); err == nil || err.Error() != want {
				t.Fatalf("err = %v, want %q\n%s", err, want, out.String())
			}
			if after := folderState(t, dir); !maps.Equal(after, before) {
				t.Errorf("the project changed:\nbefore %v\nafter  %v", before, after)
			}
			if s.applied != nil {
				t.Errorf("applied %q", s.applied)
			}
			if c.outside && (out.Len() != 0 || s.authenticated != 0) {
				t.Errorf("authenticated %d; printed:\n%s", s.authenticated, out.String())
			}
			if !c.outside && (!strings.HasSuffix(out.String(), passwordSentence) || s.authenticated != 1) {
				t.Errorf("authenticated %d:\n%s", s.authenticated, out.String())
			}
		})
	}
}

// Init's screen answered 1 by an account outside the sudo and admin groups
// is refused before anything is written, in words alone. A password refused at the screen
// step, once the project is written, says what is true: the project is set
// up, the screen is not, and cyfr screen on sets it up; no screen file is
// written and the project's files are as init wrote them. So does an
// account in the sudo group at the question and out of it by the screen
// step: no password is asked and nothing runs as root.
func TestInitScreenRefusals(t *testing.T) {
	t.Run("outside the groups", func(t *testing.T) {
		s, _ := initProjectOnScreen(t)
		s.administrator = nil
		askInput = strings.NewReader("1\n")
		dir, _ := os.Getwd()
		before := folderState(t, dir)
		var out bytes.Buffer
		err := runInit(context.Background(), initOptions{}, &out, &out)
		if err == nil || err.Error() != "Your account, "+currentAccount(t)+", is not in the sudo or admin group, so CYFR does not run commands as root for it. Nothing was changed. Whoever administers this machine can add your account to the sudo group; then run `cyfr init` again" {
			t.Fatalf("err = %v\n%s", err, out.String())
		}
		if after := folderState(t, dir); !maps.Equal(after, before) {
			t.Errorf("init changed the folder:\nbefore %v\nafter  %v", before, after)
		}
		if out.String() != screenQuestion || s.authenticated != 0 || s.applied != nil {
			t.Errorf("authenticated %d, applied %q:\n%s", s.authenticated, s.applied, out.String())
		}
	})
	t.Run("the password refused", func(t *testing.T) {
		s, _ := initProjectOnScreen(t)
		stubLauncher(t, true, nil)
		s.authErr = os.ErrPermission
		askInput = strings.NewReader("1\n")
		var out bytes.Buffer
		err := runInit(context.Background(), initOptions{}, &out, &out)
		if err == nil || err.Error() != "The password was not accepted, so the screen was not set up; CYFR is set up in this directory. Run `cyfr screen on` here to set it up" {
			t.Fatalf("err = %v\n%s", err, out.String())
		}
		if fileExists(screenDir) || !fileExists(".env") || s.applied != nil || s.authenticated != 1 {
			t.Errorf("screen files %v, .env %v, applied %q, authenticated %d", fileExists(screenDir), fileExists(".env"), s.applied, s.authenticated)
		}
	})
	t.Run("out of the groups once the project is written", func(t *testing.T) {
		s, _ := initProjectOnScreen(t)
		stubLauncher(t, true, nil)
		// In the sudo group at the question, out of it by the screen step.
		groups := machine.groups
		machine.groups = func(ctx context.Context, account string) []string {
			if account != "" && fileExists(".env") {
				return s.member
			}
			return groups(ctx, account)
		}
		askInput = strings.NewReader("1\n")
		var out bytes.Buffer
		err := runInit(context.Background(), initOptions{}, &out, &out)
		want := "Your account, " + currentAccount(t) + ", is not in the sudo or admin group, so the screen was not set up; CYFR is set up in this directory. Whoever administers this machine can add your account to the sudo group; then run `cyfr screen on` here"
		if err == nil || err.Error() != want {
			t.Fatalf("err = %v, want %q\n%s", err, want, out.String())
		}
		if ending := "\n\n" + localEnding("http://localhost:4000") + setupLinkLine(t, "http://localhost:4000"); !strings.HasSuffix(out.String(), ending) {
			t.Errorf("init printed:\n%s\nwant it to end on:\n%s", out.String(), ending)
		}
		if fileExists(screenDir) || !fileExists(".env") || s.applied != nil || s.authenticated != 0 {
			t.Errorf("screen files %v, .env %v, applied %q, authenticated %d", fileExists(screenDir), fileExists(".env"), s.applied, s.authenticated)
		}
	})
}

// A no changes nothing as root, says so with the next step and is no
// failure; a failed sudo says to run it again.
func TestScreenOnDeclinedOrFailed(t *testing.T) {
	s := screenProject(t)
	askInput = strings.NewReader("no\n")
	var out bytes.Buffer
	if err := runScreenOn(context.Background(), &out); err != nil || s.applied != nil || !strings.HasSuffix(out.String(), "[no]: Nothing was installed. Run cyfr screen on again when you want to continue.\n") {
		t.Fatalf("err = %v, applied %v:\n%s", err, s.applied, out.String())
	}
	askInput = strings.NewReader("yes\n")
	s.applyErr = os.ErrPermission
	err := screenOn(context.Background(), true, &out)
	if err == nil || !strings.Contains(err.Error(), "run `cyfr screen on` again") || s.forgotten != 1 {
		t.Fatalf("err = %v, forgotten %d", err, s.forgotten)
	}
}

// The files name the account and the directory; the token
// stays in .env, which the shell reads itself; and the unit runs the
// session, which runs the launcher, both of which can run.
func TestScreenFilesAreFilledIn(t *testing.T) {
	screenProject(t)
	if err := writeScreenFiles("/home/alice/cyfr", "alice"); err != nil {
		t.Fatal(err)
	}
	launcher := read(t, filepath.Join(screenDir, "launcher.sh"))
	if !strings.Contains(launcher, "\n    /opt/cyfr/resources/cyfr screen app /home/alice/cyfr\n") || strings.Contains(launcher, "@") {
		t.Errorf("launcher:\n%s", launcher)
	}
	session := read(t, filepath.Join(screenDir, "session.sh"))
	if !strings.Contains(session, "\ndbus-run-session labwc -C /home/alice/cyfr/.cyfr/screen -s /home/alice/cyfr/.cyfr/screen/launcher.sh ") || strings.Contains(session, "@") {
		t.Errorf("session:\n%s", session)
	}
	for _, name := range []string{"launcher.sh", "session.sh"} {
		info, err := os.Stat(filepath.Join(screenDir, name))
		if err != nil || info.Mode().Perm() != 0o755 {
			t.Errorf("%s mode %v (%v)", name, info.Mode(), err)
		}
	}
	unit := read(t, filepath.Join(screenDir, "cyfr-screen.service"))
	for _, want := range []string{"User=alice\n", "WorkingDirectory=/home/alice/cyfr\n", "Conflicts=getty@tty1.service\n", "TTYPath=/dev/tty1\n", "PAMName=login\n", "StandardInput=tty\n", "Restart=always\n", "ExecStart=/home/alice/cyfr/.cyfr/screen/session.sh\n"} {
		if !strings.Contains(unit, want) {
			t.Errorf("the unit lacks %q:\n%s", want, unit)
		}
	}
	entries, err := os.ReadDir(screenDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.Contains(read(t, filepath.Join(screenDir, e.Name())), "the-token") {
			t.Errorf("%s holds the setup token", e.Name())
		}
	}
}

// Off leaves packages and profile, and needs nothing to be on: its first
// command cannot stop the rest.
func TestScreenOffRunsTheCommandsThroughOneSudo(t *testing.T) {
	s := screenProject(t)
	var out bytes.Buffer
	for range 2 {
		if err := screenOff(&out); err != nil {
			t.Fatal(err)
		}
	}
	if len(s.applied) != 2 || !slices.Equal(s.applied[0], screenGivenBack) || s.forgotten != 2 {
		t.Fatalf("applied %q, forgotten %d", s.applied, s.forgotten)
	}
}

// screenQuestion is init's screen question, as the terminal shows it.
const screenQuestion = "This machine has no desktop. Show CYFR on its screen?\n" +
	"  1. Yes. At power-on this screen shows CYFR full screen, with an on-screen keyboard.\n" +
	"  2. No. This screen keeps its login prompt, and you open CYFR from another machine.\n" +
	"Choose 1 or 2 [1]: "

// envWatch is a terminal's input that records whether .env exists when a
// question reads it.
type envWatch struct {
	in      io.Reader
	written bool
}

func (w *envWatch) Read(p []byte) (int, error) {
	w.written = w.written || fileExists(".env")
	return w.in.Read(p)
}

// On a machine with no desktop init asks first whether its screen shows
// CYFR, before anything is written, the first answer the default; once
// .env is written it runs what `screen on` runs, its question already
// answered, and its ending is the reboot's. The second answer, and the
// end of the input, leave the screen alone and end on the setup link.
func TestInitAsksForTheScreenBeforeWriting(t *testing.T) {
	for _, c := range []struct {
		name, input string
		screen      bool
	}{
		{"the default", "\n", true},
		{"one", "1\n", true},
		{"two", "2\n", false},
		{"the end of the input", "", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			s, _ := initProjectOnScreen(t)
			stubLauncher(t, true, nil)
			in := &envWatch{in: strings.NewReader(c.input)}
			askInput = in
			var out bytes.Buffer
			if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
				t.Fatalf("init: %v\n%s", err, out.String())
			}
			if !strings.HasPrefix(out.String(), screenQuestion) || in.written {
				t.Errorf("init did not ask first, before .env was written (written: %v):\n%s", in.written, out.String())
			}
			if strings.Contains(out.String(), "(yes/no)") {
				t.Errorf("init asked twice:\n%s", out.String())
			}
			ending := "\n\n" + localEnding("http://localhost:4000")
			if c.screen {
				ending += "Next: cyfr up, then sudo reboot.\nAt power-on this screen opens CYFR's setup page, which makes its first person's account with this box as its first device.\n"
			} else {
				ending += setupLinkLine(t, "http://localhost:4000")
			}
			if !strings.HasSuffix(out.String(), ending) {
				t.Errorf("init printed:\n%s\nwant it to end on:\n%s", out.String(), ending)
			}
			if installed := len(s.applied) == 1 && slices.Contains(s.applied[0], "systemctl enable cyfr-screen"); installed != c.screen || len(s.applied) > 1 {
				t.Errorf("applied %q, want the screen installed: %v", s.applied, c.screen)
			}
			if c.screen && !fileExists(filepath.Join(screenDir, "launcher.sh")) {
				t.Errorf("init did not write the screen's files")
			}
		})
	}
}

// A machine with a desktop, and --no-interactive, are asked nothing and
// keep their screen.
func TestInitLeavesTheScreenAloneOnADesktopOrWithoutATerminal(t *testing.T) {
	for name, set := range map[string]func(s *standIn){
		"a desktop":        func(s *standIn) { s.displayManager = true },
		"--no-interactive": func(*standIn) { askTerminal = func() bool { return false } },
	} {
		t.Run(name, func(t *testing.T) {
			s, _ := initProjectOnScreen(t)
			set(s)
			askInput = noInput{t}
			var out bytes.Buffer
			if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
				t.Fatalf("init: %v\n%s", err, out.String())
			}
			if strings.Contains(out.String(), "Show CYFR on its screen?") || s.applied != nil {
				t.Errorf("init asked for the screen, or applied %q:\n%s", s.applied, out.String())
			}
		})
	}
}

// An interrupt at the screen question ends init there, before it writes a
// file, takes the lock or runs anything: on a release build the question
// comes before the scaffold's download and --force's removals.
func TestInitScreenQuestionEndsOnAnInterrupt(t *testing.T) {
	for _, release := range []bool{false, true} {
		s, engine := initProjectOnScreen(t)
		o := initOptions{noPull: true}
		if release {
			savedVersion, savedDownload := version.Version, downloadScaffold
			t.Cleanup(func() { version.Version, downloadScaffold = savedVersion, savedDownload })
			version.Version = "0.6.0-alpha.1"
			downloadScaffold = func(string) error {
				t.Error("init downloaded the scaffold before its question was answered")
				return nil
			}
			o.force = true
		}
		in, asked := blockAfter(t)
		askInput = in
		var out bytes.Buffer
		err := interruptAt(t, asked, func(ctx context.Context) error { return runInit(ctx, o, &out, &out) })
		wantInterrupted(t, err, "Interrupted; nothing was written.")
		nothingWritten(t, ".env.example", "docker-compose.yml")
		if engine.locks != 0 || s.applied != nil {
			t.Errorf("the interrupted init took the lock %d times and applied %q", engine.locks, s.applied)
		}
	}
}

// A screen whose install fails leaves init's ending without it, and init
// says to run `cyfr screen on` again.
func TestInitEndsWithoutTheScreenWhenItsInstallFails(t *testing.T) {
	s, _ := initProjectOnScreen(t)
	stubLauncher(t, true, nil)
	s.applyErr = os.ErrPermission
	askInput = strings.NewReader("1\n")
	var out bytes.Buffer
	err := runInit(context.Background(), initOptions{noPull: true}, &out, &out)
	if err == nil || err.Error() != "Showing CYFR on this screen failed. Fix what is shown above, then run `cyfr screen on` again" {
		t.Fatalf("init answered %v\n%s", err, out.String())
	}
	if want := "\n\n" + localEnding("http://localhost:4000") + setupLinkLine(t, "http://localhost:4000"); !strings.HasSuffix(out.String(), want) {
		t.Errorf("init printed:\n%s\nwant it to end on:\n%s", out.String(), want)
	}
}

// The box's screen reads whether no one is set up from that container's log
// since its start, under the stack's lock, and brings the setup token on an
// added box's first hello only then: the boot's not-set-up line with no
// set-up line after it is open; a set-up line after it, a log with
// neither, one that cannot be read, or a lock another command holds is
// not.
func TestScreenSetupOpen_ReadsCyfrsLog(t *testing.T) {
	token := func(s localStack) string {
		dir, err := os.Getwd()
		if err != nil {
			t.Fatal(err)
		}
		local, err := readLocal(shell.NewWork(t.Context()), dir, "screen")
		if err != nil {
			t.Fatal(err)
		}
		got, _ := local.Shell.SetupToken(t.Context())
		return got
	}
	for _, c := range []struct {
		name, log, exit string
		want            bool
	}{
		{"no one set up", "booting\n" + logNotSetUp, "0", true},
		{"set up since the boot", logNotSetUp + logSetUp, "0", false},
		{"set up at the boot", "booting\n", "0", false},
		{"a log unread", logNotSetUp, "1", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := newLocalStack(t)
			s.env(4000)
			s.runs("c0ffee", s.project, nil, 4000)
			s.answer("logs.out", c.log)
			s.answer("logs.exit", c.exit)
			if got := token(s); (got == testToken) != c.want || (got != "" && got != testToken) {
				t.Errorf("token %q, want it %v", got, c.want)
			}
		})
	}
	s := newLocalStack(t)
	s.env(4000)
	s.runs("c0ffee", s.project, nil, 4000)
	e, err := openEngine(".")
	if err != nil {
		t.Fatal(err)
	}
	unlock, err := e.Lock("access tailnet")
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	if token(s) != "" {
		t.Error("setup read as open under a lock another command holds")
	}
}

// The screen's page says where the app's cyfr, which runs the shell, is
// another release than the one the folder is set to, with the instruction
// `cyfr update` gives a package's own cyfr (installPackage), which brings
// the app there whichever cyfr is on PATH; it says nothing where they
// agree or where either is no release.
func TestScreenSaysWhereTheAppIsAnotherRelease(t *testing.T) {
	dir := t.TempDir()
	compose := func(tag string) {
		body := "services:\n  cyfr:\n    image: ghcr.io/cyfrworks/cyfr:" + tag + "\n  locus-runtime:\n    image: ghcr.io/cyfrworks/cyfr-locus:" + tag + "\n"
		if err := os.WriteFile(filepath.Join(dir, "docker-compose.yml"), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	for _, c := range []struct{ folder, ours, want string }{
		{"0.6.0@sha256:" + strings.Repeat("a", 64), "0.6.0", ""},
		{"0.6.1@sha256:" + strings.Repeat("a", 64), "0.6.0", "This screen's CYFR app is release 0.6.0 and the CYFR in " + dir + " is set to release 0.6.1, so the screen may not work as it should. To bring the app to release 0.6.1, install the package cyfr-desktop of release 0.6.1 from " + releasesPage + "/tag/0.6.1."},
		{"latest", "0.6.0", ""},
		{"0.6.1", "dev", ""},
	} {
		compose(c.folder)
		if got := releaseApart(dir, c.ours); got != c.want {
			t.Errorf("the folder at %s, the app at %s: %q, want %q", c.folder, c.ours, got, c.want)
		}
	}
}

// The screen's launcher starts the app on the route its folder's CYFR
// takes, read at that start: a tailnet folder's proxy and resolver rules,
// none for another, and none for a folder that cannot be read: there the
// shell fails before it shows anything, the reason goes to the app's
// error stream, the app ends itself and the launcher tries again.
func TestTheScreensAppStartsOnItsFoldersRoute(t *testing.T) {
	for _, c := range []struct {
		name, env string
		route     []string
	}{
		{"tailnet", "CYFR_ACCESS=tailnet\nCYFR_HOST=box.tail1234.ts.net\nCYFR_PUBLIC_URL=https://box.tail1234.ts.net\nCYFR_TAILNET_NODE_ID=nAAAAAAAAACNTRL\nCYFR_PORT=4000\n",
			[]string{"--proxy-server=socks5://127.0.0.1:1055", "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1"}},
		{"local", "CYFR_ACCESS=local\nCYFR_PORT=4321\n", nil},
		{"public", "CYFR_ACCESS=public\nCYFR_HOST=cyfr.example.com\nCYFR_PUBLIC_URL=https://cyfr.example.com\nCYFR_PORT=4000\n", nil},
		{"unreadable", "", nil},
	} {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			if c.env != "" {
				if err := os.WriteFile(filepath.Join(dir, ".env"), []byte(c.env), 0o600); err != nil {
					t.Fatal(err)
				}
				if _, err := readFolder(dir); err != nil {
					t.Fatalf("the folder is not read: %v", err)
				}
			}
			want := append([]string{"/opt/cyfr/CYFR", "--screen-project=" + dir}, c.route...)
			if got := screenAppArgs(dir); !slices.Equal(got, want) {
				t.Fatalf("the app starts as %q, want %q", got, want)
			}
		})
	}
}

// `cyfr screen app` is the screen's launcher's alone: it resolves, and the
// screen's help lists it nowhere.
func TestTheScreensAppCommandIsHidden(t *testing.T) {
	found, rest, err := rootCmd.Find([]string{"screen", "app", "/home/alice/cyfr"})
	if err != nil || found != screenAppCmd || !slices.Equal(rest, []string{"/home/alice/cyfr"}) {
		t.Fatalf("cyfr screen app resolves to %v %q (%v)", found, rest, err)
	}
	out, err := runCommand(t, t.Context(), "screen", "--help")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "\n  off ") {
		t.Fatalf("the screen's help lists no commands:\n%s", out)
	}
	if strings.Contains(out, "\n  app ") {
		t.Fatalf("the screen's help lists cyfr screen app:\n%s", out)
	}
}
