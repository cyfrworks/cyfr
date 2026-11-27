// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/guard"
	"github.com/cyfr/locus/keeper/internal/frame"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// fakeResolver answers each host from table, an absent one as not found.
func fakeResolver(t *testing.T, table map[string][]string) {
	t.Helper()
	before := lookupHost
	t.Cleanup(func() { lookupHost = before })
	lookupHost = func(_ context.Context, host string) ([]netip.Addr, error) {
		texts, ok := table[host]
		if !ok {
			return nil, errors.New("no such host")
		}
		out := make([]netip.Addr, len(texts))
		for i, text := range texts {
			out[i] = netip.MustParseAddr(text)
		}
		return out, nil
	}
}

func TestResolveHostsTakesEveryAddressOnceUnmapped(t *testing.T) {
	fakeResolver(t, map[string][]string{
		"api.example.com": {"203.0.113.7", "2001:db8::7", "::ffff:198.51.100.1"},
		"cdn.example.com": {"203.0.113.7", "fe80::1%eth0"},
	})
	got, code, err := resolveHosts([]string{"api.example.com", "cdn.example.com"})
	want := []netip.Addr{netip.MustParseAddr("198.51.100.1"), netip.MustParseAddr("203.0.113.7"),
		netip.MustParseAddr("2001:db8::7"), netip.MustParseAddr("fe80::1")}
	if err != nil || code != "" || !reflect.DeepEqual(got, want) {
		t.Fatalf("resolved %v, %q, %v; want %v", got, code, err, want)
	}
}

func TestAHostThatResolvesToNothingRefusesTheSpawn(t *testing.T) {
	fakeResolver(t, map[string][]string{"api.example.com": {"203.0.113.7"}, "empty.example.com": {}})
	for _, hosts := range [][]string{{"api.example.com", "absent.example.com"}, {"empty.example.com"}} {
		if _, code, err := resolveHosts(hosts); err == nil || code != protocol.CodeHostsUnresolved {
			t.Errorf("%v: %q, %v", hosts, code, err)
		}
	}
}

// fakeRouteGuard stands in for the island's guard: it records every admit
// and clear, checks an admit's descriptors as the guard does, and answers
// the space's UDP names with "answer:<spawn id>" while the route stands.
type fakeRouteGuard struct {
	mu     sync.Mutex
	conn   uint64
	calls  []routeCall
	routes map[string]*answering
	// refuse refuses every admit; hold, when set, is waited on inside each
	// admit before it answers; before runs inside each admit before it
	// answers, as a connection's end that comes just then would.
	refuse bool
	hold   chan struct{}
	before func(spawnID string)
	// machines is why it routes no person's VM, as a hello would say.
	machines string
	// refuseClears refuses that many clears before it answers one; dead
	// says no connection is live.
	refuseClears int
	dead         bool
	// afterLive runs as Live returns, as a peer's close just after the
	// check would; beforeClear runs as a clear arrives, before it answers.
	afterLive   func()
	beforeClear func(spawnID string)
	// changes answers each change in turn, nil to accept it, an error to
	// refuse it (a guard.ErrRouteWithdrawn among them); past its end every
	// change is accepted. A machine's admit makes no route of the fake's
	// names: its VM is a stand-in too.
	changes []error
}

type routeCall struct {
	op      string
	spawnID string
	reach   string
	addrs   []netip.Addr
	port    uint16
	private bool
	conn    uint64
	uid     int
}

func (g *fakeRouteGuard) Admit(spawnID, reach string, addrs []netip.Addr, netns, udp, tcp *os.File) (guard.Route, error) {
	return g.admit(routeCall{op: guard.TypeAdmit, spawnID: spawnID, reach: reach, addrs: addrs}, netns, udp, tcp)
}

func (g *fakeRouteGuard) AdmitRole(spawnID string, port uint16, private bool, netns, udp, tcp *os.File) (guard.Route, error) {
	return g.admit(routeCall{op: guard.TypeAdmit, spawnID: spawnID, reach: guard.ReachRole, port: port, private: private}, netns, udp, tcp)
}

func (g *fakeRouteGuard) admit(call routeCall, netns, udp, tcp *os.File) (guard.Route, error) {
	spawnID := call.spawnID
	g.mu.Lock()
	call.conn = g.conn
	g.calls = append(g.calls, call)
	hold, before, refuse, conn := g.hold, g.before, g.refuse, g.conn
	g.mu.Unlock()
	if err := checkSpaceDescriptors(netns, udp, tcp); err != nil {
		return guard.Route{}, err
	}
	if hold != nil {
		<-hold
	}
	if before != nil {
		before(spawnID)
	}
	if refuse {
		return guard.Route{}, errors.New("refused")
	}
	a, err := answerNames(udp, spawnID)
	if err != nil {
		return guard.Route{}, err
	}
	g.mu.Lock()
	if g.routes == nil {
		g.routes = map[string]*answering{}
	}
	g.routes[spawnID] = a
	g.mu.Unlock()
	return guard.Route{Conn: conn}, nil
}

func (g *fakeRouteGuard) AdmitMachine(spawnID string, uid int, reach string, addrs []netip.Addr, netns, udp, tcp, nl *os.File) (guard.Machine, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.calls = append(g.calls, routeCall{op: guard.TypeAdmit, spawnID: spawnID, reach: reach, addrs: addrs, conn: g.conn, uid: uid})
	if g.refuse {
		return guard.Machine{}, errors.New("refused")
	}
	return guard.Machine{Route: guard.Route{Conn: g.conn}, Inner: netip.MustParseAddr("10.213.0.2"),
		Gateway: netip.MustParseAddr("10.213.0.1")}, nil
}

func (g *fakeRouteGuard) Change(spawnID string, r guard.Route, reach string, addrs []netip.Addr) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.calls = append(g.calls, routeCall{op: guard.TypeChange, spawnID: spawnID, reach: reach, addrs: addrs, conn: r.Conn})
	if g.dead || r.Conn != g.conn {
		return guard.ErrConnectionGone
	}
	if len(g.changes) > 0 {
		err := g.changes[0]
		g.changes = g.changes[1:]
		return err
	}
	return nil
}

func (g *fakeRouteGuard) Machines() string {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.machines
}

func (g *fakeRouteGuard) Live(r guard.Route) bool {
	g.mu.Lock()
	live, after := !g.dead && r.Conn == g.conn, g.afterLive
	g.mu.Unlock()
	if after != nil {
		after()
	}
	return live
}

func (g *fakeRouteGuard) Clear(spawnID string, r guard.Route) error {
	g.mu.Lock()
	before := g.beforeClear
	g.mu.Unlock()
	if before != nil {
		before(spawnID)
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	g.calls = append(g.calls, routeCall{op: guard.TypeClear, spawnID: spawnID, conn: r.Conn})
	if g.refuseClears > 0 {
		g.refuseClears--
		return errors.New("refused: the guard could not remove the whole route, and tries again")
	}
	if a := g.routes[spawnID]; a != nil {
		a.stop()
		delete(g.routes, spawnID)
	}
	return nil
}

func (g *fakeRouteGuard) taken() []routeCall {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]routeCall(nil), g.calls...)
}

// waitOps waits for the guard to have been asked ops for spawnID, in order.
func (g *fakeRouteGuard) waitOps(t *testing.T, spawnID string, ops ...string) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for {
		var got []string
		for _, c := range g.taken() {
			if c.spawnID == spawnID {
				got = append(got, c.op)
			}
		}
		if reflect.DeepEqual(got, ops) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("spawn %s: the guard was asked %v, want %v", spawnID, got, ops)
		}
		time.Sleep(20 * time.Millisecond) // sleep-ok: a bounded poll of the guard's record
	}
}

// checkSpaceDescriptors holds an admit's descriptors to what the guard
// takes: a network namespace that is not the keeper's, and a UDP and a
// listening TCP socket bound to 127.0.0.11:53 in it.
func checkSpaceDescriptors(netns, udp, tcp *os.File) error {
	var own, space unix.Stat_t
	if err := unix.Stat("/proc/self/ns/net", &own); err != nil {
		return err
	}
	if err := unix.Fstat(int(netns.Fd()), &space); err != nil {
		return err
	}
	if own.Ino == space.Ino {
		return errors.New("the namespace is the keeper's own")
	}
	for _, f := range []*os.File{udp, tcp} {
		sa, err := unix.Getsockname(int(f.Fd()))
		in, ok := sa.(*unix.SockaddrInet4)
		if err != nil || !ok || in.Port != 53 || in.Addr != [4]byte{127, 0, 0, 11} {
			return errors.New("a name socket is not bound to 127.0.0.11:53")
		}
	}
	if on, err := unix.GetsockoptInt(int(tcp.Fd()), unix.SOL_SOCKET, unix.SO_ACCEPTCONN); err != nil || on != 1 {
		return errors.New("the TCP name socket is not listening")
	}
	return nil
}

// answering is one route's names in the fake, as the guard's are: the
// socket is taken before the goroutine that reads it starts, and stop
// returns only once that goroutine is done.
type answering struct {
	pc   net.PacketConn
	done chan struct{}
}

// answerNames answers every datagram on a copy of udp with
// "answer:<spawn id>" until stopped.
func answerNames(udp *os.File, spawnID string) (*answering, error) {
	pc, err := net.FilePacketConn(udp)
	if err != nil {
		return nil, err
	}
	a := &answering{pc: pc, done: make(chan struct{})}
	go func() {
		defer close(a.done)
		buf := make([]byte, 512)
		for {
			_, from, err := pc.ReadFrom(buf)
			if err != nil {
				return
			}
			_, _ = pc.WriteTo([]byte("answer:"+spawnID), from)
		}
	}()
	return a, nil
}

func (a *answering) stop() {
	_ = a.pc.Close()
	<-a.done
}

// A routed space's command starts only once the guard has admitted its
// route: while the admit waits, nothing of the command has run and the
// spawn is not answered. Its loopback is its own and up, its names are
// answered on its own sockets by the guard alone, and its retirement has
// the guard withdraw that route once its processes are gone.
func TestARoutedSpaceStartsOnlyAfterItsRouteIsAdmitted(t *testing.T) {
	k := routedKeeper(t)
	marker := filepath.Join(filepath.Dir(k.homes), "ran")
	k.guard.hold = make(chan struct{})
	script := `touch ` + marker + `; "$TEST_BINARY" ask 127.0.0.11:53; "$TEST_BINARY" own 3000 mine 0; echo done`
	req := spawnRequest(t, k.attach, "r1", script, map[string]string{"TEST_BINARY": k.helper}, false, 64<<20)
	done := make(chan struct{})
	go func() { k.handleSpawn(t, req); close(done) }()
	deadline := time.Now().Add(10 * time.Second)
	for len(k.guard.taken()) == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond) // sleep-ok: a bounded poll for the admit to arrive
	}
	if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the command ran before its route was admitted: %v", err)
	}
	close(k.guard.hold)
	<-done
	spawned := k.reply(t)
	if spawned["type"] != protocol.TypeSpawned {
		t.Fatalf("answered %v", spawned)
	}
	spawnID := spawned["spawn_id"].(string)
	calls := k.guard.taken()
	if len(calls) != 1 || calls[0].spawnID != spawnID || calls[0].reach != guard.ReachIsland || calls[0].addrs != nil {
		t.Fatalf("the guard was asked %+v", calls)
	}
	rc := k.accept(t)
	rc.readUntil(t, func() bool { return false })
	out := string(rc.got[frame.StreamStdout])
	for _, want := range []string{"ask 127.0.0.11:53: answer:" + spawnID, "own 3000: mine", "done"} {
		if !strings.Contains(out, want) {
			t.Errorf("the routed space lacks %q:\n%s", want, out)
		}
	}
	k.releasedPair(t, spawnID)
	k.guard.waitOps(t, spawnID, guard.TypeAdmit, guard.TypeClear)
}

// A spawn whose hosts are resolving as its role's process ends never
// starts: it is refused once they resolve, before anything of it is made
// or the guard is asked, and the role's end waits for that start before it
// is over.
func TestASpawnResolvingAsItsRoleEndsNeverStarts(t *testing.T) {
	k := routedKeeper(t)
	resolving, resolve := make(chan struct{}), make(chan struct{})
	before := lookupHost
	t.Cleanup(func() { lookupHost = before })
	lookupHost = func(context.Context, string) ([]netip.Addr, error) {
		close(resolving)
		<-resolve
		return []netip.Addr{netip.MustParseAddr("203.0.113.7")}, nil
	}
	req := spawnRequest(t, k.attach, "r1", "true", map[string]string{}, false, 64<<20)
	req.Hosts = []string{"api.example.com"}
	done := make(chan struct{})
	go func() {
		k.handleSpawn(t, req)
		close(done)
	}()
	<-resolving
	// The role's process ends: its end begins as endClient's does, and
	// waits for the start in flight.
	k.s.mu.Lock()
	k.c.ended = true
	k.s.mu.Unlock()
	waited := make(chan bool, 1)
	go func() { waited <- k.s.awaitStarts(k.c) }()
	select {
	case <-waited:
		t.Fatal("the role's end did not wait for its spawn's start")
	case <-time.After(200 * time.Millisecond): // sleep-ok: the end must still be waiting while the hosts resolve
	}
	close(resolve)
	<-done
	if !<-waited {
		t.Fatal("the role's end timed out waiting for its spawn's start")
	}
	if reply := k.reply(t); reply["type"] != protocol.TypeError || reply["code"] != protocol.CodeInternal || reply["spawn_id"] != nil {
		t.Fatalf("the spawn of a role that ended answered %v", reply)
	}
	if calls := k.guard.taken(); len(calls) != 0 {
		t.Fatalf("the guard was asked to route a spawn of a role that ended: %+v", calls)
	}
}

// Two routed spaces at once: each binds the same port on its own loopback
// and reaches its own listener there, and each has the route of its own
// start's hosts, whatever the other's.
func TestEachRoutedSpaceHasItsOwnLoopbackAndHosts(t *testing.T) {
	fakeResolver(t, map[string][]string{"api.example.com": {"203.0.113.7"}})
	k := routedKeeper(t)
	listed := spawnRequest(t, k.attach, "a", `"$TEST_BINARY" own 3000 first 3; echo done`, map[string]string{"TEST_BINARY": k.helper}, false, 64<<20)
	listed.Hosts = []string{"api.example.com"}
	k.handleSpawn(t, listed)
	first := k.reply(t)
	k.handleSpawn(t, spawnRequest(t, k.attach, "b", `"$TEST_BINARY" own 3000 second 0; echo done`, map[string]string{"TEST_BINARY": k.helper}, false, 64<<20))
	second := k.reply(t)
	if first["type"] != protocol.TypeSpawned || second["type"] != protocol.TypeSpawned {
		t.Fatalf("answered %v and %v", first, second)
	}
	outs := map[string]bool{}
	for range 2 {
		rc := k.accept(t)
		rc.readUntil(t, func() bool { return false })
		outs[string(rc.got[frame.StreamStdout])] = true
	}
	if !outs["own 3000: first\ndone\n"] || !outs["own 3000: second\ndone\n"] {
		t.Fatalf("the two spaces' loopbacks: %v", outs)
	}
	calls := k.guard.taken()
	want := map[string]routeCall{
		first["spawn_id"].(string):  {op: guard.TypeAdmit, spawnID: first["spawn_id"].(string), reach: guard.ReachHosts, addrs: []netip.Addr{netip.MustParseAddr("203.0.113.7")}, conn: 1},
		second["spawn_id"].(string): {op: guard.TypeAdmit, spawnID: second["spawn_id"].(string), reach: guard.ReachIsland, conn: 1},
	}
	if len(calls) < 2 || !reflect.DeepEqual(calls[0], want[calls[0].spawnID]) || !reflect.DeepEqual(calls[1], want[calls[1].spawnID]) {
		t.Fatalf("the guard was asked %+v, want %+v", calls, want)
	}
	for range 4 {
		k.reply(t)
	}
}

// A routed spawn whose route the guard refuses, and one whose admit was
// answered over a connection that ended as it was answered, are refused
// under the spawn id the keeper gave them and released: nothing of their
// command ran, and the place is free at their release alone. One whose
// hosts resolve to nothing is refused before the guard is asked anything.
func TestARouteNotAdmittedRefusesTheSpawnAndStartsNothing(t *testing.T) {
	fakeResolver(t, map[string][]string{})
	k := routedKeeper(t)
	marker := filepath.Join(filepath.Dir(k.homes), "ran")
	script := `touch ` + marker
	k.guard.refuse = true
	k.handleSpawn(t, spawnRequest(t, k.attach, "x", script, map[string]string{}, false, 64<<20))
	k.expect(t, protocol.NewReleased(k.refusedMade(t, "x", protocol.CodeGuardUnavailable)))

	k.guard.mu.Lock()
	k.guard.refuse = false
	k.guard.before = func(string) { k.s.guardLost(1) }
	k.guard.mu.Unlock()
	k.handleSpawn(t, spawnRequest(t, k.attach, "y", script, map[string]string{}, false, 64<<20))
	k.expect(t, protocol.NewReleased(k.refusedMade(t, "y", protocol.CodeGuardUnavailable)))
	if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a refused route's command ran: %v", err)
	}

	asked := len(k.guard.taken())
	unresolved := spawnRequest(t, k.attach, "z", script, map[string]string{}, false, 64<<20)
	unresolved.Hosts = []string{"absent.example.com"}
	k.handleSpawn(t, unresolved)
	if r := k.reply(t); r["type"] != protocol.TypeError || r["code"] != protocol.CodeHostsUnresolved || r["id"] != "z" {
		t.Fatalf("answered %v", r)
	}
	if len(k.guard.taken()) != asked {
		t.Fatal("the guard was asked about a spawn whose hosts resolve to nothing")
	}
	k.s.mu.Lock()
	st := k.s.pools["runner"].Stats()
	k.s.mu.Unlock()
	if st.Free != st.Size || st.Quarantined != 0 {
		t.Fatalf("the refused spawns' uids are not back in the pool once released: %+v", st)
	}
}

// The end of the guard's connection kills every space routed over it, at
// once and before guardLost returns, so the client dials again only after:
// each ends killed and is released, its route asked of no connection, and a
// space of a later connection lives on.
func TestTheGuardsConnectionEndKillsEveryRoutedSpace(t *testing.T) {
	k := routedKeeper(t)
	k.handleSpawn(t, spawnRequest(t, k.attach, "a", `echo up; sleep 600`, map[string]string{}, false, 64<<20))
	a := k.reply(t)["spawn_id"].(string)
	rcA := k.accept(t)
	k.guard.mu.Lock()
	k.guard.conn = 2
	k.guard.mu.Unlock()
	k.handleSpawn(t, spawnRequest(t, k.attach, "b", `echo up; sleep 600`, map[string]string{}, false, 64<<20))
	b := k.reply(t)["spawn_id"].(string)
	rcB := k.accept(t)
	for _, rc := range []*relayConn{rcA, rcB} {
		rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "up\n") })
	}
	k.s.mu.Lock()
	group := k.s.spawns[a].group
	k.s.mu.Unlock()
	k.s.guardLost(1)
	// The group is empty, or already removed by the retirement that
	// followed the kill.
	if pids, err := group.Procs(); (err != nil && !errors.Is(err, os.ErrNotExist)) || len(pids) != 0 {
		t.Fatalf("a space routed over the ended connection still runs when guardLost returns: %v %v", pids, err)
	}
	exited := k.reply(t)
	if exited["type"] != protocol.TypeExited || exited["spawn_id"] != a || exited["signal"] != "SIGKILL" {
		t.Fatalf("answered %v", exited)
	}
	if released := k.reply(t); released["type"] != protocol.TypeReleased || released["spawn_id"] != a {
		t.Fatalf("answered %v", released)
	}
	for _, c := range k.guard.taken() {
		if c.op == guard.TypeClear && c.spawnID == a {
			t.Fatalf("a route of the ended connection was asked of the guard: %+v", c)
		}
	}
	k.s.mu.Lock()
	_, live := k.s.spawns[b]
	k.s.mu.Unlock()
	if !live {
		t.Fatal("a space of a later connection was killed")
	}
	k.release(t, b)
	k.releasedPair(t, b)
}

// A route the guard refuses to clear stays the keeper's: it is asked again
// at each sweep, and forgotten only once the guard says cleared.
func TestARouteIsTheKeepersUntilTheGuardSaysCleared(t *testing.T) {
	k := routedKeeper(t)
	k.guard.mu.Lock()
	k.guard.refuseClears = 2
	k.guard.mu.Unlock()
	k.handleSpawn(t, spawnRequest(t, k.attach, "c", `echo up`, map[string]string{}, false, 64<<20))
	spawnID := k.reply(t)["spawn_id"].(string)
	rc := k.accept(t)
	rc.readUntil(t, func() bool { return false })
	k.releasedPair(t, spawnID)
	k.guard.waitOps(t, spawnID, guard.TypeAdmit, guard.TypeClear)
	k.s.mu.Lock()
	_, held := k.s.uncleared[spawnID]
	k.s.mu.Unlock()
	if !held {
		t.Fatal("a route the guard refused to clear was counted cleared")
	}
	k.s.retryClears()
	k.s.mu.Lock()
	_, held = k.s.uncleared[spawnID]
	k.s.mu.Unlock()
	if !held {
		t.Fatal("a route the guard refused again was counted cleared")
	}
	k.s.retryClears()
	k.guard.waitOps(t, spawnID, guard.TypeAdmit, guard.TypeClear, guard.TypeClear, guard.TypeClear)
	k.s.mu.Lock()
	_, held = k.s.uncleared[spawnID]
	k.s.mu.Unlock()
	if held {
		t.Fatal("a route the guard cleared is still asked for")
	}
}

// A routed space that outlives its kill after the guard's connection ended
// ends the keeper before anything dials again.
func TestASurvivorOfTheGuardsEndEndsTheKeeper(t *testing.T) {
	k := routedKeeper(t)
	exited := make(chan int, 1)
	k.s.exit = func(code int) { exited <- code }
	k.s.groupKilled = func(*spawn) bool { return false }
	k.handleSpawn(t, spawnRequest(t, k.attach, "s", `echo up; sleep 600`, map[string]string{}, false, 64<<20))
	k.reply(t)
	rc := k.accept(t)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "up\n") })
	k.s.mu.Lock()
	var group interface{ Procs() ([]int, error) }
	for _, sp := range k.s.routing {
		group = sp.group
	}
	k.s.mu.Unlock()
	k.s.guardLost(1)
	select {
	case code := <-exited:
		if code != ExitLost {
			t.Fatalf("the keeper ended %d", code)
		}
	default:
		t.Fatal("the keeper went on with a routed space of the lost guard alive")
	}
	// The keeper's last act is the kernel's group kill: the space's
	// processes are gone, though the kill the test stood in for left them.
	if pids, err := group.Procs(); (err != nil && !errors.Is(err, os.ErrNotExist)) || len(pids) != 0 {
		t.Fatalf("the space outlived the keeper's end: %v %v", pids, err)
	}
	k.s.groupKilled = nil
}

// A command released just after its connection was found live belongs to a
// space already counted among the routed ones: the peer's close that comes
// after the check, and the loss it brings, kill it before guardLost returns.
func TestAReleaseJustBeforeTheGuardsEndIsKilledByIt(t *testing.T) {
	k := routedKeeper(t)
	lost := make(chan struct{})
	k.guard.mu.Lock()
	k.guard.afterLive = func() {
		// The peer closes now: its loss waits for the keeper's lock, held
		// by the release, and then finds the space.
		go func() { k.s.guardLost(1); close(lost) }()
	}
	k.guard.mu.Unlock()
	k.handleSpawn(t, spawnRequest(t, k.attach, "w", `echo up; sleep 600`, map[string]string{}, false, 64<<20))
	spawned := k.reply(t)
	if spawned["type"] != protocol.TypeSpawned {
		t.Fatalf("answered %v", spawned)
	}
	<-lost
	k.s.mu.Lock()
	sp := k.s.spawns[spawned["spawn_id"].(string)]
	k.s.mu.Unlock()
	if sp != nil {
		if pids, err := sp.group.Procs(); (err != nil && !errors.Is(err, os.ErrNotExist)) || len(pids) != 0 {
			t.Fatalf("a space released just before the guard's end outlived it: %v %v", pids, err)
		}
	}
	exited := k.reply(t)
	if exited["type"] != protocol.TypeExited || exited["signal"] != "SIGKILL" {
		t.Fatalf("answered %v", exited)
	}
	k.reply(t)
}

// An admitted whose connection is no longer live at the release refuses the
// spawn: its command never runs.
func TestAnAdmittedOfAConnectionNotLiveRefusesTheSpawn(t *testing.T) {
	k := routedKeeper(t)
	marker := filepath.Join(filepath.Dir(k.homes), "ran")
	k.guard.mu.Lock()
	k.guard.dead = true
	k.guard.mu.Unlock()
	k.handleSpawn(t, spawnRequest(t, k.attach, "d", `touch `+marker, map[string]string{}, false, 64<<20))
	k.expect(t, protocol.NewReleased(k.refusedMade(t, "d", protocol.CodeGuardUnavailable)))
	if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the command of a route not live ran: %v", err)
	}
}

// A routed keeper's boot has its guard make and clear one probe route; a
// guard that is not there refuses it, naming the guard's socket.
func TestBootProvesTheGuard(t *testing.T) {
	k := routedKeeper(t)
	spec := k.s.cfg.Pools[0]
	if err := k.s.proveGuard(spec); err != nil {
		t.Fatalf("a guard that makes and clears a route: %v", err)
	}
	calls := k.guard.taken()
	if len(calls) != 2 || calls[0].op != guard.TypeAdmit || calls[1].op != guard.TypeClear || calls[0].spawnID != calls[1].spawnID {
		t.Fatalf("the boot asked the guard %+v, want one admit and its clear", calls)
	}
	missing := filepath.Join(t.TempDir(), "absent.sock")
	k.s.cfg.Guard = missing
	k.s.guard = guard.NewClient(missing, "net:[x]", nil)
	err := k.s.proveGuard(spec)
	if err == nil || !strings.Contains(err.Error(), missing) {
		t.Fatalf("a missing guard: %v", err)
	}
}
