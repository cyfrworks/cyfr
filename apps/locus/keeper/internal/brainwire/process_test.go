// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package brainwire

import (
	"io"
	"testing"
	"time"
)

// A harness that goes on after its input closes, as Claude Code 2.1.323
// does while a request to its model streams (aq-drivers cl-c8: 17.6 s), is
// asked to end with a TERM before it is killed at the bound, and its own
// end is the one Stop waits for.
func TestAHarnessThatGoesOnAfterItsInputIsAskedToEndBeforeItIsKilled(t *testing.T) {
	p, err := spawn([]string{"/bin/sh", "-c", "trap 'exit 7' TERM; while :; do sleep 0.05; done"}, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	p.Stop()
	<-p.Done
	if p.Status != 7 {
		t.Fatalf("the harness ended by its own exit on TERM, not killed: status %d", p.Status)
	}
	if took := time.Since(started); took < termAfter || took >= closeWait {
		t.Fatalf("it was asked to end after %v, and not killed at the %v bound: took %v", termAfter, closeWait, took)
	}
}

// A harness that ends when its input closes is not signalled at all.
func TestAHarnessThatEndsWithItsInputIsNotSignalled(t *testing.T) {
	p, err := spawn([]string{"/bin/sh", "-c", "trap 'exit 7' TERM; cat >/dev/null; exit 3"}, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	p.Stop()
	<-p.Done
	if p.Status != 3 {
		t.Fatalf("the harness ended by itself: status %d", p.Status)
	}
}
