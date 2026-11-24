// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"errors"
	"os"
	"testing"
	"time"
)

// The keeper's end of a stage's socket takes a deadline, so a stage that
// never hands its terminal up is given up on within the stage's bound,
// with the deadline's own error.
func TestAStalledTerminalHandoffEndsWithinTheBound(t *testing.T) {
	stageEnd, keeperEnd, err := keeperPair("terminal")
	if err != nil {
		t.Fatal(err)
	}
	defer stageEnd.Close()
	defer keeperEnd.Close()
	began := time.Now()
	_, err = receiveTerminal(keeperEnd, 24, 80)
	if !errors.Is(err, os.ErrDeadlineExceeded) || time.Since(began) > stageTimeout+2*time.Second {
		t.Fatalf("a stalled handoff answered %v after %s", err, time.Since(began))
	}
}
