// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package guard

import (
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
	defer lock.Close()
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
	c := dialRaw(t, path)
	admit := func(id string) []byte {
		return []byte(fmt.Sprintf(`{"v":3,"type":"admit","spawn_id":%q,"reach":"island"}`, id))
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
	if got := c.send(t, admit("00000000000000000000000000000003"), three(t)...); got.Type != TypeAdmitted {
		t.Fatalf("an admit once the lock is free answered %+v\n%s", got, out)
	}
}

// A private host in a loose IPv4 spelling (shorthand, octal, hex, one
// integer), which the script's getent read as inet_aton does (010.9.9.9
// as 8.9.9.9), is no address to the guard: it is asked as a name, and an
// all-digit one the resolver refuses unasked, so it opens nothing, in the
// script's sentence.
func TestAPrivateHostInALooseIPv4SpellingOpensNothing(t *testing.T) {
	p := aPlace(t, "1")
	env := map[string]string{"CYFR_GUARD_CONTROL_PLANE": controlPlane,
		"CYFR_PRIVATE_EGRESS_TARGETS": "10.1,010.9.9.9,0x0a090909,167314698"}
	resolve := func(name, network string) []string {
		if strings.ContainsAny(name, "abcdefghijklmnopqrstuvwxyz") {
			// A name the island's resolver holds no record of, as Docker's
			// answers 0x0a090909.
			return nil
		}
		return resolveHost(name, network)
	}
	log, out := logged()
	isl := readIsland(log, p, func(k string) string { return env[k] }, resolve)
	if isl.targets != nil {
		t.Fatalf("a loose spelling opened %q", isl.targets)
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
