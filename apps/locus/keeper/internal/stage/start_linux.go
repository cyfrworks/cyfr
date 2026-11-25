// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package stage

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"syscall"

	"golang.org/x/sys/unix"
)

// SpaceAttr is how the keeper starts every space's stage, a spawn's, a role
// process's and a person's machine's alike: in a session of
// its own, killed if this keeper dies, cloned into a new user, network and
// IPC namespace, which takes no capability of the keeper's own namespace,
// and holding as ambient capabilities, inside that namespace only, what the
// stage needs there to become the pooled ids, bring a routed space's
// loopback up and bind its name sockets, build the space's files in a mount
// namespace it owns, and drop every set. It keeps the keeper's ids until
// the keeper has mapped them. A pty spawn's command takes its terminal as
// its controlling one, in the space's own session (package stage).
func SpaceAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{
		Setsid:     true,
		Pdeathsig:  syscall.SIGKILL,
		Cloneflags: unix.CLONE_NEWUSER | unix.CLONE_NEWNET | unix.CLONE_NEWIPC,
		AmbientCaps: []uintptr{unix.CAP_SETUID, unix.CAP_SETGID, unix.CAP_SETPCAP, unix.CAP_SYS_ADMIN,
			unix.CAP_NET_ADMIN, unix.CAP_NET_BIND_SERVICE},
	}
}

// MapIDs maps a cloned stage's uid and gid to themselves from the parent
// side, the one side that may map an id the child could not: setgroups is
// denied first, as a gid map written from outside requires, then gid_map,
// then uid_map. The keeper holds SETUID and SETGID in its own namespace,
// which is what these writes take.
func MapIDs(pid, uid, gid int) error {
	proc := filepath.Join("/proc", strconv.Itoa(pid))
	for _, w := range []struct{ file, content string }{
		{"setgroups", "deny"},
		{"gid_map", strconv.Itoa(gid) + " " + strconv.Itoa(gid) + " 1\n"},
		{"uid_map", strconv.Itoa(uid) + " " + strconv.Itoa(uid) + " 1\n"},
	} {
		// Each map is written whole by one write at offset 0, as the kernel
		// takes it.
		f, err := os.OpenFile(filepath.Join(proc, w.file), os.O_WRONLY, 0)
		if err == nil {
			_, err = f.Write([]byte(w.content))
			if cerr := f.Close(); err == nil {
				err = cerr
			}
		}
		if err != nil {
			return fmt.Errorf("writing %s: %w", w.file, err)
		}
	}
	return nil
}
