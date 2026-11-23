// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"os"
	"os/exec"
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
