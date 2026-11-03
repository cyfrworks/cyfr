// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package holder

import (
	"os"
	"os/exec"
	"strings"
	"testing"

	"golang.org/x/sys/unix"
)

// TestHardenProcess runs in a child process: an unprivileged process cannot
// raise its core-dump hard limit again.
func TestHardenProcess(t *testing.T) {
	if os.Getenv("CYFR_HOLDER_HARDEN_CHILD") != "1" {
		cmd := exec.Command(os.Args[0], "-test.run=^TestHardenProcess$", "-test.v")
		cmd.Env = append(os.Environ(), "CYFR_HOLDER_HARDEN_CHILD=1")
		out, err := cmd.CombinedOutput()
		if err != nil || !strings.Contains(string(out), "--- PASS: TestHardenProcess") {
			t.Fatalf("child: %v\n%s", err, out)
		}
		return
	}
	if d, _ := unix.PrctlRetInt(unix.PR_GET_DUMPABLE, 0, 0, 0, 0); d != 1 {
		t.Fatalf("the process starts not dumpable (%d); this test would prove nothing", d)
	}
	if err := HardenProcess(); err != nil {
		t.Fatal(err)
	}
	var lim unix.Rlimit
	if err := unix.Getrlimit(unix.RLIMIT_CORE, &lim); err != nil {
		t.Fatal(err)
	}
	if lim.Cur != 0 || lim.Max != 0 {
		t.Fatalf("RLIMIT_CORE = %+v, want 0/0", lim)
	}
	if d, err := unix.PrctlRetInt(unix.PR_GET_DUMPABLE, 0, 0, 0, 0); err != nil || d != 0 {
		t.Fatalf("PR_GET_DUMPABLE = %d, %v; want 0", d, err)
	}
}
