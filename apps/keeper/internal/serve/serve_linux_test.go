// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/keeper/internal/frame"
	"github.com/cyfr/keeper/internal/home"
	"github.com/cyfr/keeper/internal/logx"
	"github.com/cyfr/keeper/internal/pool"
	"github.com/cyfr/keeper/internal/procfs"
	"github.com/cyfr/keeper/internal/protocol"
	"github.com/cyfr/keeper/internal/relay"
	"github.com/cyfr/keeper/internal/residue"
	"github.com/cyfr/keeper/internal/retire"
	"github.com/cyfr/keeper/internal/stage"
)

// TestMain lets the test binary stand in for cyfr-keeper's helpers, which
// the spawner under test starts as `<self> stage`, `<self> relay` and
// `<self> retire`, dispatched as main.go dispatches them. `<self> hold` is
// the memory tests' command.
func TestMain(m *testing.M) {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "stage":
			os.Exit(stage.Main())
		case "relay":
			os.Exit(relay.Main())
		case "retire":
			os.Exit(retire.Main())
		case "hold":
			os.Exit(hold(os.Args[2:]))
		}
	}
	os.Exit(m.Run())
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

const (
	testPoolFirst = 39001
	testPoolLast  = 39002
	testToken     = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
)

// keeper is a server wired as `serve` wires it, without the client process:
// the test holds the client's end of the channel and the attach socket. It
// needs root, to run the stage under a pooled uid and the relay as `nobody`.
type keeper struct {
	s       *server
	channel *protocol.LineReader
	ln      net.Listener
	attach  string
	homes   string
	stop    chan struct{}
}

func newKeeper(t *testing.T) *keeper {
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

	base, err := os.MkdirTemp("", "cyfr-keeper-")
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
	// helpers, which go test keeps in a directory only root can enter.
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	binary := filepath.Join(base, "cyfr-keeper")
	data, err := os.ReadFile(self)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(binary, data, 0o755); err != nil {
		t.Fatal(err)
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

	spec := pool.Spec{Name: "runner", First: testPoolFirst, Last: testPoolLast}
	accounts := map[int]Account{}
	for uid := spec.First; uid <= spec.Last; uid++ {
		accounts[uid] = Account{UID: uid, GID: uid, Name: strconv.Itoa(uid)}
	}
	s := &server{
		cfg:      Config{Pools: []pool.Spec{spec}, HomeRoot: homes},
		log:      logx.NewWriter(os.Stderr, "cyfr-keeper", false),
		self:     binary,
		client:   Account{UID: 65534, GID: 65534, Name: "nobody", Home: "/"},
		accounts: accounts,
		roots:    residue.Roots{Dirs: []string{base}},
		pools:    map[string]*pool.Pool{spec.Name: pool.New(spec)},
		spawns:   map[string]*spawn{},
		waiters:  map[int]*child{},
		channel:  os.NewFile(uintptr(fds[0]), "channel"),
	}
	k := &keeper{s: s, channel: protocol.NewLineReader(theirs), ln: ln, attach: attach, homes: homes, stop: make(chan struct{})}

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
		s.channel.Close()
		signal.Stop(sigchld)
		close(k.stop)
	})
	return k
}

// reply reads the next line the spawner sent on the channel.
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
	return k.spawnBounded(t, id, script, env, control, 0)
}

// spawnRequest is the parsed request for a spawn of `/bin/sh -c script`,
// with a memory bound when memoryBytes is not zero.
func spawnRequest(t *testing.T, attach, id, script string, env map[string]string, control bool, memoryBytes uint64) *protocol.Request {
	t.Helper()
	message := map[string]any{
		"v": protocol.Version, "type": protocol.TypeSpawn, "id": id, "pool": "runner",
		"argv": []string{"/bin/sh", "-c", script}, "env": env, "control": control,
		"attach": map[string]string{"path": attach, "token": testToken},
	}
	if memoryBytes != 0 {
		message["memory_bytes"] = memoryBytes
	}
	line, err := json.Marshal(message)
	if err != nil {
		t.Fatal(err)
	}
	req, rerr := protocol.ParseRequest(line)
	if rerr != nil {
		t.Fatal(rerr)
	}
	return req
}

// spawnBounded is spawn with a memory bound, none when memoryBytes is zero.
func (k *keeper) spawnBounded(t *testing.T, id, script string, env map[string]string, control bool, memoryBytes uint64) (string, int, *relayConn) {
	t.Helper()
	k.s.handleSpawn(spawnRequest(t, k.attach, id, script, env, control, memoryBytes))

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

func (k *keeper) release(t *testing.T, spawnID string) {
	t.Helper()
	grace := int64(0)
	k.s.handleRelease(&protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: spawnID, GraceMs: &grace})
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

func TestRunnerLifecycleUnderAPooledUID(t *testing.T) {
	k := newKeeper(t)
	t.Setenv("SPAWN_TEST_CANARY", "leaked")

	// A runner: its control channel is fd 3, its environment is the
	// request's and nothing of the spawner's, and closing fd 3 ends the
	// control stream while the process lives.
	script := `if [ -e /proc/self/fd/3 ]; then echo fd3:open; else echo fd3:closed; fi
env
echo env:done
IFS= read -r line <&3
printf 'echo:%s\n' "$line" >&3
echo 'to stderr' >&2
exec 3>&-
sleep 60`
	spawnID, uid, rc := k.spawn(t, "1", script, map[string]string{"OPUS_ROLE": "runner"}, true)
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
	for _, want := range []string{"OPUS_ROLE=runner\n", "HOME=" + k.homes + "/" + strconv.Itoa(uid) + "-", "USER=" + strconv.Itoa(uid) + "\n"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("environment lacks %q:\n%s", want, stdout)
		}
	}
	if strings.Contains(stdout, "SPAWN_TEST_CANARY") {
		t.Fatalf("the spawner's environment reached the runner:\n%s", stdout)
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

	// Releasing it again names a spawn the spawner no longer holds.
	k.release(t, spawnID)
	if again := k.reply(t); again["type"] != protocol.TypeError || again["code"] != protocol.CodeUnknownSpawn || again["spawn_id"] != spawnID {
		t.Fatalf("second release: %v", again)
	}
}

func TestRunnerExitEndsItsControlStreamAndRetiresIt(t *testing.T) {
	k := newKeeper(t)
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
	k := newKeeper(t)
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
