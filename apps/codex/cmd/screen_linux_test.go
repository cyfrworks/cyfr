// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The screen's session ends its login session whenever it ends, which is
// what stops every process of the screen: at the stop's SIGTERM, with the
// compositor still running, and when the compositor ends by itself. It
// asks no password either way, and exits 0, so a stop leaves the service
// stopped and Restart= starts it again only after the compositor's own end.
// A refused end is said in the journal through logger, and nothing on
// standard error, and exits 1, so the service shows it failed.
func TestScreenSessionEndsItsLoginSession(t *testing.T) {
	const stays = "echo $$ >\"$BIN/compositor\"\nexec sleep 60"
	const refused = "-t cyfr-screen -p user.err loginctl could not end the screen's login session, so its processes, the CYFR app among them, still run\n"
	for _, c := range []struct {
		name, compositor, loginctl string
		stop                       bool
		status                     int
		said, logged               string
	}{
		{"at the stop", stays, "", true, 0, "", ""},
		{"when the compositor ends by itself", "exit 3", "", false, 0, "", ""},
		{"refused, at the stop", stays, "echo 'Failed to terminate session: Access denied' >&2\nexit 1", true, 1,
			"Failed to terminate session: Access denied\n", refused},
		{"refused, when the compositor ends by itself", "exit 3", "exit 1", false, 1, "", refused},
	} {
		t.Run(c.name, func(t *testing.T) {
			screenProject(t)
			if err := writeScreenFiles("/home/alice/cyfr", "alice"); err != nil {
				t.Fatal(err)
			}
			bin := t.TempDir()
			for name, body := range map[string]string{
				"dbus-run-session": "#!/bin/sh\necho \"$*\" >\"$BIN/compositor-args\"\n" + c.compositor + "\n",
				"loginctl":         "#!/bin/sh\necho \"$*\" >>\"$BIN/loginctl.ran\"\n" + c.loginctl + "\n",
				"logger":           "#!/bin/sh\necho \"$*\" >>\"$BIN/logger.ran\"\n",
			} {
				if err := os.WriteFile(filepath.Join(bin, name), []byte(body), 0o755); err != nil {
					t.Fatal(err)
				}
			}
			session := exec.Command("/bin/sh", filepath.Join(screenDir, "session.sh"))
			session.Env = []string{"PATH=" + bin + ":/usr/bin:/bin", "BIN=" + bin}
			// A file, not a pipe: the compositor stand-in that outlives the
			// session holds its standard error.
			said, err := os.Create(filepath.Join(bin, "said"))
			if err != nil {
				t.Fatal(err)
			}
			defer said.Close()
			session.Stderr = said
			if err := session.Start(); err != nil {
				t.Fatal(err)
			}
			ended := make(chan error, 1)
			go func() { ended <- session.Wait() }()
			if c.stop {
				compositor := filepath.Join(bin, "compositor")
				deadline := time.Now().Add(10 * time.Second)
				for !fileExists(compositor) {
					if time.Now().After(deadline) {
						_ = session.Process.Kill()
						t.Fatal("the compositor did not start")
					}
					time.Sleep(10 * time.Millisecond)
				}
				t.Cleanup(func() {
					if pid, err := strconv.Atoi(strings.TrimSpace(read(t, compositor))); err == nil {
						_ = syscall.Kill(pid, syscall.SIGKILL)
					}
				})
				if err := session.Process.Signal(syscall.SIGTERM); err != nil {
					t.Fatal(err)
				}
			}
			select {
			case <-ended:
				if got := session.ProcessState.ExitCode(); got != c.status {
					t.Errorf("the session exited %d (%v), want %d", got, session.ProcessState, c.status)
				}
			case <-time.After(10 * time.Second):
				_ = session.Process.Kill()
				t.Fatal("the session did not end")
			}
			if got, want := read(t, filepath.Join(bin, "compositor-args")), "labwc -C /home/alice/cyfr/.cyfr/screen -s /home/alice/cyfr/.cyfr/screen/launcher.sh\n"; got != want {
				t.Errorf("the compositor ran as %q, want %q", got, want)
			}
			if got, want := read(t, filepath.Join(bin, "loginctl.ran")), "--no-ask-password terminate-session self\n"; got != want {
				t.Errorf("loginctl ran as %q, want %q", got, want)
			}
			if got := read(t, said.Name()); got != c.said {
				t.Errorf("the session said %q on standard error, want %q", got, c.said)
			}
			if got, _ := os.ReadFile(filepath.Join(bin, "logger.ran")); string(got) != c.logged {
				t.Errorf("logger ran as %q, want %q", got, c.logged)
			}
		})
	}
}

// Root installs only the package cyfr checked: the commands copy the
// account's file where the account cannot write and check the copy
// against the sum the release's signed checksums named before apt is
// handed it, so a file changed after the fetch is never installed. What
// root staged is gone on every way out, and a copy, a check or an apt
// that fails, or an interrupt, ends the commands before anything of the
// screen is installed. Run here as written, as this account, the
// programs that change the machine stand-ins.
func TestScreenOnInstallsOnlyThePackageItChecked(t *testing.T) {
	const after = "apt-get install -y --no-install-recommends labwc wvkbd swayidle\ngetent group tss\nthe unit\n" +
		"systemctl daemon-reload\nsystemctl disable getty@tty1\nsystemctl enable cyfr-screen\n"
	for _, c := range []struct {
		name, body, apt, ran string
		installed            bool
	}{
		{"the package fetched", "the app", "", "apt-get update\napt-get install the app\n" + after, true},
		{"a package put in its place", "another program", "", "apt-get update\n", false},
		{"a copy that fails", "", "", "apt-get update\n", false},
		{"apt refusing the package", "the app", "exit 100", "apt-get update\napt-get install the app\n", false},
		{"an interrupt during apt", "the app", "kill -INT $PPID; sleep 1; exit 130", "apt-get update\napt-get install the app\n", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			standInMachine(t)
			dir, bin, staged := t.TempDir(), t.TempDir(), t.TempDir()
			if err := os.MkdirAll(filepath.Join(dir, screenDir), 0o700); err != nil {
				t.Fatal(err)
			}
			sum := sha256.Sum256([]byte("the app"))
			if c.body != "" {
				if err := os.WriteFile(filepath.Join(dir, screenAppFile), []byte(c.body), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			for name, body := range map[string]string{
				"apt-get": "case \"$3\" in\n*.deb) cat \"$3\" >\"$BIN/handed\"; echo 'apt-get install the app' >>\"$BIN/ran\"; " + c.apt + " ;;\n" +
					"*) echo \"apt-get $*\" >>\"$BIN/ran\" ;;\nesac",
				"getent":    "echo \"getent $*\" >>\"$BIN/ran\"; exit 2",
				"systemctl": "echo \"systemctl $*\" >>\"$BIN/ran\"",
				// The service's unit is not written into /etc here.
				"install": "case \"$4\" in /etc/*) echo 'the unit' >>\"$BIN/ran\"; exit 0 ;; esac\nexec /usr/bin/install \"$@\"",
			} {
				if err := os.WriteFile(filepath.Join(bin, name), []byte("#!/bin/sh\n"+body+"\n"), 0o700); err != nil {
					t.Fatal(err)
				}
			}
			commands := screenCommands(dir, "alice", hex.EncodeToString(sum[:]))
			sh := exec.Command("/bin/sh", "-c", strings.Join(commands, " && "))
			sh.Env = append(os.Environ(), "PATH="+bin+":/usr/bin:/bin", "BIN="+bin, "TMPDIR="+staged)
			said, err := sh.CombinedOutput()
			if (err == nil) != c.installed {
				t.Errorf("the commands ended with %v, want installed %v:\n%s", err, c.installed, said)
			}
			if got := read(t, filepath.Join(bin, "ran")); got != c.ran {
				t.Errorf("ran:\n%s\nwant:\n%s", got, c.ran)
			}
			if got, _ := os.ReadFile(filepath.Join(bin, "handed")); c.body == "another program" && got != nil || c.apt == "" && c.installed && string(got) != "the app" {
				t.Errorf("apt was handed %q", got)
			}
			if left, _ := os.ReadDir(staged); len(left) != 0 {
				t.Errorf("root's staging left %v", left)
			}
		})
	}
}

// TestScreenEndParentHelper is a process and its child for
// TestScreenEndParent: as "parent" it runs itself again as "child" and
// ends when it does, unless ended before; as "child" it ends its parent
// where its parent is CYFR_SCREEN_END_PROGRAM, writing first's mark and
// what it answered beside it.
func TestScreenEndParentHelper(t *testing.T) {
	dir := os.Getenv("CYFR_SCREEN_END_DIR")
	switch os.Getenv("CYFR_SCREEN_END_ROLE") {
	case "parent":
		child := exec.Command(os.Args[0], "-test.run=^TestScreenEndParentHelper$")
		child.Env = append(os.Environ(), "CYFR_SCREEN_END_ROLE=child")
		_ = child.Run()
	case "child":
		err := screenEndParent(os.Getenv("CYFR_SCREEN_END_PROGRAM"), func() {
			_ = os.WriteFile(filepath.Join(dir, "first"), nil, 0o600)
		})
		answer := "ended"
		if err != nil {
			answer = err.Error()
		}
		_ = os.WriteFile(filepath.Join(dir, "answer"), []byte(answer), 0o600)
	default:
		t.Skip("run by TestScreenEndParent")
	}
}

// The shell ends its parent by the kernel only where that parent is the
// installed app's program, and runs first before; any other parent goes
// on, nothing run, and the answer says what the parent was.
func TestScreenEndParent(t *testing.T) {
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name, program string
		ended         bool
	}{
		{"its parent is the program", self, true},
		{"its parent is another", "/opt/cyfr/CYFR", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			parent := exec.Command(os.Args[0], "-test.run=^TestScreenEndParentHelper$")
			parent.Env = append(os.Environ(), "CYFR_SCREEN_END_ROLE=parent", "CYFR_SCREEN_END_DIR="+dir, "CYFR_SCREEN_END_PROGRAM="+c.program)
			began := time.Now()
			err := parent.Run()
			// The child answers after its parent's end.
			var answer []byte
			for deadline := time.Now().Add(10 * time.Second); len(answer) == 0 && time.Now().Before(deadline); {
				answer, _ = os.ReadFile(filepath.Join(dir, "answer"))
				time.Sleep(10 * time.Millisecond) // sleep-ok: polls the child's answer, bounded
			}
			_, firstErr := os.Stat(filepath.Join(dir, "first"))
			status, _ := parent.ProcessState.Sys().(syscall.WaitStatus)
			killed := status.Signaled() && status.Signal() == syscall.SIGKILL
			if killed != c.ended || (firstErr == nil) != c.ended {
				t.Fatalf("the parent ended by SIGKILL: %v (%v, after %v), first ran: %v, the child answered %q", killed, err, time.Since(began), firstErr == nil, answer)
			}
			if c.ended && string(answer) != "ended" {
				t.Fatalf("the child answered %q", answer)
			}
			if !c.ended && !strings.Contains(string(answer), "not the installed app") {
				t.Fatalf("the child answered %q", answer)
			}
		})
	}
}

// TestEndScreenAppHelper is a process and its child for
// TestEndScreenAppWaitsOnNoReader: as "parent" it starts itself again as
// "child" with a standard error it has filled and never reads, as the
// stuck app holds the shell's, and waits for it; as "child" it carries out
// an unconfirmed hide (endScreenApp) on its parent, then says when.
func TestEndScreenAppHelper(t *testing.T) {
	dir := os.Getenv("CYFR_END_APP_DIR")
	switch os.Getenv("CYFR_END_APP_ROLE") {
	case "parent":
		var p [2]int
		if err := syscall.Pipe2(p[:], syscall.O_NONBLOCK|syscall.O_CLOEXEC); err != nil {
			t.Fatal(err)
		}
		for {
			if _, err := syscall.Write(p[1], make([]byte, 4096)); err != nil {
				break
			}
		}
		if err := syscall.SetNonblock(p[1], false); err != nil {
			t.Fatal(err)
		}
		child := exec.Command(os.Args[0], "-test.run=^TestEndScreenAppHelper$")
		child.Env = append(os.Environ(), "CYFR_END_APP_ROLE=child")
		child.Stderr = os.NewFile(uintptr(p[1]), "full")
		_ = child.Start()
		_ = child.Wait()
	case "child":
		// As the shell does, through its writer to main (desktop.NewWriter):
		// a write to a pipe nobody reads is an error, not this process's end.
		signal.Ignore(syscall.SIGPIPE)
		ln, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		screenLog = filepath.Join(dir, "log")
		self, _ := os.Executable()
		began := time.Now()
		endScreenApp(self, ln, errors.New("the compositor still shows 1 of the 1 windows"))
		_ = os.WriteFile(filepath.Join(dir, "said"), []byte(time.Since(began).String()), 0o600)
	default:
		t.Skip("run by TestEndScreenAppWaitsOnNoReader")
	}
}

// An unconfirmed hide is carried out whatever the stuck app leaves unread:
// with the shell's standard error full and never read, and the system's
// log read by nobody, the parent is ended at once, and what is said is
// said after, within its own bound.
func TestEndScreenAppWaitsOnNoReader(t *testing.T) {
	dir := t.TempDir()
	logged, err := net.ListenUnixgram("unixgram", &net.UnixAddr{Name: filepath.Join(dir, "log"), Net: "unixgram"})
	if err != nil {
		t.Fatal(err)
	}
	defer logged.Close()
	parent := exec.Command(os.Args[0], "-test.run=^TestEndScreenAppHelper$")
	parent.Env = append(os.Environ(), "CYFR_END_APP_ROLE=parent", "CYFR_END_APP_DIR="+dir)
	if err := parent.Start(); err != nil {
		t.Fatal(err)
	}
	ended := make(chan error, 1)
	go func() { ended <- parent.Wait() }()
	select {
	case <-ended:
	case <-time.After(5 * time.Second):
		_ = parent.Process.Kill()
		t.Fatal("the parent was not ended: the end waited on a reader")
	}
	status, _ := parent.ProcessState.Sys().(syscall.WaitStatus)
	if !status.Signaled() || status.Signal() != syscall.SIGKILL {
		t.Fatalf("the parent ended as %v, not by SIGKILL", parent.ProcessState)
	}
	var said []byte
	for deadline := time.Now().Add(5 * time.Second); len(said) == 0 && time.Now().Before(deadline); {
		said, _ = os.ReadFile(filepath.Join(dir, "said"))
		time.Sleep(10 * time.Millisecond) // sleep-ok: polls the child's answer, bounded
	}
	if len(said) == 0 {
		t.Fatal("the child never finished saying why")
	}
	buf := make([]byte, 4096)
	_ = logged.SetReadDeadline(time.Now().Add(time.Second))
	n, err := logged.Read(buf)
	if err != nil || !strings.Contains(string(buf[:n]), "cyfr-screen[") || !strings.Contains(string(buf[:n]), "was ended from outside") {
		t.Fatalf("the system's log got %q (%v)", buf[:n], err)
	}
}
