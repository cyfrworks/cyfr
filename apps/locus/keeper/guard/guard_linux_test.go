// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package guard

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"reflect"
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
// list a namespace holding the static rules, as a guard's own namespace
// does once its rules are in, and each route's chains when asked for them.
func standInTools(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	tools := map[string]string{
		"iptables": `case "$*" in
"-w 5 -S") echo '-P INPUT ACCEPT' ;;
"-w 5 -S CYFR_GUARD_ROUTES") echo '-N CYFR_GUARD_ROUTES' ;;
"-w 5 -S CYFR_GUARD_REPLIES") echo '-N CYFR_GUARD_REPLIES' ;;
"-w 5 -t nat -S CYFR_GUARD_ROLES") echo '-N CYFR_GUARD_ROLES' ;;
"-w 5 -S CYFR_GUARD_R"[0-9]*|"-w 5 -S CYFR_GUARD_P"[0-9]*) echo "-N $4" ;;
esac`,
		"ip6tables":        "",
		"iptables-restore": "cat >/dev/null",
		"iptables-save":    `case "$2" in nat) printf '` + strings.ReplaceAll(standInNat, "\n", `\n`) + `' ;; raw) ;; *) printf '` + strings.ReplaceAll(standInFilter, "\n", `\n`) + `' ;; esac`,
		"ip6tables-save":   `case "$2" in raw) ;; *) printf '` + strings.ReplaceAll(standInFilter, "\n", `\n`) + `' ;; esac`,
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
		resolve: func(string, string) []string { return nil }, conntrack: func() error { return nil }}, out
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

// A private host's name is resolved in the families the island has an
// address of, loopback's apart, and an address of a family it lacks opens
// nothing: on an island with no IPv6, as the shipped one, no IPv6 rule goes
// in for a private host, and the log says what opens nothing. On an island
// with both families, both go in.
func TestAPrivateHostOpensOnlyTheFamiliesTheIslandHas(t *testing.T) {
	names := map[string]map[string][]string{
		"both.test":   {"ip4": {"10.9.9.9"}, "ip6": {"fd00:99::5"}},
		"v6only.test": {"ip6": {"fd00:99::6"}},
	}
	var asked []string
	resolve := func(name, network string) []string {
		asked = append(asked, name+" "+network)
		var out []string
		for _, family := range []string{"ip4", "ip6"} {
			if network == family || network == "ip" {
				out = append(out, names[name][family]...)
			}
		}
		return out
	}
	env := map[string]string{"CYFR_GUARD_CONTROL_PLANE": controlPlane,
		"CYFR_PRIVATE_EGRESS_TARGETS": "both.test,v6only.test,fd00:99::7,10.9.9.10,fd00:aa::/64"}
	returns := func(st static) []string {
		var out []string
		for _, r := range st.rules {
			if len(r.args) == 6 && r.args[0] == "-A" && r.args[1] == chainOwn && r.args[2] == "-d" && r.args[5] == "RETURN" {
				out = append(out, r.String())
			}
		}
		return out
	}
	for _, c := range []struct {
		name    string
		inet6   string
		network string
		want    []string
		logs    []string
	}{
		{"an island with no IPv6", "00000000000000000000000000000001 01 80 10 80       lo\n", "ip4",
			[]string{"iptables -A CYFR_GUARD -d 10.9.9.9 -j RETURN", "iptables -A CYFR_GUARD -d 10.9.9.10 -j RETURN",
				"ip6tables -A CYFR_GUARD -d fd00:aa::/64 -j RETURN"},
			[]string{"private target both.test: 10.9.9.9 passes\n", "private target v6only.test resolves to nothing here: it opens nothing\n",
				"private target fd00:99::7 resolves to nothing here: it opens nothing\n"}},
		{"an island with IPv6", "00000000000000000000000000000001 01 80 10 80       lo\nfd000077000000000000000000000002 02 40 00 80     eth0\n", "ip",
			[]string{"iptables -A CYFR_GUARD -d 10.9.9.9 -j RETURN", "ip6tables -A CYFR_GUARD -d fd00:99::5 -j RETURN",
				"ip6tables -A CYFR_GUARD -d fd00:99::6 -j RETURN", "ip6tables -A CYFR_GUARD -d fd00:99::7 -j RETURN",
				"iptables -A CYFR_GUARD -d 10.9.9.10 -j RETURN", "ip6tables -A CYFR_GUARD -d fd00:aa::/64 -j RETURN"},
			[]string{"private target both.test: fd00:99::5 passes\n", "private target v6only.test: fd00:99::6 passes\n",
				"private target fd00:99::7: fd00:99::7 passes\n"}},
		// Two islands nothing reaches, where the script's getent differed
		// (resolveNetwork): with IPv6 alone, no IPv4 host opens; with
		// loopback alone, no host opens. A range opens as written.
		{"an island with IPv6 alone", "fd000077000000000000000000000002 02 40 00 80     eth0\n", "ip6",
			[]string{"ip6tables -A CYFR_GUARD -d fd00:99::5 -j RETURN", "ip6tables -A CYFR_GUARD -d fd00:99::6 -j RETURN",
				"ip6tables -A CYFR_GUARD -d fd00:99::7 -j RETURN", "ip6tables -A CYFR_GUARD -d fd00:aa::/64 -j RETURN"},
			[]string{"private target both.test: fd00:99::5 passes\n", "private target 10.9.9.10 resolves to nothing here: it opens nothing\n"}},
		{"an island with loopback alone", "00000000000000000000000000000001 01 80 10 80       lo\n", "",
			[]string{"ip6tables -A CYFR_GUARD -d fd00:aa::/64 -j RETURN"},
			[]string{"private target both.test resolves to nothing here: it opens nothing\n",
				"private target 10.9.9.10 resolves to nothing here: it opens nothing\n"}},
	} {
		p := aPlace(t, "1")
		if err := os.WriteFile(filepath.Join(p.proc, "net/if_inet6"), []byte(c.inet6), 0o644); err != nil {
			t.Fatal(err)
		}
		if c.network != "ip" && c.network != "ip4" {
			// No IPv4 address but loopback's.
			trie := "Local:\n     |-- 127.0.0.1\n        /32 host LOCAL\n"
			if err := os.WriteFile(filepath.Join(p.proc, "net/fib_trie"), []byte(trie), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		asked = nil
		log, out := logged()
		st, err := staticRules(log, readIsland(log, p, func(k string) string { return env[k] }, resolve))
		if err != nil {
			t.Fatal(err)
		}
		if got := returns(st); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: the private hosts' rules\n%s\nwant\n%s\n%s", c.name, strings.Join(got, "\n"), strings.Join(c.want, "\n"), out)
		}
		for _, line := range c.logs {
			if !strings.Contains(out.String(), "[cyfr-guard] info: "+line) {
				t.Errorf("%s: the log lacks %q:\n%s", c.name, line, out)
			}
		}
		want := []string{"both.test " + c.network, "v6only.test " + c.network}
		if c.network == "" {
			want = nil
		}
		if !reflect.DeepEqual(asked, want) {
			t.Errorf("%s: the resolver was asked %q, want %q", c.name, asked, want)
		}
	}
}

// A route's change that outlives its bound says so, and leaves the route's
// removal to the withdrawal that follows on a bound of its own, rather than
// trying it on the bound already spent.
func TestARouteChangePastItsBoundNamesTheTimeout(t *testing.T) {
	standInTools(t)
	slow := t.TempDir()
	// The route's own rules outlive the bound; its clearing before them
	// does not. sleep-ok: the stand-in outlives the change's shortened
	// bound, which ends it.
	restore := "#!/bin/sh\nif grep -q '^:CYFR_GUARD_R3 '; then exec sleep 30; fi\n"
	if err := os.WriteFile(filepath.Join(slow, "iptables-restore"), []byte(restore), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", slow+":"+os.Getenv("PATH"))
	p := aPlace(t, "1")
	lock, err := os.OpenFile(p.lock(), os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	log, out := logged()
	k := &rulesOf{log: log, at: p, st: static{rng: "10.213.0.0/16"}, lock: lock, bound: 300 * time.Millisecond}
	err = k.install(aRoute(ReachIsland))
	if err == nil || !strings.Contains(err.Error(), "route sp3's change did not finish within 300ms") {
		t.Fatalf("the change past its bound answered %v", err)
	}
	want := "[cyfr-guard] error: route sp3's change did not finish within 300ms: its withdrawal removes what of it stands\n"
	if out.String() != want {
		t.Fatalf("the change past its bound logged:\n%s\nwant:\n%s", out, want)
	}
}

// rulesMaker makes a route's rules alone, as the guard does, and no pair.
type rulesMaker struct{ k *rulesOf }

func (m rulesMaker) pair(*route) error      { return nil }
func (m rulesMaker) unpair(*route) error    { return nil }
func (m rulesMaker) rules(r *route) error   { return m.k.install(r) }
func (m rulesMaker) unrules(r *route) error { return m.k.withdraw(r) }
func (m rulesMaker) change(old, next *route) error {
	return m.k.change(old, next)
}

// A route's change takes the guard's lock within its own bound, as the
// script's flock ran inside its 30 s: while another process holds the lock
// (a health check that never ends), each admit is refused once the bound
// has passed and the control goes on answering; once the lock is free a
// route is made again.
func TestARouteChangeWaitsForTheLockOnlyWithinItsBound(t *testing.T) {
	standInTools(t)
	p := aPlace(t, "1")
	lock, err := os.OpenFile(p.lock(), os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	// The guard's lock stays open until the server has withdrawn what the
	// connection made, at the connection's end (below).
	t.Cleanup(func() { lock.Close() })
	held, err := os.OpenFile(p.lock(), os.O_RDWR, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	if err := unix.Flock(int(held.Fd()), unix.LOCK_SH); err != nil {
		t.Fatal(err)
	}
	log, out := logged()
	bound := 300 * time.Millisecond
	k := &rulesOf{log: log, at: p, st: static{rng: "10.213.0.0/16"}, lock: lock, bound: bound}
	s := newServer(log, "net:[1]", netip.MustParsePrefix("10.213.0.0/16"), rulesMaker{k})
	path := filepath.Join(t.TempDir(), "guard.sock")
	l, err := net.ListenUnix("unixpacket", &net.UnixAddr{Name: path, Net: "unixpacket"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			conn, err := l.AcceptUnix()
			if err != nil {
				return
			}
			go s.serve(conn)
		}
	}()
	ended := make(chan struct{}, 1)
	s.onEnd = func() { ended <- struct{}{} }
	c := dialRaw(t, path)
	t.Cleanup(func() {
		c.conn.Close()
		select {
		case <-ended:
		case <-time.After(4 * applyTimeout):
			t.Error("the connection's end was not handled")
		}
	})
	admit := func(id string) []byte {
		return []byte(fmt.Sprintf(`{"v":4,"type":"admit","spawn_id":%q,"reach":"island"}`, id))
	}
	for _, id := range []string{"00000000000000000000000000000001", "00000000000000000000000000000002"} {
		began := time.Now()
		got := c.send(t, admit(id), three(t)...)
		if got.Type != TypeRefused || !strings.Contains(got.Reason, "did not finish within 300ms") {
			t.Fatalf("an admit under a held lock answered %+v\n%s", got, out)
		}
		// The admit's change and its withdrawal each wait their bound.
		if waited := time.Since(began); waited < bound || waited > 2*bound+5*time.Second {
			t.Fatalf("an admit under a held lock was answered after %s", waited)
		}
	}
	if !strings.Contains(out.String(), "[cyfr-guard] error: route sp0's change did not finish within 300ms: its withdrawal removes what of it stands\n") {
		t.Fatalf("the change does not name its timeout:\n%s", out)
	}
	if err := unix.Flock(int(held.Fd()), unix.LOCK_UN); err != nil {
		t.Fatal(err)
	}
	// The change once the lock is free runs on a bound sized for a loaded
	// runner, set under the server's lock, which every change runs under.
	s.mu.Lock()
	k.bound = applyTimeout
	s.mu.Unlock()
	if got := c.send(t, admit("00000000000000000000000000000003"), three(t)...); got.Type != TypeAdmitted {
		t.Fatalf("an admit once the lock is free answered %+v\n%s", got, out)
	}
}

// A private host in a loose IPv4 spelling (shorthand, octal, hex, one
// integer, or parts of each), which the script's getent read as inet_aton
// does (010.9.9.9 as 8.9.9.9), is no address to the guard, and no resolver
// is asked of it, Go's own or the C library's: it opens nothing, in the
// script's sentence. A name that only begins like one is asked.
func TestAPrivateHostInALooseIPv4SpellingOpensNothing(t *testing.T) {
	p := aPlace(t, "1")
	env := map[string]string{"CYFR_GUARD_CONTROL_PLANE": controlPlane,
		"CYFR_PRIVATE_EGRESS_TARGETS": "10.1,010.9.9.9,0x0a090909,167314698,0x0a.9.011,10.9.9.9.,10.0x9g"}
	var asked []string
	resolve := func(name, network string) []string {
		asked = append(asked, name)
		if name == "10.0x9g" {
			// A name, which the island's resolver holds no record of.
			return nil
		}
		// The real resolver, the C library's with GODEBUG=netdns=cgo,
		// which reads a loose spelling as inet_aton does: the guard asks
		// it nothing of one.
		return resolveHost(name, network)
	}
	log, out := logged()
	isl := readIsland(log, p, func(k string) string { return env[k] }, resolve)
	if isl.targets != nil {
		t.Fatalf("a loose spelling opened %q", isl.targets)
	}
	if want := []string{"10.0x9g"}; !reflect.DeepEqual(asked, want) {
		t.Fatalf("the resolver was asked %q, want %q", asked, want)
	}
	for _, target := range strings.Split(env["CYFR_PRIVATE_EGRESS_TARGETS"], ",") {
		if line := "[cyfr-guard] info: private target " + target + " resolves to nothing here: it opens nothing\n"; !strings.Contains(out.String(), line) {
			t.Errorf("the log lacks %q:\n%s", line, out)
		}
	}
}

// The control plane's value is refused before any private host's name is
// asked, as the script checked it first: a wrong value is refused at once.
func TestAControlPlaneIsRefusedBeforeAnyNameIsAsked(t *testing.T) {
	for _, value := range []string{"", "fd00::2"} {
		p := aPlace(t, "1")
		env := map[string]string{"CYFR_GUARD_CONTROL_PLANE": value, "CYFR_PRIVATE_EGRESS_TARGETS": "both.test"}
		asked := 0
		log, out := logged()
		isl := readIsland(log, p, func(k string) string { return env[k] }, func(string, string) []string { asked++; return nil })
		if asked != 0 {
			t.Fatalf("a control plane of %q: a name was asked first", value)
		}
		if _, err := staticRules(log, isl); err == nil || !strings.Contains(out.String(), "[cyfr-guard] error: CYFR_GUARD_CONTROL_PLANE is ") {
			t.Fatalf("a control plane of %q was not refused:\n%s", value, out)
		}
	}
}

// lateContext is a context whose deadline passes before it is done, as a
// loaded runner's timer fires late: done closes only at its cancel.
type lateContext struct {
	context.Context
	deadline time.Time
}

func (c lateContext) Deadline() (time.Time, bool) { return c.deadline, true }

// A wait for the lock ends only once the change's context is done, so the
// change judges its timeout by the one clock its bound is: a wait that ends
// by the wall clock while the context's timer has not fired would read as
// a lock error, with no timeout line.
func TestALockWaitEndsOnlyWithItsContext(t *testing.T) {
	p := aPlace(t, "1")
	lock, err := os.OpenFile(p.lock(), os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	held, err := os.OpenFile(p.lock(), os.O_RDWR, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	if err := unix.Flock(int(held.Fd()), unix.LOCK_SH); err != nil {
		t.Fatal(err)
	}
	inner, cancel := context.WithCancel(context.Background())
	ctx := lateContext{Context: inner, deadline: time.Now().Add(20 * time.Millisecond)}
	// The context is done well after its deadline has passed.
	timer := time.AfterFunc(300*time.Millisecond, cancel)
	defer timer.Stop()
	err = flockBy(ctx, lock, unix.LOCK_EX)
	if err == nil || ctx.Err() == nil || !errors.Is(err, ctx.Err()) {
		t.Fatalf("the wait for the lock ended with %v while the context's error is %v", err, ctx.Err())
	}
}

// A machine's change sends its new route chain alone, one commit, and
// records it. One the kernel refused leaves the old chain and its record;
// one taken but not recorded puts the old chain back; and one that cannot
// put it back either is errRouteBroken, the route in no known state.
func TestAMachinesChangeIsOneCommitOrTheOldChainStands(t *testing.T) {
	standInTools(t)
	tools := t.TempDir()
	sent := filepath.Join(tools, "sent")
	// Each restore's input is kept, one file each, and the restore fails
	// while the file "refuse" holds the count of restores to refuse.
	// One listed in "slow" takes its input, as a commit that went in, and
	// outlives a change's bound. sleep-ok: the stand-in outlives the bound.
	restore := "#!/bin/sh\nn=$(ls " + tools + " | grep -c '^sent')\ncat > " + sent + ".$n\n" +
		"if [ -f " + tools + "/slow ] && grep -qx \"$n\" " + tools + "/slow; then exec sleep 30; fi\n" +
		"if [ -f " + tools + "/refuse ] && grep -qx \"$n\" " + tools + "/refuse; then exit 1; fi\nexit 0\n"
	if err := os.WriteFile(filepath.Join(tools, "iptables-restore"), []byte(restore), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", tools+":"+os.Getenv("PATH"))
	refuse := func(nths ...string) {
		if err := os.WriteFile(filepath.Join(tools, "refuse"), []byte(strings.Join(nths, "\n")+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	read := func(n int) string {
		b, err := os.ReadFile(fmt.Sprintf("%s.%d", sent, n))
		if err != nil {
			t.Fatalf("restore %d: %v", n, err)
		}
		return string(b)
	}
	p := aPlace(t, "1")
	lock, err := os.OpenFile(p.lock(), os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	log, _ := logged()
	st := static{rng: "10.213.0.0/16"}
	k := &rulesOf{log: log, at: p, st: st, lock: lock, bound: applyTimeout}
	old := aRoute(ReachNone)
	old.machine, old.uid = true, 30201
	next := *old
	next.reach, next.addresses = ReachHosts, []string{"1.2.3.4"}

	if err := k.change(old, &next); err != nil {
		t.Fatalf("the change: %v", err)
	}
	if got := read(0); got != changeRules(&next, st) {
		t.Fatalf("the change sent:\n%s\nwant:\n%s", got, changeRules(&next, st))
	}
	if !exists(p.record("sp3")) {
		t.Fatal("the change was not recorded")
	}

	refuse("1")
	if err := k.change(&next, old); err == nil || errors.Is(err, errRouteBroken) {
		t.Fatalf("a change the kernel refused answered %v", err)
	}
	if !exists(sent+".1") || exists(sent+".2") {
		t.Fatal("a change the kernel refused was followed by another restore")
	}

	// A record that cannot be written: the old chain goes back.
	if err := os.RemoveAll(p.routes()); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p.routes(), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	refuse()
	if err := k.change(&next, old); err == nil || errors.Is(err, errRouteBroken) {
		t.Fatalf("a change not recorded answered %v", err)
	}
	if read(2) != changeRules(old, st) || read(3) != changeRules(&next, st) {
		t.Fatalf("a change not recorded did not put the old chain back:\n%s\nthen\n%s", read(2), read(3))
	}
	if got, err := os.ReadFile(p.routes()); err != nil || len(got) != 0 {
		t.Fatalf("a change not recorded touched the record: %q %v", got, err)
	}
	refuse("5")
	if err := k.change(&next, old); !errors.Is(err, errRouteBroken) {
		t.Fatalf("a change neither recorded nor put back answered %v", err)
	}

	// A restore that outlives its bound may have committed: the old chain
	// is put back on a bound of its own, and where that cannot be done the
	// route is in no known state.
	if err := os.Remove(p.routes()); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(p.routes(), 0o755); err != nil {
		t.Fatal(err)
	}
	refuse()
	slow := func(nths ...string) {
		if err := os.WriteFile(filepath.Join(tools, "slow"), []byte(strings.Join(nths, "\n")+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	slow("6")
	k.bound = 300 * time.Millisecond
	err = k.change(old, &next)
	if err == nil || errors.Is(err, errRouteBroken) || !strings.Contains(err.Error(), "its old reach is put back") {
		t.Fatalf("a change past its bound answered %v", err)
	}
	if read(7) != changeRules(old, st) {
		t.Fatalf("a change past its bound put back:\n%s", read(7))
	}
	slow("8", "9")
	if err := k.change(old, &next); !errors.Is(err, errRouteBroken) {
		t.Fatalf("a change past its bound whose put-back outlived its own answered %v", err)
	}
}

// The resolver a guard asks its routes' names of is Docker's unless
// CYFR_GUARD_RESOLVER names another, as a person's VM's guard names the
// host's guard; a value that is not an IPv4 address and port refuses the
// start before any rule goes in.
func TestTheResolverIsDockersUnlessTheGuardIsGivenAnother(t *testing.T) {
	for _, c := range []struct{ value, want string }{{"", islandResolver}, {"169.254.0.53:53", "169.254.0.53:53"}} {
		if got, ok := resolverOf(c.value); !ok || got != c.want {
			t.Errorf("%q: the routes' names are asked of %q (%t), want %s", c.value, got, ok, c.want)
		}
	}
	standInTools(t)
	for _, bad := range []string{"169.254.0.53", "[fd00::53]:53", "169.254.0.53:0", "resolver:53", "169.254.000.53:53"} {
		if _, ok := resolverOf(bad); ok {
			t.Errorf("%q was taken as a resolver", bad)
		}
		p := aPlace(t, "1")
		g, out := aStart(p, filepath.Join(t.TempDir(), "guard.sock"))
		env := g.env
		g.env = func(k string) string {
			if k == "CYFR_GUARD_RESOLVER" {
				return bad
			}
			return env(k)
		}
		if listener, _, code := g.start(); listener != nil || code != ExitConfig {
			t.Errorf("%q: the guard started (%d)\n%s", bad, code, out)
		}
		if !strings.Contains(out.String(), "refusing to start: CYFR_GUARD_RESOLVER is '"+bad+"'") || strings.Contains(out.String(), "routes take") {
			t.Errorf("%q: the refusal is not named before any rule:\n%s", bad, out)
		}
	}
}
