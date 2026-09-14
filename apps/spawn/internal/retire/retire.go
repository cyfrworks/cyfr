// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package retire ends everything a pool uid is running. `cyfr-spawn retire`
// runs as that uid: it sends SIGTERM to every process the uid owns and
// waits out the grace period, then sends SIGKILL until none is left, and
// removes the spawn's home. Signalling with pid -1 as the uid itself
// reaches exactly that uid's processes, including daemons that left the
// spawn's session, without the spawner naming a pid that could be reused.
package retire

import (
	"errors"
	"fmt"

	"github.com/cyfr/spawn/internal/home"
	"github.com/cyfr/spawn/internal/protocol"
)

// Exit statuses of `cyfr-spawn retire`.
const (
	// ExitClean means no process of the uid remains and the home is gone.
	ExitClean = 0
	// ExitSurvivors means a process of the uid outlived every SIGKILL.
	ExitSurvivors = 1
	// ExitHome means the home could not be removed.
	ExitHome = 2
	// ExitInvalid means the spec or the process's credentials were wrong.
	ExitInvalid = 3
)

// Spec is what the spawner hands a retire process over its spec pipe. Home
// is empty when the spawn's home is already gone or was never recorded.
type Spec struct {
	UID      int    `json:"uid"`
	HomeRoot string `json:"home_root"`
	Home     string `json:"home,omitempty"`
	GraceMs  int64  `json:"grace_ms"`
}

// Validate checks a non-root uid, a grace within the protocol's bound, and
// a home named for the uid directly under the home root.
func (s Spec) Validate() error {
	if s.UID <= 0 {
		return errors.New("uid must be non-zero")
	}
	if s.GraceMs < 0 || s.GraceMs > protocol.MaxGraceMs {
		return fmt.Errorf("grace_ms must be within 0..%d", protocol.MaxGraceMs)
	}
	if s.Home != "" {
		return home.Validate(s.HomeRoot, s.Home, s.UID)
	}
	return nil
}
