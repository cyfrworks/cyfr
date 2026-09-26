// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cgroup

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// namespaceRoot is a directory holding the files Delegate reads at the root
// of a container's cgroup namespace. A directory is not a cgroup: the kernel
// side, a group's control files and the bound itself, is proven by package
// serve's tests and by tests/builder-image/memory.py.
func namespaceRoot(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(root, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func delegated() map[string]string {
	return map[string]string{"cgroup.controllers": "cpuset cpu io memory pids\n", "memory.max": "3221225472\n", "cgroup.procs": ""}
}

// keeperFiles stands in for the kernel, which gives the keeper group its
// control files once the root enables the memory controller: it makes the
// group with the files named.
func keeperFiles(t *testing.T, root string, files ...string) {
	t.Helper()
	if err := os.Mkdir(filepath.Join(root, keeperLeaf), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, file := range files {
		if err := os.WriteFile(filepath.Join(root, keeperLeaf, file), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestOwnReadsTheV2PathAndRefusesAnyOtherHierarchy(t *testing.T) {
	for self, want := range map[string]string{"0::/\n": "/", "0::/keeper-30001\n": "/keeper-30001", "0::/keeper": "/keeper"} {
		if got, err := Own([]byte(self)); err != nil || got != want {
			t.Errorf("Own(%q) = %q, %v; want %q", self, got, err, want)
		}
	}
	for _, self := range []string{"", "\n", "12:memory:/docker/abc\n0::/docker/abc\n", "1:name=systemd:/\n", "0::relative\n"} {
		if got, err := Own([]byte(self)); err == nil {
			t.Errorf("Own(%q) = %q, want a refusal", self, got)
		}
	}
}

func TestDelegateMovesTheRootsProcessesAsideAndEnablesMemory(t *testing.T) {
	root := namespaceRoot(t, delegated())
	keeperFiles(t, root, boundFiles...)
	for _, self := range []string{"0::/\n", "0::/keeper\n"} {
		m, err := Delegate(root, []byte(self))
		if err != nil || m == nil {
			t.Fatalf("Delegate from %q: %v", self, err)
		}
	}
	if info, err := os.Stat(filepath.Join(root, keeperLeaf)); err != nil || !info.IsDir() {
		t.Fatalf("no keeper group: %v", err)
	}
	if got, _ := os.ReadFile(filepath.Join(root, "cgroup.subtree_control")); string(got) != "+memory" {
		t.Fatalf("cgroup.subtree_control holds %q", got)
	}
}

func TestDelegateSaysWhyBoundsAreUnavailable(t *testing.T) {
	without := func(name string) map[string]string {
		files := delegated()
		delete(files, name)
		return files
	}
	noMemory := delegated()
	noMemory["cgroup.controllers"] = "cpuset cpu io pids\n"
	stuck := delegated()
	stuck["cgroup.procs"] = "1\n"

	for name, c := range map[string]struct {
		self  string
		files map[string]string
		want  string
	}{
		"a keeper outside a namespace root": {"0::/docker/0123abcd\n", delegated(), "not the root of a cgroup namespace"},
		"a cgroup v1 host":                  {"12:memory:/docker/0123abcd\n0::/\n", delegated(), "cgroup v2"},
		"no cgroup v2 mount":                {"0::/\n", without("cgroup.controllers"), "not a cgroup v2 mount"},
		"no memory controller":              {"0::/\n", noMemory, "memory controller is not enabled"},
		"the machine's root cgroup":         {"0::/\n", without("memory.max"), "not a delegated cgroup"},
		"processes that do not move":        {"0::/\n", stuck, "processes remain"},
	} {
		m, err := Delegate(namespaceRoot(t, c.files), []byte(c.self))
		if err == nil || m != nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: Delegate = %v, %v; want an error naming %q", name, m, err, c.want)
		}
	}
}

// A process the root keeps is named with the write's error and what /proc
// says it is: one whose move the kernel refused, and one listed still
// after a write that succeeded.
func TestDrainNamesEveryProcessItCannotMove(t *testing.T) {
	self := strconv.Itoa(os.Getpid())
	files := delegated()
	files["cgroup.procs"] = self + "\n"

	refused := namespaceRoot(t, files)
	// A directory where the leaf's cgroup.procs belongs: every write fails.
	if err := os.MkdirAll(filepath.Join(refused, keeperLeaf, "cgroup.procs"), 0o755); err != nil {
		t.Fatal(err)
	}
	_, err := Delegate(refused, []byte("0::/\n"))
	if err == nil {
		t.Fatal("a root whose process cannot move was delegated")
	}
	for _, want := range []string{"processes remain in " + refused, "pid " + self + " (", "moving it: ", "is a directory", "state "} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the refusal %q does not name %q", err, want)
		}
	}

	stuck := namespaceRoot(t, files)
	_, err = Delegate(stuck, []byte("0::/\n"))
	if err == nil || !strings.Contains(err.Error(), "pid "+self+" (") || !strings.Contains(err.Error(), "still listed") {
		t.Fatalf("a process listed after its move: %v", err)
	}

	gone := namespaceRoot(t, map[string]string{"cgroup.controllers": "memory\n", "memory.max": "max\n", "cgroup.procs": "999999999\n"})
	_, err = Delegate(gone, []byte("0::/\n"))
	if err == nil || !strings.Contains(err.Error(), "pid 999999999 (no /proc entry") {
		t.Fatalf("a pid /proc does not know: %v", err)
	}
}

// pausing replaces the wait between two passes over the root with then,
// recording each wait asked for, for the rest of the test.
func pausing(t *testing.T, then func()) *[]time.Duration {
	t.Helper()
	var waits []time.Duration
	pause = func(d time.Duration) {
		waits = append(waits, d)
		if then != nil {
			then()
		}
	}
	t.Cleanup(func() { pause = time.Sleep })
	return &waits
}

// cgroup.procs lists a process of another pid namespace as 0: the
// runtime's own process entering the container for a `docker exec` as it
// restarts in place. A write cannot name it and it is not the keeper's, so
// the drain skips it, delegates beside it, and names in a refusal only the
// processes it could see.
func TestDrainSkipsWhatItCannotSee(t *testing.T) {
	files := delegated()
	files["cgroup.procs"] = "0\n0\n"
	root := namespaceRoot(t, files)
	keeperFiles(t, root, boundFiles...)
	waits := pausing(t, nil)
	if m, err := Delegate(root, []byte("0::/\n")); err != nil || m == nil {
		t.Fatalf("a root holding only processes of another pid namespace: %v", err)
	}
	if moved, _ := os.ReadFile(filepath.Join(root, keeperLeaf, "cgroup.procs")); len(moved) != 0 {
		t.Errorf("the drain wrote %q, naming a process it cannot see", moved)
	}
	if len(*waits) != 0 {
		t.Errorf("the drain waited %v with nothing it could move", *waits)
	}

	self := strconv.Itoa(os.Getpid())
	files["cgroup.procs"] = "0\n" + self + "\n0\n"
	stuck := namespaceRoot(t, files)
	waits = pausing(t, nil)
	_, err := Delegate(stuck, []byte("0::/\n"))
	if err == nil || !strings.Contains(err.Error(), "processes remain in "+stuck+": pid "+self+" (") ||
		strings.Contains(err.Error(), "pid 0") {
		t.Fatalf("the refusal names what it could see alone: %v", err)
	}
	if len(*waits) != drainAttempts-1 || (*waits)[0] != 50*time.Millisecond {
		t.Errorf("the drain waited %v between its %d passes, want 50ms each", *waits, drainAttempts)
	}
}

// A root that empties between two passes, as a process of another pid
// namespace leaves it, is delegated after one wait.
func TestDrainWaitsForTheRootToEmpty(t *testing.T) {
	files := delegated()
	files["cgroup.procs"] = strconv.Itoa(os.Getpid()) + "\n0\n"
	root := namespaceRoot(t, files)
	keeperFiles(t, root, boundFiles...)
	waits := pausing(t, func() {
		if err := os.WriteFile(filepath.Join(root, "cgroup.procs"), nil, 0o644); err != nil {
			t.Error(err)
		}
	})
	if m, err := Delegate(root, []byte("0::/\n")); err != nil || m == nil {
		t.Fatalf("a root that empties on the second pass: %v", err)
	}
	if len(*waits) != 1 || (*waits)[0] != drainInterval {
		t.Errorf("the drain waited %v, want one wait of %v", *waits, drainInterval)
	}
}

// A root the memory controller cannot be enabled for, while processes of
// another pid namespace stay in it, is refused after the passes, naming
// how many it could not see.
func TestDelegateNamesTheProcessesItCouldNotSee(t *testing.T) {
	files := delegated()
	files["cgroup.procs"] = "0\n"
	root := namespaceRoot(t, files)
	keeperFiles(t, root, boundFiles...)
	// A directory where cgroup.subtree_control belongs: every write fails,
	// as the kernel refuses one while the root holds a process.
	if err := os.Mkdir(filepath.Join(root, "cgroup.subtree_control"), 0o755); err != nil {
		t.Fatal(err)
	}
	waits := pausing(t, nil)
	_, err := Delegate(root, []byte("0::/\n"))
	if err == nil || !strings.Contains(err.Error(), "enabling the memory controller") ||
		!strings.Contains(err.Error(), "1 processes of another pid namespace") {
		t.Fatalf("a root the controller cannot be enabled for: %v", err)
	}
	if len(*waits) != drainAttempts-1 {
		t.Errorf("Delegate waited %d times between its %d attempts", len(*waits), drainAttempts)
	}
}

// A group that could swap past its bound, or lose one process and live on,
// is not held to it: a kernel without either file enforces no bound here.
func TestDelegateRefusesAKernelThatCannotHoldAGroupToItsBound(t *testing.T) {
	for missing, present := range map[string][]string{
		"memory.swap.max":  {"memory.max", "memory.oom.group"},
		"memory.oom.group": {"memory.max", "memory.swap.max"},
		"memory.max":       {"memory.swap.max", "memory.oom.group"},
	} {
		root := namespaceRoot(t, delegated())
		keeperFiles(t, root, present...)
		if m, err := Delegate(root, []byte("0::/\n")); err == nil || m != nil || !strings.Contains(err.Error(), "no "+missing) {
			t.Errorf("without %s: Delegate = %v, %v", missing, m, err)
		}
	}
}

func TestDelegateRefusesAReadOnlyMount(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("uid 0 writes a directory whatever its mode; the read-only mount is tests/builder-image/memory.py's case")
	}
	root := namespaceRoot(t, delegated())
	if err := os.Chmod(root, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(root, 0o755) })
	if m, err := Delegate(root, []byte("0::/\n")); err == nil || m != nil || !strings.Contains(err.Error(), "not writable") {
		t.Fatalf("Delegate = %v, %v", m, err)
	}
}

func TestCreateSetsTheBoundNoSwapAndTheGroupKill(t *testing.T) {
	m := &Manager{root: t.TempDir()}
	g, err := m.Create(Name(30001), 1<<30)
	if err != nil {
		t.Fatal(err)
	}
	if g.Path() != "/keeper-30001" {
		t.Fatalf("path %q", g.Path())
	}
	for file, want := range map[string]string{"memory.max": "1073741824", "memory.swap.max": "0", "memory.oom.group": "1"} {
		if got, err := os.ReadFile(filepath.Join(m.root, "keeper-30001", file)); err != nil || string(got) != want {
			t.Errorf("%s holds %q (%v), want %q", file, got, err, want)
		}
	}
	if err := g.Add(4321); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(filepath.Join(m.root, "keeper-30001", "cgroup.procs")); string(got) != "4321" {
		t.Fatalf("cgroup.procs holds %q", got)
	}
	for _, name := range []string{"", "keeper", "keeper-", "keeper-0", "keeper-30001/..", "../keeper-30001", "keeper-30001x"} {
		if g, err := m.Create(name, 1<<30); err == nil {
			t.Errorf("Create(%q) made %v", name, g)
		}
	}
}

func TestCreateNeverReusesAnEarlierSpawnsGroup(t *testing.T) {
	m := &Manager{root: t.TempDir()}
	if err := os.Mkdir(filepath.Join(m.root, "keeper-30002"), 0o755); err != nil {
		t.Fatal(err)
	}
	g, err := m.Create(Name(30002), 1<<30)
	if err != nil {
		t.Fatalf("an empty group left behind was not replaced: %v", err)
	}
	// What cannot be removed still holds something of the earlier spawn.
	if again, err := m.Create(Name(30002), 1<<30); err == nil || !strings.Contains(err.Error(), "earlier spawn") {
		t.Fatalf("Create over a group in use = %v, %v", again, err)
	}
	for _, file := range []string{"memory.max", "memory.swap.max", "memory.oom.group"} {
		if err := os.Remove(filepath.Join(m.root, "keeper-30002", file)); err != nil {
			t.Fatal(err)
		}
	}
	if err := g.Remove(); err != nil {
		t.Fatal(err)
	}
	if err := g.Remove(); err != nil {
		t.Fatalf("removing a group already gone: %v", err)
	}
}

func TestKillsTellsTheSpawnsBoundFromTheContainers(t *testing.T) {
	m := &Manager{root: t.TempDir()}
	g, err := m.Create(Name(30003), 1<<30)
	if err != nil {
		t.Fatal(err)
	}
	events := filepath.Join(m.root, "keeper-30003", "memory.events")
	for content, want := range map[string]Kills{
		"low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\noom_group_kill 0\n":  {},
		"low 0\nhigh 0\nmax 19\noom 1\noom_kill 7\noom_group_kill 1\n": {AtBound: true},
		"low 0\nhigh 0\nmax 0\noom 0\noom_kill 3\noom_group_kill 1\n":  {Outside: true},
		"low 0\nhigh 0\nmax 40\noom 2\noom_kill 0\noom_group_kill 0\n": {},
		"oom 1\noom_kill 1\n": {AtBound: true},
		"low 0\nhigh 0\nmax 536\noom 26\noom_kill 2\noom_group_kill 1\n": {AtBound: true},
	} {
		if err := os.WriteFile(events, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		if got, err := g.Kills(); err != nil || got != want {
			t.Errorf("events %q: %+v, %v; want %+v", content, got, err, want)
		}
	}
	for _, content := range []string{"", "oom 1\n", "oom_kill 1\n", "oom one\noom_kill 1\n", "oom 1 2\noom_kill 1\n"} {
		if err := os.WriteFile(events, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		if got, err := g.Kills(); err == nil {
			t.Errorf("events %q read as %+v", content, got)
		}
	}
	if err := os.Remove(events); err != nil {
		t.Fatal(err)
	}
	if got, err := g.Kills(); err == nil {
		t.Errorf("missing events read as %+v", got)
	}
}
