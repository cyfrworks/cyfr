// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package vm

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// testMaker is a Maker whose tool is a script: it marks that it began,
// fails when fail exists, waits while stop exists, and then writes its
// arguments to its output file.
func testMaker(t *testing.T) (Maker, string) {
	t.Helper()
	dir := t.TempDir()
	tool := filepath.Join(dir, "tool")
	script := `#!/bin/sh
d=$(dirname "$0")
: > "$d/began"
[ -e "$d/fail" ] && exit 3
while [ -e "$d/stop" ]; do sleep 0.01; done # sleep-ok: the tool stands in for a slow maker until the test releases it
printf '%s\n' "$@" > "$2"
`
	if err := os.WriteFile(tool, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	volume := filepath.Join(dir, "guest")
	if err := os.Mkdir(volume, 0o755); err != nil {
		t.Fatal(err)
	}
	id := filepath.Join(dir, "image-digest")
	if err := os.WriteFile(id, []byte(digest+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return Maker{Dir: volume, Digest: id, Tool: tool, Root: "/", Wait: 5 * time.Second, Log: io.Discard}, dir
}

func names(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range entries {
		out = append(out, e.Name())
	}
	return out
}

// began waits, within a bound, for the tool's mark that a making began.
func began(t *testing.T, dir string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(filepath.Join(dir, "began")); err == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("no making began")
		}
		time.Sleep(10 * time.Millisecond) // sleep-ok: a bounded wait on the tool's mark
	}
}

func TestDeviceIsMadeOnceUnderAnImage(t *testing.T) {
	mk, _ := testMaker(t)
	path, made, err := mk.Device()
	if err != nil || !made || path != filepath.Join(mk.Dir, digest+".sqfs") {
		t.Fatalf("first Device: %q %v %v", path, made, err)
	}
	args, _ := os.ReadFile(path)
	if want := strings.Join(MakeArgs("/", path+".tmp"), "\n") + "\n"; string(args) != want {
		t.Fatalf("the tool was given %q, want %q", args, want)
	}
	again, made, err := mk.Device()
	if err != nil || made || again != path {
		t.Fatalf("second Device: %q %v %v", again, made, err)
	}
	if got := names(t, mk.Dir); !slices.Equal(got, []string{".lock", digest + ".sqfs"}) {
		t.Fatalf("the volume holds %v", got)
	}
}

func TestMakeArgsStayOnTheRootsFilesystem(t *testing.T) {
	args := MakeArgs("/", "/out")
	if args[0] != "/" || args[1] != "/out" || !slices.Contains(args, "-one-file-system") {
		t.Fatalf("MakeArgs: %v", args)
	}
	if i := slices.Index(args, "-comp"); i < 0 || args[i+1] != "lz4" {
		t.Fatalf("MakeArgs compress otherwise: %v", args)
	}
}

func TestANewImageReplacesTheOldDeviceOnceWhole(t *testing.T) {
	mk, _ := testMaker(t)
	old := filepath.Join(mk.Dir, strings.Repeat("f", 64)+".sqfs")
	leftover := filepath.Join(mk.Dir, strings.Repeat("e", 64)+".sqfs.tmp")
	for _, f := range []string{old, leftover} {
		if err := os.WriteFile(f, []byte("x"), 0o640); err != nil {
			t.Fatal(err)
		}
	}
	if _, made, err := mk.Device(); err != nil || !made {
		t.Fatalf("Device: %v %v", made, err)
	}
	if got := names(t, mk.Dir); !slices.Equal(got, []string{".lock", digest + ".sqfs"}) {
		t.Fatalf("the volume holds %v", got)
	}
}

func TestAFailedMakingLeavesNoDeviceAndKeepsTheOld(t *testing.T) {
	mk, dir := testMaker(t)
	old := filepath.Join(mk.Dir, strings.Repeat("f", 64)+".sqfs")
	if err := os.WriteFile(old, []byte("x"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "fail"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := mk.Device(); err == nil {
		t.Fatal("a failed making was taken")
	}
	if got := names(t, mk.Dir); !slices.Equal(got, []string{".lock", filepath.Base(old)}) {
		t.Fatalf("the volume holds %v", got)
	}
}

func TestAStartWaitsForAnotherMakingAndTakesItsDevice(t *testing.T) {
	mk, dir := testMaker(t)
	stop := filepath.Join(dir, "stop")
	if err := os.WriteFile(stop, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	type result struct {
		path string
		made bool
		err  error
	}
	results := make(chan result, 2)
	var wg sync.WaitGroup
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			p, m, err := mk.Device()
			results <- result{p, m, err}
		}()
	}
	// One start is making; the other waits on the lock.
	began(t, dir)
	if err := os.Remove(stop); err != nil {
		t.Fatal(err)
	}
	wg.Wait()
	close(results)
	var made int
	for r := range results {
		if r.err != nil || r.path != filepath.Join(mk.Dir, digest+".sqfs") {
			t.Fatalf("a start: %+v", r)
		}
		if r.made {
			made++
		}
	}
	if made != 1 {
		t.Fatalf("%d starts made the device", made)
	}
}

func TestAStartPastTheBoundIsRefusedWithItsReason(t *testing.T) {
	mk, dir := testMaker(t)
	if err := os.WriteFile(filepath.Join(dir, "stop"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	maker := make(chan error, 1)
	go func() { _, _, err := mk.Device(); maker <- err }()
	waiter := mk
	waiter.Wait = 200 * time.Millisecond
	began(t, dir)
	refused := make(chan error, 1)
	go func() { _, _, err := waiter.Device(); refused <- err }()
	select {
	case err := <-refused:
		if !errors.Is(err, ErrMaking) {
			t.Fatalf("a start past the bound: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a start past the bound was not refused")
	}
	_ = os.Remove(filepath.Join(dir, "stop"))
	if err := <-maker; err != nil {
		t.Fatalf("the maker: %v", err)
	}
}

func TestDeviceRefusesAnImageWithoutItsIdentity(t *testing.T) {
	mk, _ := testMaker(t)
	for _, raw := range []string{"", "not a digest", strings.Repeat("A", 64)} {
		if err := os.WriteFile(mk.Digest, []byte(raw), 0o644); err != nil {
			t.Fatal(err)
		}
		if _, _, err := mk.Device(); err == nil {
			t.Fatalf("identity %q was taken", raw)
		}
	}
	_ = os.Remove(mk.Digest)
	if _, _, err := mk.Device(); err == nil {
		t.Fatal("a missing identity was taken")
	}
}
