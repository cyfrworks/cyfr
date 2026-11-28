// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package cgroup bounds a spawn's memory and CPU with a cgroup v2 group of
// its own, of two levels: the mark, named for the spawn, and inside it the
// bound, the one leaf that holds the spawn's processes and both its bounds.
//
// The kernel charges a group for the pages its processes touch, the pages
// of the tmpfs files they write and the kernel memory they cause, and never
// lets the total pass the group's memory.max. A spawn's group is created
// with memory.max at its bound, memory.swap.max at zero, so the bound is
// not escaped into swap,
// memory.oom.group set, so a group that cannot stay under its bound loses
// every process at once rather than the one the kernel would pick, and
// cpu.max at its CPU quota over the fixed period, so its processes together
// use at most that share of the CPUs. Every process the spawn forks is born
// in the group. A process leaves a group only by a write to a cgroup.procs
// file, and every file here belongs to uid 0, so no spawned process moves
// itself, raises its bounds or clears the group kill.
//
// The mark is there to tell which limit killed. It has no limit of its own
// and memory.oom.group set. For an OOM the kernel kills the highest group
// with that set between the victim and the group whose limit could not be
// met, and counts oom_group_kill there and nowhere else in
// memory.events.local: in the bound for the spawn's own bound, which the
// walk never climbs past, and in the mark for any limit above it, the
// container's and the machine's included. One group cannot tell the two: an
// out-of-memory at its bound that killed nothing, then a kill from above,
// leaves the counters of a kill at the bound. So no group above a mark may
// set memory.oom.group.
//
// The namespace root holds the pool's tree (Tree), whose groups are all
// made before any memory bound is written, since the kernel makes no group
// under one whose memory.max is already below what a group costs:
//
//	service          no memory bound: the services are outside work
//	  keeper         the keeper and its helpers
//	  <role>         a role's process and its relays, at its service share
//	                 of the role's processors
//	work             memory.max W: every spawn of every role
//	  <floor role>   the role whose runners the warm floor keeps, at the
//	                 rest of its processors
//	  rest           memory.max W - F, so builds and programs never reach
//	                 the floor's memory
//	    <role>       every other role, at the rest of its processors
//
// A spawn's mark is made in its role's group under work. No group of the
// tree sets memory.oom.group, so a kill for work's or rest's bound is
// counted in the mark as a limit above the spawn's own, and every group of
// it has memory.swap.max 0.
//
// Groups can be made only where the keeper's own cgroup is the root of a
// cgroup namespace mounted writable, as a container started with Docker's
// `writable-cgroups=true` security option has it; Delegate reports anything
// else as the reason bounds are unavailable, and the keeper then refuses
// its boot. cgroup v2 lets a group hold processes or enable controllers for
// its children, not both, so Delegate first moves every
// process of the namespace root, the keeper among them, into the leaf
// group `service/keeper`, which has no bound; the keeper's retirement and
// home helpers stay there.
//
// Where the host mounts cgroup2 with `nsdelegate`, as systemd does, the
// kernel refuses a write from inside the namespace to the root's own limits,
// so what is delegated is only the division of the container's allotment.
// On a host without it uid 0 in the container can rewrite the container's
// own limits; only the keeper and the container's init run as uid 0.
package cgroup

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	// Root is where a container's cgroup namespace is mounted.
	Root = "/sys/fs/cgroup"
	// SelfPath names the file holding the calling process's own cgroup.
	SelfPath = "/proc/self/cgroup"
	// serviceGroup holds the keeper's leaf and each role's, workGroup every
	// spawn, and restGroup, in work, every role's but the floor role's.
	serviceGroup = "service"
	workGroup    = "work"
	restGroup    = "rest"
	// keeperLeaf is the group the namespace root's processes move to.
	keeperLeaf = serviceGroup + "/keeper"
	// drainAttempts and drainInterval bound the passes that empty the
	// namespace root and the wait between two: a process joining it between
	// two passes is moved by the next, and one of another pid namespace,
	// which no write here moves, has that long to leave.
	drainAttempts = 20
	drainInterval = 50 * time.Millisecond
	// boundLeaf is the bound inside a spawn's mark.
	boundLeaf = "bound"
	// settleAttempts and settleInterval bound the wait for the group kill's
	// count, which the kernel writes just after it signals the first victim.
	settleAttempts = 20
	settleInterval = 10 * time.Millisecond
	// removeAttempts and removeInterval bound the wait for a group's last
	// exited process to be reaped before the group can be removed.
	removeAttempts = 100
	removeInterval = 20 * time.Millisecond
)

// PollInterval is how often KillBy looks again at a group it waits for.
const PollInterval = removeInterval

var namePattern = regexp.MustCompile(`^keeper-([1-9][0-9]{0,9}|s-[0-9a-f]{32})$`)

var roleNamePattern = regexp.MustCompile(`^[a-z][a-z0-9]{0,15}$`)

// pause waits between two passes over the namespace root and between two
// readings of a kill whose count has not settled.
var pause = time.Sleep

// Name is the group of the spawn running under the pooled uid.
func Name(uid int) string { return "keeper-" + strconv.Itoa(uid) }

// SpawnName is the group of the kept-home spawn id: several spawns of one
// kept home share its uid, so each is grouped by its own id.
func SpawnName(id string) string { return "keeper-s-" + id }

// ValidName reports whether name is a spawn's group, by uid or by spawn id.
func ValidName(name string) bool { return namePattern.MatchString(name) }

// ValidRoleName reports whether name is a role's: a lowercase letter, then
// at most 15 lowercase letters and digits, and neither keeper nor rest,
// whose groups are the tree's own.
func ValidRoleName(name string) bool {
	return roleNamePattern.MatchString(name) && name != "keeper" && name != restGroup
}

// RoleLeaf is the role name's leaf as Own reads it of a process in it.
func RoleLeaf(name string) string { return "/" + serviceGroup + "/" + name }

// SplitPath splits a spawn's group as Own reads it, `/<name>`,
// `/work/<role>/<name>` or `/work/rest/<role>/<name>`, into its role, ""
// for none, and its name, which is a spawn's (ValidName). ok is false for
// any other path.
func SplitPath(p string) (role, name string, ok bool) {
	rest, abs := strings.CutPrefix(p, "/")
	if !abs {
		return "", "", false
	}
	parts := strings.Split(rest, "/")
	switch {
	case len(parts) == 1 && ValidName(parts[0]):
		return "", parts[0], true
	case len(parts) == 3 && parts[0] == workGroup && ValidRoleName(parts[1]) && ValidName(parts[2]):
		return parts[1], parts[2], true
	case len(parts) == 4 && parts[0] == workGroup && parts[1] == restGroup && ValidRoleName(parts[2]) && ValidName(parts[3]):
		return parts[2], parts[3], true
	}
	return "", "", false
}

// Manager makes groups under the root of the keeper's cgroup namespace, or
// under a role's group in work, whose path from that root is prefix.
type Manager struct {
	root   string
	prefix string
}

// Group is one spawn's group: its mark and, inside it, its bound; or a
// role's leaf, which has no mark.
type Group struct {
	// name is the group's path from the namespace root.
	name string
	mark string
	// path is the bound's: the spawn's processes, limits and use.
	path string
}

// Delegate prepares the namespace root at root for per-spawn groups. self is
// the content of the keeper's /proc/self/cgroup. An error says why bounds
// are unavailable here; nothing else has failed.
func Delegate(root string, self []byte) (*Manager, error) {
	if path, err := Own(self); err != nil {
		return nil, err
	} else if path != "/" && path != "/"+keeperLeaf {
		return nil, fmt.Errorf("the keeper's cgroup is %s, not the root of a cgroup namespace", path)
	}
	controllers, err := os.ReadFile(filepath.Join(root, "cgroup.controllers"))
	if err != nil {
		return nil, fmt.Errorf("%s is not a cgroup v2 mount: %w", root, err)
	}
	for _, controller := range enabled {
		if !hasField(string(controllers), controller) {
			return nil, fmt.Errorf("the %s controller is not enabled for %s", controller, root)
		}
	}
	// The root cgroup of the whole machine has no memory.max: a keeper
	// there would be dividing the host, not a container's allotment.
	if _, err := os.Stat(filepath.Join(root, "memory.max")); err != nil {
		return nil, fmt.Errorf("%s is not a delegated cgroup: %w", root, err)
	}
	leaf := filepath.Join(root, keeperLeaf)
	for _, dir := range []string{filepath.Dir(leaf), leaf} {
		if err := os.Mkdir(dir, 0o755); err != nil && !errors.Is(err, fs.ErrExist) {
			return nil, fmt.Errorf("%s is not writable: %w", root, err)
		}
	}
	for attempt := 1; ; attempt++ {
		hidden, err := drain(root, leaf)
		if err != nil {
			return nil, err
		}
		err = os.WriteFile(filepath.Join(root, "cgroup.subtree_control"), []byte("+memory +cpu"), 0o644)
		if err == nil {
			break
		}
		if attempt == drainAttempts {
			if hidden > 0 {
				err = fmt.Errorf("%w, with %d processes of another pid namespace in it", err, hidden)
			}
			return nil, fmt.Errorf("enabling the memory and cpu controllers under %s: %w", root, err)
		}
		pause(drainInterval)
	}
	if err := os.WriteFile(filepath.Join(root, serviceGroup, "cgroup.subtree_control"), []byte("+memory +cpu"), 0o644); err != nil {
		return nil, fmt.Errorf("enabling the memory and cpu controllers under %s: %w", filepath.Join(root, serviceGroup), err)
	}
	// A grandchild of the root now has the files a spawn's group is bounded
	// with, or this kernel cannot hold a group to its bounds: without swap
	// accounting a group swaps past it, without the group kill it loses one
	// process and lives on, without cpu.max it takes every CPU.
	for _, file := range boundFiles {
		if _, err := os.Stat(filepath.Join(leaf, file)); err != nil {
			return nil, fmt.Errorf("this kernel gives a group no %s: %w", file, err)
		}
	}
	return &Manager{root: root}, nil
}

// enabled are the controllers Delegate enables for the spawns' groups.
var enabled = []string{"memory", "cpu"}

// boundFiles are the control files Create writes.
var boundFiles = []string{"memory.max", "memory.swap.max", "memory.oom.group", "cpu.max"}

// CPUPeriod is the period, in microseconds, of every group's cpu.max: a
// quota of CPUPeriod is one CPU.
const CPUPeriod = 100_000

// drain moves every process of root it can see into leaf, and reports how
// many entries it could not see. cgroup.procs lists a process of another
// pid namespace as 0: a process no write here can name, and none of the
// keeper's, such as the runtime's own process entering the container for a
// `docker exec` as it restarts in place, so it is skipped, and the passes
// wait drainInterval apart for it to leave. A process that exited between
// the read and the write cannot be moved and need not be; one it can see
// that is still listed after every pass is named in the error with what
// the last write to move it answered and what /proc says it is, so a
// leftover process, an unreaped zombie and a write the cgroup driver
// refuses read apart.
func drain(root, leaf string) (int, error) {
	var pids []string
	hidden := 0
	failed := map[string]error{}
	for attempt := 0; attempt < drainAttempts; attempt++ {
		if attempt > 0 {
			pause(drainInterval)
		}
		raw, err := os.ReadFile(filepath.Join(root, "cgroup.procs"))
		if err != nil {
			return 0, err
		}
		pids, hidden = pids[:0], 0
		for _, pid := range strings.Fields(string(raw)) {
			if pid == "0" {
				hidden++
			} else {
				pids = append(pids, pid)
			}
		}
		if len(pids) == 0 {
			return hidden, nil
		}
		clear(failed)
		for _, pid := range pids {
			if err := os.WriteFile(filepath.Join(leaf, "cgroup.procs"), []byte(pid), 0o644); err != nil {
				failed[pid] = err
			}
		}
	}
	remaining := make([]string, 0, len(pids))
	for _, pid := range pids {
		moved := "the write succeeded yet it is still listed"
		if err, ok := failed[pid]; ok {
			moved = "moving it: " + err.Error()
		}
		remaining = append(remaining, fmt.Sprintf("pid %s (%s; %s)", pid, describe(pid), moved))
	}
	return hidden, fmt.Errorf("processes remain in %s: %s", root, strings.Join(remaining, ", "))
}

// describe is what /proc says of a process: its command and its state, a
// zombie among them, or why it cannot say.
func describe(pid string) string {
	comm, err := os.ReadFile(filepath.Join("/proc", pid, "comm"))
	if err != nil {
		return "no /proc entry: " + err.Error()
	}
	state := "state unknown"
	if status, err := os.ReadFile(filepath.Join("/proc", pid, "status")); err == nil {
		for _, line := range strings.Split(string(status), "\n") {
			if value, ok := strings.CutPrefix(line, "State:"); ok {
				state = "state " + strings.TrimSpace(value)
				break
			}
		}
	}
	return strings.TrimSpace(string(comm)) + ", " + state
}

// Own returns the group a /proc/<pid>/cgroup file says the process is in: a
// cgroup v2 path, with a spawn's bound read as the spawn's group (Path). A
// file naming any other hierarchy is refused, the bound being a cgroup v2
// one, and so is a spawn's mark, which bounds nothing.
func Own(self []byte) (string, error) {
	lines := strings.Split(strings.TrimSpace(string(self)), "\n")
	if len(lines) != 1 || !strings.HasPrefix(lines[0], "0::/") {
		return "", errors.New("the process is not in a cgroup v2 hierarchy alone")
	}
	in := strings.TrimPrefix(lines[0], "0::")
	if mark, ok := strings.CutSuffix(in, "/"+boundLeaf); ok {
		if _, _, spawn := SplitPath(mark); spawn {
			return mark, nil
		}
	}
	if _, _, spawn := SplitPath(in); spawn {
		return "", fmt.Errorf("the process is in the mark of %s, outside its bound", in)
	}
	return in, nil
}

// Create makes the group name: its mark, and inside it the bound with the
// memory bound and the CPU quota, in microseconds of every CPUPeriod. A
// group of that name left by an earlier spawn is removed first, so a group's
// counters are always its own spawn's.
func (m *Manager) Create(name string, memoryBytes, cpuQuota uint64) (*Group, error) {
	if !namePattern.MatchString(name) {
		return nil, fmt.Errorf("group name %q", name)
	}
	mark := filepath.Join(m.root, name)
	g := &Group{name: path.Join(m.prefix, name), mark: mark, path: filepath.Join(mark, boundLeaf)}
	for _, dir := range []string{g.path, g.mark} {
		if err := os.Remove(dir); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return nil, fmt.Errorf("removing the group an earlier spawn left: %w", err)
		}
	}
	if err := g.make(memoryBytes, cpuQuota); err != nil {
		_ = os.Remove(g.path)
		_ = os.Remove(g.mark)
		return nil, err
	}
	return g, nil
}

// A Tree is the pool's groups (the package doc's tree): service and work,
// and in work rest. NewTree makes them with their controllers and no memory
// bound; each role's groups are made in it (Role), and only then are work's
// and rest's bounds written (Bound).
type Tree struct {
	root string
}

// mkdir and write are the tree's two acts on the cgroup filesystem, apart
// so a test can read their order.
var (
	mkdir = os.Mkdir
	write = os.WriteFile
)

// NewTree makes the pool's groups under the namespace root m manages: those
// an earlier keeper left are kept, empty of processes as they must be, and
// each group's controllers are enabled and its swap is 0. No memory bound
// is written: work's and rest's stay unbounded until Bound.
func (m *Manager) NewTree() (*Tree, error) {
	if m.prefix != "" {
		return nil, errors.New("a tree inside a role's group")
	}
	for _, dir := range []string{serviceGroup, workGroup, workGroup + "/" + restGroup} {
		if err := makeGroup(filepath.Join(m.root, dir), true); err != nil {
			return nil, err
		}
	}
	// A bound an earlier keeper wrote is lifted until Bound, so no group is
	// made under one already at 0.
	for _, dir := range []string{workGroup, workGroup + "/" + restGroup} {
		if err := write(filepath.Join(m.root, dir, "memory.max"), []byte("max"), 0o644); err != nil {
			return nil, fmt.Errorf("memory.max of %s: %w", dir, err)
		}
	}
	return &Tree{root: m.root}, nil
}

// makeGroup makes the group dir, unless it exists, with swap 0, and when it
// is a parent the memory and cpu controllers for its children.
func makeGroup(dir string, parent bool) error {
	if err := mkdir(dir, 0o755); err != nil && !errors.Is(err, fs.ErrExist) {
		return err
	}
	settings := [][2]string{{"memory.swap.max", "0"}}
	if parent {
		settings = append(settings, [2]string{"cgroup.subtree_control", "+memory +cpu"})
	}
	for _, s := range settings {
		if err := write(filepath.Join(dir, s[0]), []byte(s[1]), 0o644); err != nil {
			return fmt.Errorf("%s of %s: %w", s[0], dir, err)
		}
	}
	return nil
}

// A role's processors, in microseconds of every CPUPeriod, zero for no
// bound: the role's whole bound, split between its service and its work.
// ServiceCPU is what its service is given of a bound of cpu: the lesser of
// half a processor and half the bound; its work has the rest. Neither lends
// to the other.
func ServiceCPU(cpu uint64) uint64 { return min(CPUPeriod/2, cpu/2) }

// Role makes the role name's two groups: its leaf in service, which holds
// its process and its relays, and its group in work, in which its spawns'
// groups are made, directly in work for the floor's role and in rest for
// every other. A bound of cpu is split between the two (ServiceCPU). It
// answers the Manager of its spawns' groups and its leaf. Groups of that
// name an earlier keeper left are removed first: every group of a spawn or
// a VM it left in them is ended (cgroup.kill) and removed, so nothing of
// an earlier keeper's runs while this one admits.
func (t *Tree) Role(name string, cpu uint64, floor bool) (*Manager, *Group, error) {
	if !ValidRoleName(name) {
		return nil, nil, fmt.Errorf("role group %q", name)
	}
	prefix := workGroup + "/" + restGroup + "/" + name
	if floor {
		prefix = workGroup + "/" + name
	}
	work := filepath.Join(t.root, prefix)
	leaf := &Group{name: serviceGroup + "/" + name, path: filepath.Join(t.root, serviceGroup, name)}
	if err := endLeft(work); err != nil {
		return nil, nil, fmt.Errorf("ending the groups an earlier keeper left in role %s's: %w", name, err)
	}
	for _, d := range []string{leaf.path, work} {
		if err := os.Remove(d); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return nil, nil, fmt.Errorf("removing the group an earlier keeper left: %w", err)
		}
	}
	service := cpu
	if cpu > 0 {
		service = ServiceCPU(cpu)
	}
	for _, g := range []struct {
		dir    string
		parent bool
		cpu    uint64
	}{{leaf.path, false, service}, {work, true, cpu - service}} {
		if err := makeGroup(g.dir, g.parent); err != nil {
			return nil, nil, fmt.Errorf("role %s: %w", name, err)
		}
		if g.cpu > 0 {
			if err := write(filepath.Join(g.dir, "cpu.max"), []byte(strconv.FormatUint(g.cpu, 10)+" "+strconv.Itoa(CPUPeriod)), 0o644); err != nil {
				return nil, nil, fmt.Errorf("cpu.max of role %s: %w", name, err)
			}
		}
	}
	return &Manager{root: work, prefix: prefix}, leaf, nil
}

// endLeft ends and removes every group under dir an earlier keeper left:
// each child's processes by the kernel's group kill, until its events say
// it is empty or the bound passes, then its groups from the innermost out.
func endLeft(dir string) error {
	children, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, c := range children {
		if !c.IsDir() {
			continue
		}
		child := filepath.Join(dir, c.Name())
		populated := func() bool {
			events, err := os.ReadFile(filepath.Join(child, "cgroup.events"))
			return err == nil && !slices.Contains(strings.Split(string(events), "\n"), "populated 0")
		}
		for attempt := 0; attempt < removeAttempts && populated(); attempt++ {
			_ = os.WriteFile(filepath.Join(child, "cgroup.kill"), []byte("1"), 0o644)
			time.Sleep(removeInterval)
		}
		if populated() {
			return fmt.Errorf("group %s still holds processes after its kill", child)
		}
		if err := endLeft(child); err != nil {
			return err
		}
		if err := removeEmpty(child); err != nil {
			return err
		}
	}
	return nil
}

// Bound writes work's memory bound and rest's, once every group of the
// tree is made.
func (t *Tree) Bound(work, rest uint64) error {
	for _, b := range []struct {
		dir   string
		bytes uint64
	}{{workGroup, work}, {workGroup + "/" + restGroup, rest}} {
		if err := write(filepath.Join(t.root, b.dir, "memory.max"), []byte(strconv.FormatUint(b.bytes, 10)), 0o644); err != nil {
			return fmt.Errorf("memory.max of %s: %w", b.dir, err)
		}
	}
	return nil
}

// Limit is the memory.max of the namespace root m manages, the container's
// own limit, and false where it has none.
func (m *Manager) Limit() (uint64, bool, error) {
	raw, err := os.ReadFile(filepath.Join(m.root, "memory.max"))
	if err != nil {
		return 0, false, err
	}
	value := strings.TrimSpace(string(raw))
	if value == "max" {
		return 0, false, nil
	}
	bytes, err := strconv.ParseUint(value, 10, 64)
	if err != nil {
		return 0, false, fmt.Errorf("memory.max of %s holds %q", m.root, value)
	}
	return bytes, true, nil
}

// Path is the manager's group as Own reads it, "/" for the namespace root.
func (m *Manager) Path() string { return "/" + m.prefix }

// Dir is the directory the manager makes its groups in.
func (m *Manager) Dir() string { return m.root }

// Kill ends every process of the manager's group and of every group in it
// at once, by the kernel's group kill (cgroup.kill), and reports whether
// the group holds no process within the bound (cgroup.events).
func (m *Manager) Kill() bool {
	empty := func() bool {
		events, err := os.ReadFile(filepath.Join(m.root, "cgroup.events"))
		return err == nil && slices.Contains(strings.Split(string(events), "\n"), "populated 0")
	}
	for attempt := 0; attempt < removeAttempts; attempt++ {
		if empty() {
			return true
		}
		_ = os.WriteFile(filepath.Join(m.root, "cgroup.kill"), []byte("1"), 0o644)
		time.Sleep(removeInterval)
	}
	return empty()
}

func (g *Group) make(memoryBytes, cpuQuota uint64) error {
	type setting struct{ file, value string }
	for _, level := range []struct {
		dir      string
		settings []setting
	}{
		{g.mark, []setting{
			{"memory.oom.group", "1"},
			{"cgroup.subtree_control", "+memory +cpu"},
		}},
		{g.path, []setting{
			{"memory.max", strconv.FormatUint(memoryBytes, 10)},
			{"memory.swap.max", "0"},
			{"memory.oom.group", "1"},
			{"cpu.max", strconv.FormatUint(cpuQuota, 10) + " " + strconv.Itoa(CPUPeriod)},
		}},
	} {
		if err := os.Mkdir(level.dir, 0o755); err != nil {
			return err
		}
		for _, s := range level.settings {
			if err := os.WriteFile(filepath.Join(level.dir, s.file), []byte(s.value), 0o644); err != nil {
				return fmt.Errorf("%s: %w", s.file, err)
			}
		}
	}
	return nil
}

// Path is the spawn's group as Own reads it of a process in its bound.
func (g *Group) Path() string { return "/" + g.name }

// Add moves the process pid, and with it everything it forks, into the group.
func (g *Group) Add(pid int) error {
	return os.WriteFile(filepath.Join(g.path, "cgroup.procs"), []byte(strconv.Itoa(pid)), 0o644)
}

// Cause is what the kernel's out-of-memory killer killed processes of a
// group for.
type Cause int

const (
	// NotKilled: it killed none.
	NotKilled Cause = iota
	// AtBound: the group reached its own bound and lost its processes for it.
	AtBound
	// Above: a limit above the group's, the container's or the machine's,
	// killed them.
	Above
	// Either: it killed them, and the counters do not say for which of the
	// two, so it is neither's to name.
	Either
)

// KilledFor reads the cause from the memory.events.local of the bound and of
// the mark (the package says why). A kill counted in both levels is Either.
// With no count in the mark, a bound that never ran out of memory was killed
// from above, since the kernel counts `oom` before it kills at a bound. One
// that did run out waits for the group kill's count, and is Either if none
// comes, as on a kernel older than 5.17, which keeps no oom_group_kill.
func (g *Group) KilledFor() (Cause, error) {
	for attempt := 0; ; attempt++ {
		bound, err := counters(filepath.Join(g.path, "memory.events.local"), "oom", "oom_kill")
		if err != nil {
			return NotKilled, err
		}
		if bound["oom_kill"] == 0 {
			return NotKilled, nil
		}
		mark, err := counters(filepath.Join(g.mark, "memory.events.local"), "oom", "oom_kill")
		if err != nil {
			return NotKilled, err
		}
		atBound, above := bound["oom_group_kill"] > 0, mark["oom_group_kill"] > 0
		_, counted := bound["oom_group_kill"]
		switch {
		case atBound && above:
			return Either, nil
		case atBound:
			return AtBound, nil
		case above || bound["oom"] == 0:
			return Above, nil
		case !counted || attempt == settleAttempts:
			return Either, nil
		}
		pause(settleInterval)
	}
}

// kernelParts are the kernel memory a memory.stat names where it has no
// `kernel` line (before 5.18), each charged apart from the others and none
// given back under pressure: not every kernel names each, and together they
// are less than that line.
var kernelParts = []string{"kernel_stack", "pagetables", "percpu", "vmalloc", "slab_unreclaimable"}

// Use is one reading of what a group uses.
type Use struct {
	Bytes uint64
	// Lesser says that the kernel counts no `kernel` line and Bytes is the
	// lesser sum, of the parts of it that kernel names.
	Lesser bool
}

// Used is the memory the group uses that cannot be given back, from one read
// of its memory.stat, which is one snapshot: anon + shmem + kernel -
// slab_reclaimable. File cache is none of it, a program's own code included,
// whatever the kernel's reclaim takes for active: a session that only reads
// must refuse no other while that memory is free. A tmpfs's pages are shmem.
// Without a `kernel` line it is anon + shmem + kernelParts and says Lesser. A
// stat that does not read, or that leaves nothing in use, is an error, never
// a zero.
//
// The kernel writes the one snapshot from counts it folds in batches of 64
// pages a CPU, or every two seconds: a reading may trail the charges by
// that, so a session just started can be an error for that long and a small
// one read low by up to its own size.
func (g *Group) Used() (Use, error) {
	stat, err := counters(filepath.Join(g.path, "memory.stat"), "anon", "shmem")
	if err != nil {
		return Use{}, err
	}
	held := stat["anon"] + stat["shmem"]
	var givenBack uint64
	kernel, whole := stat["kernel"]
	if whole {
		reclaimable, ok := stat["slab_reclaimable"]
		if !ok {
			return Use{}, errors.New("memory.stat: a kernel line and no slab_reclaimable line")
		}
		held, givenBack = held+kernel, reclaimable
	} else {
		for _, part := range kernelParts {
			held += stat[part]
		}
	}
	if held <= givenBack {
		return Use{}, errors.New("memory.stat counts nothing in use")
	}
	return Use{Bytes: held - givenBack, Lesser: !whole}, nil
}

// counters reads a cgroup file of `name count` lines that holds every name
// required.
func counters(file string, required ...string) (map[string]uint64, error) {
	raw, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	base := filepath.Base(file)
	counts := map[string]uint64{}
	sc := bufio.NewScanner(bytes.NewReader(raw))
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) != 2 {
			return nil, fmt.Errorf("%s: malformed line %q", base, sc.Text())
		}
		n, err := strconv.ParseUint(fields[1], 10, 64)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", base, err)
		}
		counts[fields[0]] = n
	}
	for _, name := range required {
		if _, ok := counts[name]; !ok {
			return nil, fmt.Errorf("%s: no %s line", base, name)
		}
	}
	return counts, sc.Err()
}

// Procs lists the processes in the group.
func (g *Group) Procs() ([]int, error) {
	raw, err := os.ReadFile(filepath.Join(g.path, "cgroup.procs"))
	if err != nil {
		return nil, err
	}
	var pids []int
	for _, field := range strings.Fields(string(raw)) {
		pid, err := strconv.Atoi(field)
		if err != nil {
			return nil, fmt.Errorf("cgroup.procs: %q", field)
		}
		pids = append(pids, pid)
	}
	return pids, nil
}

// Signal sends sig to every process in the group. A process may leave its
// group only by a write its uid cannot make, so the group is every process
// the spawn started.
func (g *Group) Signal(sig syscall.Signal) error {
	pids, err := g.Procs()
	if err != nil {
		return err
	}
	for _, pid := range pids {
		_ = syscall.Kill(pid, sig)
	}
	return nil
}

// Kill ends every process in the group within grace (KillBy).
func (g *Group) Kill(grace time.Duration) bool {
	return g.KillBy(time.Now().Add(grace))
}

// KillBy ends every process in the group by deadline: SIGTERM to each when
// the deadline has not passed, waits for them to exit until that instant,
// never past it, then the kernel's group kill (cgroup.kill), so the kill is
// sent within one poll of the deadline, until the group is empty or the
// bound passes. It reports whether the group is empty.
func (g *Group) KillBy(deadline time.Time) bool {
	empty := func() bool {
		pids, err := g.Procs()
		return err == nil && len(pids) == 0
	}
	if time.Now().Before(deadline) {
		_ = g.Signal(syscall.SIGTERM)
		for !empty() {
			left := time.Until(deadline)
			if left <= 0 {
				break
			}
			time.Sleep(min(removeInterval, left))
		}
	}
	for attempt := 0; attempt < removeAttempts; attempt++ {
		if empty() {
			return true
		}
		if err := os.WriteFile(filepath.Join(g.path, "cgroup.kill"), []byte("1"), 0o644); err != nil {
			_ = g.Signal(syscall.SIGKILL)
		}
		time.Sleep(removeInterval)
	}
	return empty()
}

// Remove removes the group, its bound and then its mark, once its processes
// are gone, waiting briefly for the last of them to be reaped.
func (g *Group) Remove() error {
	for _, dir := range []string{g.path, g.mark} {
		if dir == "" {
			continue
		}
		if err := removeEmpty(dir); err != nil {
			return err
		}
	}
	return nil
}

func removeEmpty(dir string) error {
	var err error
	for attempt := 0; attempt < removeAttempts; attempt++ {
		if err = os.Remove(dir); err == nil || errors.Is(err, fs.ErrNotExist) {
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
