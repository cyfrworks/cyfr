// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/access"
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
	return append([]string{
		"install -m 0644 " + files + "/52cyfr-screen " + screenAptLine,
		"install -m 0644 " + files + "/cyfr-screen.service " + screenUnit,
		"systemctl daemon-reload",
		"systemctl disable getty@tty1",
		"systemctl enable cyfr-screen",
	}, tail...)
}

// `cyfr screen on` shows the plain commands, asks once and runs them
// through one sudo, starting nothing, then forgets the login and says what
// is next; packages it has are not installed again, and with none to
// install it reads no package lists.
func TestScreenOnRunsTheCommandsThroughOneSudo(t *testing.T) {
	s := screenProject(t)
	askInput = strings.NewReader("yes\n")
	dir, _ := os.Getwd()
	var out bytes.Buffer
	if err := screenOn(context.Background(), true, &out); err != nil {
		t.Fatalf("%v\n%s", err, out.String())
	}
	want := append([]string{
		"apt-get update",
		"apt-get install -y --no-install-recommends labwc wvkbd",
		"deb=$(mktemp --suffix=.deb)",
		`curl -fsSL -o "$deb" ` + chromeDeb,
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
	s.installed = []string{"labwc", "wvkbd", "google-chrome-stable"}
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

// A no changes nothing as root, and a failed sudo says to run it again.
func TestScreenOnDeclinedOrFailed(t *testing.T) {
	s := screenProject(t)
	askInput = strings.NewReader("no\n")
	var out bytes.Buffer
	if err := screenOn(context.Background(), true, &out); err == nil || s.applied != nil {
		t.Fatalf("err = %v, applied %v", err, s.applied)
	}
	askInput = strings.NewReader("yes\n")
	s.applyErr = os.ErrPermission
	err := screenOn(context.Background(), true, &out)
	if err == nil || !strings.Contains(err.Error(), "run `cyfr screen on` again") || s.forgotten != 1 {
		t.Fatalf("err = %v, forgotten %d", err, s.forgotten)
	}
}

// The files carry the address, the account and the directory; the token
// stays in .env; the launcher can run; and tailnet access goes through the
// proxy, local access does not.
func TestScreenFilesAreFilledIn(t *testing.T) {
	screenProject(t)
	if err := writeScreenFiles(access.Head{Mode: access.ModeLocal, Port: 4321}, "/home/alice/cyfr", "alice"); err != nil {
		t.Fatal(err)
	}
	launcher := read(t, filepath.Join(screenDir, "launcher.sh"))
	if !strings.Contains(launcher, "http://localhost:4321/setup#") || !strings.Contains(launcher, "http://127.0.0.1:4321/") || strings.Contains(launcher, "socks5") || strings.Contains(launcher, "@PORT@") {
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
	if got := read(t, filepath.Join(screenDir, "waiting.html")); !strings.Contains(got, "Run <code>cyfr up</code> in /home/alice/cyfr to start it.") {
		t.Errorf("waiting page:\n%s", got)
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

	if err := writeScreenFiles(access.Head{Mode: access.ModeTailnet, Port: 4321, PublicURL: "https://m.t.ts.net"}, "/home/alice/cyfr", "alice"); err != nil {
		t.Fatal(err)
	}
	launcher = read(t, filepath.Join(screenDir, "launcher.sh"))
	if !strings.Contains(launcher, `set -- --proxy-server=socks5://127.0.0.1:1055 "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1"`) || !strings.Contains(launcher, "https://m.t.ts.net/setup#") {
		t.Errorf("tailnet launcher:\n%s", launcher)
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
		"rm -f " + screenUnit + " " + screenAptLine,
		"systemctl daemon-reload",
		"systemctl enable --now getty@tty1",
	}
	if len(s.applied) != 2 || !slices.Equal(s.applied[0], want) || s.forgotten != 2 {
		t.Fatalf("applied %q, forgotten %d", s.applied, s.forgotten)
	}
}

// Init offers the screen on a machine that can show it. The default, and
// a machine with a desktop, leave it alone; the first choice runs what
// `screen on` runs, its question already answered.
func TestInitOffersTheScreen(t *testing.T) {
	t.Run("the default", func(t *testing.T) {
		s := screenProject(t)
		askInput = strings.NewReader("\n")
		var out bytes.Buffer
		if err := offerScreen(context.Background(), &out); err != nil || s.applied != nil {
			t.Fatalf("err = %v, applied %v", err, s.applied)
		}
		for _, want := range []string{"Show CYFR on this machine's own screen?", "1. With its own screen", "2. Without a screen"} {
			if !strings.Contains(out.String(), want) {
				t.Errorf("the offer lacks %q:\n%s", want, out.String())
			}
		}
	})
	t.Run("with its own screen", func(t *testing.T) {
		s := screenProject(t)
		askInput = strings.NewReader("1\n")
		var out bytes.Buffer
		if err := offerScreen(context.Background(), &out); err != nil || len(s.applied) != 1 {
			t.Fatalf("err = %v, applied %v", err, s.applied)
		}
		if strings.Contains(out.String(), "(yes/no)") {
			t.Errorf("init asked twice:\n%s", out.String())
		}
	})
	t.Run("a desktop", func(t *testing.T) {
		s := screenProject(t)
		s.displayManager = true
		var out bytes.Buffer
		if err := offerScreen(context.Background(), &out); err != nil || out.Len() != 0 {
			t.Fatalf("err = %v, out %q", err, out.String())
		}
	})
}
