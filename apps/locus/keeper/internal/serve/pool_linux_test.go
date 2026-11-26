// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/logx"
)

// orderedTree is a pool tree that notes each call makePool makes of it, in
// order, before the tree acts.
type orderedTree struct {
	tree  *cgroup.Tree
	calls []string
}

func (o *orderedTree) Role(name string, cpu uint64, floor bool) (*cgroup.Manager, *cgroup.Group, error) {
	o.calls = append(o.calls, "role "+name)
	return o.tree.Role(name, cpu, floor)
}

func (o *orderedTree) Bound(work, rest uint64) error {
	o.calls = append(o.calls, fmt.Sprintf("bound %d %d", work, rest))
	return o.tree.Bound(work, rest)
}

// fakeNamespaceRoot stands in for a delegated cgroup namespace's root, the
// container's own memory.max being limit ("max" for none), with the files
// the kernel gives the keeper's leaf.
func fakeNamespaceRoot(t *testing.T, limit string) *cgroup.Manager {
	t.Helper()
	root := t.TempDir()
	for name, content := range map[string]string{"cgroup.controllers": "cpu memory\n", "memory.max": limit + "\n", "cgroup.procs": ""} {
		if err := os.WriteFile(filepath.Join(root, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	leaf := filepath.Join(root, "service", "keeper")
	if err := os.MkdirAll(leaf, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, file := range []string{"memory.max", "memory.swap.max", "memory.oom.group", "cpu.max"} {
		if err := os.WriteFile(filepath.Join(leaf, file), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	m, err := cgroup.Delegate(root, []byte("0::/\n"))
	if err != nil {
		t.Fatal(err)
	}
	return m
}

const poolMiB = 1 << 20

// The boot's own making of the pool: from a scripted MemTotal and container
// limit, at the shipped reserve and share, every role's groups are made
// before work's and rest's bounds are written, once, and each group holds
// the bounds of the sizing rule and of its role's processors; F is kept
// only where a role keeps the floor; and a pool of no work says which of
// the machine's memory and the container's limit left it none.
func TestThePoolIsMadeByTheSizingRuleAndBoundLast(t *testing.T) {
	roles := func(floor bool) []*role {
		return []*role{
			{spec: RoleSpec{Name: "runtime", Floor: floor}},
			{spec: RoleSpec{Name: "builds"}},
			{spec: RoleSpec{Name: "backends"}},
		}
	}
	cpus := []uint64{400_000, 200_000, 0}
	for name, c := range map[string]struct {
		total, limit string
		floor        bool
		work, rest   uint64
		warning      string
	}{
		"an 8 GiB machine":             {"8126464", "max", true, 4832 * poolMiB, 4668 * poolMiB, ""},
		"a 4 GiB machine":              {"3801088", "max", true, 608 * poolMiB, 444 * poolMiB, ""},
		"a container's smaller limit":  {"8126464", "2147483648", true, 1248 * poolMiB, 1084 * poolMiB, ""},
		"no role keeping the floor":    {"3801088", "max", false, 608 * poolMiB, 608 * poolMiB, ""},
		"a machine of no work":         {"3178496", "max", true, 0, 0, "the machine's 3104 MiB less the reserve, 2304 MiB,"},
		"a container that leaves none": {"8126464", "629145600", true, 0, 0, "the container's own limit of 600 MiB"},
	} {
		t.Run(name, func(t *testing.T) {
			memory := fakeNamespaceRoot(t, c.limit)
			meminfo := filepath.Join(t.TempDir(), "meminfo")
			if err := os.WriteFile(meminfo, []byte("MemTotal:       "+c.total+" kB\nMemFree:         1 kB\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			tree, err := memory.NewTree()
			if err != nil {
				t.Fatal(err)
			}
			ordered := &orderedTree{tree: tree}
			var logged bytes.Buffer
			rs := roles(c.floor)
			sizes, err := makePool(logx.NewWriter(&logged, "cyfr-locus", false), ordered, rs, cpus, memory, meminfo, 2304*poolMiB, 800*poolMiB)
			if err != nil {
				t.Fatal(err)
			}
			want := []string{"role runtime", "role builds", "role backends", fmt.Sprintf("bound %d %d", c.work, c.rest)}
			if strings.Join(ordered.calls, "; ") != strings.Join(want, "; ") {
				t.Fatalf("the pool was made as %q, want %q", ordered.calls, want)
			}
			if sizes.Work != c.work || sizes.Rest != c.rest {
				t.Errorf("sizes %+v", sizes)
			}
			files := map[string]string{
				"work/memory.max": fmt.Sprint(c.work), "work/rest/memory.max": fmt.Sprint(c.rest),
				"service/builds/cpu.max": "50000 100000", "work/rest/builds/cpu.max": "150000 100000",
				"service/runtime/cpu.max": "50000 100000",
			}
			if c.floor {
				files["work/runtime/cpu.max"] = "350000 100000"
			} else {
				files["work/rest/runtime/cpu.max"] = "350000 100000"
			}
			for _, group := range []string{"service", "work", "work/rest", "service/backends", "work/rest/backends"} {
				files[group+"/memory.swap.max"] = "0"
			}
			for file, value := range files {
				if got, err := os.ReadFile(filepath.Join(memory.Dir(), file)); err != nil || string(got) != value {
					t.Errorf("%s: %q, %v; want %q", file, got, err, value)
				}
			}
			for _, file := range []string{"service/backends/cpu.max", "work/rest/backends/cpu.max", "service/memory.max"} {
				if _, err := os.Stat(filepath.Join(memory.Dir(), file)); err == nil {
					t.Errorf("%s is written", file)
				}
			}
			for i, r := range rs {
				if r.groups == nil || r.leaf == nil || r.leaf.Path() != "/service/"+r.spec.Name {
					t.Errorf("role %d's groups: %+v %+v", i, r.groups, r.leaf)
				}
			}
			if warned := strings.Contains(logged.String(), "no memory for work"); warned != (c.warning != "") ||
				!strings.Contains(logged.String(), c.warning) {
				t.Errorf("the log %q, want a warning naming %q", logged.String(), c.warning)
			}
		})
	}
}
