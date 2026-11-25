// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package home

import (
	"os"
	"testing"
)

// AsFileIDs ends no thread when it gives the caller's ids back: a thread
// that ended would fire the parent-death signal of every process it had
// started, a space's stage among them. Each call runs on the caller's own
// thread more often than not, so every thread there was before is still
// there after many calls.
func TestAsFileIDsEndsNoThread(t *testing.T) {
	before := threads(t)
	for i := 0; i < 64; i++ {
		if err := AsFileIDs(os.Getuid(), os.Getgid(), func() error { return nil }); err != nil {
			t.Fatal(err)
		}
	}
	after := map[string]bool{}
	for _, tid := range threads(t) {
		after[tid] = true
	}
	for _, tid := range before {
		if !after[tid] {
			t.Fatalf("thread %s ended after AsFileIDs gave its ids back", tid)
		}
	}
}

func threads(t *testing.T) []string {
	t.Helper()
	entries, err := os.ReadDir("/proc/self/task")
	if err != nil {
		t.Skip(err)
	}
	var tids []string
	for _, e := range entries {
		tids = append(tids, e.Name())
	}
	return tids
}
