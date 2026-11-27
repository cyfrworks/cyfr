// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package guard

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// The saves the stand-in tools print, and the digest of them.
const (
	standInFilter = "*filter\n:INPUT ACCEPT [0:0]\n-A OUTPUT -j CYFR_GUARD\nCOMMIT\n"
	standInNat    = "*nat\n:CYFR_GUARD_ROLES - [0:0]\nCOMMIT\n"
)

// standInTools puts iptables tools first on PATH that take every rule and
// list a namespace holding the static rules and no route, as a guard's own
// namespace does once its rules are in.
func standInTools(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	tools := map[string]string{
		"iptables": `case "$*" in
"-w 5 -S") echo '-P INPUT ACCEPT' ;;
"-w 5 -S CYFR_GUARD_ROUTES") echo '-N CYFR_GUARD_ROUTES' ;;
"-w 5 -S CYFR_GUARD_REPLIES") echo '-N CYFR_GUARD_REPLIES' ;;
"-w 5 -t nat -S CYFR_GUARD_ROLES") echo '-N CYFR_GUARD_ROLES' ;;
esac`,
		"ip6tables":        "",
		"iptables-restore": "cat >/dev/null",
		"iptables-save":    `if [ "$2" = nat ]; then printf '` + strings.ReplaceAll(standInNat, "\n", `\n`) + `'; else printf '` + strings.ReplaceAll(standInFilter, "\n", `\n`) + `'; fi`,
		"ip6tables-save":   `printf '` + strings.ReplaceAll(standInFilter, "\n", `\n`) + `'`,
	}
	for name, body := range tools {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+body+"\nexit 0\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
}

// aPlace is a guard's folder holding what an earlier guard left (its
// ready file and a route's record), and a /proc of a namespace on one
// island subnet whose forwarding is forward.
func aPlace(t *testing.T, forward string) place {
	t.Helper()
	root := t.TempDir()
	p := place{dir: filepath.Join(root, "run"), proc: filepath.Join(root, "proc")}
	files := map[string]string{
		"run/ready":                        "an earlier guard's digest\n",
		"run/routes/sp0":                   "-N CYFR_GUARD_R0\n",
		"proc/sys/net/ipv4/ip_forward":     forward + "\n",
		"proc/sys/net/ipv4/icmp_ratelimit": "0\n",
		"proc/net/route": "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n" +
			"eth0\t000012AC\t00000000\t0001\t0\t0\t0\t0000FFFF\t0\t0\t0\n",
		"proc/net/ipv6_route": "",
		"proc/net/fib_trie":   "Local:\n     |-- 172.18.0.3\n        /32 host LOCAL\n",
	}
	for name, content := range files {
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(p.proc, "self/ns"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("net:[4026531840]", filepath.Join(p.proc, "self/ns/net")); err != nil {
		t.Fatal(err)
	}
	return p
}

// aStart is a guard's start in p, its control on socket, logging to out.
func aStart(p place, socket string) (starting, fmt.Stringer) {
	log, out := logged()
	env := map[string]string{"CYFR_GUARD_CONTROL_PLANE": controlPlane, "CYFR_GUARD_CONTROL": socket}
	return starting{log: log, at: p, env: func(k string) string { return env[k] },
		resolve: func(string) []string { return nil }, conntrack: func() error { return nil }}, out
}

func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

// A guard that cannot bring its control up is never reported healthy: its
// rules are in, but the ready file is written only once the control
// listens, so the health check finds none.
func TestAGuardThatCannotBringItsControlUpIsNeverReady(t *testing.T) {
	standInTools(t)
	p := aPlace(t, "1")
	// The control's folder is a file: no socket can be made in it.
	notADir := filepath.Join(t.TempDir(), "control")
	if err := os.WriteFile(notADir, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	g, out := aStart(p, filepath.Join(notADir, "guard.sock"))
	listener, _, code := g.start()
	if listener != nil || code != ExitConfig {
		t.Fatalf("the guard served with no control: %v %d\n%s", listener, code, out)
	}
	if !strings.Contains(out.String(), "routes take 10.213.0.0/16") || !strings.Contains(out.String(), "refusing to start: ") {
		t.Fatalf("the guard did not install its rules, then refuse its control:\n%s", out)
	}
	if exists(p.ready()) {
		t.Fatalf("a guard with no control wrote its ready file:\n%s", out)
	}
	clog, cout := logged()
	if check(clog, p) == nil || !strings.Contains(cout.String(), "not ready: "+p.ready()+" is absent") {
		t.Fatalf("the health check passed a guard with no control:\n%s", cout)
	}
}

// A guard that starts again removes the ready file and the routes' records
// an earlier one left before anything else, so a start it refuses is
// never healthy on what the earlier guard recorded.
func TestAGuardsStartRemovesWhatAnEarlierOneLeftFirst(t *testing.T) {
	standInTools(t)
	p := aPlace(t, "0")
	g, out := aStart(p, filepath.Join(t.TempDir(), "guard.sock"))
	if listener, _, code := g.start(); listener != nil || code != ExitRefused {
		t.Fatalf("a guard without forwarding started: %d\n%s", code, out)
	}
	if !strings.Contains(out.String(), "[cyfr-guard] error: net.ipv4.ip_forward is '0' in this namespace, not 1") {
		t.Fatalf("the refusal is not named:\n%s", out)
	}
	if exists(p.ready()) || exists(p.record("sp0")) {
		t.Fatalf("the earlier guard's ready file or record survives a refused start")
	}
}

// The health check takes the lock shared, waiting at most its bound for a
// route's change, which holds it exclusively, to end; it then compares
// what the kernel holds with what the guard recorded.
func TestTheCheckWaitsForARouteChangeAndComparesTheRecords(t *testing.T) {
	standInTools(t)
	p := aPlace(t, "1")
	want := digest(standInFilter, standInFilter, standInNat)
	if err := os.WriteFile(p.ready(), []byte(want+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(p.routes()); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p.rangeFile(), []byte("10.213.0.0/16\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	log, out := logged()
	if err := check(log, p); err != nil {
		t.Fatalf("the check refused the rules recorded:\n%s", out)
	}

	lock, err := os.OpenFile(p.lock(), os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	log, out = logged()
	began := time.Now()
	if err := check(log, p); err == nil || !strings.Contains(out.String(), "not ready: the rules are changing") {
		t.Fatalf("the check passed during a route's change:\n%s", out)
	}
	if waited := time.Since(began); waited < checkLockWait || waited > checkLockWait+5*time.Second {
		t.Fatalf("the check waited %s for the change, not its bound %s", waited, checkLockWait)
	}
	released := make(chan error, 1)
	go func() {
		log, _ := logged()
		released <- check(log, p)
	}()
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_UN); err != nil {
		t.Fatal(err)
	}
	if err := <-released; err != nil {
		t.Fatalf("the check refused once the change ended: %v", err)
	}

	// A rule set that is not the one recorded, and a route the guard holds
	// no record of, are refused.
	if err := os.WriteFile(p.ready(), []byte(strings.Repeat("0", 64)+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	log, out = logged()
	if check(log, p) == nil || !strings.Contains(out.String(), "not ready: the rules installed are not the ones recorded") {
		t.Fatalf("the check passed rules not recorded:\n%s", out)
	}
	if err := os.WriteFile(p.ready(), []byte(want+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(p.routes(), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p.record("sp4"), []byte("-N CYFR_GUARD_R4\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	log, out = logged()
	if check(log, p) == nil || !strings.Contains(out.String(), "not ready: the routes' chains are not the routes the guard recorded") {
		t.Fatalf("the check passed a record of a route the kernel does not hold:\n%s", out)
	}
}
