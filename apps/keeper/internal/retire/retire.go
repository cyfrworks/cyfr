// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package retire ends everything a pool uid is running and removes what it
// left behind. `cyfr-keeper retire` runs as that uid: it sends SIGTERM to
// every process the uid owns and waits out the grace period, then sends
// SIGKILL until none is left; it removes the System V IPC objects the uid
// owns or created and its POSIX message queues, and then each path of its
// spec (package residue). Signalling with pid -1 as the uid itself reaches
// exactly that uid's processes, including daemons that left the spawn's
// session, without the spawner naming a pid that could be reused.
package retire

import (
	"errors"
	"fmt"
	"path/filepath"

	"github.com/cyfr/keeper/internal/protocol"
	"github.com/cyfr/keeper/internal/residue"
)

// Exit statuses of `cyfr-keeper retire`.
const (
	// ExitClean means no process of the uid remains and everything it was
	// asked to remove is gone.
	ExitClean = 0
	// ExitSurvivors means a process of the uid outlived every SIGKILL.
	ExitSurvivors = 1
	// ExitResidue means an IPC object, a message queue or a path could not
	// be removed.
	ExitResidue = 2
	// ExitInvalid means the spec or the process's credentials were wrong.
	ExitInvalid = 3
)

// MaxSpecBytes bounds the spec a retire process reads.
const MaxSpecBytes = 1 << 20

// Spec is what the spawner hands a retire process over its spec pipe: the
// uid, the grace its processes get after SIGTERM, and the entries it owns
// that are to be removed, each lying below a writable mount.
type Spec struct {
	UID     int      `json:"uid"`
	GraceMs int64    `json:"grace_ms"`
	Paths   []string `json:"paths,omitempty"`
}

// Validate checks a non-root uid, a grace within the protocol's bound, and
// at most residue.MaxPaths clean absolute paths other than "/".
func (s Spec) Validate() error {
	if s.UID <= 0 {
		return errors.New("uid must be non-zero")
	}
	if s.GraceMs < 0 || s.GraceMs > protocol.MaxGraceMs {
		return fmt.Errorf("grace_ms must be within 0..%d", protocol.MaxGraceMs)
	}
	if len(s.Paths) > residue.MaxPaths {
		return fmt.Errorf("at most %d paths", residue.MaxPaths)
	}
	for _, p := range s.Paths {
		if !filepath.IsAbs(p) || filepath.Clean(p) != p || p == "/" {
			return fmt.Errorf("path %q must be clean, absolute and not /", p)
		}
	}
	return nil
}
