// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package guard

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cyfr/locus/keeper/internal/logx"
)

// recordMode runs standInRecords.
const recordMode = "CYFR_GUARD_TEST_RECORDS"

// A machine's route's raw-table line is read back as iptables lists it,
// the one form the route's rules install, its record and its removal read
// and the static rules' digest leaves out: on the real rules and kernel, a
// machine's route made and withdrawn leaves the guard's check passing at
// each point and no line of it in the raw table, and an ordinary route
// made and withdrawn leaves the check and the static rules' digest as they
// were.
func TestAMachinesRouteIsRecordedAndWithdrawnAsTheKernelListsIt(t *testing.T) {
	if os.Getuid() != 0 {
		t.Skip("the real rules are installed by root alone")
	}
	for _, tool := range []string{"iptables-restore", "ip6tables"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("this host has no %s: %v", tool, err)
		}
	}
	cmd := exec.Command(os.Args[0], "-test.run=^$")
	cmd.Env = append(os.Environ(), recordMode+"=1")
	cmd.SysProcAttr = userNetAttr()
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("the stand-in: %v\n%s", err, out)
	}
	for _, want := range []string{
		"records: the check passes before any route",
		"records: the check passes with a machine's route",
		"records: the machine's record holds its source line",
		"records: the check passes after the machine's withdrawal",
		"records: the raw table holds nothing of the machine",
		"records: the check passes with an ordinary route",
		"records: the check passes after the ordinary route's withdrawal",
		"records: the static rules' digest is as it was",
	} {
		if !strings.Contains(string(out), want) {
			t.Errorf("lacks %q:\n%s", want, out)
		}
	}
}

// standInRecords installs the static rules in a namespace of its own, then
// a machine's route and an ordinary one, and runs the guard's check at
// each point.
func standInRecords() int {
	fail := func(format string, args ...any) int {
		fmt.Printf("records: "+format+"\n", args...)
		return 1
	}
	log := logx.New("cyfr-guard-test")
	isl := island{controlPlane: "192.0.2.1", routes: []string{"198.51.100.0/24"}, subnets: []string{"198.51.100.0/24"}, local: []string{"198.51.100.1"}}
	st, err := staticRules(log, isl)
	if err != nil {
		return fail("%v", err)
	}
	for _, r := range st.rules {
		ctx, cancel := bounded()
		_, err := tool(ctx, "", false, r.tool(), append([]string{"-w", "5"}, r.args...)...)
		cancel()
		if err != nil {
			return fail("%s: %v", r, err)
		}
	}
	dir, err := os.MkdirTemp("", "cyfr-guard-records-")
	if err != nil {
		return fail("%v", err)
	}
	defer os.RemoveAll(dir)
	// The check reads the namespace's two settings the guard's compose
	// service makes: here a proc of the test's own holds them.
	proc := filepath.Join(dir, "proc")
	if err := os.MkdirAll(filepath.Join(proc, "sys/net/ipv4"), 0o755); err != nil {
		return fail("%v", err)
	}
	for name, v := range map[string]string{"ip_forward": "1", "icmp_ratelimit": "0"} {
		if err := os.WriteFile(filepath.Join(proc, "sys/net/ipv4", name), []byte(v+"\n"), 0o644); err != nil {
			return fail("%v", err)
		}
	}
	p := place{dir: dir, proc: proc}
	if err := os.MkdirAll(p.routes(), 0o755); err != nil {
		return fail("%v", err)
	}
	if err := writeFile(p.rangeFile(), st.rng+"\n"); err != nil {
		return fail("%v", err)
	}
	ctx, cancel := bounded()
	defer cancel()
	recorded, err := saves(ctx, log)
	if err != nil {
		return fail("%v", err)
	}
	if err := writeFile(p.ready(), recorded+"\n"); err != nil {
		return fail("%v", err)
	}
	lock, err := os.OpenFile(p.lock(), os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		return fail("%v", err)
	}
	k := &rulesOf{log: log, at: p, st: st, lock: lock, bound: applyTimeout}
	checked := func(when string) bool {
		if err := check(log, p); err != nil {
			fmt.Printf("records: the check fails %s: %v\n", when, err)
			return false
		}
		fmt.Printf("records: the check passes %s\n", when)
		return true
	}
	checked("before any route")
	rng, _ := ParseRange(st.rng)
	gw, inner := slotAddresses(rng, 0)
	machine := &route{slot: 0, gateway: gw, inner: inner, mark: 1, reach: ReachNone, machine: true, uid: vmmUID}
	if err := k.install(machine); err != nil {
		return fail("the machine's route: %v", err)
	}
	checked("with a machine's route")
	if rec, err := os.ReadFile(p.record(outerName(0))); err == nil && strings.Contains(string(rec), sourceLine(outerName(0), inner.String())) {
		fmt.Println("records: the machine's record holds its source line")
	}
	if err := k.withdraw(machine); err != nil {
		return fail("the machine's withdrawal: %v", err)
	}
	checked("after the machine's withdrawal")
	if raw, err := iptables(ctx, false, "-t", "raw", "-S", "PREROUTING"); err == nil && !strings.Contains(raw, outerName(0)) {
		fmt.Println("records: the raw table holds nothing of the machine")
	} else {
		fmt.Printf("records: the raw table holds %q (%v)\n", raw, err)
	}
	gw1, inner1 := slotAddresses(rng, 1)
	ordinary := &route{slot: 1, gateway: gw1, inner: inner1, mark: 2, reach: ReachIsland}
	if err := k.install(ordinary); err != nil {
		return fail("the ordinary route: %v", err)
	}
	checked("with an ordinary route")
	if err := k.withdraw(ordinary); err != nil {
		return fail("the ordinary route's withdrawal: %v", err)
	}
	checked("after the ordinary route's withdrawal")
	if now, err := saves(ctx, log); err == nil && now == recorded {
		fmt.Println("records: the static rules' digest is as it was")
	}
	return 0
}
