// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cgroup

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
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
	for self, want := range map[string]string{"0::/\n": "/", "0::/spawn-30001\n": "/spawn-30001", "0::/keeper": "/keeper"} {
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
		"a spawner outside a namespace root": {"0::/docker/0123abcd\n", delegated(), "not the root of a cgroup namespace"},
		"a cgroup v1 host":                   {"12:memory:/docker/0123abcd\n0::/\n", delegated(), "cgroup v2"},
		"no cgroup v2 mount":                 {"0::/\n", without("cgroup.controllers"), "not a cgroup v2 mount"},
		"no memory controller":               {"0::/\n", noMemory, "memory controller is not enabled"},
		"the machine's root cgroup":          {"0::/\n", without("memory.max"), "not a delegated cgroup"},
		"processes that do not move":         {"0::/\n", stuck, "processes remain"},
	} {
		m, err := Delegate(namespaceRoot(t, c.files), []byte(c.self))
		if err == nil || m != nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: Delegate = %v, %v; want an error naming %q", name, m, err, c.want)
		}
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
	if g.Path() != "/spawn-30001" {
		t.Fatalf("path %q", g.Path())
	}
	for file, want := range map[string]string{"memory.max": "1073741824", "memory.swap.max": "0", "memory.oom.group": "1"} {
		if got, err := os.ReadFile(filepath.Join(m.root, "spawn-30001", file)); err != nil || string(got) != want {
			t.Errorf("%s holds %q (%v), want %q", file, got, err, want)
		}
	}
	if err := g.Add(4321); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(filepath.Join(m.root, "spawn-30001", "cgroup.procs")); string(got) != "4321" {
		t.Fatalf("cgroup.procs holds %q", got)
	}
	for _, name := range []string{"", "keeper", "spawn-", "spawn-0", "spawn-30001/..", "../spawn-30001", "spawn-30001x"} {
		if g, err := m.Create(name, 1<<30); err == nil {
			t.Errorf("Create(%q) made %v", name, g)
		}
	}
}

func TestCreateNeverReusesAnEarlierSpawnsGroup(t *testing.T) {
	m := &Manager{root: t.TempDir()}
	if err := os.Mkdir(filepath.Join(m.root, "spawn-30002"), 0o755); err != nil {
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
		if err := os.Remove(filepath.Join(m.root, "spawn-30002", file)); err != nil {
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
	events := filepath.Join(m.root, "spawn-30003", "memory.events")
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
