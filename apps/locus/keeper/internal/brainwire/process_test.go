// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package brainwire

import (
	"bytes"
	"io"
	"testing"
	"time"
)

// A harness that goes on after its input closes, as Claude Code 2.1.323
// does while a request to its model streams (17.6 s measured), is
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

// A stop's last lines to the harness (Codex's turn/interrupt) are written
// without holding its bounds: a harness that never reads its input, its
// pipe full, is still asked to end at termAfter and killed at closeWait.
func TestAStopsLastLinesHoldNeitherOfItsBounds(t *testing.T) {
	p, err := spawn([]string{"/bin/sh", "-c", "trap 'exit 7' TERM; while :; do sleep 0.05; done"}, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	full := bytes.Repeat([]byte("x"), 1<<20)
	started := time.Now()
	stopped := make(chan struct{})
	go func() {
		p.Stop(full)
		close(stopped)
	}()
	select {
	case <-stopped:
	case <-time.After(2 * closeWait):
		t.Fatal("the stop was held by a line the harness never read")
	}
	if p.Status != 7 {
		t.Fatalf("the harness ended by its own exit on TERM, not killed: status %d", p.Status)
	}
	if took := time.Since(started); took < termAfter || took >= closeWait {
		t.Fatalf("it was asked to end after %v, within the %v bound: took %v", termAfter, closeWait, took)
	}
}
