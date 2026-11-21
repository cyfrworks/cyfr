// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package holdertest runs a disposable software TPM for the tests of the
// chip holder and of its callers.
package holdertest

import (
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// SWTPM is a disposable software TPM serving one test from its own state
// directory.
type SWTPM struct {
	bin, dir string
	env      []string
	cmd      *exec.Cmd
	done     chan struct{} // closed once cmd has exited and been waited for
}

// New finds swtpm, without starting it: CYFR_TEST_SWTPM names an unpacked
// swtpm binary (<root>/usr/bin/swtpm, its libraries under <root>/usr/lib);
// without it the swtpm on PATH runs, and without either the test skips,
// or fails under CYFR_TEST_SWTPM_REQUIRED, which CI sets so a lost install
// fails the job rather than skipping the chip tests unseen. The test's end
// kills it.
func New(t *testing.T) *SWTPM {
	t.Helper()
	s := &SWTPM{bin: os.Getenv("CYFR_TEST_SWTPM"), dir: t.TempDir(), env: os.Environ()}
	if s.bin != "" {
		if _, err := os.Stat(s.bin); err != nil {
			t.Fatalf("CYFR_TEST_SWTPM: %v", err)
		}
		root := filepath.Dir(filepath.Dir(filepath.Dir(s.bin)))
		libs, _ := filepath.Glob(filepath.Join(root, "usr", "lib", "*-linux-gnu"))
		var path []string
		for _, l := range libs {
			path = append(path, l, filepath.Join(l, "swtpm"))
		}
		s.env = append(s.env, "LD_LIBRARY_PATH="+strings.Join(path, ":"))
	} else if p, err := exec.LookPath("swtpm"); err == nil {
		s.bin = p
	} else if os.Getenv("CYFR_TEST_SWTPM_REQUIRED") != "" {
		t.Fatal("swtpm is not installed, and CYFR_TEST_SWTPM_REQUIRED says the chip tests must run")
	} else {
		t.Skip("swtpm is not installed: the chip holder is unproven here")
	}
	t.Cleanup(func() {
		if s.cmd != nil {
			_ = s.cmd.Process.Kill()
			<-s.done
		}
	})
	return s
}

// Sock is the TPM's socket.
func (s *SWTPM) Sock() string { return filepath.Join(s.dir, "s") }

// Log is what swtpm wrote.
func (s *SWTPM) Log() string {
	b, _ := os.ReadFile(filepath.Join(s.dir, "log"))
	return string(b)
}

// Start runs swtpm on the state directory and waits until its socket
// accepts a connection.
func (s *SWTPM) Start(t *testing.T) {
	t.Helper()
	_ = os.Remove(s.Sock())
	log, err := os.OpenFile(filepath.Join(s.dir, "log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	s.cmd = exec.Command(s.bin, "socket", "--tpm2", "--tpmstate", "dir="+s.dir,
		"--server", "type=unixio,path="+s.Sock(), "--ctrl", "type=unixio,path="+filepath.Join(s.dir, "c"),
		"--flags", "not-need-init,startup-clear")
	s.cmd.Env, s.cmd.Stdout, s.cmd.Stderr = s.env, log, log
	if err := s.cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done, cmd := make(chan struct{}), s.cmd
	s.done = done
	go func() { _ = cmd.Wait(); close(done) }()
	deadline := time.Now().Add(10 * time.Second)
	for {
		if c, err := net.Dial("unix", s.Sock()); err == nil {
			c.Close()
			return
		}
		select {
		case <-done:
			t.Fatalf("swtpm exited before it listened:\n%s", s.Log())
		case <-time.After(10 * time.Millisecond): // sleep-ok: polls the socket swtpm opens, bounded by deadline
		}
		if time.Now().After(deadline) {
			t.Fatalf("swtpm did not listen within 10 s:\n%s", s.Log())
		}
	}
}

// Stop ends swtpm with SIGTERM, killing one slow to act on it: its state
// is what an orderly TPM shutdown before it wrote.
func (s *SWTPM) Stop(t *testing.T) {
	t.Helper()
	_ = s.cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-s.done:
	case <-time.After(10 * time.Second):
		_ = s.cmd.Process.Kill()
		select {
		case <-s.done:
		case <-time.After(10 * time.Second):
			t.Fatalf("swtpm did not stop on SIGTERM or SIGKILL:\n%s", s.Log())
		}
	}
}
