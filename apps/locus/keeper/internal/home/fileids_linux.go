// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package home

import (
	"errors"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

// AsFileIDs runs fn as uid and gid would reach files, on a thread that takes
// their file ids (setfsuid and setfsgid, which the keeper's SETUID and
// SETGID allow) and ends with its goroutine, never unlocked, so no other
// goroutine runs with them. Before it answers, on success and on failure
// alike, the thread takes the caller's own file ids back and reads them from
// its own status (threadFileIDs): a goroutine that ends locked on the
// process's main thread leaves that thread parked, not gone, and the main
// thread's ids are the caller's as /proc shows them.
func AsFileIDs(uid, gid int, fn func() error) error {
	done := make(chan error, 1)
	ownUID, ownGID := unix.Getuid(), unix.Getgid()
	go func() {
		runtime.LockOSThread()
		err := withFileIDs(uid, gid, fn)
		_ = unix.Setfsuid(ownUID)
		_ = unix.Setfsgid(ownGID)
		if fsUID, fsGID, rerr := threadFileIDs(); rerr != nil || fsUID != ownUID || fsGID != ownGID {
			err = errors.Join(err, fmt.Errorf("the thread's file ids are %d:%d after their restoration, not the caller's %d:%d (%v)", fsUID, fsGID, ownUID, ownGID, rerr))
		}
		done <- err
	}()
	return <-done
}

// withFileIDs runs fn on the calling thread, which the caller has locked,
// under the file ids uid and gid, which it reads back first.
func withFileIDs(uid, gid int, fn func() error) error {
	_ = unix.Setfsgid(gid)
	_ = unix.Setfsuid(uid)
	// setfsuid and setfsgid answer the ids before, never an error: the
	// ids the thread now holds are read back.
	if got, _ := unix.SetfsuidRetUid(-1); got != uid {
		return fmt.Errorf("the thread's file uid is %d, not %d", got, uid)
	}
	if got, _ := unix.SetfsgidRetGid(-1); got != gid {
		return fmt.Errorf("the thread's file gid is %d, not %d", got, gid)
	}
	return fn()
}

// threadFileIDs reads the calling thread's file uid and gid, the fourth of
// the Uid and Gid lines of /proc/thread-self/status.
func threadFileIDs() (uid, gid int, err error) {
	status, err := os.ReadFile("/proc/thread-self/status")
	if err != nil {
		return 0, 0, err
	}
	ids := map[string]int{}
	for _, line := range strings.Split(string(status), "\n") {
		name, rest, ok := strings.Cut(line, ":")
		if f := strings.Fields(rest); ok && (name == "Uid" || name == "Gid") && len(f) == 4 {
			if ids[name], err = strconv.Atoi(f[3]); err != nil {
				return 0, 0, err
			}
		}
	}
	u, okU := ids["Uid"]
	g, okG := ids["Gid"]
	if !okU || !okG {
		return 0, 0, errors.New("no Uid or Gid line of four ids")
	}
	return u, g, nil
}
