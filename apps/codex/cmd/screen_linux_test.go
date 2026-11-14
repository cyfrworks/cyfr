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
func TestScreenSessionEndsItsLoginSession(t *testing.T) {
	for _, c := range []struct {
		name, compositor string
		stop             bool
	}{
		{"at the stop", "echo $$ >\"$BIN/compositor\"\nexec sleep 60", true},
		{"when the compositor ends by itself", "exit 3", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			screenProject(t)
			if err := writeScreenFiles("/home/alice/cyfr", "alice"); err != nil {
				t.Fatal(err)
			}
			bin := t.TempDir()
			for name, body := range map[string]string{
				"dbus-run-session": "#!/bin/sh\necho \"$*\" >\"$BIN/compositor-args\"\n" + c.compositor + "\n",
				"loginctl":         "#!/bin/sh\necho \"$*\" >>\"$BIN/loginctl.ran\"\n",
			} {
				if err := os.WriteFile(filepath.Join(bin, name), []byte(body), 0o755); err != nil {
					t.Fatal(err)
				}
			}
			session := exec.Command("/bin/sh", filepath.Join(screenDir, "session.sh"))
			session.Env = []string{"PATH=" + bin + ":/usr/bin:/bin", "BIN=" + bin}
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
			case err := <-ended:
				if err != nil {
					t.Fatalf("the session exited %v, want 0", err)
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
		})
	}
}
