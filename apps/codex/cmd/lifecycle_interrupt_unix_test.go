// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"context"
	"io"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"
)

// An interrupt during cyfr up's docker compose up keeps the lock until the
// compose child ends: an update in that window refuses, and the start then
// answers the interrupt and releases the lock.
func TestUpInterruptHoldsTheLockUntilComposeEnds(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.answer("up.block", "")
	result := make(chan error, 1)
	t.Cleanup(func() {
		s.answer("up.release", "")
		select {
		case <-result:
		case <-time.After(5 * time.Second):
		}
	})
	go func() { result <- upCmd.RunE(upCmd, nil) }()
	deadline := time.Now().Add(5 * time.Second)
	for !s.hasCall(profiles + "up -d") {
		if time.Now().After(deadline) {
			t.Fatal("cyfr up did not reach docker compose up")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err := syscall.Kill(os.Getpid(), syscall.SIGINT); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-result:
		t.Fatalf("cyfr up ended before its compose child: %v", err)
	case <-time.After(100 * time.Millisecond):
	}
	if holder := s.engine.held(); holder != "up" {
		t.Fatalf("cyfr up released its lock before compose ended (held by %q)", holder)
	}
	if err := homeStep(context.Background(), io.Discard, io.Discard); err == nil || !strings.Contains(err.Error(), "Another cyfr command holds CYFR's lock (`up`)") {
		t.Fatalf("an update was admitted inside the interrupted start: %v", err)
	}
	s.answer("up.release", "")
	select {
	case err := <-result:
		if err == nil || !strings.Contains(err.Error(), "interrupted") {
			t.Fatalf("cyfr up answered %v, want the interrupt", err)
		}
		result <- err
	case <-time.After(5 * time.Second):
		t.Fatal("cyfr up did not end after compose")
	}
	if holder := s.engine.held(); holder != "" {
		t.Fatalf("cyfr up left the lock held, by %s", holder)
	}
}
