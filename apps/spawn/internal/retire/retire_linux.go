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

	"github.com/cyfr/spawn/internal/home"
	"github.com/cyfr/spawn/internal/logx"
	"github.com/cyfr/spawn/internal/procfs"
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
	data, err := io.ReadAll(io.LimitReader(os.NewFile(SpecFD, "spec"), 4096))
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

	self := os.Getpid()
	live := func() int {
		c, err := procfs.ScanUID("/proc", spec.UID, self)
		if err != nil {
			return -1
		}
		return c.Live
	}

	if spec.GraceMs > 0 {
		_ = unix.Kill(-1, unix.SIGTERM)
		deadline := time.Now().Add(time.Duration(spec.GraceMs) * time.Millisecond)
		for live() != 0 && time.Now().Before(deadline) {
			time.Sleep(pollInterval)
		}
	}

	status := ExitSurvivors
	for i := 0; i < killAttempts; i++ {
		_ = unix.Kill(-1, unix.SIGKILL)
		if live() == 0 {
			status = ExitClean
			break
		}
		time.Sleep(pollInterval)
	}
	if status != ExitClean {
		log.Warn("retire: uid %d still runs processes after SIGKILL", spec.UID)
	}

	if spec.Home != "" {
		if err := home.Remove(spec.Home, spec.UID); err != nil {
			log.Error("retire: uid %d: %v", spec.UID, err)
			if status == ExitClean {
				status = ExitHome
			}
		}
	}
	return status
}
