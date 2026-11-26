// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/admission"
	"github.com/cyfr/locus/keeper/internal/frame"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/logx"
	"github.com/cyfr/locus/keeper/internal/pool"
	"github.com/cyfr/locus/keeper/internal/procfs"
	"github.com/cyfr/locus/keeper/internal/protocol"
	"github.com/cyfr/locus/keeper/internal/residue"
	"github.com/cyfr/locus/keeper/internal/stage"
)

// TestMain gives the test binary the commands spawns run as `<helper> …`:
// `hold` and `mapped` are the memory tests', `fill` the relay's end's,
// `mounts` and `queue` the space tests', `dial`, `ask` and `own` the network tests',
// `role` a role's process (roleHelper).
// The keeper under test starts its own helpers, `stage`, `relay`, `retire`
// and `home`, from a plain build of cyfr-locus (keeperBinary).
func TestMain(m *testing.M) {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "hold":
			os.Exit(hold(os.Args[2:]))
		case "mapped":
			os.Exit(mapped(os.Args[2:]))
		case "dial":
			os.Exit(dial(os.Args[2:]))
		case "ask":
			os.Exit(ask(os.Args[2]))
		case "own":
			os.Exit(own(os.Args[2:]))
		case "fill":
			os.Exit(fill())
		case "mounts":
			os.Exit(tryMounts())
		case "queue":
			os.Exit(queue(os.Args[2:]))
		case "role":
			os.Exit(roleHelper(os.Args[2:]))
		}
	}
	os.Exit(m.Run())
}

// dial tries a TCP connection to each address it is given and prints
// `dial <address>: ok` or `dial <address>: <error>` for each.
func dial(addresses []string) int {
	for _, address := range addresses {
		conn, err := net.DialTimeout("tcp", address, 2*time.Second)
		if err != nil {
			fmt.Printf("dial %s: %v\n", address, err)
			continue
		}
		conn.Close()
		fmt.Printf("dial %s: ok\n", address)
	}
	return 0
}

// ask sends one datagram to address and prints `ask <address>: <answer>`
// or the error.
func ask(address string) int {
	conn, err := net.DialTimeout("udp", address, 2*time.Second)
	if err == nil {
		_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
		_, err = conn.Write([]byte("q"))
	}
	buf := make([]byte, 512)
	n := 0
	if err == nil {
		n, err = conn.Read(buf)
	}
	if err != nil {
		fmt.Printf("ask %s: %v\n", address, err)
		return 0
	}
	fmt.Printf("ask %s: %s\n", address, buf[:n])
	return 0
}

// own listens on 127.0.0.1:<port>, answering each connection with the word
// it is given, keeps the listener for the seconds it is told to, and
// prints `own <port>: <what a connection to that port read>` first.
func own(args []string) int {
	ln, err := net.Listen("tcp", "127.0.0.1:"+args[0])
	if err != nil {
		fmt.Printf("own %s: %v\n", args[0], err)
		return 0
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			_, _ = c.Write([]byte(args[1]))
			c.Close()
		}
	}()
	c, err := net.DialTimeout("tcp", "127.0.0.1:"+args[0], 2*time.Second)
	if err != nil {
		fmt.Printf("own %s: %v\n", args[0], err)
		return 0
	}
	got, _ := io.ReadAll(c)
	c.Close()
	fmt.Printf("own %s: %s\n", args[0], got)
	seconds, _ := strconv.Atoi(args[2])
	time.Sleep(time.Duration(seconds) * time.Second) // sleep-ok: the listener stands while the other space binds the port
	return 0
}

// hold touches every page of the MiB it is told to hold, says so, keeps them
// for the seconds it is told to and exits 0.
func hold(args []string) int {
	mib, _ := strconv.Atoi(args[0])
	seconds, _ := strconv.Atoi(args[1])
	held := make([][]byte, 0, mib)
	for i := 0; i < mib; i++ {
		page := make([]byte, 1<<20)
		for j := range page {
			page[j] = 1
		}
		held = append(held, page)
	}
	fmt.Println("held")
	time.Sleep(time.Duration(seconds) * time.Second)
	return int(held[0][0]) - 1
}

// mapped maps the file it is given, as a program maps its own code, touches
// every page, and keeps it for the seconds it is told to.
func mapped(args []string) int {
	file, err := os.Open(args[0])
	if err != nil {
		return 1
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return 1
	}
	pages, err := unix.Mmap(int(file.Fd()), 0, int(info.Size()), unix.PROT_READ, unix.MAP_SHARED)
	if err != nil {
		return 1
	}
	seconds, _ := strconv.Atoi(args[1])
	var sum byte
	for end := time.Now().Add(time.Duration(seconds) * time.Second); time.Now().Before(end); time.Sleep(200 * time.Millisecond) {
		for i := 0; i < len(pages); i += 4096 {
			sum += pages[i]
		}
	}
	runtime.KeepAlive(sum)
	return 0
}

const (
	testPoolFirst = 39001
	testPoolLast  = 39002
	testToken     = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
)

// keeper is a server wired as `serve` wires it, with one role's client and
// without its process: the test holds the client's end of the channel and
// the attach socket. It needs root, to run the stage under a pooled uid and
// the relay as `nobody`, the role's uid here.
type keeper struct {
	s       *server
	c       *client
	channel *protocol.LineReader
	ln      net.Listener
	attach  string
	homes   string
	stop    chan struct{}
	// guard is a routed keeper's stand-in guard, nil for a relay keeper.
	guard *fakeRouteGuard
	// helper is the test binary, executable by every uid: the commands
	// spawns run (TestMain).
	helper string
}

// testClient is a client of a role "test" drawing from spec, of account
// acct, on channel: a role's client as serve makes one, without its
// process, groups or run folder.
// testClient is a client of a role of the pool spec, the floor's (whose
// kinds are a runner's) where its pool is the runner pool, as the
// runtime's is.
func testClient(channel *os.File, spec pool.Spec, acct Account) *client {
	r := &role{spec: RoleSpec{Name: "test", UID: acct.UID, Pool: spec.Name, Floor: spec.Name == "runner"}, pool: spec, account: acct}
	c := &client{role: r, id: randomHex(16), channel: channel, places: map[string]*place{}, wake: make(chan struct{}, 1)}
	r.client = c
	return c
}

// keeperBuild is the plain build of cyfr-locus the keepers under test
// start their helpers from, made once.
var keeperBuild struct {
	once sync.Once
	path string
	err  error
}

// keeperBinary builds cyfr-locus, the keeper's main package, statically and
// without the race detector, as the image carries it: a space's waiter and
// init then weigh in its group what they weigh in the image's, whatever
// this test binary was built with.
func keeperBinary(t *testing.T) string {
	t.Helper()
	keeperBuild.once.Do(func() {
		dir, err := os.MkdirTemp("", "cyfr-locus-build-")
		if err != nil {
			keeperBuild.err = err
			return
		}
		keeperBuild.path = filepath.Join(dir, "cyfr-locus")
		cmd := exec.Command("go", "build", "-o", keeperBuild.path, "github.com/cyfr/locus/keeper")
		cmd.Dir = filepath.Join("..", "..")
		cmd.Env = append(os.Environ(), "CGO_ENABLED=0")
		if out, err := cmd.CombinedOutput(); err != nil {
			keeperBuild.err = fmt.Errorf("go build: %v\n%s", err, out)
		}
	})
	if keeperBuild.err != nil {
		t.Fatal(keeperBuild.err)
	}
	return keeperBuild.path
}

// newKeeper is a keeper whose runner pool's spaces reach nothing but their
// relays.
func newKeeper(t *testing.T) *keeper { return newKeeperOf(t, pool.ReachRelay) }

// routedKeeper is a bounded keeper whose runner pool is routed, behind a
// stand-in guard that admits every route (fakeRouteGuard).
func routedKeeper(t *testing.T) *keeper {
	t.Helper()
	return newKeeperOf(t, pool.ReachRouted).withMemory(t)
}

// newKeeperOf is newKeeper with its runner pool's spaces of the given
// reach, on a host that gives a spawn its space as the keeper's start-time
// probe proves; elsewhere the test is skipped, naming the probe's refusal.
// The test's supplementary groups are cleared while it runs, as serve.Main
// clears the keeper's.
func newKeeperOf(t *testing.T, reach string) *keeper {
	t.Helper()
	if os.Getuid() != 0 {
		t.Skip("starting processes under pooled uids needs root")
	}
	// The stage insists on no_new_privs, which the processes forked from
	// this thread inherit; serve.Main sets it on every thread, which the
	// race detector's cgo forbids here, so the test stays on one thread.
	runtime.LockOSThread()
	t.Cleanup(runtime.UnlockOSThread)
	if err := unix.Prctl(unix.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0); err != nil {
		t.Fatal(err)
	}
	if err := unix.Prctl(unix.PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0); err != nil {
		t.Fatal(err)
	}

	base, err := os.MkdirTemp("", "cyfr-locus-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(base) })
	if err := os.Chmod(base, 0o755); err != nil {
		t.Fatal(err)
	}
	homes := filepath.Join(base, "homes")
	if err := os.Mkdir(homes, 0o733); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(homes, home.RootMode.Perm()|os.ModeSticky); err != nil {
		t.Fatal(err)
	}
	if err := home.CheckRoot(homes); err != nil {
		t.Fatal(err)
	}
	// The pooled uids and the client user must be able to execute the
	// keeper's binary and the test's helper, which go test keeps in a
	// directory only root can enter. A space sees the container's /opt and
	// none of its /tmp, so the copies are kept there, and the space's files
	// are built where the image builds them.
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(stage.Root, 0o755); err != nil {
		t.Fatal(err)
	}
	bin, err := os.MkdirTemp("/opt", "cyfr-locus-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(bin) })
	if err := os.Chmod(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	binary := filepath.Join(bin, "cyfr-locus")
	helper := filepath.Join(bin, "cyfr-locus-test")
	for copy, from := range map[string]string{binary: keeperBinary(t), helper: self} {
		data, err := os.ReadFile(from)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(copy, data, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	attachDir := filepath.Join(base, "attach")
	if err := os.Mkdir(attachDir, 0o755); err != nil {
		t.Fatal(err)
	}
	attach := filepath.Join(attachDir, "attach.sock")
	ln, err := net.Listen("unix", attach)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	if err := os.Chmod(attach, 0o777); err != nil {
		t.Fatal(err)
	}

	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err := unix.SetNonblock(fds[0], true); err != nil {
		t.Fatal(err)
	}
	theirs := os.NewFile(uintptr(fds[1]), "client-channel")
	t.Cleanup(func() { theirs.Close() })

	spec := pool.Spec{Name: "runner", First: testPoolFirst, Last: testPoolLast, Reach: reach}
	accounts := map[int]Account{}
	for uid := spec.First; uid <= spec.Last; uid++ {
		accounts[uid] = Account{UID: uid, GID: uid, Name: strconv.Itoa(uid)}
	}
	s := &server{
		cfg:       Config{Pools: []pool.Spec{spec}, HomeRoot: filepath.Dir(homes)},
		log:       logx.NewWriter(os.Stderr, "cyfr-locus", false),
		self:      binary,
		accounts:  accounts,
		roots:     residue.Roots{Dirs: []string{base}},
		pools:     map[string]*pool.Pool{spec.Name: pool.New(spec)},
		spawns:    map[string]*spawn{},
		unremoved: map[*spawn]*removal{},
		waiters:   map[int]*child{},
		keptLive:  map[int]int{},
		keptOps:   map[int]*sync.Mutex{},
		ended:     make(chan struct{}),
		ledger:    admission.New(testWork, true),
	}
	c := testClient(os.NewFile(uintptr(fds[0]), "channel"), spec, Account{UID: 65534, GID: 65534, Name: "nobody"})
	c.role.homeRoot = homes
	k := &keeper{s: s, c: c, channel: protocol.NewLineReader(theirs), ln: ln, attach: attach, homes: homes, stop: make(chan struct{}), helper: helper}
	// The keeper's own end would end the test binary: a test that expects
	// it sets its own.
	s.exit = func(code int) { t.Errorf("the keeper ended %d", code) }
	if reach == pool.ReachRouted {
		k.guard = &fakeRouteGuard{conn: 1}
		s.guard = k.guard
		s.cfg.Guard = "/run/test/guard.sock"
	}
	groups, err := syscall.Getgroups()
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Setgroups([]int{}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = syscall.Setgroups(groups) })
	if err := probeSpaces(s.self, s.cfg, s.accounts); err != nil {
		t.Skipf("this host does not give a spawn its space: %v", err)
	}

	sigchld := make(chan os.Signal, 1)
	signal.Notify(sigchld, unix.SIGCHLD)
	go func() {
		tick := time.NewTicker(100 * time.Millisecond)
		defer tick.Stop()
		for {
			select {
			case <-sigchld:
			case <-tick.C:
			case <-k.stop:
				return
			}
			s.reap()
		}
	}()
	t.Cleanup(func() {
		s.mu.Lock()
		live := make([]*spawn, 0, len(s.spawns))
		for _, sp := range s.spawns {
			live = append(live, sp)
		}
		s.mu.Unlock()
		for _, sp := range live {
			s.retire(sp, 0, false)
		}
		for _, sp := range live {
			select {
			case <-sp.retired:
			case <-time.After(20 * time.Second):
			}
		}
		if r := c.role; r.leaf != nil {
			r.leaf.KillBy(time.Now())
			_ = r.leaf.Remove()
			_ = os.Remove(r.groups.Dir())
		}
		c.channel.Close()
		signal.Stop(sigchld)
		close(k.stop)
	})
	return k
}

// reply reads the next line the keeper sent on the channel.
func (k *keeper) reply(t *testing.T) map[string]any {
	t.Helper()
	line, tooLong, err := k.channel.Next()
	if err != nil || tooLong {
		t.Fatalf("reading the channel: %v (too long %t)", err, tooLong)
	}
	var m map[string]any
	if err := json.Unmarshal(line, &m); err != nil {
		t.Fatalf("reply %q: %v", line, err)
	}
	return m
}

// spawn asks for a spawn of `/bin/sh -c script` and answers its spawn id
// and uid, and the relay's connection read past its attach frame.
func (k *keeper) spawn(t *testing.T, id, script string, env map[string]string, control bool) (string, int, *relayConn) {
	t.Helper()
	return k.spawnBounded(t, id, script, env, control, 64<<20)
}

// boundAt has the keeper bound every spawn to memoryBytes and one
// processor until the test ends, whatever its kind, as a test's work
// needs; the bounds each kind has are held by their own tests.
func boundAt(t *testing.T, memoryBytes uint64) {
	t.Helper()
	before := limitsOf
	limitsOf = func(string, uint64) admission.Limits {
		return admission.Limits{MemoryBytes: memoryBytes, Processors: 1}
	}
	t.Cleanup(func() { limitsOf = before })
}

// spawnRequest is the parsed request for a spawn of `/bin/sh -c script`
// in the place of its own id, the keeper bounding it to memoryBytes.
func spawnRequest(t *testing.T, attach, id, script string, env map[string]string, control bool, memoryBytes uint64) *protocol.Request {
	t.Helper()
	boundAt(t, memoryBytes)
	message := map[string]any{
		"v": protocol.Version, "type": protocol.TypeSpawn, "id": id, "place": id, "pool": "runner",
		"argv": []string{"/bin/sh", "-c", script}, "env": env, "control": control,
		"attach": map[string]string{"path": attach, "token": testToken},
	}
	line, err := json.Marshal(message)
	if err != nil {
		t.Fatal(err)
	}
	req, rerr := protocol.ParseRequest(line)
	if rerr != nil {
		t.Fatal(rerr.Detail)
	}
	return req
}

// spawnBounded is spawn with the given memory bound.
func (k *keeper) spawnBounded(t *testing.T, id, script string, env map[string]string, control bool, memoryBytes uint64) (string, int, *relayConn) {
	t.Helper()
	req := spawnRequest(t, k.attach, id, script, env, control, memoryBytes)
	k.handleSpawn(t, req)

	spawned := k.reply(t)
	if spawned["type"] != protocol.TypeSpawned || spawned["id"] != id {
		t.Fatalf("spawn %s answered %v", id, spawned)
	}
	uid := int(spawned["uid"].(float64))
	if uid < testPoolFirst || uid > testPoolLast || spawned["pid"].(float64) <= 0 {
		t.Fatalf("spawned %v", spawned)
	}
	if v, ok := k.ln.(interface{ SetDeadline(time.Time) error }); ok {
		_ = v.SetDeadline(time.Now().Add(10 * time.Second))
	}
	conn, err := k.ln.Accept()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	_ = conn.SetDeadline(time.Now().Add(20 * time.Second))
	rc := &relayConn{conn: conn, buf: make([]byte, frame.MaxPayload), got: map[byte][]byte{}}
	stream, payload, err := frame.Read(conn, rc.buf)
	if err != nil || stream != frame.StreamAttach || string(payload) != testToken {
		t.Fatalf("attach frame %d %q %v", stream, payload, err)
	}
	return spawned["spawn_id"].(string), uid, rc
}

// parsed is the request line parses to.
func parsed(t *testing.T, line string) *protocol.Request {
	t.Helper()
	req, rerr := protocol.ParseRequest([]byte(line))
	if rerr != nil {
		t.Fatal(rerr.Detail)
	}
	return req
}

// place has the keeper hold a place of id for kind, and answers its reply.
func (k *keeper) place(t *testing.T, id, kind string) map[string]any {
	t.Helper()
	k.s.handle(k.c, parsed(t, `{"v":8,"type":"place","id":"`+id+`","kind":"`+kind+`"}`))
	return k.reply(t)
}

// kind is a place's kind the keeper's client may name: a run's on the
// floor's role, a program's on any other.
func (k *keeper) kind() string {
	if k.c.role.spec.Floor {
		return protocol.KindRun
	}
	return protocol.KindProgram
}

// handleSpawn places the place req names, a run's on the floor's role and
// a program's on any other, and then asks for the spawn, as a client does
// once its preparation is done.
func (k *keeper) handleSpawn(t *testing.T, req *protocol.Request) {
	t.Helper()
	if placed := k.place(t, req.Place, k.kind()); placed["type"] != protocol.TypePlaced || placed["id"] != req.Place {
		t.Fatalf("place %s answered %v", req.Place, placed)
	}
	k.s.handleSpawn(k.c, req)
}

func (k *keeper) release(t *testing.T, spawnID string) {
	t.Helper()
	grace := int64(0)
	k.s.handleRelease(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: spawnID, GraceMs: &grace})
}

// relayConn is the client's view of one relay: every stream's bytes so far
// and which streams have ended.
type relayConn struct {
	conn  net.Conn
	buf   []byte
	got   map[byte][]byte
	ended map[byte]bool
	eof   bool
}

// readUntil reads frames until done reports true, or the connection ends.
func (rc *relayConn) readUntil(t *testing.T, done func() bool) {
	t.Helper()
	if rc.ended == nil {
		rc.ended = map[byte]bool{}
	}
	for !done() && !rc.eof {
		stream, payload, err := frame.Read(rc.conn, rc.buf)
		if errors.Is(err, io.EOF) {
			rc.eof = true
			return
		}
		if err != nil {
			t.Fatalf("reading the relay: %v", err)
		}
		if len(payload) == 0 {
			rc.ended[stream] = true
		} else {
			rc.got[stream] = append(rc.got[stream], payload...)
		}
	}
}

func (rc *relayConn) send(t *testing.T, stream byte, payload []byte) {
	t.Helper()
	if err := frame.Write(rc.conn, stream, payload); err != nil {
		t.Fatal(err)
	}
}

// An undeclared KEEPER_ variable stops `serve` before it looks at its
// privileges, so the refusal names the variable whoever runs the test.
func TestServeRefusesAnUndeclaredKeeperVariableNamingIt(t *testing.T) {
	t.Setenv("KEEPER_POOL", "build:30001-30016")
	logFile, err := os.CreateTemp(t.TempDir(), "stderr")
	if err != nil {
		t.Fatal(err)
	}
	stderr := os.Stderr
	os.Stderr = logFile
	code := Main(strings.Fields("--role builds:10012:4100:build --pool build:30001-30016:routed --home-root /var/lib/locus/homes --guard /run/g -- /app/bin/locus start"))
	os.Stderr = stderr

	logged, err := os.ReadFile(logFile.Name())
	if err != nil {
		t.Fatal(err)
	}
	if code != ExitConfig || !strings.Contains(string(logged), "refusing to start: KEEPER_POOL: not a variable cyfr-locus reads") {
		t.Fatalf("exit %d, logged %q", code, logged)
	}
	if strings.Contains(string(logged), "30001") {
		t.Fatalf("the refusal carries the variable's value: %q", logged)
	}
}

func TestRunnerLifecycleUnderAPooledUID(t *testing.T) {
	k := boundedKeeper(t)
	t.Setenv("SPAWN_TEST_CANARY", "leaked")

	// A runner: its control channel is fd 3, its environment is the
	// request's and nothing of the keeper's, and closing fd 3 ends the
	// control stream while the process lives.
	script := `if [ -e /proc/self/fd/3 ]; then echo fd3:open; else echo fd3:closed; fi
env
echo env:done
IFS= read -r line <&3
printf 'echo:%s\n' "$line" >&3
echo 'to stderr' >&2
exec 3>&-
sleep 60`
	spawnID, uid, rc := k.spawn(t, "1", script, map[string]string{"RUNTIME_ROLE": "runner"}, true)
	rc.send(t, frame.StreamControl, []byte(`{"v":1,"type":"assign"}`+"\n"))
	rc.readUntil(t, func() bool {
		return rc.ended[frame.StreamControl] && strings.Contains(string(rc.got[frame.StreamStdout]), "env:done\n")
	})
	if rc.eof {
		t.Fatal("the relay ended while the runner lives")
	}
	if got := string(rc.got[frame.StreamControl]); got != `echo:{"v":1,"type":"assign"}`+"\n" {
		t.Fatalf("control stream carried %q", got)
	}
	stdout := string(rc.got[frame.StreamStdout])
	if !strings.Contains(stdout, "fd3:open\n") {
		t.Fatalf("fd 3 is not open in the runner:\n%s", stdout)
	}
	for _, want := range []string{"RUNTIME_ROLE=runner\n", "HOME=" + k.homes + "/" + strconv.Itoa(uid) + "-", "USER=" + strconv.Itoa(uid) + "\n"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("environment lacks %q:\n%s", want, stdout)
		}
	}
	if strings.Contains(stdout, "SPAWN_TEST_CANARY") {
		t.Fatalf("the keeper's environment reached the runner:\n%s", stdout)
	}
	if c, err := procfs.ScanUID("/proc", uid, 0); err != nil || c.Live == 0 {
		t.Fatalf("no live process under uid %d: %+v %v", uid, c, err)
	}

	// Release: every process of the uid is killed, the relay's streams
	// end, the home is gone and the uid is free again.
	k.release(t, spawnID)
	exited := k.reply(t)
	if exited["type"] != protocol.TypeExited || exited["spawn_id"] != spawnID || exited["signal"] != "SIGKILL" {
		t.Fatalf("after release: %v", exited)
	}
	released := k.reply(t)
	if released["type"] != protocol.TypeReleased || released["spawn_id"] != spawnID {
		t.Fatalf("after exited: %v", released)
	}
	rc.readUntil(t, func() bool { return false })
	if !rc.ended[frame.StreamStdout] || !rc.ended[frame.StreamStderr] || string(rc.got[frame.StreamStderr]) != "to stderr\n" {
		t.Fatalf("streams after release: ended %v stderr %q", rc.ended, rc.got[frame.StreamStderr])
	}
	assertRetired(t, k, uid)

	// Releasing it again names a spawn the keeper no longer holds.
	k.release(t, spawnID)
	if again := k.reply(t); again["type"] != protocol.TypeError || again["code"] != protocol.CodeUnknownSpawn || again["spawn_id"] != spawnID {
		t.Fatalf("second release: %v", again)
	}
}

func TestRunnerExitEndsItsControlStreamAndRetiresIt(t *testing.T) {
	k := boundedKeeper(t)
	spawnID, uid, rc := k.spawn(t, "2", `printf 'bye\n' >&3; exit 7`, map[string]string{}, true)
	rc.readUntil(t, func() bool { return false })
	if string(rc.got[frame.StreamControl]) != "bye\n" || !rc.ended[frame.StreamControl] || !rc.ended[frame.StreamStdout] || !rc.ended[frame.StreamStderr] {
		t.Fatalf("streams: %q ended %v", rc.got, rc.ended)
	}
	exited := k.reply(t)
	if exited["type"] != protocol.TypeExited || exited["spawn_id"] != spawnID || exited["code"] != float64(7) {
		t.Fatalf("exit: %v", exited)
	}
	if released := k.reply(t); released["type"] != protocol.TypeReleased || released["spawn_id"] != spawnID {
		t.Fatalf("after exited: %v", released)
	}
	assertRetired(t, k, uid)
}

func TestASpawnWithoutControlHasNoFd3(t *testing.T) {
	k := boundedKeeper(t)
	script := `if [ -e /proc/self/fd/3 ]; then echo fd3:open; else echo fd3:closed; fi`
	spawnID, uid, rc := k.spawn(t, "3", script, map[string]string{}, false)
	rc.readUntil(t, func() bool { return false })
	if string(rc.got[frame.StreamStdout]) != "fd3:closed\n" || len(rc.got[frame.StreamControl]) != 0 || rc.ended[frame.StreamControl] {
		t.Fatalf("streams: %q ended %v", rc.got, rc.ended)
	}
	if exited := k.reply(t); exited["type"] != protocol.TypeExited || exited["code"] != float64(0) {
		t.Fatalf("exit: %v", exited)
	}
	if released := k.reply(t); released["type"] != protocol.TypeReleased || released["spawn_id"] != spawnID {
		t.Fatalf("after exited: %v", released)
	}
	assertRetired(t, k, uid)
}

// assertRetired checks that nothing of the uid remains and it is free.
func assertRetired(t *testing.T, k *keeper, uid int) {
	t.Helper()
	if c, err := procfs.ScanUID("/proc", uid, 0); err != nil || c.Total() != 0 {
		t.Fatalf("processes of uid %d after retirement: %+v %v", uid, c, err)
	}
	entries, err := os.ReadDir(k.homes)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), fmt.Sprintf("%d-", uid)) {
			t.Fatalf("home %s outlived retirement", e.Name())
		}
	}
	k.s.mu.Lock()
	st := k.s.pools["runner"].Stats()
	held := len(k.s.spawns)
	k.s.mu.Unlock()
	if st.Free != st.Size || st.Quarantined != 0 || held != 0 {
		t.Fatalf("pool after retirement: %+v, %d spawns held", st, held)
	}
}

// mainLogs runs `serve` with args, its stderr kept, and answers its exit
// and what it logged.
func mainLogs(t *testing.T, args string) (int, string) {
	t.Helper()
	logFile, err := os.CreateTemp(t.TempDir(), "stderr")
	if err != nil {
		t.Fatal(err)
	}
	stderr := os.Stderr
	os.Stderr = logFile
	code := Main(strings.Fields(args))
	os.Stderr = stderr
	logged, err := os.ReadFile(logFile.Name())
	if err != nil {
		t.Fatal(err)
	}
	return code, string(logged)
}

// A keeper given no role's key would run nothing, and one given a role's
// bound it cannot read would hold it to none: each refuses its boot by the
// variables' names, never their values, before it looks at its privileges.
func TestServeRefusesNoKeyAndAnUnreadableBoundByName(t *testing.T) {
	const args = "--role runtime:10011:4200:runner:private --role builds:10012:4100:build --pool runner:30101-30108:relay --pool build:30001-30016:routed --home-root /var/lib/locus/homes --guard /run/g -- /app/bin/locus start"
	t.Setenv("LOCUS_RUNTIME_KEY", "")
	t.Setenv("LOCUS_BUILDS_KEY", "")
	code, logged := mainLogs(t, args)
	if code != ExitConfig || !strings.Contains(logged, "no role's key is set (LOCUS_RUNTIME_KEY, LOCUS_BUILDS_KEY)") {
		t.Fatalf("no key: exit %d, logged %q", code, logged)
	}
	t.Setenv("LOCUS_BUILDS_KEY", "secret-key")
	t.Setenv("LOCUS_RUNTIME_CPU_LIMIT", "four")
	code, logged = mainLogs(t, args)
	if code != ExitConfig || !strings.Contains(logged, "role runtime: LOCUS_RUNTIME_CPU_LIMIT is not a number of processors") || strings.Contains(logged, "four") || strings.Contains(logged, "secret-key") {
		t.Fatalf("an unreadable bound: exit %d, logged %q", code, logged)
	}
	t.Setenv("LOCUS_RUNTIME_CPU_LIMIT", "")
	t.Setenv("LOCUS_CORE_RESERVE_BYTES", "2G")
	code, logged = mainLogs(t, args)
	if code != ExitConfig || !strings.Contains(logged, "LOCUS_CORE_RESERVE_BYTES is not a count of bytes") || strings.Contains(logged, "2G") || strings.Contains(logged, "secret-key") {
		t.Fatalf("an unreadable reserve: exit %d, logged %q", code, logged)
	}
}

// A keeper given no --kept-homes refuses every home request as unavailable
// on the channel, before any helper runs, and a request after them is still
// handled.
func TestHomeRequestsWithoutKeptHomesAreRefused(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "tests", "fixtures", "keeper_protocol.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Home []json.RawMessage `json:"home_requests"`
	}
	if err := json.Unmarshal(data, &v); err != nil || len(v.Home) == 0 {
		t.Fatalf("home_requests: %d, %v", len(v.Home), err)
	}
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	ours, theirs := os.NewFile(uintptr(fds[0]), "channel"), os.NewFile(uintptr(fds[1]), "client-channel")
	defer theirs.Close()
	var logged strings.Builder
	s := &server{
		log:      logx.NewWriter(&logged, "cyfr-locus", false),
		pools:    map[string]*pool.Pool{},
		spawns:   map[string]*spawn{},
		waiters:  map[int]*child{},
		keptLive: map[int]int{},
		keptOps:  map[int]*sync.Mutex{},
		ledger:   admission.New(testWork, true),
	}
	done := make(chan struct{})
	go func() { s.serveChannel(testClient(ours, pool.Spec{Name: "runner"}, Account{})); close(done) }()

	var ids []string
	for _, raw := range v.Home {
		var req struct {
			ID   string `json:"id"`
			Type string `json:"type"`
		}
		if err := json.Unmarshal(raw, &req); err != nil {
			t.Fatal(err)
		}
		if req.Type == protocol.TypeSpawn {
			continue
		}
		ids = append(ids, req.ID)
		var line bytes.Buffer
		if err := json.Compact(&line, raw); err != nil {
			t.Fatal(err)
		}
		if _, err := theirs.Write(append(line.Bytes(), '\n')); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := theirs.Write([]byte(`{"v":8,"type":"pool","id":"after","pool":"backends"}` + "\n")); err != nil {
		t.Fatal(err)
	}
	lr := protocol.NewLineReader(theirs)
	got := map[string]protocol.ErrorReply{}
	for range append(ids, "after") {
		line, _, err := lr.Next()
		if err != nil {
			t.Fatal(err)
		}
		var reply protocol.ErrorReply
		if err := json.Unmarshal(line, &reply); err != nil {
			t.Fatalf("reply %s: %v", line, err)
		}
		got[reply.ID] = reply
	}
	for _, id := range ids {
		if want := protocol.NewError(id, "", protocol.CodeUnavailable); got[id] != want {
			t.Fatalf("request %s answered %+v, want %+v", id, got[id], want)
		}
	}
	if want := protocol.NewError("after", "", protocol.CodeUnknownPool); got["after"] != want {
		t.Fatalf("the request after answered %+v", got["after"])
	}
	theirs.Close()
	<-done
	ours.Close()
	if n := strings.Count(logged.String(), "no --kept-homes"); n != len(ids) {
		t.Fatalf("logged %d refusals naming --kept-homes, want %d: %q", n, len(ids), logged.String())
	}
}

// A resize sets the size of a spawn's terminal through the keeper's own
// descriptor of its master and answers nothing; one of a held spawn without
// a terminal is refused as a bad request, and one of a spawn the keeper does
// not hold as unknown, as a signal is. None needs root.
func TestAResizeSetsTheTerminalOrIsRefused(t *testing.T) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	ours, theirs := os.NewFile(uintptr(fds[0]), "channel"), os.NewFile(uintptr(fds[1]), "client-channel")
	t.Cleanup(func() { ours.Close(); theirs.Close() })
	master, slave, err := openPty(24, 80)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { slave.Close() })
	withPty := &spawn{id: strings.Repeat("a", 32), pty: master}
	plain := &spawn{id: strings.Repeat("b", 32)}
	t.Cleanup(withPty.closePty)
	s := &server{
		log:    logx.NewWriter(io.Discard, "cyfr-locus", false),
		spawns: map[string]*spawn{withPty.id: withPty, plain.id: plain},
		ledger: admission.New(testWork, true),
	}
	c := testClient(ours, pool.Spec{Name: "runner"}, Account{})
	withPty.client, plain.client = c, c
	resize := func(spawnID string) *protocol.Request {
		req, rerr := protocol.ParseRequest([]byte(`{"v":8,"type":"resize","spawn_id":"` + spawnID + `","rows":50,"cols":132}`))
		if rerr != nil {
			t.Fatal(rerr.Detail)
		}
		return req
	}
	s.handle(c, resize(withPty.id))
	if ws, err := unix.IoctlGetWinsize(int(slave.Fd()), unix.TIOCGWINSZ); err != nil || ws.Row != 50 || ws.Col != 132 {
		t.Fatalf("the terminal after the resize: %+v, %v", ws, err)
	}
	unknown := strings.Repeat("c", 32)
	s.handle(c, resize(plain.id))
	s.handle(c, resize(unknown))

	// The resize that succeeded sent nothing: the first reply is the next
	// request's refusal.
	lr := protocol.NewLineReader(theirs)
	for _, want := range []protocol.ErrorReply{
		protocol.NewError("", plain.id, protocol.CodeBadRequest),
		protocol.NewError("", unknown, protocol.CodeUnknownSpawn),
	} {
		line, _, err := lr.Next()
		if err != nil {
			t.Fatal(err)
		}
		var got protocol.ErrorReply
		if err := json.Unmarshal(line, &got); err != nil || got != want {
			t.Fatalf("answered %s, want %+v", line, want)
		}
	}
}

// The probe checks a space's namespace mappings, credentials, capability
// drop and filter, and a routed space's loopback and name sockets, and
// passes where the host allows them.
func TestTheProbeProvesTheSpaceWhereTheHostAllowsIt(t *testing.T) {
	newKeeper(t)
	routedKeeper(t)
}

// A relay space runs in a user, network and IPC namespace of its own that
// maps only its pooled uid and gid, holds no capability in any set, and
// reaches nothing: the loopback is down and no other interface exists. Its
// uid, home, control channel and retirement are those of any spawn.
func TestARelaySpaceHasItsOwnNamespacesAndNoCapability(t *testing.T) {
	k := newKeeper(t).withMemory(t)
	keeperNet, err := os.Readlink("/proc/self/ns/net")
	if err != nil {
		t.Fatal(err)
	}
	keeperUser, err := os.Readlink("/proc/self/ns/user")
	if err != nil {
		t.Fatal(err)
	}
	keeperIPC, err := os.Readlink("/proc/self/ns/ipc")
	if err != nil {
		t.Fatal(err)
	}
	script := `awk '{print "uid_map:" $1 " " $2 " " $3}' /proc/self/uid_map
awk '{print "gid_map:" $1 " " $2 " " $3}' /proc/self/gid_map
echo "setgroups:$(cat /proc/self/setgroups)"
grep -E '^(Uid|Gid|Groups|CapInh|CapPrm|CapEff|CapBnd|CapAmb|NoNewPrivs):' /proc/self/status
echo "net:$(readlink /proc/self/ns/net)"
echo "user:$(readlink /proc/self/ns/user)"
echo "ipc:$(readlink /proc/self/ns/ipc)"
echo "interfaces:$(tail -n +3 /proc/net/dev | cut -d: -f1 | tr -d ' ' | tr '\n' ' ')"
echo "routes:$(tail -n +2 /proc/net/route | wc -l)"
if [ -e /proc/self/fd/3 ]; then echo fd3:open; fi
echo "fd4:$(readlink /proc/self/fd/4 | cut -c1-7)"
if [ -e /proc/self/fd/5 ]; then echo fd5:open; else echo fd5:closed; fi
"$TEST_BINARY" dial 127.0.0.1:1 10.0.0.1:80
echo done`
	_, uid, rc := k.spawn(t, "1", script, map[string]string{"TEST_BINARY": k.helper}, true)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "done\n") })
	stdout := string(rc.got[frame.StreamStdout])
	id := strconv.Itoa(uid)
	for _, want := range []string{
		"uid_map:" + id + " " + id + " 1", "gid_map:" + id + " " + id + " 1", "setgroups:deny",
		"Uid:\t" + id + "\t" + id + "\t" + id + "\t" + id, "Gid:\t" + id + "\t" + id + "\t" + id + "\t" + id,
		"CapInh:\t0000000000000000", "CapPrm:\t0000000000000000", "CapEff:\t0000000000000000",
		"CapBnd:\t0000000000000000", "CapAmb:\t0000000000000000", "NoNewPrivs:\t1",
		"interfaces:lo \n", "routes:0\n", "fd3:open", "fd4:socket:", "fd5:closed",
		"dial 127.0.0.1:1: dial tcp 127.0.0.1:1: connect: network is unreachable",
		"dial 10.0.0.1:80: dial tcp 10.0.0.1:80: connect: network is unreachable",
	} {
		if !strings.Contains(strings.Join(strings.Fields(stdout), " "), strings.Join(strings.Fields(want), " ")) {
			t.Errorf("the relay space lacks %q:\n%s", want, stdout)
		}
	}
	if !regexpMatch(`(?m)^Groups:\s*$`, stdout) {
		t.Errorf("the relay space has supplementary groups:\n%s", stdout)
	}
	for _, own := range []string{"net:" + keeperNet, "user:" + keeperUser, "ipc:" + keeperIPC} {
		if strings.Contains(stdout, own+"\n") {
			t.Errorf("the relay space shares the keeper's %s:\n%s", own, stdout)
		}
	}
	rc.readUntil(t, func() bool { return false })
	if exited := k.reply(t); exited["type"] != protocol.TypeExited || exited["code"] != float64(0) {
		t.Fatalf("exit: %v", exited)
	}
	if released := k.reply(t); released["type"] != protocol.TypeReleased {
		t.Fatalf("after exited: %v", released)
	}
	assertRetired(t, k, uid)

	// The pool lends every uid, the first one again last, each to a spawn
	// in a namespace of its own.
	for i, want := range []int{testPoolFirst + testPoolLast - uid, uid} {
		_, got, rc := k.spawn(t, strconv.Itoa(i+2), `readlink /proc/self/ns/net; echo done`, map[string]string{}, false)
		rc.readUntil(t, func() bool { return false })
		stdout := string(rc.got[frame.StreamStdout])
		if got != want || !strings.Contains(stdout, "done\n") || strings.Contains(stdout, keeperNet) {
			t.Fatalf("spawn of uid %d, want %d: %q", got, want, stdout)
		}
		k.reply(t)
		k.reply(t)
		assertRetired(t, k, got)
	}
}

// A relay space's relay, its fd 4, is carried on stream 5 once the client
// opens it, both ways.
func TestARelaySpacesRelayIsCarriedOnceOpened(t *testing.T) {
	k := newKeeper(t).withMemory(t)
	script := `printf 'call\n' >&4; IFS= read -r answer <&4; echo "got:$answer"`
	spawnID, uid, rc := k.spawn(t, "1", script, map[string]string{}, true)
	rc.send(t, frame.StreamRelay, nil)
	rc.readUntil(t, func() bool { return string(rc.got[frame.StreamRelay]) == "call\n" })
	rc.send(t, frame.StreamRelay, []byte("answer\n"))
	rc.readUntil(t, func() bool { return false })
	if got := string(rc.got[frame.StreamStdout]); got != "got:answer\n" || !rc.ended[frame.StreamRelay] {
		t.Fatalf("stdout %q, relay %q, ended %v", got, rc.got[frame.StreamRelay], rc.ended)
	}
	if exited := k.reply(t); exited["type"] != protocol.TypeExited || exited["code"] != float64(0) {
		t.Fatalf("exit: %v", exited)
	}
	if released := k.reply(t); released["spawn_id"] != spawnID {
		t.Fatalf("after exited: %v", released)
	}
	assertRetired(t, k, uid)
}

// A client that never opens stream 5 receives no frame on it, its end
// included, though the spawn wrote to its relay and exited.
func TestARelaySpacesRelayIsSilentUnopened(t *testing.T) {
	k := newKeeper(t).withMemory(t)
	spawnID, uid, rc := k.spawn(t, "1", `printf 'call\n' >&4; printf 'bye\n' >&3; echo done`, map[string]string{}, true)
	rc.readUntil(t, func() bool { return false })
	if _, sent := rc.got[frame.StreamRelay]; sent || rc.ended[frame.StreamRelay] {
		t.Fatalf("a frame on the unopened relay stream: %q ended %v", rc.got[frame.StreamRelay], rc.ended)
	}
	if string(rc.got[frame.StreamStdout]) != "done\n" || string(rc.got[frame.StreamControl]) != "bye\n" ||
		!rc.ended[frame.StreamStdout] || !rc.ended[frame.StreamStderr] || !rc.ended[frame.StreamControl] {
		t.Fatalf("streams: %q ended %v", rc.got, rc.ended)
	}
	if exited := k.reply(t); exited["type"] != protocol.TypeExited || exited["code"] != float64(0) {
		t.Fatalf("exit: %v", exited)
	}
	if released := k.reply(t); released["spawn_id"] != spawnID {
		t.Fatalf("after exited: %v", released)
	}
	assertRetired(t, k, uid)
}

// The keeper places a stage in its spawn's bounded group from the parent
// side before the spec releases it, so the command starts inside its
// bound, in its own namespace, where the group is its cgroup namespace's
// root.
func TestASpaceRunsInItsBoundedGroup(t *testing.T) {
	k := newKeeper(t).withMemory(t)
	keeperNet, err := os.Readlink("/proc/self/ns/net")
	if err != nil {
		t.Fatal(err)
	}
	_, uid, rc := k.spawnBounded(t, "1", `cat /proc/self/cgroup; readlink /proc/self/ns/net; echo done`, map[string]string{}, false, 64<<20)
	rc.readUntil(t, func() bool { return false })
	stdout := string(rc.got[frame.StreamStdout])
	if !strings.Contains(stdout, "0::/\n") || !strings.Contains(stdout, "done\n") || strings.Contains(stdout, keeperNet) {
		t.Fatalf("the bounded space of uid %d: %q", uid, stdout)
	}
	k.reply(t)
	k.reply(t)
	assertRetired(t, k, uid)
}

func regexpMatch(pattern, s string) bool { return regexp.MustCompile(pattern).MatchString(s) }

// openPty opens a pseudo-terminal of rows by cols in the test's own devpts:
// its master, as a spawn's terminal is handed up, and its slave.
func openPty(rows, cols uint16) (master, slave *os.File, err error) {
	mfd, err := unix.Open("/dev/ptmx", unix.O_RDWR|unix.O_NOCTTY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, nil, err
	}
	master = os.NewFile(uintptr(mfd), "pty-master")
	unlock := 0
	if _, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(mfd), unix.TIOCSPTLCK, uintptr(unsafe.Pointer(&unlock))); errno != 0 {
		master.Close()
		return nil, nil, errno
	}
	n, err := unix.IoctlGetUint32(mfd, unix.TIOCGPTN)
	if err != nil {
		master.Close()
		return nil, nil, err
	}
	sfd, err := unix.Open("/dev/pts/"+strconv.FormatUint(uint64(n), 10), unix.O_RDWR|unix.O_NOCTTY|unix.O_CLOEXEC, 0)
	if err != nil {
		master.Close()
		return nil, nil, err
	}
	if err := unix.IoctlSetWinsize(sfd, unix.TIOCSWINSZ, &unix.Winsize{Row: rows, Col: cols}); err != nil {
		master.Close()
		unix.Close(sfd)
		return nil, nil, err
	}
	return master, os.NewFile(uintptr(sfd), "pty-slave"), nil
}
