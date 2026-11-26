// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/guard"
	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/frame"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/pool"
	"github.com/cyfr/locus/keeper/internal/procfs"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// roleReport is what a role's process says of itself as it starts
// (roleHelper): who it runs as, what it holds, sees and reaches.
type roleReport struct {
	UID, GID int
	Groups   []int
	// Status holds /proc/self/status's capability sets and NoNewPrivs.
	Status map[string]string
	// NS names each namespace it is in.
	NS  map[string]string
	Env []string
	// Procs is every process its /proc lists, `<uid> <comm>`.
	Procs []string
	// Paths says, of each path it was asked about, what a stat answered.
	Paths map[string]string
	// Writes says, of each place it wrote to, what the write answered.
	Writes map[string]string
	// Reaches says, of each address it dialled, what the dial answered.
	Reaches map[string]string
	// Channel is what its fd 3 links to.
	Channel string
}

// roleHelper is a role's process: `role <tcp> <abstract> <path>…`. It
// reports on itself as roleReport, dialling tcp and abstract, an address
// and an abstract socket outside its space, and stating each path, then
// carries its channel to and from the test, which listens in its run folder
// (KEEPER_RUN_DIR) at proxy.sock at the same path it has outside, and ends
// when the test closes that connection.
func roleHelper(args []string) int {
	tcp, abstract, paths := args[0], args[1], args[2:]
	r := roleReport{UID: os.Getuid(), GID: os.Getgid(), Status: map[string]string{}, NS: map[string]string{},
		Env: os.Environ(), Paths: map[string]string{}, Writes: map[string]string{}, Reaches: map[string]string{}}
	r.Groups, _ = os.Getgroups()
	if raw, err := os.ReadFile("/proc/self/status"); err == nil {
		for _, line := range strings.Split(string(raw), "\n") {
			if name, value, ok := strings.Cut(line, ":"); ok && (strings.HasPrefix(name, "Cap") || name == "NoNewPrivs") {
				r.Status[name] = strings.TrimSpace(value)
			}
		}
	}
	for _, ns := range []string{"user", "pid", "ipc", "mnt", "net", "cgroup"} {
		r.NS[ns], _ = os.Readlink("/proc/self/ns/" + ns)
	}
	entries, _ := os.ReadDir("/proc")
	for _, e := range entries {
		if _, err := strconv.Atoi(e.Name()); err != nil {
			continue
		}
		comm, _ := os.ReadFile("/proc/" + e.Name() + "/comm")
		var st unix.Stat_t
		_ = unix.Stat("/proc/"+e.Name(), &st)
		r.Procs = append(r.Procs, fmt.Sprintf("%d %s", st.Uid, strings.TrimSpace(string(comm))))
	}
	for _, p := range paths {
		_, err := os.Stat(p)
		r.Paths[p] = errText(err)
	}
	runDir := os.Getenv(protocol.RunDirEnv)
	for _, p := range []string{filepath.Join(runDir, "written"), "/written", "/tmp/role-marker", "/dev/shm/role-marker"} {
		r.Writes[p] = errText(os.WriteFile(p, []byte("x"), 0o600))
	}
	dial := func(network, address string) string {
		c, err := net.DialTimeout(network, address, 2*time.Second)
		if err == nil {
			c.Close()
		}
		return errText(err)
	}
	r.Reaches["outside tcp"] = dial("tcp", tcp)
	r.Reaches["outside abstract"] = dial("unix", "@"+abstract)
	// Its own of each, beside: a positive control of the dial.
	if ln, err := net.Listen("tcp", "127.0.0.1:0"); err == nil {
		r.Reaches["own tcp"] = dial("tcp", ln.Addr().String())
		ln.Close()
	}
	if ln, err := net.Listen("unix", "@"+abstract); err == nil {
		r.Reaches["own abstract"] = dial("unix", "@"+abstract)
		ln.Close()
	}
	r.Channel, _ = os.Readlink("/proc/self/fd/3")

	conn, err := net.Dial("unix", filepath.Join(runDir, "proxy.sock"))
	if err != nil {
		fmt.Fprintln(os.Stderr, "role helper:", err)
		return 1
	}
	line, _ := json.Marshal(r)
	if _, err := conn.Write(append(line, '\n')); err != nil {
		return 1
	}
	channel := os.NewFile(3, "channel")
	go func() { _, _ = io.Copy(conn, channel) }()
	_, _ = io.Copy(channel, conn)
	return 0
}

func errText(err error) string {
	if err == nil {
		return ""
	}
	var errno syscall.Errno
	if errors.As(err, &errno) {
		return unix.ErrnoName(errno)
	}
	return err.Error()
}

const (
	testRoleUID  = 39201
	testRoleUID2 = 39202
)

// roleUnderTest is one role a rolesKeeper runs: its proxied channel, which
// the test reads and writes as the role's process would, and its report.
type roleUnderTest struct {
	r      *role
	ln     net.Listener
	attach net.Listener
	conn   net.Conn
	lines  *bufio.Reader
	report roleReport
}

// rolesKeeper is a bounded keeper whose roles are two of its own, alpha
// and beta, each with a relay pool of its own, run as serve runs them: each
// process started in its space by startRole and kept by keepRole, its
// channel carried to the test by roleHelper. The roles' processes are
// asked what outside, the test's own run folder for spawns, holds:
// outsideTCP and outsideAbstract, where the test listens.
type rolesKeeper struct {
	*keeper
	roles map[string]*roleUnderTest
	// outsideTCP and outsideAbstract are where the test listens, outside
	// every role's space.
	outsideTCP, outsideAbstract string
	// running closes once every role's keepRole has returned.
	running chan struct{}
	// tree is the pool's groups the roles' groups were made in.
	tree *cgroup.Tree
}

func newRolesKeeper(t *testing.T, cpus map[string]uint64) *rolesKeeper {
	t.Helper()
	k := newKeeper(t)
	restart := restartAfter
	restartAfter = 200 * time.Millisecond
	t.Cleanup(func() { restartAfter = restart })
	if k.guard == nil {
		k.guard = &fakeRouteGuard{conn: 1}
		k.s.guard = k.guard
		k.s.cfg.Guard = "/run/test/guard.sock"
	}
	base := filepath.Dir(k.homes)
	k.s.runRoot = filepath.Join(base, "run")
	if err := os.Mkdir(k.s.runRoot, 0o711); err != nil {
		t.Fatal(err)
	}
	keptRoot := filepath.Join(base, "kept")
	if err := os.Mkdir(keptRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(keptRoot, home.KeptRootMode.Perm()|os.ModeSticky); err != nil {
		t.Fatal(err)
	}
	k.s.cfg.Kept = &home.Kept{Root: keptRoot, First: testKeptFirst, Last: testKeptLast}
	k.s.roles = nil

	tcp, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { tcp.Close() })
	abstractName := "locus-role-test-" + randomHex(4)
	abstract, err := net.Listen("unix", "@"+abstractName)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { abstract.Close() })
	rk := &rolesKeeper{keeper: k, roles: map[string]*roleUnderTest{}, outsideTCP: tcp.Addr().String(), outsideAbstract: abstractName, running: make(chan struct{})}

	self, err := os.ReadFile(cgroup.SelfPath)
	if err != nil {
		t.Fatal(err)
	}
	root, err := cgroup.Delegate(cgroup.Root, self)
	if err != nil {
		t.Skipf("no memory bound can be enforced here: %v", err)
	}
	tree, err := root.NewTree()
	if err != nil {
		t.Fatal(err)
	}
	rk.tree = tree
	for i, name := range []string{"alpha", "beta"} {
		first := 39011 + 2*i
		spec := pool.Spec{Name: "p" + name, First: first, Last: first + 1, Reach: pool.ReachRelay}
		k.s.pools[spec.Name] = pool.New(spec)
		for uid := spec.First; uid <= spec.Last; uid++ {
			k.s.accounts[uid] = Account{UID: uid, GID: uid, Name: strconv.Itoa(uid)}
		}
		k.s.cfg.Pools = append(k.s.cfg.Pools, spec)
		uid := testRoleUID + i
		rs := RoleSpec{Name: name, UID: uid, Port: uint16(4300 + i), Pool: spec.Name, Private: i == 0, Kept: i == 1, Floor: i == 0}
		r := &role{spec: rs, pool: spec, account: Account{UID: uid, GID: uid, Name: rs.User()},
			runDir: filepath.Join(k.s.runRoot, name), homeRoot: k.homes}
		if r.groups, r.leaf, err = tree.Role(name, cpus[name], rs.Floor); err != nil {
			t.Fatal(err)
		}
		k.s.roles = append(k.s.roles, r)
		rk.roles[name] = &roleUnderTest{r: r}
		t.Setenv(rs.KeyEnv(), "key-of-"+name)
		t.Setenv("LOCUS_"+strings.ToUpper(name)+"_CPU_LIMIT", "1")
	}
	if err := makeRunDirs(k.s.runRoot, k.s.roles); err != nil {
		t.Fatal(err)
	}
	// Each role is asked of every role's run folder, the home root, the
	// kept root and the run root.
	k.s.cfg.Command = []string{k.helper, "role", rk.outsideTCP, abstractName}
	for _, r := range k.s.roles {
		k.s.cfg.Command = append(k.s.cfg.Command, r.runDir)
	}
	k.s.cfg.Command = append(k.s.cfg.Command, k.homes, keptRoot, k.s.runRoot)
	for _, ru := range rk.roles {
		ru.ln = listenFor(t, filepath.Join(ru.r.runDir, "proxy.sock"))
		ru.attach = listenFor(t, filepath.Join(ru.r.runDir, "attach.sock"))
	}
	// The roles end before newKeeperOf's cleanup retires what is left;
	// then their groups go.
	t.Cleanup(func() {
		k.s.end(ExitLost)
		k.s.endRoles()
		select {
		case <-rk.running:
		case <-time.After(30 * time.Second):
			t.Error("the roles did not end")
		}
		for _, r := range k.s.roles {
			r.leaf.KillBy(time.Now())
			_ = r.leaf.Remove()
			_ = os.Remove(r.groups.Dir())
		}
	})
	return rk
}

// listenFor listens at path, a socket every uid may connect to.
func listenFor(t *testing.T, path string) net.Listener {
	t.Helper()
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	if err := os.Chmod(path, 0o777); err != nil {
		t.Fatal(err)
	}
	return ln
}

// start starts every role as run does, and keeps each (keepRole).
func (rk *rolesKeeper) start(t *testing.T) {
	t.Helper()
	for _, r := range rk.s.roles {
		c, err := rk.s.startRole(r)
		if err != nil {
			t.Fatalf("role %s: %v", r.spec.Name, err)
		}
		rk.s.publishRole(r, c)
	}
	done := make(chan struct{}, len(rk.s.roles))
	for _, r := range rk.s.roles {
		go func() { rk.s.keepRole(r); done <- struct{}{} }()
	}
	go func() {
		for range rk.s.roles {
			<-done
		}
		close(rk.running)
	}()
	for _, ru := range rk.roles {
		ru.accept(t)
	}
}

// accept takes the role's process's proxied channel and its report.
func (ru *roleUnderTest) accept(t *testing.T) {
	t.Helper()
	_ = ru.ln.(*net.UnixListener).SetDeadline(time.Now().Add(20 * time.Second))
	conn, err := ru.ln.Accept()
	if err != nil {
		t.Fatalf("role %s's process did not connect: %v", ru.r.spec.Name, err)
	}
	t.Cleanup(func() { conn.Close() })
	ru.conn, ru.lines = conn, bufio.NewReader(conn)
	ru.report = roleReport{}
	if err := json.Unmarshal([]byte(ru.line(t)), &ru.report); err != nil {
		t.Fatal(err)
	}
}

func (ru *roleUnderTest) line(t *testing.T) string {
	t.Helper()
	_ = ru.conn.SetReadDeadline(time.Now().Add(20 * time.Second))
	line, err := ru.lines.ReadString('\n')
	if err != nil {
		t.Fatalf("role %s's channel: %v", ru.r.spec.Name, err)
	}
	return strings.TrimSuffix(line, "\n")
}

// ask sends a request on the role's channel, as its process does, and
// answers the reply.
func (ru *roleUnderTest) ask(t *testing.T, request string) map[string]any {
	t.Helper()
	if _, err := ru.conn.Write([]byte(request + "\n")); err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	line := ru.line(t)
	if err := json.Unmarshal([]byte(line), &m); err != nil {
		t.Fatalf("reply %q: %v", line, err)
	}
	return m
}

// spawn has the role place and spawn `sleep 600` in its own pool, its relay
// attached in its run folder, and answers the spawn's id, uid and leader.
func (ru *roleUnderTest) spawn(t *testing.T, id string) (string, int, *relayConn) {
	t.Helper()
	if placed := ru.ask(t, `{"v":6,"type":"place","id":"`+id+`","kind":"run"}`); placed["type"] != protocol.TypePlaced {
		t.Fatalf("role %s's place: %v", ru.r.spec.Name, placed)
	}
	req := fmt.Sprintf(`{"v":6,"type":"spawn","id":%q,"place":%q,"pool":%q,"argv":["/bin/sh","-c","exec sleep 600"],"env":{},"rlimits":{},"memory_bytes":%d,"cpu_quota":%d,"control":false,"attach":{"path":%q,"token":%q}}`,
		id, id, ru.r.pool.Name, 64<<20, protocol.CPUPeriod, filepath.Join(ru.r.runDir, "attach.sock"), testToken)
	spawned := ru.ask(t, req)
	if spawned["type"] != protocol.TypeSpawned {
		t.Fatalf("role %s's spawn: %v", ru.r.spec.Name, spawned)
	}
	_ = ru.attach.(*net.UnixListener).SetDeadline(time.Now().Add(20 * time.Second))
	conn, err := ru.attach.Accept()
	if err != nil {
		t.Fatalf("role %s's spawn's relay did not attach in its run folder: %v", ru.r.spec.Name, err)
	}
	t.Cleanup(func() { conn.Close() })
	_ = conn.SetDeadline(time.Now().Add(20 * time.Second))
	rc := &relayConn{conn: conn, buf: make([]byte, frame.MaxPayload), got: map[byte][]byte{}}
	stream, payload, err := frame.Read(conn, rc.buf)
	if err != nil || stream != frame.StreamAttach || string(payload) != testToken {
		t.Fatalf("the relay's attach frame: %d %q %v", stream, payload, err)
	}
	return spawned["spawn_id"].(string), int(spawned["uid"].(float64)), rc
}

// A role's process runs in a space of its own: its uid, no capability, no
// namespace of the keeper's nor of the other role's, its environment
// alone, its own processes, /tmp, /dev/shm, loopback and abstract sockets,
// the image read-only and its own run folder writable at its path, and no
// other role's run folder, home root or kept root.
func TestARoleRunsInItsOwnSpace(t *testing.T) {
	rk := newRolesKeeper(t, nil)
	rk.start(t)
	keeperNS := map[string]string{}
	for _, ns := range []string{"user", "pid", "ipc", "mnt", "net", "cgroup"} {
		keeperNS[ns], _ = os.Readlink("/proc/self/ns/" + ns)
	}
	alpha, beta := rk.roles["alpha"], rk.roles["beta"]
	for name, ru := range rk.roles {
		other := beta
		if ru == beta {
			other = alpha
		}
		rep := ru.report
		if rep.UID != ru.r.account.UID || rep.GID != ru.r.account.GID || len(rep.Groups) != 0 {
			t.Errorf("role %s runs as %d:%d %v", name, rep.UID, rep.GID, rep.Groups)
		}
		for _, set := range []string{"CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb"} {
			if rep.Status[set] != "0000000000000000" {
				t.Errorf("role %s holds %s %s", name, set, rep.Status[set])
			}
		}
		if rep.Status["NoNewPrivs"] != "1" {
			t.Errorf("role %s: NoNewPrivs %q", name, rep.Status["NoNewPrivs"])
		}
		for ns, own := range rep.NS {
			if own == "" || own == keeperNS[ns] || own == other.report.NS[ns] {
				t.Errorf("role %s's %s namespace %q is not its own (the keeper's %q, role %s's %q)", name, ns, own, keeperNS[ns], other.r.spec.Name, other.report.NS[ns])
			}
		}
		env := RoleEnviron(os.Environ(), ru.r.spec, ru.r.runDir, rep.Channel)
		var want []string
		for n, v := range env {
			want = append(want, n+"="+v)
		}
		slices.Sort(want)
		got := slices.Sorted(slices.Values(rep.Env))
		if !reflect.DeepEqual(got, want) {
			t.Errorf("role %s's environment %q, want %q", name, got, want)
		}
		for _, kv := range rep.Env {
			if strings.HasPrefix(kv, "LOCUS_"+strings.ToUpper(other.r.spec.Name)+"_") || strings.Contains(kv, "_CPU_LIMIT=") {
				t.Errorf("role %s holds %s", name, kv)
			}
		}
		for _, p := range rep.Procs {
			if !strings.HasPrefix(p, strconv.Itoa(ru.r.account.UID)+" ") {
				t.Errorf("role %s sees process %q, not its own", name, p)
			}
		}
		if len(rep.Procs) == 0 || len(rep.Procs) > 2 {
			t.Errorf("role %s sees processes %q: want its space's init and itself", name, rep.Procs)
		}
		if len(rep.Paths) != 5 {
			t.Errorf("role %s stated %v, want five paths", name, rep.Paths)
		}
		for path, got := range rep.Paths {
			want := "ENOENT"
			if path == ru.r.runDir || path == rk.s.runRoot {
				want = ""
			}
			if got != want {
				t.Errorf("role %s: a stat of %s answered %q, want %q", name, path, got, want)
			}
		}
		for path, got := range rep.Writes {
			want := ""
			if path == "/written" {
				want = "EROFS"
			}
			if got != want {
				t.Errorf("role %s: a write to %s answered %q, want %q", name, path, got, want)
			}
		}
		if info, err := os.Lstat(filepath.Join(ru.r.runDir, "written")); err != nil || info.Sys().(*syscall.Stat_t).Uid != uint32(ru.r.account.UID) {
			t.Errorf("role %s's write to its run folder is not there as its own outside: %v", name, err)
		}
		for reach, want := range map[string]string{"outside tcp": "ECONNREFUSED", "outside abstract": "ECONNREFUSED", "own tcp": "", "own abstract": ""} {
			if got := rep.Reaches[reach]; got != want {
				t.Errorf("role %s: %s answered %q, want %q", name, reach, got, want)
			}
		}
		if rep.Channel == "" || !strings.HasPrefix(rep.Channel, "socket:[") {
			t.Errorf("role %s's fd 3 is %q", name, rep.Channel)
		}
	}
	for _, marker := range []string{"/tmp/role-marker", "/dev/shm/role-marker"} {
		if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("a role's %s is the keeper's: %v", marker, err)
		}
	}
	// Each was routed by the guard as a role at its port, the runtime's
	// private, and its environment's key is its own.
	var admitted []routeCall
	for _, call := range rk.guard.taken() {
		if call.reach == guard.ReachRole {
			admitted = append(admitted, call)
		}
	}
	if len(admitted) != 2 {
		t.Fatalf("the guard admitted %+v", admitted)
	}
	for _, call := range admitted {
		ru := alpha
		if call.spawnID == beta.r.client.id {
			ru = beta
		}
		if call.spawnID != ru.r.client.id || call.port != ru.r.spec.Port || call.private != ru.r.spec.Private {
			t.Errorf("role %s's admit %+v", ru.r.spec.Name, call)
		}
	}
}

// From one role's channel, every pool, spawn, place and kept home of the
// other's is refused with the code an unknown one gets, and its spawn runs
// on; each role's own are answered, each reply on the channel it was asked
// on. Both run in their own role's group.
func TestARoleNamesOnlyItsOwn(t *testing.T) {
	rk := newRolesKeeper(t, nil)
	rk.start(t)
	alpha, beta := rk.roles["alpha"], rk.roles["beta"]
	betaSpawn, betaUID, _ := beta.spawn(t, "b1")
	alphaSpawn, _, _ := alpha.spawn(t, "a1")
	if placed := beta.ask(t, `{"v":6,"type":"place","id":"bp","kind":"run"}`); placed["type"] != protocol.TypePlaced {
		t.Fatalf("beta's place: %v", placed)
	}
	refusals := map[string]string{
		`{"v":6,"type":"pool","id":"x1","pool":"pbeta"}`:                             protocol.CodeUnknownPool,
		`{"v":6,"type":"signal","spawn_id":"` + betaSpawn + `","sig":"SIGKILL"}`:     protocol.CodeUnknownSpawn,
		`{"v":6,"type":"resize","spawn_id":"` + betaSpawn + `","rows":10,"cols":10}`: protocol.CodeUnknownSpawn,
		`{"v":6,"type":"release","spawn_id":"` + betaSpawn + `","grace_ms":0}`:       protocol.CodeUnknownSpawn,
		`{"v":6,"type":"measure","id":"x2","place":"b1"}`:                            protocol.CodeUnmeasured,
		`{"v":6,"type":"assign","id":"x3","place":"bp","kind":"run"}`:                protocol.CodeBadRequest,
		`{"v":6,"type":"home_list","id":"x4"}`:                                       protocol.CodeUnavailable,
		`{"v":6,"type":"home_make","id":"x5","home":"vlt_alpha"}`:                    protocol.CodeUnavailable,
	}
	for request, code := range refusals {
		reply := alpha.ask(t, request)
		if reply["type"] != protocol.TypeError || reply["code"] != code {
			t.Errorf("alpha's %s answered %v, want %s", request, reply, code)
		}
	}
	// A spawn naming beta's place, which alpha does not hold, or beta's
	// pool from a place of alpha's own.
	spawnIn := func(place, poolName string) string {
		return fmt.Sprintf(`{"v":6,"type":"spawn","id":%q,"place":%q,"pool":%q,"argv":["true"],"env":{},"rlimits":{},"memory_bytes":%d,"cpu_quota":%d,"control":false,"attach":{"path":"/run/x.sock","token":%q}}`,
			place, place, poolName, 64<<20, protocol.CPUPeriod, testToken)
	}
	if reply := alpha.ask(t, spawnIn("bp", "palpha")); reply["code"] != protocol.CodeBadRequest {
		t.Errorf("alpha's spawn in beta's place answered %v", reply)
	}
	if placed := alpha.ask(t, `{"v":6,"type":"place","id":"ap","kind":"run"}`); placed["type"] != protocol.TypePlaced {
		t.Fatalf("alpha's place: %v", placed)
	}
	if reply := alpha.ask(t, spawnIn("ap", "pbeta")); reply["code"] != protocol.CodeUnknownPool {
		t.Errorf("alpha's spawn from beta's pool answered %v", reply)
	}
	// Each role's own are answered, on its own channel.
	if reply := alpha.ask(t, `{"v":6,"type":"pool","id":"y1","pool":"palpha"}`); reply["type"] != protocol.TypePool || reply["free"] != float64(1) {
		t.Errorf("alpha's own pool answered %v", reply)
	}
	if reply := beta.ask(t, `{"v":6,"type":"home_list","id":"y2"}`); reply["type"] != protocol.TypeHomes {
		t.Errorf("beta's own home_list answered %v", reply)
	}
	if reply := beta.ask(t, `{"v":6,"type":"assign","id":"y3","place":"bp","kind":"warm"}`); reply["type"] != protocol.TypeAssigned {
		t.Errorf("beta's own assign answered %v", reply)
	}
	// Beta's spawn runs on under its uid.
	if c, err := procfs.ScanUID("/proc", betaUID, 0); err != nil || c.Total() == 0 {
		t.Fatalf("beta's spawn under uid %d after alpha's asks: %+v, %v", betaUID, c, err)
	}
	// Each role's process, its relays and its spawns are in its own group.
	for _, ru := range []*roleUnderTest{alpha, beta} {
		rk.s.mu.Lock()
		var sp *spawn
		for _, s := range rk.s.spawns {
			if s.client.role == ru.r {
				sp = s
			}
		}
		leader := ru.r.client.proc.pid
		rk.s.mu.Unlock()
		for what, c := range map[string]struct {
			pid  int
			want string
		}{
			"process":       {leader, cgroup.RoleLeaf(ru.r.spec.Name)},
			"spawn's relay": {sp.relay.pid, cgroup.RoleLeaf(ru.r.spec.Name)},
			"spawn":         {sp.leader.pid, ru.r.groups.Path() + "/" + cgroup.Name(sp.account.UID) + "/bound"},
		} {
			raw, err := os.ReadFile(fmt.Sprintf("/proc/%d/cgroup", c.pid))
			if got := strings.TrimPrefix(strings.TrimSpace(string(raw)), "0::"); err != nil || got != c.want {
				t.Errorf("role %s's %s is in %q (%v), want %q", ru.r.spec.Name, what, got, err, c.want)
			}
		}
		if info, err := os.Stat(ru.r.groups.Dir()); err != nil || !info.IsDir() {
			t.Errorf("role %s's group: %v", ru.r.spec.Name, err)
		}
	}
	_ = alphaSpawn
}

// Each role's two groups hold its processors, its service's share and its
// work's the rest, where it has a bound of them, and no memory bound of
// their own, no swap and no memory.oom.group, so a kill for work's or
// rest's bound is a limit above its spawns'. The floor's role's work is
// beside rest, every other's in it.
func TestEachRolesGroupReadsItsLimits(t *testing.T) {
	rk := newRolesKeeper(t, map[string]uint64{"alpha": 200_000})
	rk.start(t)
	for name, c := range map[string]struct {
		work    string
		service map[string]string
		groups  map[string]string
	}{
		"alpha": {"/work/alpha", map[string]string{"cpu.max": "50000 100000", "memory.max": "max", "memory.swap.max": "0"},
			map[string]string{"cpu.max": "150000 100000", "memory.max": "max", "memory.swap.max": "0", "memory.oom.group": "0"}},
		"beta": {"/work/rest/beta", map[string]string{"cpu.max": "max 100000", "memory.max": "max", "memory.swap.max": "0"},
			map[string]string{"cpu.max": "max 100000", "memory.max": "max", "memory.swap.max": "0", "memory.oom.group": "0"}},
	} {
		r := rk.roles[name].r
		if r.groups.Path() != c.work || r.leaf.Path() != cgroup.RoleLeaf(name) {
			t.Errorf("role %s's groups are %s and %s", name, r.leaf.Path(), r.groups.Path())
		}
		for dir, want := range map[string]map[string]string{filepath.Join(cgroup.Root, r.leaf.Path()): c.service, r.groups.Dir(): c.groups} {
			for file, value := range want {
				raw, err := os.ReadFile(filepath.Join(dir, file))
				if got := strings.TrimSpace(string(raw)); err != nil || got != value {
					t.Errorf("role %s's %s/%s is %q (%v), want %q", name, dir, file, got, err, value)
				}
			}
		}
	}
}

// A machine of no work boots: every group is made before work's bound is
// written, so with work and rest at 0 each role starts outside them and
// answers on its channel, and a spawn, whose group no bound of 0 holds, is
// refused while its role runs on.
func TestAPoolOfNoWorkStartsItsRolesAndRefusesEachSpawn(t *testing.T) {
	rk := newRolesKeeper(t, nil)
	t.Cleanup(func() {
		if err := rk.tree.Bound(1<<62, 1<<62); err != nil {
			t.Errorf("lifting the pool's bounds: %v", err)
		}
	})
	if err := rk.tree.Bound(0, 0); err != nil {
		t.Fatal(err)
	}
	rk.start(t)
	for name, ru := range rk.roles {
		pool := "p" + name
		if reply := ru.ask(t, `{"v":6,"type":"pool","id":"z1","pool":"`+pool+`"}`); reply["type"] != protocol.TypePool {
			t.Fatalf("role %s at no work: its pool answered %v", name, reply)
		}
		if placed := ru.ask(t, `{"v":6,"type":"place","id":"zp","kind":"run"}`); placed["type"] != protocol.TypePlaced {
			t.Fatalf("role %s's place: %v", name, placed)
		}
		spawn := fmt.Sprintf(`{"v":6,"type":"spawn","id":"zp","place":"zp","pool":%q,"argv":["true"],"env":{},"rlimits":{},"memory_bytes":%d,"cpu_quota":%d,"control":false,"attach":{"path":"/run/x.sock","token":%q}}`,
			pool, 64<<20, protocol.CPUPeriod, testToken)
		if reply := ru.ask(t, spawn); reply["type"] != protocol.TypeError || reply["id"] != "zp" {
			t.Errorf("role %s's spawn at no work answered %v", name, reply)
		}
		// The refused spawn's uid goes back to its pool once its retirement
		// has found it clean, and the role answers throughout.
		deadline := time.Now().Add(10 * time.Second)
		for {
			reply := ru.ask(t, `{"v":6,"type":"pool","id":"z2","pool":"`+pool+`"}`)
			if reply["type"] != protocol.TypePool {
				t.Fatalf("role %s after the refused spawn: its pool answered %v", name, reply)
			}
			if reply["free"] == reply["size"] {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("role %s: the refused spawn's uid is not free again: %v", name, reply)
			}
			time.Sleep(cgroup.PollInterval) // sleep-ok: a bounded poll for the uid's retirement
		}
	}
	rk.s.mu.Lock()
	held := len(rk.s.spawns)
	rk.s.mu.Unlock()
	if held != 0 {
		t.Errorf("%d spawns are held at no work", held)
	}
}

// A role's process that ends, here as its channel's reader closes, has
// every spawn it held retired and its route withdrawn, and starts again
// alone with a fresh channel and account; the other role's process and its
// spawn run on untouched.
func TestARoleThatEndsStartsAgainAloneWhileTheOtherRunsOn(t *testing.T) {
	rk := newRolesKeeper(t, nil)
	rk.start(t)
	alpha, beta := rk.roles["alpha"], rk.roles["beta"]
	alphaSpawn, alphaUID, _ := alpha.spawn(t, "a1")
	betaSpawn, betaUID, _ := beta.spawn(t, "b1")
	rk.s.mu.Lock()
	first, betaClient := alpha.r.client, beta.r.client
	betaLeader := rk.s.spawns[betaSpawn].leader
	rk.s.mu.Unlock()

	alpha.conn.Close()
	alpha.accept(t)
	rk.s.mu.Lock()
	again := alpha.r.client
	_, held := rk.s.spawns[alphaSpawn]
	ended := first.ended
	rk.s.mu.Unlock()
	if again == nil || again == first || again.proc.pid == first.proc.pid || again.id == first.id || !ended {
		t.Fatalf("alpha after its end: %+v, first %+v", again, first)
	}
	if held {
		t.Fatalf("alpha's spawn %s is still held after its role's end", alphaSpawn)
	}
	if c, err := procfs.ScanUID("/proc", alphaUID, 0); err != nil || c.Total() != 0 {
		t.Fatalf("alpha's spawn's uid %d after its role's end: %+v, %v", alphaUID, c, err)
	}
	rk.s.mu.Lock()
	st := rk.s.pools["palpha"].Stats()
	rk.s.mu.Unlock()
	if st.Free != st.Size {
		t.Fatalf("alpha's pool after its role's end: %+v", st)
	}
	// Its new start holds nothing of its last: neither the spawn nor the
	// place.
	if reply := alpha.ask(t, `{"v":6,"type":"release","spawn_id":"`+alphaSpawn+`","grace_ms":0}`); reply["code"] != protocol.CodeUnknownSpawn {
		t.Fatalf("the new alpha's release of its last start's spawn answered %v", reply)
	}
	if reply := alpha.ask(t, `{"v":6,"type":"place","id":"a1","kind":"run"}`); reply["type"] != protocol.TypePlaced {
		t.Fatalf("the new alpha's place of its last start's place id answered %v", reply)
	}
	// Its route was withdrawn before its new one was admitted.
	var ops []string
	for _, call := range rk.guard.taken() {
		if call.spawnID == first.id || call.spawnID == again.id {
			ops = append(ops, call.op+" "+map[bool]string{true: "first", false: "again"}[call.spawnID == first.id])
		}
	}
	if want := []string{"admit first", "clear first", "admit again"}; !reflect.DeepEqual(ops, want) {
		t.Fatalf("the guard was asked %v, want %v", ops, want)
	}
	// Beta ran on: its process, its channel and its spawn.
	rk.s.mu.Lock()
	same := beta.r.client == betaClient && !betaClient.proc.reaped() && !betaClient.ended
	rk.s.mu.Unlock()
	if !same || betaLeader.reaped() {
		t.Fatal("beta's process or spawn did not run on through alpha's end")
	}
	if c, err := procfs.ScanUID("/proc", betaUID, 0); err != nil || c.Total() == 0 {
		t.Fatalf("beta's spawn's uid %d: %+v, %v", betaUID, c, err)
	}
	if reply := beta.ask(t, `{"v":6,"type":"pool","id":"bp","pool":"pbeta"}`); reply["type"] != protocol.TypePool || reply["free"] != float64(1) {
		t.Fatalf("beta's channel after alpha's end answered %v", reply)
	}
	for _, call := range rk.guard.taken() {
		if call.spawnID == betaClient.id && call.op == guard.TypeClear {
			t.Fatal("beta's route was withdrawn at alpha's end")
		}
	}
}

// A role's process killed is a death like any: it starts again alone.
func TestARoleKilledStartsAgain(t *testing.T) {
	rk := newRolesKeeper(t, nil)
	rk.start(t)
	beta := rk.roles["beta"]
	rk.s.mu.Lock()
	first := beta.r.client
	rk.s.mu.Unlock()
	rk.s.signalChild(first.proc, unix.SIGKILL)
	beta.accept(t)
	rk.s.mu.Lock()
	again := beta.r.client
	ended := first.ended
	rk.s.mu.Unlock()
	if again == nil || again == first || !ended {
		t.Fatalf("beta after its kill: %+v", again)
	}
	if reply := beta.ask(t, `{"v":6,"type":"pool","id":"p","pool":"pbeta"}`); reply["type"] != protocol.TypePool {
		t.Fatalf("beta's new channel answered %v", reply)
	}
}

// The guard's loss under a role's route ends the keeper: every role
// process and its space are killed before the guard client may dial again,
// and no role starts again.
func TestTheGuardsLossUnderARoleEndsTheKeeper(t *testing.T) {
	rk := newRolesKeeper(t, nil)
	rk.start(t)
	rk.s.mu.Lock()
	var standing []*client
	for _, r := range rk.s.roles {
		standing = append(standing, r.client)
	}
	rk.s.mu.Unlock()
	rk.s.guardLost(1)
	for _, c := range standing {
		if procs, err := c.role.leaf.Procs(); err != nil || len(procs) != 0 {
			t.Errorf("role %s's leaf after the guard's loss: %v, %v", c.role.spec.Name, procs, err)
		}
	}
	select {
	case <-rk.s.ended:
	default:
		t.Fatal("the keeper did not end")
	}
	if rk.s.endCode != ExitLost {
		t.Fatalf("the keeper ends %d", rk.s.endCode)
	}
	select {
	case <-rk.running:
	case <-time.After(20 * time.Second):
		t.Fatal("a role kept running after the guard's loss")
	}
	for _, ru := range rk.roles {
		_ = ru.ln.(*net.UnixListener).SetDeadline(time.Now().Add(restartAfter * 3))
		if conn, err := ru.ln.Accept(); err == nil {
			conn.Close()
			t.Fatalf("role %s started again after the guard's loss", ru.r.spec.Name)
		}
	}
}

// The guard's loss after a role's route is admitted and its command
// released, before the role stands (publishRole), ends it as it ends a
// role standing: its space is killed, the keeper ends, and the start,
// published as run publishes it, is ended and never made again.
func TestTheGuardsLossAsARoleStartsEndsIt(t *testing.T) {
	rk := newRolesKeeper(t, nil)
	alpha := rk.roles["alpha"].r
	c, err := rk.s.startRole(alpha)
	if err != nil {
		t.Fatal(err)
	}
	rk.s.guardLost(1)
	if procs, err := alpha.leaf.Procs(); err != nil || len(procs) != 0 {
		t.Errorf("alpha's leaf after the guard's loss: %v, %v", procs, err)
	}
	select {
	case <-rk.s.ended:
	default:
		t.Fatal("the keeper did not end")
	}
	if rk.s.endCode != ExitLost {
		t.Fatalf("the keeper ends %d", rk.s.endCode)
	}
	if ending := rk.s.publishRole(alpha, c); !ending {
		t.Fatal("the start was published as if the keeper ran on")
	}
	go func() {
		rk.s.keepRole(alpha)
		close(rk.running)
	}()
	select {
	case <-rk.running:
	case <-time.After(20 * time.Second):
		t.Fatal("alpha kept running after the guard's loss")
	}
	admits := 0
	for _, call := range rk.guard.taken() {
		if call.op == guard.TypeAdmit && call.reach == guard.ReachRole {
			admits++
		}
	}
	if admits != 1 {
		t.Fatalf("the guard admitted %d roles' routes, want alpha's one start", admits)
	}
}

// A role's process that ends before its channel's reader has run starts
// again as any end does: the reader serves the start it was made for. The
// first reader of beta is held until beta's end is over and keepRole waits
// to start it again.
func TestAnEndBeforeItsReaderRunsStartsTheRoleAgain(t *testing.T) {
	rk := newRolesKeeper(t, nil)
	restartAfter = 2 * time.Second
	held, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	rk.s.readerStarts = func(r *role) {
		if r.spec.Name == "beta" {
			once.Do(func() {
				close(held)
				<-release
			})
		}
	}
	rk.start(t)
	<-held
	beta := rk.roles["beta"]
	rk.s.mu.Lock()
	first := beta.r.client
	rk.s.mu.Unlock()
	rk.s.signalChild(first.proc, unix.SIGKILL)
	for deadline := time.Now().Add(20 * time.Second); ; {
		rk.s.mu.Lock()
		over := first.ended && beta.r.client == nil
		rk.s.mu.Unlock()
		if over {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("beta's end did not finish")
		}
		time.Sleep(10 * time.Millisecond) // sleep-ok: a bounded poll for beta's end
	}
	time.Sleep(200 * time.Millisecond) // sleep-ok: well inside the restart's wait, where keepRole holds no client
	close(release)
	beta.accept(t)
	if reply := beta.ask(t, `{"v":6,"type":"pool","id":"p","pool":"pbeta"}`); reply["type"] != protocol.TypePool {
		t.Fatalf("beta's new channel answered %v", reply)
	}
}

// routed gives the role name a routed pool in place of its relay one,
// before the roles start: its spawns' spaces are admitted by the guard.
func (rk *rolesKeeper) routed(name string) {
	r := rk.roles[name].r
	spec := r.pool
	spec.Reach = pool.ReachRouted
	r.pool = spec
	rk.s.pools[spec.Name] = pool.New(spec)
	for i := range rk.s.cfg.Pools {
		if rk.s.cfg.Pools[i].Name == spec.Name {
			rk.s.cfg.Pools[i] = spec
		}
	}
}

// heldSpawn has the role ask for a spawn of its routed pool with the
// guard's admits held, and answers once its admit is waiting: the spawn
// is past every check before its route's word, its stage made and in its
// group. The guard's admits stay held until release is closed.
func (rk *rolesKeeper) heldSpawn(t *testing.T, ru *roleUnderTest, id string) (release func()) {
	t.Helper()
	if placed := ru.ask(t, `{"v":6,"type":"place","id":"`+id+`","kind":"run"}`); placed["type"] != protocol.TypePlaced {
		t.Fatalf("role %s's place: %v", ru.r.spec.Name, placed)
	}
	hold := make(chan struct{})
	rk.guard.mu.Lock()
	rk.guard.hold = hold
	rk.guard.mu.Unlock()
	var once sync.Once
	release = func() { once.Do(func() { close(hold) }) }
	t.Cleanup(release)
	req := fmt.Sprintf(`{"v":6,"type":"spawn","id":%q,"place":%q,"pool":%q,"argv":["/bin/sh","-c","exec sleep 600"],"env":{},"rlimits":{},"memory_bytes":%d,"cpu_quota":%d,"control":false,"attach":{"path":%q,"token":%q}}`,
		id, id, ru.r.pool.Name, 64<<20, protocol.CPUPeriod, filepath.Join(ru.r.runDir, "attach.sock"), testToken)
	if _, err := ru.conn.Write([]byte(req + "\n")); err != nil {
		t.Fatal(err)
	}
	for deadline := time.Now().Add(20 * time.Second); rk.spawnAdmits() == 0; {
		if time.Now().After(deadline) {
			t.Fatal("the spawn's admit did not arrive")
		}
		time.Sleep(10 * time.Millisecond) // sleep-ok: a bounded poll for the spawn's admit
	}
	return release
}

// spawnAdmits counts the guard's admits of spawns' routes.
func (rk *rolesKeeper) spawnAdmits() int {
	n := 0
	for _, call := range rk.guard.taken() {
		if call.op == guard.TypeAdmit && call.reach == guard.ReachIsland {
			n++
		}
	}
	return n
}

// A role's end waits for its spawn's start in flight, and that start,
// held at its route's admission past every earlier check, sends its stage
// nothing once the end has begun: no route's word, so no command and no
// relay. It is retired, its route withdrawn, before the role starts again:
// the withdrawal is held, and the role waits for it.
func TestARolesEndWaitsForItsSpawnsStartWhichNeverLaunches(t *testing.T) {
	rk := newRolesKeeper(t, nil)
	rk.routed("alpha")
	rk.start(t)
	alpha := rk.roles["alpha"]
	rk.s.mu.Lock()
	first := alpha.r.client
	rk.s.mu.Unlock()
	release := rk.heldSpawn(t, alpha, "s1")
	var spawnID string
	for _, call := range rk.guard.taken() {
		if call.reach == guard.ReachIsland {
			spawnID = call.spawnID
		}
	}
	rk.s.signalChild(first.proc, unix.SIGKILL)
	for deadline := time.Now().Add(20 * time.Second); ; {
		rk.s.mu.Lock()
		ended := first.ended
		rk.s.mu.Unlock()
		if ended {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("alpha's end did not begin")
		}
		time.Sleep(10 * time.Millisecond) // sleep-ok: a bounded poll for alpha's end
	}
	time.Sleep(3 * restartAfter) // sleep-ok: alpha would start again within this, were its end not waiting for the start
	again := func() bool {
		for _, call := range rk.guard.taken() {
			if call.op == guard.TypeAdmit && call.reach == guard.ReachRole && call.port == alpha.r.spec.Port && call.spawnID != first.id {
				return true
			}
		}
		return false
	}
	if again() {
		t.Fatal("alpha started again while its spawn's start was in flight")
	}
	clearing, clear := make(chan struct{}), make(chan struct{})
	rk.guard.mu.Lock()
	rk.guard.beforeClear = func(id string) {
		if id == spawnID {
			close(clearing)
			<-clear
		}
	}
	rk.guard.mu.Unlock()
	release()
	select {
	case <-clearing:
	case <-time.After(20 * time.Second):
		t.Fatal("the refused start's route was not withdrawn")
	}
	time.Sleep(3 * restartAfter) // sleep-ok: alpha would start again within this, were its end not waiting for the refused start's retirement
	if again() {
		t.Fatal("alpha started again while its refused spawn was still retiring")
	}
	close(clear)
	alpha.accept(t)
	_ = alpha.attach.(*net.UnixListener).SetDeadline(time.Now().Add(2 * time.Second))
	if conn, err := alpha.attach.Accept(); err == nil {
		conn.Close()
		t.Fatal("the start of a role that ended launched its command: its relay attached")
	}
	var ops []string
	for _, call := range rk.guard.taken() {
		switch {
		case call.spawnID == spawnID:
			ops = append(ops, call.op+" spawn")
		case call.op == guard.TypeAdmit && call.reach == guard.ReachRole && call.port == alpha.r.spec.Port && call.spawnID != first.id:
			ops = append(ops, "admit alpha again")
		}
	}
	if want := []string{"admit spawn", "clear spawn", "admit alpha again"}; !reflect.DeepEqual(ops, want) {
		t.Fatalf("the guard was asked %v, want %v", ops, want)
	}
}

// A start that outlives its role's end's bound ends the keeper, and the
// keeper's last act, the kill of every role's group, takes it: nothing of
// a start not yet registered outlives the keeper. Served as run serves.
func TestAStartPastItsRolesEndBoundIsKilledAtTheKeepersEnd(t *testing.T) {
	rk := newRolesKeeper(t, nil)
	rk.routed("alpha")
	bound := startsTimeout
	startsTimeout = time.Second
	t.Cleanup(func() { startsTimeout = bound })
	code := make(chan int, 1)
	go func() {
		code <- rk.s.serve(make(chan os.Signal))
		close(rk.running)
	}()
	for _, ru := range rk.roles {
		ru.accept(t)
	}
	alpha := rk.roles["alpha"]
	release := rk.heldSpawn(t, alpha, "s1")
	rk.s.mu.Lock()
	var held *spawn
	for _, sp := range rk.s.routing {
		held = sp
	}
	first := alpha.r.client
	rk.s.mu.Unlock()
	if held == nil || held.group == nil || held.leader == nil {
		t.Fatalf("the start in flight: %+v", held)
	}
	if procs, err := held.group.Procs(); err != nil || len(procs) == 0 {
		t.Fatalf("the start's stage is not in its group: %v, %v", procs, err)
	}
	rk.s.signalChild(first.proc, unix.SIGKILL)
	select {
	case c := <-code:
		if c != ExitLost {
			t.Fatalf("the keeper ends %d", c)
		}
	case <-time.After(60 * time.Second):
		t.Fatal("the keeper did not end past the bound")
	}
	if procs, err := held.group.Procs(); err != nil || len(procs) != 0 {
		t.Fatalf("the start's group after the keeper's end: %v, %v", procs, err)
	}
	// Released, the start is refused and retired, its group removed with it.
	release()
	select {
	case <-held.retired:
	case <-time.After(30 * time.Second):
		t.Fatal("the released start was not retired")
	}
}

// Once the guard's loss has begun the keeper's end, the boot starts no
// further role, even with the guard's client connected again: the loss
// comes after the first role's route's word, before it is published.
func TestTheBootStartsNoRoleOnceTheGuardsLossBegan(t *testing.T) {
	rk := newRolesKeeper(t, nil)
	rk.s.roleStarted = func(r *role) {
		if r.spec.Name == "alpha" {
			rk.s.guardLost(1)
			rk.guard.mu.Lock()
			rk.guard.conn = 2
			rk.guard.mu.Unlock()
		}
	}
	code := rk.s.serve(make(chan os.Signal))
	close(rk.running)
	if code != ExitLost {
		t.Fatalf("the boot ends %d", code)
	}
	for _, call := range rk.guard.taken() {
		if call.op == guard.TypeAdmit && call.port == rk.roles["beta"].r.spec.Port {
			t.Fatalf("beta was started after the guard's loss began: %+v", call)
		}
	}
	if procs, err := rk.roles["alpha"].r.leaf.Procs(); err != nil || len(procs) != 0 {
		t.Fatalf("alpha's leaf after the guard's loss: %v, %v", procs, err)
	}
}

// A run folder's maker gives its thread's file ids back before it answers,
// on success and on failure: the thread's own status reads the keeper's.
func TestARunFolderMakerGivesItsFileIDsBack(t *testing.T) {
	if os.Getuid() != 0 {
		t.Skip("taking another uid's file ids needs root")
	}
	base, err := os.MkdirTemp("", "cyfr-own-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(base) })
	if err := os.Chmod(base, os.ModeSticky|0o777); err != nil {
		t.Fatal(err)
	}
	if err := makeOwnDir(filepath.Join(base, "made"), testRoleUID, testRoleUID); err != nil {
		t.Fatalf("a folder made: %v", err)
	}
	if st := mustStat(t, filepath.Join(base, "made")); st.Uid != testRoleUID {
		t.Fatalf("the folder is uid %d's", st.Uid)
	}
	err = makeOwnDir(filepath.Join(base, "absent", "made"), testRoleUID, testRoleUID)
	if !errors.Is(err, unix.ENOENT) || strings.Contains(err.Error(), "after their restoration") {
		t.Fatalf("a folder under no parent: %v", err)
	}
}

// The run root opens to the roles only while their folders are made, each
// by its own uid: then it is the keeper's alone, and a folder there that is
// not its role's refuses the boot.
func TestEachRolesRunFolderIsItsOwn(t *testing.T) {
	if os.Getuid() != 0 {
		t.Skip("making a folder as another uid needs root")
	}
	// Each role's uid makes its folder itself, so it must reach the root.
	base, err := os.MkdirTemp("", "cyfr-run-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(base) })
	if err := os.Chmod(base, 0o755); err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(base, "run")
	if err := os.Mkdir(root, 0o755); err != nil {
		t.Fatal(err)
	}
	roles := []*role{
		{spec: RoleSpec{Name: "alpha"}, account: Account{UID: testRoleUID, GID: testRoleUID}, runDir: filepath.Join(root, "alpha")},
		{spec: RoleSpec{Name: "beta"}, account: Account{UID: testRoleUID2, GID: testRoleUID2}, runDir: filepath.Join(root, "beta")},
	}
	if err := makeRunDirs(root, roles); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Lstat(root); err != nil || info.Mode() != RunRootMode {
		t.Fatalf("the run root after: %v, %v", info.Mode(), err)
	}
	for _, r := range roles {
		if err := home.CheckOwnDir(r.runDir, r.account.UID, errors.New("not its own")); err != nil {
			t.Fatal(err)
		}
		if st := mustStat(t, r.runDir); int(st.Gid) != r.account.GID {
			t.Fatalf("%s is of group %d", r.runDir, st.Gid)
		}
	}
	// Again, as after a keeper's restart: the folders stand.
	if err := makeRunDirs(root, roles); err != nil {
		t.Fatalf("a second boot: %v", err)
	}
	// A folder of another's refuses the boot, and the root is closed
	// again.
	if err := os.Chown(roles[1].runDir, testRoleUID, testRoleUID); err != nil {
		t.Fatal(err)
	}
	if err := makeRunDirs(root, roles); err == nil {
		t.Fatal("a run folder of another role's uid was taken")
	}
	if info, _ := os.Lstat(root); info.Mode() != RunRootMode {
		t.Fatalf("the run root after a refusal: %v", info.Mode())
	}
}

func mustStat(t *testing.T, path string) *syscall.Stat_t {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	return info.Sys().(*syscall.Stat_t)
}
