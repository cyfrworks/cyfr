// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cgroup

import (
	"errors"
	"io/fs"
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
	if err := os.MkdirAll(filepath.Join(root, keeperLeaf), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, file := range files {
		if err := os.WriteFile(filepath.Join(root, keeperLeaf, file), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestOwnReadsTheV2PathAndRefusesAnyOtherHierarchy(t *testing.T) {
	for self, want := range map[string]string{
		"0::/\n":                   "/",
		"0::/keeper-30001/bound\n": "/keeper-30001",
		"0::/service/keeper":       "/service/keeper",
		"0::/keeper-s-0123456789abcdef0123456789abcdef/bound":                    "/keeper-s-0123456789abcdef0123456789abcdef",
		"0::/keeper-30001/bound/inner":                                           "/keeper-30001/bound/inner",
		"0::/work/runtime/keeper-30101/bound":                                    "/work/runtime/keeper-30101",
		"0::/work/rest/backends/keeper-s-0123456789abcdef0123456789abcdef/bound": "/work/rest/backends/keeper-s-0123456789abcdef0123456789abcdef",
		"0::/service/runtime":                                                    "/service/runtime",
	} {
		if got, err := Own([]byte(self)); err != nil || got != want {
			t.Errorf("Own(%q) = %q, %v; want %q", self, got, err, want)
		}
	}
	for _, self := range []string{"", "\n", "12:memory:/docker/abc\n0::/docker/abc\n", "1:name=systemd:/\n", "0::relative\n", "0::/keeper-30001\n", "0::/work/runtime/keeper-30101\n", "0::/work/rest/builds/keeper-30001\n"} {
		if got, err := Own([]byte(self)); err == nil {
			t.Errorf("Own(%q) = %q, want a refusal", self, got)
		}
	}
}

func TestDelegateMovesTheRootsProcessesAsideAndEnablesMemoryAndCPU(t *testing.T) {
	root := namespaceRoot(t, delegated())
	keeperFiles(t, root, boundFiles...)
	for _, self := range []string{"0::/\n", "0::/service/keeper\n"} {
		m, err := Delegate(root, []byte(self))
		if err != nil || m == nil {
			t.Fatalf("Delegate from %q: %v", self, err)
		}
	}
	if info, err := os.Stat(filepath.Join(root, keeperLeaf)); err != nil || !info.IsDir() {
		t.Fatalf("no keeper group: %v", err)
	}
	for _, dir := range []string{root, filepath.Join(root, serviceGroup)} {
		if got, _ := os.ReadFile(filepath.Join(dir, "cgroup.subtree_control")); string(got) != "+memory +cpu" {
			t.Fatalf("%s's cgroup.subtree_control holds %q", dir, got)
		}
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
	noCPU := delegated()
	noCPU["cgroup.controllers"] = "cpuset io memory pids\n"
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
		"no cpu controller":                 {"0::/\n", noCPU, "cpu controller is not enabled"},
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

	gone := namespaceRoot(t, map[string]string{"cgroup.controllers": "cpu memory\n", "memory.max": "max\n", "cgroup.procs": "999999999\n"})
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
	if err == nil || !strings.Contains(err.Error(), "enabling the memory and cpu controllers") ||
		!strings.Contains(err.Error(), "1 processes of another pid namespace") {
		t.Fatalf("a root the controller cannot be enabled for: %v", err)
	}
	if len(*waits) != drainAttempts-1 {
		t.Errorf("Delegate waited %d times between its %d attempts", len(*waits), drainAttempts)
	}
}

// A group that could swap past its bound, lose one process and live on,
// or take every CPU is not held to its bounds: a kernel without any one of
// those files enforces none here.
func TestDelegateRefusesAKernelThatCannotHoldAGroupToItsBound(t *testing.T) {
	for _, missing := range boundFiles {
		var present []string
		for _, file := range boundFiles {
			if file != missing {
				present = append(present, file)
			}
		}
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

func TestCreateSetsTheBoundsNoSwapAndTheGroupKill(t *testing.T) {
	m := &Manager{root: t.TempDir()}
	g, err := m.Create(Name(30001), 1<<30, 200_000)
	if err != nil {
		t.Fatal(err)
	}
	if g.Path() != "/keeper-30001" {
		t.Fatalf("path %q", g.Path())
	}
	for file, want := range map[string]string{
		"memory.max": "1073741824", "memory.swap.max": "0",
		"memory.oom.group": "1", "cpu.max": "200000 100000",
	} {
		if got, err := os.ReadFile(filepath.Join(m.root, "keeper-30001", boundLeaf, file)); err != nil || string(got) != want {
			t.Errorf("%s holds %q (%v), want %q", file, got, err, want)
		}
	}
	for file, want := range map[string]string{"memory.oom.group": "1", "cgroup.subtree_control": "+memory +cpu"} {
		if got, err := os.ReadFile(filepath.Join(m.root, "keeper-30001", file)); err != nil || string(got) != want {
			t.Errorf("the mark's %s holds %q (%v), want %q", file, got, err, want)
		}
	}
	if _, err := os.Stat(filepath.Join(m.root, "keeper-30001", "memory.max")); err == nil {
		t.Error("the mark was given a bound, which would stand where the spawn's does")
	}
	if err := g.Add(4321); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(filepath.Join(m.root, "keeper-30001", boundLeaf, "cgroup.procs")); string(got) != "4321" {
		t.Fatalf("cgroup.procs holds %q", got)
	}
	for _, name := range []string{"", "keeper", "keeper-", "keeper-0", "keeper-30001/..", "../keeper-30001", "keeper-30001x"} {
		if g, err := m.Create(name, 1<<30, 100_000); err == nil {
			t.Errorf("Create(%q) made %v", name, g)
		}
	}
}

func TestCreateNeverReusesAnEarlierSpawnsGroup(t *testing.T) {
	m := &Manager{root: t.TempDir()}
	if err := os.Mkdir(filepath.Join(m.root, "keeper-30002"), 0o755); err != nil {
		t.Fatal(err)
	}
	g, err := m.Create(Name(30002), 1<<30, 100_000)
	if err != nil {
		t.Fatalf("an empty group left behind was not replaced: %v", err)
	}
	// What cannot be removed still holds something of the earlier spawn.
	if again, err := m.Create(Name(30002), 1<<30, 100_000); err == nil || !strings.Contains(err.Error(), "earlier spawn") {
		t.Fatalf("Create over a group in use = %v, %v", again, err)
	}
	files := []string{"memory.oom.group", "cgroup.subtree_control"}
	for _, file := range boundFiles {
		files = append(files, filepath.Join(boundLeaf, file))
	}
	for _, file := range files {
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

func TestKilledForTellsTheSpawnsBoundFromALimitAbove(t *testing.T) {
	m := &Manager{root: t.TempDir()}
	g, err := m.Create(Name(30003), 1<<30, 100_000)
	if err != nil {
		t.Fatal(err)
	}
	bound := filepath.Join(m.root, "keeper-30003", boundLeaf, "memory.events.local")
	mark := filepath.Join(m.root, "keeper-30003", "memory.events.local")
	const quiet = "low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\noom_group_kill 0\n"
	const marked = "low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\noom_group_kill 1\n"
	const uncounted = "low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\n"
	for _, c := range []struct {
		name, bound, mark string
		want              Cause
		waits             int
	}{
		{name: "no kill", bound: quiet, mark: quiet, want: NotKilled},
		{name: "out of memory at the bound, nothing killed", bound: "max 40\noom 2\noom_kill 0\noom_group_kill 0\n", mark: quiet, want: NotKilled},
		{name: "at the bound", bound: "max 19\noom 1\noom_kill 7\noom_group_kill 1\n", mark: quiet, want: AtBound},
		{name: "at the bound, many times over", bound: "max 536\noom 26\noom_kill 2\noom_group_kill 1\n", mark: quiet, want: AtBound},
		{name: "from above", bound: "oom 0\noom_kill 3\noom_group_kill 0\n", mark: marked, want: Above},
		{name: "from above, after the bound failed with nothing to kill", bound: "oom 1\noom_kill 1\noom_group_kill 0\n", mark: marked, want: Above},
		{name: "from above, counted by neither level", bound: "oom 0\noom_kill 1\noom_group_kill 0\n", mark: quiet, want: Above},
		{name: "at both", bound: "oom 1\noom_kill 3\noom_group_kill 1\n", mark: marked, want: Either},
		{name: "out of memory at the bound, and no group kill ever counted", bound: "oom 1\noom_kill 1\noom_group_kill 0\n", mark: quiet, want: Either, waits: settleAttempts},
		{name: "a kernel with no group kill count, out of memory at the bound", bound: "oom 1\noom_kill 1\n", mark: uncounted, want: Either},
		{name: "a kernel with no group kill count, never out of memory at the bound", bound: "oom 0\noom_kill 1\n", mark: uncounted, want: Above},
	} {
		for file, content := range map[string]string{bound: c.bound, mark: c.mark} {
			if err := os.WriteFile(file, []byte(content), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		waits := pausing(t, nil)
		if got, err := g.KilledFor(); err != nil || got != c.want || len(*waits) != c.waits {
			t.Errorf("%s: %v, %v after %d waits; want %v after %d", c.name, got, err, len(*waits), c.want, c.waits)
		}
	}

	// The group kill's count follows the first victim's signal.
	for file, content := range map[string]string{bound: "oom 1\noom_kill 1\noom_group_kill 0\n", mark: quiet} {
		if err := os.WriteFile(file, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	pausing(t, func() { _ = os.WriteFile(bound, []byte("oom 1\noom_kill 2\noom_group_kill 1\n"), 0o644) })
	if got, err := g.KilledFor(); err != nil || got != AtBound {
		t.Errorf("a count that settled read as %v, %v", got, err)
	}

	for _, content := range []string{"", "oom 1\n", "oom_kill 1\n", "oom one\noom_kill 1\n", "oom 1 2\noom_kill 1\n"} {
		if err := os.WriteFile(bound, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		if got, err := g.KilledFor(); err == nil {
			t.Errorf("events %q read as %v", content, got)
		}
	}
	if err := os.Remove(bound); err != nil {
		t.Fatal(err)
	}
	if got, err := g.KilledFor(); err == nil {
		t.Errorf("missing events read as %v", got)
	}
}

// A group's use is the memory that cannot be given back, summed from one
// memory.stat of either shape: with a `kernel` line the whole, without one
// the lesser, of the parts that kernel names. File cache is none of it,
// whatever memory.current says, and no reading is zero.
func TestUsedIsTheMemoryThatCannotBeGivenBack(t *testing.T) {
	const whole = "anon 8192\nfile 2097152\nkernel 40960\nkernel_stack 16384\npagetables 4096\nsec_pagetables 0\n" +
		"percpu 512\nsock 4096\nvmalloc 1024\nshmem 12288\ninactive_file 0\nactive_file 2084864\n" +
		"slab_reclaimable 8192\nslab_unreclaimable 4096\n"
	const v517 = "anon 8192\nfile 2097152\nkernel_stack 16384\npagetables 4096\npercpu 512\nsock 4096\nvmalloc 1024\n" +
		"shmem 12288\ninactive_file 0\nactive_file 2084864\nslab_reclaimable 8192\nslab_unreclaimable 4096\nslab 12288\n"
	const v54 = "anon 8192\nfile 2097152\nkernel_stack 16384\nslab 12288\nsock 4096\nshmem 12288\ninactive_file 0\n" +
		"slab_reclaimable 8192\nslab_unreclaimable 4096\n"
	for _, c := range []struct {
		name    string
		stat    string
		current string
		want    uint64
		lesser  bool
		fails   bool
	}{
		{name: "with a kernel line", stat: whole, current: "2142208", want: 8192 + 12288 + 40960 - 8192},
		{name: "with a kernel line, and memory.current never read", stat: whole, want: 8192 + 12288 + 40960 - 8192},
		{name: "before 5.18", stat: v517, current: "2142208", want: 8192 + 12288 + 16384 + 4096 + 512 + 1024 + 4096, lesser: true},
		{name: "5.4, which names fewer parts", stat: v54, current: "2142208", want: 8192 + 12288 + 16384 + 4096, lesser: true},
		{name: "all cache", stat: "anon 0\nfile 4096\nkernel 4096\nshmem 0\ninactive_file 0\nslab_reclaimable 4096\n", current: "8192", fails: true},
		{name: "nothing counted", stat: "anon 0\nkernel 0\nshmem 0\ninactive_file 0\nslab_reclaimable 0\n", current: "8192", fails: true},
		{name: "more given back than held", stat: "anon 0\nkernel 0\nshmem 0\ninactive_file 0\nslab_reclaimable 4096\n", current: "8192", fails: true},
		{name: "no anon", stat: "kernel 4096\nshmem 0\ninactive_file 0\nslab_reclaimable 0\n", current: "8192", fails: true},
		{name: "no shmem", stat: "anon 4096\nkernel 4096\ninactive_file 0\nslab_reclaimable 0\n", current: "8192", fails: true},
		{name: "a kernel line and no slab_reclaimable", stat: "anon 4096\nkernel 4096\nshmem 0\ninactive_file 0\n", current: "8192", fails: true},
		{name: "a count that does not read", stat: "anon max\nkernel 4096\nshmem 0\ninactive_file 0\nslab_reclaimable 0\n", current: "8192", fails: true},
		{name: "no memory.stat", current: "8192", fails: true},
	} {
		files := map[string]string{}
		if c.stat != "" {
			files["memory.stat"] = c.stat
		}
		if c.current != "" {
			files["memory.current"] = c.current + "\n"
		}
		used, err := (&Group{path: namespaceRoot(t, files)}).Used()
		if (err != nil) != c.fails || used != (Use{Bytes: c.want, Lesser: c.lesser}) {
			t.Errorf("%s: Used = %v, %v; want %d, lesser %t, failing %t", c.name, used, err, c.want, c.lesser, c.fails)
		}
	}
}

func TestSplitPathNamesASpawnsGroupInItsRole(t *testing.T) {
	for p, want := range map[string][3]string{
		"/keeper-30001":                         {"", "keeper-30001", "true"},
		"/work/runtime/keeper-30101":            {"runtime", "keeper-30101", "true"},
		"/work/rest/b2/keeper-s-" + hex32:       {"b2", "keeper-s-" + hex32, "true"},
		"/work/rest/builds/keeper-30001":        {"builds", "keeper-30001", "true"},
		"/service/runtime":                      {"", "", "false"},
		"/work/runtime":                         {"", "", "false"},
		"/work/rest/keeper-30001":               {"", "", "false"},
		"/work/keeper/keeper-30001":             {"", "", "false"},
		"/work/Runtime/keeper-30101":            {"", "", "false"},
		"/other/keeper-30101":                   {"", "", "false"},
		"/work/runtime/keeper-30101/x":          {"", "", "false"},
		"/work/rest/rest/keeper-30101":          {"", "", "false"},
		"/role-runtime/keeper-30101":            {"", "", "false"},
		"keeper-30001":                          {"", "", "false"},
		"/":                                     {"", "", "false"},
		"/work/rest/a/b/keeper-30101":           {"", "", "false"},
		"/work/rest/abcdefghijklmnopq/keeper-1": {"", "", "false"},
	} {
		role, name, ok := SplitPath(p)
		if got := [3]string{role, name, strconv.FormatBool(ok)}; ok != (want[2] == "true") || (ok && got != want) {
			t.Errorf("SplitPath(%q) = %q", p, got)
		}
	}
}

const hex32 = "0123456789abcdef0123456789abcdef"

// recording replaces the tree's mkdir and write, which still act on the
// test's folder, with ones that also note each act in order, for the rest
// of the test.
func recording(t *testing.T) *[]string {
	t.Helper()
	var acts []string
	mkdir = func(dir string, mode os.FileMode) error {
		acts = append(acts, "mkdir "+dir)
		return os.Mkdir(dir, mode)
	}
	write = func(file string, data []byte, mode os.FileMode) error {
		acts = append(acts, "write "+file+" "+string(data))
		return os.WriteFile(file, data, mode)
	}
	t.Cleanup(func() { mkdir, write = os.Mkdir, os.WriteFile })
	return &acts
}

// The tree is service, work and rest, each group's swap 0 and its
// controllers on; a role's leaf is in service and its spawns' groups in
// work, the floor role's beside rest and every other's in it, each at its
// share of the role's processors; and no memory bound is written until
// every group is made, work at W and rest at W - F.
func TestTheTreeIsMadeWholeBeforeAnyMemoryBound(t *testing.T) {
	root := t.TempDir()
	acts := recording(t)
	tree, err := (&Manager{root: root}).NewTree()
	if err != nil {
		t.Fatal(err)
	}
	runtime, runtimeLeaf, err := tree.Role("runtime", 400_000, true)
	if err != nil {
		t.Fatal(err)
	}
	builds, _, err := tree.Role("builds", 2*CPUPeriod, false)
	if err != nil {
		t.Fatal(err)
	}
	backends, backendsLeaf, err := tree.Role("backends", 0, false)
	if err != nil {
		t.Fatal(err)
	}
	if err := tree.Bound(0, 0); err != nil {
		t.Fatal(err)
	}

	lastMkdir, firstBound := -1, -1
	for i, act := range *acts {
		if strings.HasPrefix(act, "mkdir ") {
			lastMkdir = i
		}
		if firstBound < 0 && strings.HasSuffix(act, "/memory.max 0") {
			firstBound = i
		}
	}
	if firstBound < 0 || lastMkdir > firstBound {
		t.Fatalf("a group was made after a memory bound was written: %q", *acts)
	}
	for file, want := range map[string]string{
		"service/memory.swap.max": "0", "service/cgroup.subtree_control": "+memory +cpu",
		"work/memory.swap.max": "0", "work/cgroup.subtree_control": "+memory +cpu", "work/memory.max": "0",
		"work/rest/memory.swap.max": "0", "work/rest/cgroup.subtree_control": "+memory +cpu", "work/rest/memory.max": "0",
		"service/runtime/cpu.max": "50000 100000", "work/runtime/cpu.max": "350000 100000",
		"service/builds/cpu.max": "50000 100000", "work/rest/builds/cpu.max": "150000 100000",
		"service/backends/memory.swap.max": "0", "work/rest/backends/memory.swap.max": "0",
		"work/rest/backends/cgroup.subtree_control": "+memory +cpu",
	} {
		if got, err := os.ReadFile(filepath.Join(root, file)); err != nil || string(got) != want {
			t.Errorf("%s: %q, %v; want %q", file, got, err, want)
		}
	}
	for _, file := range []string{"service/backends/cpu.max", "work/rest/backends/cpu.max", "service/memory.max", "service/runtime/memory.max"} {
		if _, err := os.Stat(filepath.Join(root, file)); !errors.Is(err, fs.ErrNotExist) {
			t.Errorf("%s is written: %v", file, err)
		}
	}
	if runtimeLeaf.Path() != RoleLeaf("runtime") || backendsLeaf.Path() != "/service/backends" {
		t.Errorf("leaves %q, %q", runtimeLeaf.Path(), backendsLeaf.Path())
	}
	for m, want := range map[*Manager]string{runtime: "/work/runtime", builds: "/work/rest/builds", backends: "/work/rest/backends"} {
		if m.Path() != want || m.Dir() != filepath.Join(root, want) {
			t.Errorf("a role's spawns' groups in %q (%s), want %q", m.Path(), m.Dir(), want)
		}
	}
	g, err := builds.Create(Name(30001), 1<<20, CPUPeriod)
	if err != nil {
		t.Fatal(err)
	}
	if g.Path() != "/work/rest/builds/keeper-30001" {
		t.Fatalf("a spawn's group in its role's: %q", g.Path())
	}
	if role, name, ok := SplitPath(g.Path()); !ok || role != "builds" || name != "keeper-30001" {
		t.Errorf("SplitPath of a spawn's group: %q %q %v", role, name, ok)
	}
	for _, bad := range []string{"", "Runtime", "a_b", "log-x", "rest", "keeper"} {
		if _, _, err := tree.Role(bad, 0, false); err == nil {
			t.Errorf("role %q accepted", bad)
		}
	}
	if _, err := runtime.NewTree(); err == nil {
		t.Error("a tree inside a role's group was made")
	}
}

// A tree an earlier keeper left is made again: its groups kept, its bounds
// lifted before a role's group is made under them, then written anew.
func TestATreeLeftBoundedIsMadeAgain(t *testing.T) {
	root := t.TempDir()
	// The earlier keeper's role groups are gone with its roles; its tree
	// stays, bounded to 0 (a test folder's files would keep a group from
	// being removed, as a cgroup's never do).
	tree, err := (&Manager{root: root}).NewTree()
	if err != nil {
		t.Fatal(err)
	}
	if err := tree.Bound(0, 0); err != nil {
		t.Fatal(err)
	}
	acts := recording(t)
	again, err := (&Manager{root: root}).NewTree()
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := again.Role("runtime", 0, true); err != nil {
		t.Fatal(err)
	}
	lifted := map[string]bool{}
	for _, act := range *acts {
		if strings.HasSuffix(act, "/memory.max max") {
			lifted[strings.TrimSuffix(strings.TrimPrefix(act, "write "+root+"/"), "/memory.max max")] = true
		}
		if strings.HasPrefix(act, "mkdir "+root+"/work/runtime") && !(lifted["work"] && lifted["work/rest"]) {
			t.Fatalf("%s before work's and rest's bounds were lifted: %q", act, *acts)
		}
	}
	if err := again.Bound(2<<30, 2<<30-FloorBytesForTest); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(filepath.Join(root, "work", "rest", "memory.max")); string(got) != strconv.FormatUint(2<<30-FloorBytesForTest, 10) {
		t.Errorf("rest's bound %q", got)
	}
}

// FloorBytesForTest is any floor: the tree writes the bounds it is given.
const FloorBytesForTest = 164 << 20

// The namespace root's own memory.max is the container's limit, none where
// it reads max.
func TestLimitReadsTheContainersOwn(t *testing.T) {
	for content, want := range map[string][2]uint64{"max\n": {0, 0}, "8589934592\n": {8589934592, 1}} {
		root := namespaceRoot(t, map[string]string{"memory.max": content})
		limit, limited, err := (&Manager{root: root}).Limit()
		if err != nil || limit != want[0] || limited != (want[1] == 1) {
			t.Errorf("Limit of %q: %d, %v, %v", content, limit, limited, err)
		}
	}
	root := namespaceRoot(t, map[string]string{"memory.max": "lots\n"})
	if _, _, err := (&Manager{root: root}).Limit(); err == nil {
		t.Error("a memory.max of no number was read")
	}
}
