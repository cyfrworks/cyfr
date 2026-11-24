// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// The lock the first update makes is readable by every account, whatever
// that account's umask: a lock only another account can read refuses
// every other update on the computer.
func TestTheUpdateLockIsReadableByEveryAccount(t *testing.T) {
	saved := updateLockPath
	t.Cleanup(func() { updateLockPath = saved })
	updateLockPath = filepath.Join(t.TempDir(), "cyfr-update.lock")
	old := syscall.Umask(0o077)
	unlock, err := lockUpdate()
	syscall.Umask(old)
	if err != nil {
		t.Fatal(err)
	}
	unlock()
	info, err := os.Stat(updateLockPath)
	if err != nil || info.Mode().Perm() != 0o644 {
		t.Errorf("the lock is %v (%v), want readable by every account (0644)", info.Mode().Perm(), err)
	}
}

// TestUpdateLockHelper takes and lets go the update lock at
// CYFR_TEST_LOCK_AT as the account it runs as, for
// TestASecondAccountTakesTheUpdateLock; it does nothing otherwise.
func TestUpdateLockHelper(t *testing.T) {
	at := os.Getenv("CYFR_TEST_LOCK_AT")
	if at == "" {
		return
	}
	updateLockPath = at
	unlock, err := lockUpdate()
	if err != nil {
		t.Fatal(err)
	}
	unlock()
	fmt.Println("lock taken by uid", os.Getuid())
}

// Once another account's update made the lock in the computer's shared
// sticky folder, this account's update takes it: in such a folder Linux
// refuses an open with O_CREAT of a file another account owns, root's
// open too (fs.protected_regular, 2 on Ubuntu). The other account is
// nobody, reached through runuser where this test runs as root (a
// container here), else through a sudo that asks for no password
// (GitHub's runners); with neither, the test skips.
func TestASecondAccountTakesTheUpdateLock(t *testing.T) {
	var as []string
	switch {
	case os.Geteuid() == 0:
		as = []string{"runuser", "-u", "nobody", "--"}
	case exec.Command("sudo", "-n", "-u", "nobody", "/bin/true").Run() == nil:
		as = []string{"sudo", "-n", "-u", "nobody", "--"}
	default:
		t.Skip("another account is needed: this runs as root (in a container) or with a sudo that asks for no password")
	}
	if raw, err := os.ReadFile("/proc/sys/fs/protected_regular"); err == nil {
		t.Logf("fs.protected_regular = %s", strings.TrimSpace(string(raw)))
	}
	shared, err := os.MkdirTemp("/tmp", "cyfr-lock-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(shared) })
	if err := os.Chmod(shared, 0o1777); err != nil {
		t.Fatal(err)
	}
	// The other account runs a copy of this test binary it may execute.
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	binary := filepath.Join(shared, "cmd.test")
	in, err := os.Open(self)
	if err != nil {
		t.Fatal(err)
	}
	out, err := os.OpenFile(binary, os.O_WRONLY|os.O_CREATE, 0o755)
	if err == nil {
		_, err = io.Copy(out, in)
		err = errors.Join(err, out.Close())
	}
	in.Close()
	if err != nil {
		t.Fatal(err)
	}
	lock := filepath.Join(shared, "cyfr-update.lock")
	other := exec.Command(as[0], append(as[1:], "env", "CYFR_TEST_LOCK_AT="+lock, "HOME="+shared, "TMPDIR="+shared,
		binary, "-test.run=^TestUpdateLockHelper$", "-test.v")...)
	if said, err := other.CombinedOutput(); err != nil || !strings.Contains(string(said), "lock taken by uid") {
		t.Fatalf("the other account's update could not take the lock (%v):\n%s", err, said)
	}
	info, err := os.Stat(lock)
	if err != nil {
		t.Fatal(err)
	}
	if owner := info.Sys().(*syscall.Stat_t).Uid; int(owner) == os.Getuid() {
		t.Fatalf("the lock is this account's (%d), not the other's", owner)
	}
	saved := updateLockPath
	t.Cleanup(func() { updateLockPath = saved })
	updateLockPath = lock
	unlock, err := lockUpdate()
	if err != nil {
		t.Fatalf("this account's update, after another account's, answered %v", err)
	}
	unlock()
}
