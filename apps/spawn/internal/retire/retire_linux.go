// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package retire

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/spawn/internal/logx"
	"github.com/cyfr/spawn/internal/procfs"
	"github.com/cyfr/spawn/internal/residue"
)

// SpecFD is the read end of the spec pipe; 0-2 are /dev/null, /dev/null and
// the spawner's stderr.
const SpecFD = 3

const (
	pollInterval = 20 * time.Millisecond
	killAttempts = 100
)

// Main runs `cyfr-spawn retire`.
func Main() int {
	log := logx.New("cyfr-spawn")
	data, err := io.ReadAll(io.LimitReader(os.NewFile(SpecFD, "spec"), MaxSpecBytes))
	if err != nil {
		log.Error("retire: spec: %v", err)
		return ExitInvalid
	}
	var spec Spec
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&spec); err != nil {
		log.Error("retire: spec: undecodable")
		return ExitInvalid
	}
	if err := spec.Validate(); err != nil {
		log.Error("retire: spec: %v", err)
		return ExitInvalid
	}
	ruid, euid, suid := unix.Getresuid()
	if ruid != spec.UID || euid != spec.UID || suid != spec.UID {
		log.Error("retire: running as uid %d/%d/%d, not %d", ruid, euid, suid, spec.UID)
		return ExitInvalid
	}

	status := ExitSurvivors
	if kill(spec.UID, time.Duration(spec.GraceMs)*time.Millisecond) {
		status = ExitClean
	} else {
		log.Warn("retire: uid %d still runs processes after SIGKILL", spec.UID)
	}
	if !removeResidue(log, spec) && status == ExitClean {
		status = ExitResidue
	}
	return status
}

// kill ends every process of uid but this one: SIGTERM and the grace period
// when there is one, then SIGKILL until none is left. It reports whether
// none is.
func kill(uid int, grace time.Duration) bool {
	self := os.Getpid()
	live := func() int {
		c, err := procfs.ScanUID("/proc", uid, self)
		if err != nil {
			return -1
		}
		return c.Live
	}
	if grace > 0 {
		_ = unix.Kill(-1, unix.SIGTERM)
		deadline := time.Now().Add(grace)
		for live() != 0 && time.Now().Before(deadline) {
			time.Sleep(pollInterval)
		}
	}
	for i := 0; i < killAttempts; i++ {
		_ = unix.Kill(-1, unix.SIGKILL)
		if live() == 0 {
			return true
		}
		time.Sleep(pollInterval)
	}
	return false
}

// removeResidue removes the uid's System V IPC objects, its message queues
// and the spec's paths, each of which must lie below a writable mount, and
// reports whether all of it is gone. Log lines carry counts, never the names
// a spawned process chose.
func removeResidue(log *logx.Logger, spec Spec) bool {
	_, roots, err := residue.ReadRoots()
	if err != nil {
		log.Error("retire: uid %d: reading the mount table: %v", spec.UID, err)
		return false
	}
	clean := true
	ipc, err := residue.FindIPC(residue.SysvipcDir, spec.UID)
	if err == nil {
		err = residue.RemoveIPC(ipc)
	}
	if err != nil {
		log.Error("retire: uid %d: %d System V IPC objects could not be removed", spec.UID, len(ipc))
		clean = false
	}
	if roots.Queues != "" {
		queues, err := residue.FindQueues(roots.Queues, spec.UID)
		if err == nil {
			err = residue.RemoveQueues(roots.Queues, queues)
		}
		if err != nil {
			log.Error("retire: uid %d: %d message queues could not be removed", spec.UID, len(queues))
			clean = false
		}
	}
	failed := 0
	for _, path := range spec.Paths {
		if !roots.Contains(path) || residue.RemovePath(path, spec.UID) != nil {
			failed++
		}
	}
	if failed > 0 {
		log.Error("retire: uid %d: %d of %d entries could not be removed", spec.UID, failed, len(spec.Paths))
		clean = false
	}
	return clean
}
