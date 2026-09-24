// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package cgroup bounds a spawn's memory with a cgroup v2 group of its own.
//
// The kernel charges a group for the pages its processes touch, the pages
// of the tmpfs files they write and the kernel memory they cause, and never
// lets the total pass the group's memory.max. A spawn's group is created
// with memory.max at its bound, memory.swap.max at zero, so the bound is
// not escaped into swap, and memory.oom.group set, so a group that cannot
// stay under its bound loses every process at once rather than the one the
// kernel would pick. Every process the spawn forks is born in the group. A
// process leaves a group only by a write to a cgroup.procs file, and every
// file here belongs to uid 0, so no spawned process moves itself, raises
// its bound or clears the group kill.
//
// Groups can be made only where the spawner's own cgroup is the root of a
// cgroup namespace mounted writable, as a container started with Docker's
// `writable-cgroups=true` security option has it; Delegate reports anything
// else as the reason bounds are unavailable, and the spawner then refuses a
// spawn that asks for one. cgroup v2 lets a group hold processes or enable
// controllers for its children, not both, so Delegate first moves every
// process of the namespace root, the spawner among them, into the leaf
// group `keeper`; what the spawner starts without a bound stays there.
//
// Where the host mounts cgroup2 with `nsdelegate`, as systemd does, the
// kernel refuses a write from inside the namespace to the root's own limits,
// so what is delegated is only the division of the container's allotment.
// On a host without it uid 0 in the container can rewrite the container's
// own limits; only the spawner and the container's init run as uid 0.
package cgroup

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	// Root is where a container's cgroup namespace is mounted.
	Root = "/sys/fs/cgroup"
	// SelfPath names the file holding the calling process's own cgroup.
	SelfPath = "/proc/self/cgroup"
	// keeperLeaf is the group the namespace root's processes move to.
	keeperLeaf = "keeper"
	// drainAttempts bounds the passes that empty the namespace root; a
	// process joining it between two passes is moved by the next.
	drainAttempts = 20
	// removeAttempts and removeInterval bound the wait for a group's last
	// exited process to be reaped before the group can be removed.
	removeAttempts = 100
	removeInterval = 20 * time.Millisecond
)

var namePattern = regexp.MustCompile(`^keeper-[1-9][0-9]{0,9}$`)

// Name is the group of the spawn running under uid.
func Name(uid int) string { return "keeper-" + strconv.Itoa(uid) }

// Manager makes groups under the root of the spawner's cgroup namespace.
type Manager struct {
	root string
}

// Group is one spawn's group.
type Group struct {
	name string
	path string
}

// Delegate prepares the namespace root at root for per-spawn groups. self is
// the content of the spawner's /proc/self/cgroup. An error says why bounds
// are unavailable here; nothing else has failed.
func Delegate(root string, self []byte) (*Manager, error) {
	if path, err := Own(self); err != nil {
		return nil, err
	} else if path != "/" && path != "/"+keeperLeaf {
		return nil, fmt.Errorf("the spawner's cgroup is %s, not the root of a cgroup namespace", path)
	}
	controllers, err := os.ReadFile(filepath.Join(root, "cgroup.controllers"))
	if err != nil {
		return nil, fmt.Errorf("%s is not a cgroup v2 mount: %w", root, err)
	}
	if !hasField(string(controllers), "memory") {
		return nil, fmt.Errorf("the memory controller is not enabled for %s", root)
	}
	// The root cgroup of the whole machine has no memory.max: a spawner
	// there would be dividing the host, not a container's allotment.
	if _, err := os.Stat(filepath.Join(root, "memory.max")); err != nil {
		return nil, fmt.Errorf("%s is not a delegated cgroup: %w", root, err)
	}
	leaf := filepath.Join(root, keeperLeaf)
	if err := os.Mkdir(leaf, 0o755); err != nil && !errors.Is(err, fs.ErrExist) {
		return nil, fmt.Errorf("%s is not writable: %w", root, err)
	}
	for attempt := 1; ; attempt++ {
		if err := drain(root, leaf); err != nil {
			return nil, err
		}
		err := os.WriteFile(filepath.Join(root, "cgroup.subtree_control"), []byte("+memory"), 0o644)
		if err == nil {
			break
		}
		if attempt == drainAttempts {
			return nil, fmt.Errorf("enabling the memory controller under %s: %w", root, err)
		}
	}
	// A child of the root now has the files a spawn's group is bounded
	// with, or this kernel cannot hold a group to its bound: without swap
	// accounting a group swaps past it, without the group kill it loses one
	// process and lives on.
	for _, file := range boundFiles {
		if _, err := os.Stat(filepath.Join(leaf, file)); err != nil {
			return nil, fmt.Errorf("this kernel gives a group no %s: %w", file, err)
		}
	}
	return &Manager{root: root}, nil
}

// boundFiles are the control files Create writes.
var boundFiles = []string{"memory.max", "memory.swap.max", "memory.oom.group"}

// drain moves every process of root into leaf.
func drain(root, leaf string) error {
	for attempt := 0; attempt < drainAttempts; attempt++ {
		raw, err := os.ReadFile(filepath.Join(root, "cgroup.procs"))
		if err != nil {
			return err
		}
		pids := strings.Fields(string(raw))
		if len(pids) == 0 {
			return nil
		}
		for _, pid := range pids {
			// A process that exited meanwhile cannot be moved and need not be.
			_ = os.WriteFile(filepath.Join(leaf, "cgroup.procs"), []byte(pid), 0o644)
		}
	}
	return fmt.Errorf("processes remain in %s", root)
}

// Own returns the cgroup v2 path in a /proc/<pid>/cgroup file. A file naming
// any other hierarchy is refused: the bound is a cgroup v2 one.
func Own(self []byte) (string, error) {
	lines := strings.Split(strings.TrimSpace(string(self)), "\n")
	if len(lines) != 1 || !strings.HasPrefix(lines[0], "0::/") {
		return "", errors.New("the process is not in a cgroup v2 hierarchy alone")
	}
	return strings.TrimPrefix(lines[0], "0::"), nil
}

// Create makes the group name with its memory bound. A group of that name
// left by an earlier spawn is removed first, so a group's counters are
// always its own spawn's.
func (m *Manager) Create(name string, memoryBytes uint64) (*Group, error) {
	if !namePattern.MatchString(name) {
		return nil, fmt.Errorf("group name %q", name)
	}
	g := &Group{name: name, path: filepath.Join(m.root, name)}
	if err := os.Remove(g.path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("removing the group an earlier spawn left: %w", err)
	}
	if err := os.Mkdir(g.path, 0o755); err != nil {
		return nil, err
	}
	for _, f := range []struct{ file, value string }{
		{"memory.max", strconv.FormatUint(memoryBytes, 10)},
		{"memory.swap.max", "0"},
		{"memory.oom.group", "1"},
	} {
		if err := os.WriteFile(filepath.Join(g.path, f.file), []byte(f.value), 0o644); err != nil {
			_ = os.Remove(g.path)
			return nil, fmt.Errorf("%s: %w", f.file, err)
		}
	}
	return g, nil
}

// Path is the group as its processes read it in /proc/self/cgroup.
func (g *Group) Path() string { return "/" + g.name }

// Add moves the process pid, and with it everything it forks, into the group.
func (g *Group) Add(pid int) error {
	return os.WriteFile(filepath.Join(g.path, "cgroup.procs"), []byte(strconv.Itoa(pid)), 0o644)
}

// Kills is what the kernel's out-of-memory killer did to a group.
type Kills struct {
	// AtBound reports that the group reached its own bound and lost its
	// processes for it.
	AtBound bool
	// Outside reports that processes of the group were killed for a limit
	// above it, the container's, while the group was under its own bound.
	Outside bool
}

// Kills reads the group's memory.events: `oom` counts the times the group's
// own limit could not be met, `oom_kill` the processes of the group killed
// for any limit.
func (g *Group) Kills() (Kills, error) {
	raw, err := os.ReadFile(filepath.Join(g.path, "memory.events"))
	if err != nil {
		return Kills{}, err
	}
	events, err := parseEvents(raw)
	if err != nil {
		return Kills{}, err
	}
	killed := events["oom_kill"] > 0
	return Kills{AtBound: killed && events["oom"] > 0, Outside: killed && events["oom"] == 0}, nil
}

func parseEvents(raw []byte) (map[string]uint64, error) {
	events := map[string]uint64{}
	sc := bufio.NewScanner(bytes.NewReader(raw))
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) != 2 {
			return nil, fmt.Errorf("memory.events: malformed line %q", sc.Text())
		}
		n, err := strconv.ParseUint(fields[1], 10, 64)
		if err != nil {
			return nil, fmt.Errorf("memory.events: %w", err)
		}
		events[fields[0]] = n
	}
	for _, name := range []string{"oom", "oom_kill"} {
		if _, ok := events[name]; !ok {
			return nil, fmt.Errorf("memory.events: no %s line", name)
		}
	}
	return events, sc.Err()
}

// Remove removes the group once its processes are gone, waiting briefly for
// the last of them to be reaped.
func (g *Group) Remove() error {
	var err error
	for attempt := 0; attempt < removeAttempts; attempt++ {
		if err = os.Remove(g.path); err == nil || errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		time.Sleep(removeInterval)
	}
	return err
}

func hasField(s, field string) bool {
	for _, f := range strings.Fields(s) {
		if f == field {
			return true
		}
	}
	return false
}
