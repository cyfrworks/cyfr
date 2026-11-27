// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package serve

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/guard"
	"github.com/cyfr/locus/keeper/internal/admission"
	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/frame"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/logx"
	"github.com/cyfr/locus/keeper/internal/packview"
	"github.com/cyfr/locus/keeper/internal/pool"
	"github.com/cyfr/locus/keeper/internal/protocol"
	"github.com/cyfr/locus/keeper/internal/vm"
	"golang.org/x/sys/unix"
)

// A stand-in for a person's VM and its guest's keeper: the host's half of
// every connection is real, and the guest answers each line as a guest
// keeper does, unless a test scripts otherwise (answer).

const fakeBoot = "0f1e2d3c-4b5a-4978-8796-a5b4c3d2e1f0"

// fakeVM is one booted VM.
type fakeVM struct {
	g      *fakeGuest
	boot   vmBoot
	pid    int
	bootID string
	done   chan struct{}
	once   sync.Once
	mu     sync.Mutex
	how    vm.Ended
	cause  cgroup.Cause
	used   uint64
	// controls are its control connections' guest ends, each one's
	// reader running.
	controls []net.Conn
	// unacked leaves an asked end unacknowledged; asked is the bound it
	// was asked within.
	unacked bool
	asked   time.Duration
}

func (f *fakeVM) ConnectWithin(left time.Duration) (guestControl, error) {
	select {
	case <-f.done:
		return nil, errors.New("the machine ended")
	default:
	}
	host, guest := net.Pipe()
	f.mu.Lock()
	f.controls = append(f.controls, guest)
	bootID := f.bootID
	f.mu.Unlock()
	go f.g.serve(f, guest)
	return &fakeControl{conn: host, lines: protocol.NewLineReader(host), boot: bootID}, nil
}

func (f *fakeVM) Dial(port uint32, within time.Duration) (net.Conn, error) {
	if port != vm.AttachPort {
		return nil, fmt.Errorf("port %d", port)
	}
	host, guest := net.Pipe()
	go f.g.attach(guest)
	return host, nil
}

// end ends the VM as its VMM's exit does.
func (f *fakeVM) end(how vm.Ended, cause cgroup.Cause) {
	f.once.Do(func() {
		f.mu.Lock()
		f.how, f.cause = how, cause
		controls := append([]net.Conn{}, f.controls...)
		f.mu.Unlock()
		for _, c := range controls {
			_ = c.Close()
		}
		close(f.done)
	})
}

func (f *fakeVM) Kill() { f.end(vm.EndKilled, cgroup.NotKilled) }

// End is acknowledged at once, unless the guest is told to leave its end
// unacknowledged: then the VMM is killed, as vm.Machine.End kills one past
// its bound (package vm's own tests), and the bound asked is kept.
func (f *fakeVM) End(within time.Duration) vm.Ended {
	f.mu.Lock()
	unacked := f.unacked
	f.asked = within
	f.mu.Unlock()
	if unacked {
		f.end(vm.EndKilled, cgroup.NotKilled)
	} else {
		f.end(vm.EndAcknowledged, cgroup.NotKilled)
	}
	return f.HowEnded()
}
func (f *fakeVM) Done() <-chan struct{} { return f.done }
func (f *fakeVM) HowEnded() vm.Ended {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.how
}
func (f *fakeVM) KilledFor() (cgroup.Cause, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.cause, nil
}
func (f *fakeVM) Group() *cgroup.Group { return nil }
func (f *fakeVM) Used() (cgroup.Use, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return cgroup.Use{Bytes: f.used}, nil
}
func (f *fakeVM) PID() int { return f.pid }

func (f *fakeVM) ended() bool {
	select {
	case <-f.done:
		return true
	default:
		return false
	}
}

// fakeControl is the host's end of a control connection.
type fakeControl struct {
	conn  net.Conn
	lines *protocol.LineReader
	boot  string
	mu    sync.Mutex
}

func (c *fakeControl) BootID() string { return c.boot }
func (c *fakeControl) Send(v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	_ = c.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	_, err = c.conn.Write(append(b, '\n'))
	return err
}
func (c *fakeControl) Next(deadline time.Time) ([]byte, error) {
	_ = c.conn.SetReadDeadline(deadline)
	line, _, err := c.lines.Next()
	return line, err
}
func (c *fakeControl) Close() error { return c.conn.Close() }

// fakeGuest is every VM's guest keeper of one test.
type fakeGuest struct {
	t  *testing.T
	mu sync.Mutex
	// vms are the VMs booted, in order.
	vms []*fakeVM
	// seen is every request the guests read, by type, in order.
	seen []map[string]any
	// answer, when set, answers a request in place of the guest keeper's
	// own: what it returns is written, nothing for nil, and ok false
	// leaves the request to the keeper's own answer.
	answer func(vm *fakeVM, req map[string]any) (lines []any, ok bool)
	// refuseBoot refuses every boot; bootRoute is what the route said.
	refuseBoot error
	routes     []vm.Network
	// spawns are the spawns live in every guest, by the guest's spawn id.
	spawns map[string]bool
	next   int
	// puts are the packs streams the guests took whole, by digest.
	puts map[string][]byte
	held map[string]bool
	part map[string]*bytes.Buffer
	// attached are the tokens the host presented on the attach port.
	attached []string
}

func newFakeGuest(t *testing.T) *fakeGuest {
	return &fakeGuest{t: t, spawns: map[string]bool{}, puts: map[string][]byte{}, held: map[string]bool{},
		part: map[string]*bytes.Buffer{}}
}

// boot is the server's bootVM: it makes the VM's route through b.Route,
// with no descriptors, as the guard's fake takes none, and boots.
func (g *fakeGuest) boot(b vmBoot) (guestVM, error) {
	g.mu.Lock()
	refuse := g.refuseBoot
	n := len(g.vms) + 1
	g.mu.Unlock()
	network, err := b.Route(b.UID, nil, nil, nil, nil)
	if err != nil {
		return nil, err
	}
	if refuse != nil {
		return nil, refuse
	}
	f := &fakeVM{g: g, boot: b, pid: 9000 + n, bootID: fmt.Sprintf("%08d-4b5a-4978-8796-a5b4c3d2e1f0", n), done: make(chan struct{})}
	g.mu.Lock()
	g.vms = append(g.vms, f)
	g.routes = append(g.routes, network)
	g.mu.Unlock()
	return f, nil
}

func (g *fakeGuest) booted() []*fakeVM {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]*fakeVM{}, g.vms...)
}

// requests is the type of every request the guests read, in order.
func (g *fakeGuest) requests() []string {
	g.mu.Lock()
	defer g.mu.Unlock()
	var types []string
	for _, r := range g.seen {
		types = append(types, r["type"].(string))
	}
	return types
}

// serve answers one control connection's lines as the guest keeper would.
func (g *fakeGuest) serve(f *fakeVM, conn net.Conn) {
	lines := protocol.NewLineReader(conn)
	var wmu sync.Mutex
	write := func(v any) {
		b, _ := json.Marshal(v)
		wmu.Lock()
		defer wmu.Unlock()
		_ = conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
		_, _ = conn.Write(append(b, '\n'))
	}
	for {
		line, _, err := lines.Next()
		if err != nil {
			return
		}
		// What the guest reads is a role's line to its keeper: it parses as one.
		if _, rerr := protocol.ParseRequest(line); rerr != nil {
			g.t.Errorf("the guest read a line its keeper refuses: %s: %s", line, rerr.Detail)
			continue
		}
		var req map[string]any
		_ = json.Unmarshal(line, &req)
		g.mu.Lock()
		g.seen = append(g.seen, req)
		answer := g.answer
		g.mu.Unlock()
		if answer != nil {
			if out, ok := answer(f, req); ok {
				for _, l := range out {
					write(l)
				}
				continue
			}
		}
		for _, l := range g.own(req) {
			write(l)
		}
	}
}

// own is the guest keeper's answer to req.
func (g *fakeGuest) own(req map[string]any) []any {
	id, _ := req["id"].(string)
	v := protocol.Version
	switch req["type"] {
	case protocol.TypePlace:
		return []any{protocol.NewPlaced(id, 384<<20)}
	case protocol.TypeHomeMake:
		return []any{protocol.NewHomeMade(id, 40001)}
	case protocol.TypePacksHold:
		g.mu.Lock()
		held := g.held[req["digest"].(string)]
		g.mu.Unlock()
		state := protocol.PacksMissing
		if held {
			state = protocol.PacksHeld
		}
		return []any{protocol.NewPacksReply(id, state)}
	case protocol.TypePacksPut:
		d := req["digest"].(string)
		data, _ := base64.StdEncoding.DecodeString(req["data"].(string))
		g.mu.Lock()
		defer g.mu.Unlock()
		if g.part[d] == nil {
			g.part[d] = &bytes.Buffer{}
		}
		g.part[d].Write(data)
		if req["last"] == true {
			g.puts[d] = g.part[d].Bytes()
			g.held[d] = true
			return []any{protocol.NewPacksReply(id, protocol.PacksHeld)}
		}
		return []any{protocol.NewPacksReply(id, protocol.PacksTaken)}
	case protocol.TypeSpawn:
		g.mu.Lock()
		g.next++
		spawnID := fmt.Sprintf("%032x", g.next)
		g.spawns[spawnID] = true
		g.mu.Unlock()
		return []any{protocol.NewSpawned(id, spawnID, 40001, 77)}
	case protocol.TypeRelease:
		spawnID := req["spawn_id"].(string)
		g.mu.Lock()
		live := g.spawns[spawnID]
		delete(g.spawns, spawnID)
		g.mu.Unlock()
		if !live {
			return []any{protocol.NewError("", spawnID, protocol.CodeUnknownSpawn)}
		}
		code := 0
		return []any{protocol.NewExited(spawnID, &code, nil, nil), protocol.NewReleased(spawnID)}
	case protocol.TypeHomeMeasure:
		return []any{protocol.NewHomeMeasured(id, 12345)}
	case protocol.TypeMeasure:
		return []any{protocol.NewMeasured(id, protocol.Whose{Kind: "program"}, protocol.Reading{Bytes: 90 << 20}, 0)}
	}
	_ = v
	return nil
}

// attach is the guest's half of one attach connection: the host's token,
// then the session's output and both streams' ends.
func (g *fakeGuest) attach(conn net.Conn) {
	defer conn.Close()
	buf := make([]byte, frame.MaxPayload)
	stream, token, err := frame.Read(conn, buf)
	if err != nil || stream != frame.StreamAttach {
		return
	}
	g.mu.Lock()
	g.attached = append(g.attached, string(token))
	g.mu.Unlock()
	_ = frame.Write(conn, frame.StreamStdout, []byte("from the guest\n"))
	_ = frame.Write(conn, frame.StreamStdout, nil)
	_ = frame.Write(conn, frame.StreamStderr, nil)
}

// vmKeeper is a keeper that gives the wall, over a stand-in VM, with one
// kept role whose channel the test reads, its attach socket listening, and
// people's disks under a kept root of the test's own uid.
type vmKeeper struct {
	s       *server
	c       *client
	replies *protocol.LineReader
	guest   *fakeGuest
	guard   *fakeRouteGuard
	kept    *home.Kept
	attach  string
	ln      net.Listener
	// roleEnds are the role's halves of each session's streams, accepted.
	roleEnds chan net.Conn
}

func newVMKeeper(t *testing.T) *vmKeeper {
	t.Helper()
	me, gid := os.Getuid(), os.Getgid()
	if me != gid {
		t.Skipf("a disk's image is its uid's and its group's, and this test's uid %d is not its gid %d", me, gid)
	}
	kept := &home.Kept{Root: t.TempDir(), First: me, Last: me}
	// The packs' store leaves its folders read only: they are opened again
	// before the root's removal.
	t.Cleanup(func() {
		_ = filepath.WalkDir(kept.Root, func(p string, d os.DirEntry, err error) error {
			if err == nil && d.IsDir() {
				_ = os.Chmod(p, 0o755)
			}
			return nil
		})
	})
	if err := os.Mkdir(filepath.Join(kept.Root, home.DisksDir), 0o700); err != nil {
		t.Fatal(err)
	}
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	ours, theirs := os.NewFile(uintptr(fds[0]), "channel"), os.NewFile(uintptr(fds[1]), "client-channel")
	t.Cleanup(func() { ours.Close(); theirs.Close() })
	g := newFakeGuest(t)
	fg := &fakeRouteGuard{conn: 1}
	s := &server{cfg: Config{Kept: kept}, log: logx.NewWriter(testLog(), "cyfr-locus", false),
		ledger: admission.New(testWork, false), keptOps: map[int]*sync.Mutex{}, waiters: map[int]*child{},
		spawns: map[string]*spawn{}, unremoved: map[*spawn]*removal{}, guard: fg, wall: true, imageDisks: true,
		bootVM: g.boot, rest: testWork, packs: packview.New(filepath.Join(kept.Root, packview.DirName)),
		exit: func(code int) { t.Errorf("the keeper ended %d", code) }}
	c := testClient(ours, pool.Spec{Name: "backends", Reach: pool.ReachRouted}, Account{UID: me, GID: gid})
	c.role.spec.Kept = true
	c.role.spec.Name = "backends"
	c.role.groups = folderGroups(t, "backends")
	attach := filepath.Join(t.TempDir(), "attach.sock")
	ln, err := net.Listen("unix", attach)
	if err != nil {
		t.Fatal(err)
	}
	k := &vmKeeper{s: s, c: c, replies: protocol.NewLineReader(theirs), guest: g, guard: fg, kept: kept, attach: attach,
		ln: ln, roleEnds: make(chan net.Conn, 16)}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			k.roleEnds <- conn
		}
	}()
	go s.writer(c, make(chan struct{}))
	saved := guestWait
	t.Cleanup(func() {
		guestWait = saved
		ln.Close()
		for _, f := range g.booted() {
			f.Kill()
		}
	})
	return k
}

// testLog is where a VM keeper's log goes: standard error with
// CYFR_TEST_LOG set, nowhere otherwise.
func testLog() io.Writer {
	if os.Getenv("CYFR_TEST_LOG") != "" {
		return os.Stderr
	}
	return io.Discard
}

// folderGroups is a role's groups in a tree of plain folders standing in
// for a cgroup namespace's root: the VM's group a stand-in VM never makes.
func folderGroups(t *testing.T, role string) *cgroup.Manager {
	t.Helper()
	root := t.TempDir()
	files := map[string]string{"cgroup.controllers": "cpu memory pids\n", "memory.max": "max\n", "cgroup.procs": ""}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(root, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	leaf := filepath.Join(root, "service", "keeper")
	if err := os.MkdirAll(leaf, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"memory.max", "memory.swap.max", "memory.oom.group", "cpu.max", "cgroup.procs"} {
		if err := os.WriteFile(filepath.Join(leaf, name), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	m, err := cgroup.Delegate(root, []byte("0::/\n"))
	if err != nil {
		t.Fatal(err)
	}
	tree, err := m.NewTree()
	if err != nil {
		t.Fatal(err)
	}
	groups, _, err := tree.Role(role, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	return groups
}

// disk makes athanor's disk an image, its record and its file, as a
// home_make does.
func (k *vmKeeper) disk(t *testing.T, athanor string, homes ...string) {
	t.Helper()
	d := home.Disk{Athanor: athanor, Form: home.FormImage, UID: os.Getuid(), Homes: []string{}}
	for _, h := range homes {
		d = d.With(h)
	}
	if err := k.s.putDisk(d); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(k.kept.ImagePath(athanor), nil, home.ImageMode); err != nil && !os.IsExist(err) {
		t.Fatal(err)
	}
	if err := os.Chmod(k.kept.ImagePath(athanor), home.ImageMode); err != nil {
		t.Fatal(err)
	}
}

// next reads the keeper's next line on the role's channel, within 20 s.
func (k *vmKeeper) next(t *testing.T) map[string]any {
	t.Helper()
	type read struct {
		line []byte
		err  error
	}
	got := make(chan read, 1)
	go func() {
		line, _, err := k.replies.Next()
		got <- read{line, err}
	}()
	select {
	case r := <-got:
		if r.err != nil {
			t.Fatalf("reading the channel: %v", r.err)
		}
		var m map[string]any
		if err := json.Unmarshal(r.line, &m); err != nil {
			t.Fatalf("reply %q: %v", r.line, err)
		}
		return m
	case <-time.After(20 * time.Second):
		t.Fatal("the keeper sent nothing within 20 s")
	}
	return nil
}

// expect reads the keeper's lines until one of type typ, by 20 s.
func (k *vmKeeper) expect(t *testing.T, typ string) map[string]any {
	t.Helper()
	for i := 0; i < 32; i++ {
		if m := k.next(t); m["type"] == typ {
			return m
		} else if m["type"] == "error" && typ != "error" {
			t.Fatalf("the keeper refused: %v", m)
		}
	}
	t.Fatalf("no %s among the keeper's lines", typ)
	return nil
}

// place places a session of athanor's, answered placed.
func (k *vmKeeper) place(t *testing.T, id, athanor string) {
	t.Helper()
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypePlace, ID: id, Kind: "program", Athanor: athanor, Subject: "mcp_" + id})
	if m := k.next(t); m["type"] != "placed" || m["id"] != id {
		t.Fatalf("the place answered %v", m)
	}
}

// spawnReq is a kept spawn of home in place, reaching hosts where given.
func (k *vmKeeper) spawnReq(id, place, home string, hosts []string) *protocol.Request {
	return &protocol.Request{V: protocol.Version, Type: protocol.TypeSpawn, ID: id, Place: place, Pool: "backends",
		Argv: []string{"/bin/true"}, Attach: &protocol.Attach{Path: k.attach, Token: strings.Repeat("a", 32) + id},
		HomeMode: protocol.HomeKept, Home: home, Hosts: hosts}
}

// session places and spawns one session of athanor's in home, and answers
// its spawn id and the role's half of its streams, read past the role's
// token.
func (k *vmKeeper) session(t *testing.T, id, athanor, home string, hosts []string) (string, net.Conn) {
	t.Helper()
	k.place(t, "p-"+id, athanor)
	k.s.handleSpawn(k.c, k.spawnReq(id, "p-"+id, home, hosts))
	m := k.next(t)
	if m["type"] != "spawned" {
		t.Fatalf("spawn %s answered %v", id, m)
	}
	var conn net.Conn
	select {
	case conn = <-k.roleEnds:
	case <-time.After(20 * time.Second):
		t.Fatalf("spawn %s's streams never reached the role", id)
	}
	buf := make([]byte, frame.MaxPayload)
	if stream, token, err := frame.Read(conn, buf); err != nil || stream != frame.StreamAttach || string(token) != strings.Repeat("a", 32)+id {
		t.Fatalf("spawn %s's role half opened with %d %q %v", id, stream, token, err)
	}
	return m["spawn_id"].(string), conn
}

// routeChanges are the reaches the guard was asked of the VM's route, in
// order, each with its addresses.
func (k *vmKeeper) routeChanges() []string {
	var out []string
	for _, c := range k.guard.taken() {
		if c.op == guard.TypeChange {
			out = append(out, fmt.Sprintf("%s%v", c.reach, c.addrs))
		}
	}
	return out
}

// vmEventually waits up to 20 s for cond.
func vmEventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("%s did not come within 20 s", what)
		}
		time.Sleep(10 * time.Millisecond) // sleep-ok: a bounded poll of the keeper's own state
	}
}

// machineOfAthanor is the VM the keeper holds for athanor, nil for none.
func (k *vmKeeper) machineOfAthanor(athanor string) *machine {
	k.s.mu.Lock()
	defer k.s.mu.Unlock()
	return k.s.vms[athanor]
}

var _ = syscall.Getuid
