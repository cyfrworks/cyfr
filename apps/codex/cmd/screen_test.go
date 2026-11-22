// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"bytes"
	"context"
	"io"
	"maps"
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
		machine.groups = func(account string) []string {
			if account != "" && fileExists(".env") {
				return s.member
			}
			return groups(account)
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

// The files name this program, the account and the directory; the token
// stays in .env, which the shell reads itself; and the unit runs the
// session, which runs the launcher, both of which can run.
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

// After a change of address, `cyfr access` rewrites the files of a screen
// the project has for the new head, so the screen opens the new address
// with no `cyfr screen on`, and a project with no screen gets none.
func TestAccessRewritesTheScreensFiles(t *testing.T) {
	for _, screen := range []bool{true, false} {
		standInMachine(t)
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
		if err := runAccess(context.Background(), access.ModePublic, accessOptions{domain: "cyfr.example.com"}, true, &out); err != nil {
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

// The box's screen reads whether no one is set up from cyfr's log since
// its start, under the stack's lock as cyfr setup does, and brings the
// setup token on an added box's first hello only then: the boot's
// not-set-up line with no set-up line after it is open; a set-up line
// after it, a log with neither, one that cannot be read, or a lock another
// command holds is not.
func TestScreenSetupOpen_ReadsCyfrsLog(t *testing.T) {
	const notSetUp = "[Cyfr] Not set up: no one is set up on this CYFR yet.\n"
	const setUp = "[Cyfr] Set up: this CYFR has its first person.\n"
	for _, c := range []struct {
		name, log, exit string
		want            bool
	}{
		{"no one set up", "booting\n" + notSetUp, "0", true},
		{"set up since the boot", notSetUp + setUp, "0", false},
		{"set up at the boot", "booting\n", "0", false},
		{"a log unread", notSetUp, "1", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			standInMachine(t)
			s := newUpdateScenario(t, shippedCompose(t), nil)
			dockerStandIn(t, s.fake)
			s.answer("ps.out", "c0ffee\n")
			s.answer("inspect.out", "2026-10-28T00:01:02.123456789Z\n")
			s.answer("logs.out", c.log)
			s.answer("logs.exit", c.exit)
			if got := localSetupOpen(t.Context(), ".", "screen"); got != c.want {
				t.Errorf("setup open %v, want %v", got, c.want)
			}
		})
	}
	standInMachine(t)
	s := newUpdateScenario(t, shippedCompose(t), nil)
	dockerStandIn(t, s.fake)
	s.answer("ps.out", "c0ffee\n")
	s.answer("inspect.out", "2026-10-28T00:01:02.123456789Z\n")
	s.answer("logs.out", "booting\n"+notSetUp)
	s.answer("logs.exit", "0")
	e, err := openEngine(".")
	if err != nil {
		t.Fatal(err)
	}
	unlock, err := e.Lock("access tailnet")
	if err != nil {
		t.Fatal(err)
	}
	if localSetupOpen(t.Context(), ".", "screen") {
		t.Error("setup read as open under a lock another command holds")
	}
	unlock()
	if local, err := readLocal(".", "screen"); err != nil || local.Shell.SetupOpen == nil {
		t.Error("the screen's shell does not read whether setup is open")
	}
}
