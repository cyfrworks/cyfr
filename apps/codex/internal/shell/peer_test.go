// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell_test

import (
	"io"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/desktop"
	"github.com/cyfr/codex/internal/shell"
)

// A lock waits on no peer: with main's pipe held unread behind a message
// already waiting to be written, or with main gone and its pipe closed,
// a lock that tells main locked through its writer's queue, as the
// desktop's and the screen's do, ends the sessions at the CYFR within the
// lock's own bound.
func TestLock_WaitsOnNoPeer(t *testing.T) {
	for name, closed := range map[string]bool{"main's pipe held unread": false, "main's pipe closed": true} {
		t.Run(name, func(t *testing.T) {
			read, write := io.Pipe()
			if closed {
				read.Close()
			}
			t.Cleanup(func() { read.Close() })
			to := desktop.NewWriter(write, nil)
			sh, told := shell.OpenForTest(t, func() { _ = to.Queue(desktop.Message{Type: desktop.TypeLocked}) })
			// A message main has not taken holds the writer.
			_ = to.Queue(desktop.Message{Type: desktop.TypeReady, URL: "http://127.0.0.1:7340/"})
			locked := make(chan struct{})
			began := time.Now()
			go func() {
				defer close(locked)
				sh.Lock("Locked.")
			}()
			select {
			case <-locked:
			case <-time.After(6 * time.Second):
				t.Fatal("the lock waited on main")
			}
			if told() == 0 || sh.Unlocked() {
				t.Fatalf("after %v the CYFR heard %d sessions locked, unlocked %v", time.Since(began), told(), sh.Unlocked())
			}
		})
	}
}
