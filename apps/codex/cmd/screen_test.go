// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"bytes"
	"context"
	"io"
	"os"
	"os/user"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/version"
)

// screenProject is a project directory on a machine that can show it.
func screenProject(t *testing.T) *standIn {
	t.Helper()
	s := standInMachine(t)
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)
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
		"install -m 0644 " + files + "/52cyfr-screen " + screenAptLine,
		"install -D -m 0644 " + files + "/cyfr-screen-policy.json " + screenPolicy,
		"install -m 0644 " + files + "/cyfr-screen.service " + screenUnit,
		"systemctl daemon-reload",
		"systemctl disable getty@tty1",
		"systemctl enable cyfr-screen",
	}, tail...)
}

// `cyfr screen on` shows the plain commands, asks once and runs them
// through one sudo, starting nothing, then forgets the login and says what
// is next; Chrome's download says what it fetches and shows curl's
// progress bar; packages it has are not installed again, and with none to
// install it reads no package lists.
func TestScreenOnRunsTheCommandsThroughOneSudo(t *testing.T) {
	s := screenProject(t)
	askInput = strings.NewReader("yes\n")
	dir, _ := os.Getwd()
	var out bytes.Buffer
	screenOnCmd.SetContext(context.Background())
	screenOnCmd.SetOut(&out)
	t.Cleanup(func() { screenOnCmd.SetContext(nil); screenOnCmd.SetOut(nil) })
	if err := screenOnCmd.RunE(screenOnCmd, nil); err != nil {
		t.Fatalf("%v\n%s", err, out.String())
	}
	want := append([]string{
		"apt-get update",
		"apt-get install -y --no-install-recommends labwc wvkbd swayidle",
		"deb=$(mktemp --suffix=.deb)",
		"echo 'Downloading Chrome from Google (about 110 MB)'",
		`curl -fL --progress-bar -o "$deb" ` + chromeDeb,
		`apt-get install -y "$deb"`,
		`rm -f "$deb"`,
	}, screenCommandsIn(dir)...)
	if len(s.applied) != 1 || !slices.Equal(s.applied[0], want) {
		t.Fatalf("applied %q, want one %q", s.applied, want)
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
	s.installed = []string{"labwc", "wvkbd", "swayidle", "google-chrome-stable"}
	askInput = strings.NewReader("yes\n")
	if err := screenOn(context.Background(), true, &out); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(s.applied[0], screenCommandsIn(dir)) {
		t.Errorf("applied %q", s.applied)
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
		"arm64":           {func(s *standIn) { s.arch = "arm64" }, "`cyfr screen` runs at a terminal on Ubuntu 26.04 LTS on amd64"},
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

// The files name this program, the account and the directory; the token
// stays in .env, which the shell reads itself; and the launcher can run.
func TestScreenFilesAreFilledIn(t *testing.T) {
	screenProject(t)
	if err := writeScreenFiles("/home/alice/cyfr", "alice"); err != nil {
		t.Fatal(err)
	}
	self, _ := os.Executable()
	launcher := read(t, filepath.Join(screenDir, "launcher.sh"))
	if !strings.Contains(launcher, "\n    "+self+" screen shell\n") || strings.Contains(launcher, "@") {
		t.Errorf("launcher:\n%s", launcher)
	}
	info, err := os.Stat(filepath.Join(screenDir, "launcher.sh"))
	if err != nil || info.Mode().Perm() != 0o755 {
		t.Errorf("launcher mode %v (%v)", info.Mode(), err)
	}
	unit := read(t, filepath.Join(screenDir, "cyfr-screen.service"))
	for _, want := range []string{"User=alice\n", "WorkingDirectory=/home/alice/cyfr\n", "Conflicts=getty@tty1.service\n", "TTYPath=/dev/tty1\n", "PAMName=login\n", "StandardInput=tty\n", "Restart=always\n", "-s /home/alice/cyfr/.cyfr/screen/launcher.sh\n"} {
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
	want := []string{
		"{ systemctl disable --now cyfr-screen || true; }",
		"rm -f " + screenUnit + " " + screenAptLine + " " + screenPolicy,
		"systemctl daemon-reload",
		"systemctl enable --now getty@tty1",
	}
	if len(s.applied) != 2 || !slices.Equal(s.applied[0], want) || s.forgotten != 2 {
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
				ending += "Next: cyfr up, then sudo reboot.\nAt power-on this screen opens CYFR's setup page, which sets up its first person with a passkey.\n"
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

// After a change of address, `cyfr access` rewrites the files of a screen
// the project has for the new head, so the screen opens the new address
// with no `cyfr screen on`, and a project with no screen gets none.
func TestAccessRewritesTheScreensFiles(t *testing.T) {
	for _, screen := range []bool{true, false} {
		s := newAccessProject(t)
		dir, err := filepath.EvalSymlinks(".")
		if err != nil {
			t.Fatal(err)
		}
		t.Chdir(dir)
		s.addressChanges = []string{"Every browser signs in again."}
		if screen {
			if err := writeScreenFiles(dir, "alice"); err != nil {
				t.Fatal(err)
			}
		}
		var out bytes.Buffer
		if err := runAccess(context.Background(), access.ModePublic, accessOptions{domain: "cyfr.example.com"}, true, "", &out); err != nil {
			t.Fatalf("cyfr access public: %v\n%s", err, out.String())
		}
		if !screen {
			if fileExists(screenDir) {
				t.Errorf("cyfr access wrote %s into a project with no screen", screenDir)
			}
			continue
		}
		if launcher := read(t, filepath.Join(screenDir, "launcher.sh")); !strings.Contains(launcher, " screen shell\n") {
			t.Errorf("the launcher was not rewritten:\n%s", launcher)
		}
	}
}
