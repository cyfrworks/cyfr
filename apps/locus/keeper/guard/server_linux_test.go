// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package guard

import (
	"errors"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/logx"
)

const testSpawn = "00112233445566778899aabbccddeeff"

// fakeMaker records each part of a route the server makes and removes, in
// order, and fails the parts it is told to.
type fakeMaker struct {
	mu    sync.Mutex
	steps []string
	fail  map[string]bool
}

func (f *fakeMaker) step(name string, r *route) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.steps = append(f.steps, name+" "+outerName(r.slot))
	if f.fail[name] {
		return errors.New("forced failure")
	}
	return nil
}
func (f *fakeMaker) pair(r *route) error    { return f.step("pair", r) }
func (f *fakeMaker) rules(r *route) error   { return f.step("rules", r) }
func (f *fakeMaker) unpair(r *route) error  { return f.step("unpair", r) }
func (f *fakeMaker) unrules(r *route) error { return f.step("unrules", r) }

// setFail sets which parts fail from now on.
func (f *fakeMaker) setFail(parts ...string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.fail = map[string]bool{}
	for _, p := range parts {
		f.fail[p] = true
	}
}

func (f *fakeMaker) taken() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.steps...)
}

// testServer serves the control on a socket of the test's own, with maker.
type testServer struct {
	path  string
	s     *server
	maker *fakeMaker
	ended chan struct{}
}

func startServer(t *testing.T, netns string) *testServer {
	t.Helper()
	rng, _ := ParseRange("10.213.0.0/16")
	ts := &testServer{path: filepath.Join(t.TempDir(), "guard.sock"), maker: &fakeMaker{fail: map[string]bool{}}, ended: make(chan struct{}, 16)}
	ts.s = newServer(logx.New("cyfr-guard-test"), netns, rng, ts.maker)
	ts.s.onEnd = func() { ts.ended <- struct{}{} }
	l, err := net.ListenUnix("unixpacket", &net.UnixAddr{Name: ts.path, Net: "unixpacket"})
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
			go ts.s.serve(conn)
		}
	}()
	return ts
}

// descriptors are three of the test's own, standing for a space's: the
// fake maker never looks at them. Each admit takes fresh ones, as each
// space's are its own: the names of a route read sockets of its own.
func descriptors(t *testing.T) (*os.File, *os.File, *os.File) {
	t.Helper()
	netns, err := os.Open("/proc/self/ns/net")
	if err != nil {
		t.Fatal(err)
	}
	udp, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	tcp, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	u, _ := udp.(*net.UDPConn).File()
	p, _ := tcp.(*net.TCPListener).File()
	udp.Close()
	tcp.Close()
	t.Cleanup(func() { netns.Close(); u.Close(); p.Close() })
	return netns, u, p
}

// raw is a keeper's connection that speaks the control by hand.
type raw struct{ conn *net.UnixConn }

func dialRaw(t *testing.T, path string) *raw {
	t.Helper()
	c, err := net.Dial("unixpacket", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	r := &raw{conn: c.(*net.UnixConn)}
	if hello := r.read(t); hello.Type != TypeHello {
		t.Fatalf("no hello: %+v", hello)
	}
	return r
}

func (r *raw) send(t *testing.T, packet []byte, files ...*os.File) Message {
	t.Helper()
	fds := make([]int, len(files))
	for i, f := range files {
		fds[i] = int(f.Fd())
	}
	var rights []byte
	if len(fds) > 0 {
		rights = unix.UnixRights(fds...)
	}
	if _, _, err := r.conn.WriteMsgUnix(packet, rights, nil); err != nil {
		t.Fatal(err)
	}
	return r.read(t)
}

func (r *raw) read(t *testing.T) Message {
	t.Helper()
	_ = r.conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	packet, err := readPacket(r.conn, nil)
	if err != nil {
		t.Fatal(err)
	}
	m, err := Decode(packet)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func (ts *testServer) waitEnded(t *testing.T) {
	t.Helper()
	select {
	case <-ts.ended:
	case <-time.After(10 * time.Second):
		t.Fatal("the connection's end was not handled")
	}
}

// The guard answers each request of the vectors as its answers say, and
// refuses each refused one naming what it can of it, making nothing.
func TestTheGuardAnswersTheVectors(t *testing.T) {
	v := loadVectors(t)
	ts := startServer(t, "net:[1]")
	r := dialRaw(t, ts.path)
	files := func(n int) []*os.File { return three(t)[:n] }
	answers := map[string]bool{}
	for _, a := range v.Answers {
		answers[string(a.Message)] = true
	}
	for i, req := range v.Requests {
		got := r.send(t, req.Message, files(req.Descriptors)...)
		out, _ := Encode(got)
		if got.Type == TypeRefused || got.SpawnID != testSpawn {
			t.Fatalf("request %d %s answered %s", i, req.Message, out)
		}
		if got.Type == TypeAdmitted && i == 0 {
			// The second admit of the vectors names the same spawn: the
			// first is cleared so it is answered as a new one.
			if c := r.send(t, []byte(`{"v":2,"type":"clear","spawn_id":"`+testSpawn+`"}`)); c.Type != TypeCleared {
				t.Fatalf("clear: %+v", c)
			}
		}
	}
	for _, ref := range v.Refused {
		before := len(ts.maker.taken())
		got := r.send(t, ref.Message, files(ref.Descriptors)...)
		if got.Type != TypeRefused || got.Reason == "" {
			t.Errorf("%s answered %+v", ref.Why, got)
		}
		if len(ts.maker.taken()) != before {
			t.Errorf("%s made something: %v", ref.Why, ts.maker.taken()[before:])
		}
	}
	// A second admit of a held spawn, and a clear of a spawn this
	// connection holds no route of, are the vectors' refusals.
	admit := []byte(`{"v":2,"type":"admit","spawn_id":"` + testSpawn + `","reach":"island"}`)
	if got := r.send(t, admit, three(t)...); got.Type != TypeAdmitted {
		t.Fatalf("admit: %+v", got)
	}
	for _, c := range []struct {
		packet []byte
		files  []*os.File
	}{{admit, three(t)}, {[]byte(`{"v":2,"type":"clear","spawn_id":"ffeeddccbbaa99887766554433221100"}`), nil}} {
		got := r.send(t, c.packet, c.files...)
		if got.SpawnID == "ffeeddccbbaa99887766554433221100" {
			got.SpawnID = testSpawn
		}
		out, _ := Encode(got)
		var want bool
		for a := range answers {
			if sameJSON(t, []byte(a), out) {
				want = true
			}
		}
		if !want {
			t.Errorf("%s answered %s, which the vectors do not hold", c.packet, out)
		}
	}
}

// An admit is answered only once its pair and rules are in, a clear only
// once both are removed, the pair first; every route gets its own slot and
// a mark never given before, and a withdrawn route's slot is given again.
func TestARouteIsAdmittedWholeAndClearedWhole(t *testing.T) {
	ts := startServer(t, "net:[1]")
	r := dialRaw(t, ts.path)
	admit := func(id string) Message {
		return r.send(t, []byte(`{"v":2,"type":"admit","spawn_id":"`+id+`","reach":"island"}`), three(t)...)
	}
	clear := func(id string) Message {
		return r.send(t, []byte(`{"v":2,"type":"clear","spawn_id":"`+id+`"}`))
	}
	a, b := testSpawn, "ffeeddccbbaa99887766554433221100"
	if got := admit(a); got.Type != TypeAdmitted {
		t.Fatalf("admit a: %+v", got)
	}
	if got := admit(b); got.Type != TypeAdmitted {
		t.Fatalf("admit b: %+v", got)
	}
	if got := clear(a); got.Type != TypeCleared {
		t.Fatalf("clear a: %+v", got)
	}
	if got := admit(a); got.Type != TypeAdmitted {
		t.Fatalf("admit a again: %+v", got)
	}
	want := []string{"pair sp0", "rules sp0", "pair sp1", "rules sp1", "unpair sp0", "unrules sp0", "pair sp0", "rules sp0"}
	if got := ts.maker.taken(); !reflect.DeepEqual(got, want) {
		t.Fatalf("the routes' steps %v, want %v", got, want)
	}
	if ts.s.marks != 3 {
		t.Fatalf("%d marks given for three routes", ts.s.marks)
	}
}

// A route whose making fails is answered refused with nothing of it left
// and its slot free; one whose removal fails keeps its slot taken.
func TestARefusedRouteLeavesNothing(t *testing.T) {
	ts := startServer(t, "net:[1]")
	r := dialRaw(t, ts.path)
	ts.maker.setFail("rules")
	got := r.send(t, []byte(`{"v":2,"type":"admit","spawn_id":"`+testSpawn+`","reach":"island"}`), three(t)...)
	if got.Type != TypeRefused || got.SpawnID != testSpawn {
		t.Fatalf("answered %+v", got)
	}
	if steps := ts.maker.taken(); !reflect.DeepEqual(steps, []string{"pair sp0", "rules sp0", "unpair sp0", "unrules sp0"}) {
		t.Fatalf("steps %v", steps)
	}
	ts.maker.setFail("unpair")
	if got := r.send(t, []byte(`{"v":2,"type":"admit","spawn_id":"`+testSpawn+`","reach":"island"}`), three(t)...); got.Type != TypeAdmitted {
		t.Fatalf("admit: %+v", got)
	}
	// A route whose pair cannot be removed is refused cleared, keeps its
	// slot and is the guard's to try again; a clear asked again answers
	// cleared once it is gone.
	if got := r.send(t, []byte(`{"v":2,"type":"clear","spawn_id":"`+testSpawn+`"}`)); got.Type != TypeRefused {
		t.Fatalf("a clear whose removal failed answered %+v", got)
	}
	ts.s.mu.Lock()
	taken, pending := ts.s.taken[0], len(ts.s.pending)
	ts.s.mu.Unlock()
	if !taken || pending != 1 {
		t.Fatalf("a route not wholly removed: slot taken %t, %d tried again", taken, pending)
	}
	ts.s.retryPending()
	ts.s.mu.Lock()
	taken = ts.s.taken[0]
	ts.s.mu.Unlock()
	if !taken {
		t.Fatal("a route whose pair still cannot be removed lost its slot")
	}
	ts.maker.setFail()
	if got := r.send(t, []byte(`{"v":2,"type":"clear","spawn_id":"`+testSpawn+`"}`)); got.Type != TypeCleared {
		t.Fatalf("a clear asked again once the route can go answered %+v", got)
	}
	ts.s.mu.Lock()
	taken, pending = ts.s.taken[0], len(ts.s.pending)
	ts.s.mu.Unlock()
	if taken || pending != 0 {
		t.Fatalf("a route withdrawn at last: slot taken %t, %d tried again", taken, pending)
	}
}

// A connection that ends while a route's pair cannot be removed leaves the
// route to the guard's retries, its slot taken; one that still cannot go
// past the bound ends the guard, the retries running on real time.
func TestARouteThatCannotBeWithdrawnEndsTheGuardPastItsBound(t *testing.T) {
	ts := startServer(t, "net:[1]")
	ts.s.bound, ts.s.interval = 300*time.Millisecond, 20*time.Millisecond
	exited := make(chan int, 1)
	ts.s.exit = func(code int) {
		select {
		case exited <- code:
		default:
		}
	}
	r := dialRaw(t, ts.path)
	if got := r.send(t, []byte(`{"v":2,"type":"admit","spawn_id":"`+testSpawn+`","reach":"island"}`), three(t)...); got.Type != TypeAdmitted {
		t.Fatalf("admit: %+v", got)
	}
	ts.maker.setFail("unpair")
	began := time.Now()
	r.conn.Close()
	ts.waitEnded(t)
	ts.s.mu.Lock()
	taken, pending := ts.s.taken[0], len(ts.s.pending)
	ts.s.mu.Unlock()
	if !taken || pending != 1 {
		t.Fatalf("the lost connection's route not wholly removed: slot taken %t, %d tried again", taken, pending)
	}
	stop := make(chan struct{})
	t.Cleanup(func() { close(stop) })
	go ts.s.retryLoop(stop)
	select {
	case code := <-exited:
		if code != ExitServe || time.Since(began) < ts.s.bound {
			t.Fatalf("the guard ended %d after %s, its bound %s", code, time.Since(began), ts.s.bound)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("a route not withdrawn past its bound did not end the guard")
	}
}

// A clear of a route the retry withdrew answers cleared once and touches
// nothing, whichever came first: the retry before the clear's lookup, or
// the retry succeeding and a later admit taking the slot before the clear.
func TestAClearOfARouteTheRetryWithdrewTouchesNothing(t *testing.T) {
	ts := startServer(t, "net:[1]")
	r := dialRaw(t, ts.path)
	admit := func(id string) Message {
		return r.send(t, []byte(`{"v":2,"type":"admit","spawn_id":"`+id+`","reach":"island"}`), three(t)...)
	}
	clear := func(id string) Message { return r.send(t, []byte(`{"v":2,"type":"clear","spawn_id":"`+id+`"}`)) }
	first, later := testSpawn, "ffeeddccbbaa99887766554433221100"
	if got := admit(first); got.Type != TypeAdmitted {
		t.Fatalf("admit: %+v", got)
	}
	ts.maker.setFail("unpair")
	if got := clear(first); got.Type != TypeRefused {
		t.Fatalf("a clear whose removal failed answered %+v", got)
	}
	ts.maker.setFail()
	ts.s.retryPending()
	// The slot is free now: a later route takes it and its address.
	if got := admit(later); got.Type != TypeAdmitted {
		t.Fatalf("a later admit: %+v", got)
	}
	before := len(ts.maker.taken())
	if got := clear(first); got.Type != TypeCleared {
		t.Fatalf("a clear of a route the retry withdrew answered %+v", got)
	}
	if steps := ts.maker.taken()[before:]; len(steps) != 0 {
		t.Fatalf("a clear of a withdrawn route acted on the slot's later route: %v", steps)
	}
	if got := clear(first); got.Type != TypeRefused {
		t.Fatalf("a second clear of the same route answered %+v, want refused once it is answered", got)
	}
	ts.s.mu.Lock()
	taken := ts.s.taken[0]
	ts.s.mu.Unlock()
	if !taken {
		t.Fatal("the later route's slot was freed")
	}
}

// A dump the kernel marks interrupted proves nothing; one that ends with
// DONE and no interruption answers what it holds.
func TestAnInterruptedDumpIsNoAnswer(t *testing.T) {
	addr := netip.MustParseAddr("10.213.0.2")
	done := syscall.NetlinkMessage{Header: syscall.NlMsghdr{Type: syscall.NLMSG_DONE}}
	intr := syscall.NetlinkMessage{Header: syscall.NlMsghdr{Type: syscall.NLMSG_DONE, Flags: unix.NLM_F_DUMP_INTR}}
	if found, end, interrupted, err := parseDump([]syscall.NetlinkMessage{done}, addr); err != nil || !end || interrupted || len(found) != 0 {
		t.Fatalf("a whole empty dump: %v %t %t %v", found, end, interrupted, err)
	}
	if _, end, interrupted, err := parseDump([]syscall.NetlinkMessage{intr}, addr); err != nil || !end || !interrupted {
		t.Fatalf("an interrupted dump read as whole: %t %t %v", end, interrupted, err)
	}
}

// Every netlink read the guard makes is bounded: a socket that is never
// answered gives its read up at the deadline.
func TestANetlinkReadThatIsNeverAnsweredEnds(t *testing.T) {
	before := netlinkTimeout
	netlinkTimeout = 200 * time.Millisecond
	t.Cleanup(func() { netlinkTimeout = before })
	fd, err := nlSocket(unix.NETLINK_ROUTE)
	if err != nil {
		t.Skipf("no netlink socket here: %v", err)
	}
	defer unix.Close(fd)
	began := time.Now()
	_, _, err = unix.Recvfrom(fd, make([]byte, 64), 0)
	if !errors.Is(err, unix.EAGAIN) || time.Since(began) > 2*time.Second {
		t.Fatalf("an unanswered read answered %v after %s", err, time.Since(began))
	}
}

// A connection that ends withdraws every route it made and did not clear,
// the pair of each before its rules, and leaves another connection's.
func TestALostConnectionWithdrawsItsRoutesAlone(t *testing.T) {
	ts := startServer(t, "net:[1]")
	mine, theirs := dialRaw(t, ts.path), dialRaw(t, ts.path)
	for _, c := range []struct {
		r  *raw
		id string
	}{{mine, testSpawn}, {mine, "11112233445566778899aabbccddeeff"}, {theirs, "ffeeddccbbaa99887766554433221100"}} {
		if got := c.r.send(t, []byte(`{"v":2,"type":"admit","spawn_id":"`+c.id+`","reach":"island"}`), three(t)...); got.Type != TypeAdmitted {
			t.Fatalf("admit %s: %+v", c.id, got)
		}
	}
	if got := mine.send(t, []byte(`{"v":2,"type":"clear","spawn_id":"11112233445566778899aabbccddeeff"}`)); got.Type != TypeCleared {
		t.Fatalf("clear: %+v", got)
	}
	before := len(ts.maker.taken())
	mine.conn.Close()
	ts.waitEnded(t)
	if got := ts.maker.taken()[before:]; !reflect.DeepEqual(got, []string{"unpair sp0", "unrules sp0"}) {
		t.Fatalf("the lost connection's withdrawal: %v", got)
	}
	ts.s.mu.Lock()
	theirsTaken := ts.s.taken[2]
	ts.s.mu.Unlock()
	if !theirsTaken {
		t.Fatal("another connection's route was withdrawn")
	}
}

func TestListenMakesARootOnlySocket(t *testing.T) {
	if os.Getuid() != 0 {
		t.Skip("listening in a folder root owns needs root")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "guard.sock")
	l, err := listen(path)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	socket, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	folder, err := os.Lstat(dir)
	if err != nil {
		t.Fatal(err)
	}
	if socket.Mode()&os.ModeSocket == 0 || socket.Mode().Perm() != 0o600 || folder.Mode().Perm() != 0o700 {
		t.Fatalf("the socket is %v and its folder %v, want a socket 0600 in a folder 0700", socket.Mode(), folder.Mode())
	}
}

func TestSlotAddressesAreEachSlotsOwnSlash30(t *testing.T) {
	rng, _ := ParseRange("10.213.0.0/16")
	for slot, want := range map[int][2]string{0: {"10.213.0.1", "10.213.0.2"}, 1: {"10.213.0.5", "10.213.0.6"}, 64: {"10.213.1.1", "10.213.1.2"}, slots - 1: {"10.213.255.253", "10.213.255.254"}} {
		g, i := slotAddresses(rng, slot)
		if g.String() != want[0] || i.String() != want[1] {
			t.Errorf("slot %d: %s and %s, want %v", slot, g, i, want)
		}
	}
}

// three is a fresh set of descriptors as a slice.
func three(t *testing.T) []*os.File {
	t.Helper()
	netns, udp, tcp := descriptors(t)
	return []*os.File{netns, udp, tcp}
}
