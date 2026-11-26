// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/admission"
	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/frame"
	"github.com/cyfr/locus/keeper/internal/logx"
	"github.com/cyfr/locus/keeper/internal/pool"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// placesKeeper is a keeper with no pool, no bound and no process of its own
// whose channel is read as serve reads the client's, the test holding the
// client's end: it needs no root. Every reply is read within ten seconds.
func placesKeeper(t *testing.T) (*keeper, *os.File) {
	t.Helper()
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, fd := range fds {
		if err := unix.SetNonblock(fd, true); err != nil {
			t.Fatal(err)
		}
	}
	ours, theirs := os.NewFile(uintptr(fds[0]), "channel"), os.NewFile(uintptr(fds[1]), "client-channel")
	if err := theirs.SetReadDeadline(time.Now().Add(10 * time.Second)); err != nil {
		t.Fatal(err)
	}
	s := &server{
		log:       logx.NewWriter(os.Stderr, "cyfr-locus", false),
		pools:     map[string]*pool.Pool{},
		spawns:    map[string]*spawn{},
		unremoved: map[*spawn]*removal{},
		waiters:   map[int]*child{},
		ledger:    admission.New(testWork, true),
	}
	c := testClient(ours, pool.Spec{Name: "runner"}, Account{})
	done := make(chan struct{})
	go func() { s.serveChannel(c); close(done) }()
	t.Cleanup(func() { theirs.Close(); <-done; ours.Close() })
	return &keeper{s: s, c: c, channel: protocol.NewLineReader(theirs)}, theirs
}

// testWork is the pool's work in the keepers under test: room for every
// start they make, whose own tests hold admission.
const testWork = 64 << 30

// admittedPlace is a place of c's whose the admission has given room, as
// one answered `placed`.
func admittedPlace(s *server, c *client, whose protocol.Whose) *place {
	e := &admission.Entry{Role: c.role.spec.Name, Floor: c.role.spec.Floor, Kind: whose.Kind, Athanor: whose.Athanor, Subject: whose.Subject}
	s.mu.Lock()
	defer s.mu.Unlock()
	if ev := s.ledger.Place(e, now()); len(ev.Admitted) != 1 || ev.Admitted[0] != e {
		panic("the place found no room")
	}
	return &place{whose: whose, entry: e}
}

// placedOf is the `placed` of a place of the kind, with the bound the
// keeper sets its spawn to now.
func placedOf(id, kind string) protocol.Placed {
	return protocol.NewPlaced(id, limitsOf(kind, testWork).MemoryBytes)
}

// placedRunner is the `placed` of a runner's place.
func placedRunner(id string) protocol.Placed { return placedOf(id, protocol.KindRun) }

// write sends the lines in one write, as a client sends requests at once.
func write(t *testing.T, client *os.File, lines ...string) {
	t.Helper()
	if _, err := client.Write([]byte(strings.Join(lines, "\n") + "\n")); err != nil {
		t.Fatal(err)
	}
}

// expect reads the keeper's next lines and checks each is the reply wanted,
// whole.
func (k *keeper) expect(t *testing.T, want ...any) {
	t.Helper()
	for _, w := range want {
		line, tooLong, err := k.channel.Next()
		if err != nil || tooLong {
			t.Fatalf("reading the channel for %+v: %v (too long %t)", w, err, tooLong)
		}
		encoded, err := protocol.Encode(w)
		if err != nil {
			t.Fatal(err)
		}
		if got, want := string(line), strings.TrimSuffix(string(encoded), "\n"); got != want {
			t.Fatalf("the keeper answered %s, want %s", got, want)
		}
	}
}

// spawnedIn holds sp as the spawn started in the held place id, as a spawn
// that claimed it is made in it and held once it starts.
func (k *keeper) spawnedIn(t *testing.T, id string, sp *spawn) {
	t.Helper()
	if got, _ := k.s.claimPlace(k.c, &protocol.Request{Place: id}); got != claimed {
		t.Fatalf("place %s cannot be claimed", id)
	}
	sp.client = k.c
	k.s.madeIn(id, sp)
	k.s.mu.Lock()
	k.s.spawns[sp.id] = sp
	k.s.mu.Unlock()
}

// readsAs makes every read of a group the reader takes answer as read does.
func readsAs(t *testing.T, read func(*cgroup.Group) (cgroup.Use, error)) {
	before := readUse
	readUse = read
	t.Cleanup(func() { readUse = before })
}

// fakeClock is the keeper's clock while a test sets it.
type fakeClock struct {
	mu sync.Mutex
	at time.Time
}

func clockAt(t *testing.T, at time.Time) *fakeClock {
	c := &fakeClock{at: at}
	before := now
	now = c.now
	t.Cleanup(func() { now = before })
	return c
}

func (c *fakeClock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.at
}

func (c *fakeClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.at = c.at.Add(d)
}

// asMeasured is the reply m as a `measured`, which it must be with nothing
// beside it.
func asMeasured(t *testing.T, m map[string]any) protocol.Measured {
	t.Helper()
	line, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	var got protocol.Measured
	dec := json.NewDecoder(bytes.NewReader(line))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&got); err != nil || got.Type != protocol.TypeMeasured {
		t.Fatalf("answered %v, not a measured: %v", m, err)
	}
	return got
}

// A place of a new id is placed; a second place of that id is refused, the
// first held as it was.
func TestAPlaceIsPlacedAndItsIDAgainIsRefused(t *testing.T) {
	k, client := placesKeeper(t)
	write(t, client,
		`{"v":8,"type":"place","id":"p","kind":"warm"}`,
		`{"v":8,"type":"place","id":"p","kind":"run","athanor":"ath-1"}`)
	k.expect(t, placedRunner("p"), protocol.NewError("p", "", protocol.CodeBadRequest))
}

// A spawn refused after it claimed its place frees it before the refusal is
// sent: the place sent at once before it was the spawn's to claim, and the
// client may place that id again.
func TestARefusedSpawnFreesItsPlace(t *testing.T) {
	k, client := placesKeeper(t)
	write(t, client,
		`{"v":8,"type":"place","id":"p","kind":"run"}`,
		`{"v":8,"type":"spawn","id":"s","place":"p","pool":"runner","argv":["true"],"attach":{"path":"/run/a.sock","token":"`+testToken+`"}}`)
	// This keeper enforces no bound: the spawn is refused for that, not for
	// its place.
	k.expect(t, placedRunner("p"), protocol.NewError("s", "", protocol.CodeMemoryUnavailable))
	write(t, client, `{"v":8,"type":"measure","id":"m","place":"p"}`)
	k.expect(t, protocol.NewError("m", "", protocol.CodeUnmeasured))
	write(t, client, `{"v":8,"type":"place","id":"p","kind":"run"}`)
	k.expect(t, placedRunner("p"))
}

// A drop frees a place no spawn named, the place sent at once before it
// applied first; a drop of a place the keeper does not hold sends nothing
// and holds nothing, and an assign of one is refused under its own id and
// holds nothing.
func TestADroppedPlaceIsGoneAndAnUnknownOneIsLeftAlone(t *testing.T) {
	k, client := placesKeeper(t)
	write(t, client,
		`{"v":8,"type":"place","id":"p","kind":"warm"}`,
		`{"v":8,"type":"drop","place":"p"}`)
	k.expect(t, placedRunner("p"))
	write(t, client,
		`{"v":8,"type":"drop","place":"q"}`,
		`{"v":8,"type":"assign","id":"as","place":"q","kind":"run"}`,
		`{"v":8,"type":"place","id":"p","kind":"warm"}`,
		`{"v":8,"type":"place","id":"q","kind":"warm"}`)
	k.expect(t, protocol.NewError("as", "", protocol.CodeBadRequest), placedRunner("p"), placedRunner("q"))
}

// Assigns sent at once apply in the order sent, each answered under its own
// id: the place is the last's, an athanor or a subject it does not name
// cleared. A drop of a place a spawn named leaves it, measured.
func TestAPlaceIsWhoseItsLastAssignSays(t *testing.T) {
	k, client := placesKeeper(t)
	clock := clockAt(t, time.Unix(1_800_000_000, 0))
	readsAs(t, func(*cgroup.Group) (cgroup.Use, error) { return cgroup.Use{Bytes: 3 << 20}, nil })
	write(t, client,
		`{"v":8,"type":"place","id":"p","kind":"warm"}`,
		`{"v":8,"type":"assign","id":"as-1","place":"p","kind":"run","athanor":"ath-1","subject":"run-1"}`,
		`{"v":8,"type":"assign","id":"as-2","place":"p","kind":"warm","athanor":"ath-2"}`)
	k.expect(t, placedRunner("p"), protocol.NewAssigned("as-1"), protocol.NewAssigned("as-2"))
	k.spawnedIn(t, "p", &spawn{id: strings.Repeat("a", 32)})
	k.s.read()()
	clock.advance(250 * time.Millisecond)
	write(t, client,
		`{"v":8,"type":"drop","place":"p"}`,
		`{"v":8,"type":"measure","id":"m","place":"p"}`)
	k.expect(t, protocol.NewMeasured("m", protocol.Whose{Kind: protocol.KindWarm, Athanor: "ath-2"}, protocol.Reading{Bytes: 3 << 20}, 250))
}

// A read that does not end holds back no measure and no other request: a
// measure answers the last reading at once, older with every measure.
func TestASlowReadDelaysNoMeasureAndNoOtherRequest(t *testing.T) {
	k, client := placesKeeper(t)
	clock := clockAt(t, time.Unix(1_800_000_000, 0))
	blocked, gate := make(chan struct{}), make(chan struct{})
	var reads atomic.Int32
	readsAs(t, func(*cgroup.Group) (cgroup.Use, error) {
		switch reads.Add(1) {
		case 1:
			return cgroup.Use{Bytes: 5 << 20}, nil
		case 2:
			close(blocked)
		}
		<-gate
		return cgroup.Use{Bytes: 9 << 20}, nil
	})
	every := readEvery
	readEvery = time.Millisecond
	t.Cleanup(func() { readEvery = every })

	write(t, client, `{"v":8,"type":"place","id":"p","kind":"run","athanor":"ath-1"}`)
	k.expect(t, placedRunner("p"))
	k.spawnedIn(t, "p", &spawn{id: strings.Repeat("a", 32)})
	stop, stopped := make(chan struct{}), make(chan struct{})
	go func() { k.s.reader(stop); close(stopped) }()
	t.Cleanup(func() { close(stop); <-stopped })
	t.Cleanup(func() { close(gate) })
	select {
	case <-blocked:
	case <-time.After(10 * time.Second):
		t.Fatal("the reader never read a second time")
	}

	// The first reading was stored before the second read began.
	whose := protocol.Whose{Kind: protocol.KindRun, Athanor: "ath-1"}
	clock.advance(1500 * time.Millisecond)
	write(t, client, `{"v":8,"type":"measure","id":"m1","place":"p"}`)
	k.expect(t, protocol.NewMeasured("m1", whose, protocol.Reading{Bytes: 5 << 20}, 1500))
	write(t, client, `{"v":8,"type":"place","id":"q","kind":"warm"}`)
	k.expect(t, placedRunner("q"))
	write(t, client, `{"v":8,"type":"pool","id":"after","pool":"runner"}`)
	k.expect(t, protocol.NewError("after", "", protocol.CodeUnknownPool))
	clock.advance(time.Second)
	write(t, client, `{"v":8,"type":"measure","id":"m2","place":"p"}`)
	k.expect(t, protocol.NewMeasured("m2", whose, protocol.Reading{Bytes: 5 << 20}, 2500))
}

// A reading of a spawn that left while its group was read is not stored:
// the place of that id, placed again for another spawn, has none.
func TestAReadingOfASpawnGoneIsNotStored(t *testing.T) {
	k, client := placesKeeper(t)
	blocked, gate := make(chan struct{}), make(chan struct{})
	readsAs(t, func(*cgroup.Group) (cgroup.Use, error) {
		close(blocked)
		<-gate
		return cgroup.Use{Bytes: 5 << 20}, nil
	})
	write(t, client, `{"v":8,"type":"place","id":"p","kind":"run"}`)
	k.expect(t, placedRunner("p"))
	gone := &spawn{id: strings.Repeat("a", 32)}
	k.spawnedIn(t, "p", gone)
	read := k.s.read()
	t.Cleanup(read)
	release := sync.OnceFunc(func() { close(gate) })
	t.Cleanup(release)
	select {
	case <-blocked:
	case <-time.After(10 * time.Second):
		t.Fatal("the read never began")
	}

	// The spawn leaves as its retirement's last step has it leave, with its
	// place, and the place's id is placed again for another.
	k.s.mu.Lock()
	delete(k.s.spawns, gone.id)
	delete(k.c.places, gone.place)
	k.s.mu.Unlock()
	write(t, client, `{"v":8,"type":"place","id":"p","kind":"run"}`)
	k.expect(t, placedRunner("p"))
	k.spawnedIn(t, "p", &spawn{id: strings.Repeat("b", 32)})
	release()
	read()

	write(t, client, `{"v":8,"type":"measure","id":"m","place":"p"}`)
	k.expect(t, protocol.NewError("m", "", protocol.CodeUnmeasured))
}

// A spawn naming a place the keeper does not hold, or one another spawn
// named, is refused before anything of it starts, and the place another
// spawn named stays that spawn's until its release.
func TestASpawnNamingAPlaceNotHeldOrNamedIsRefusedAndStartsNothing(t *testing.T) {
	k := boundedKeeper(t)
	spawnID, uid, _ := k.spawn(t, "a", "exec sleep 60", map[string]string{}, false)
	k.measuredAtLeast(t, "a", 1)
	for _, c := range []struct{ id, place string }{{"b", "absent"}, {"c", "a"}} {
		req := spawnRequest(t, k.attach, c.id, "exec sleep 60", map[string]string{}, false, 64<<20)
		req.Place = c.place
		k.s.handleSpawn(k.c, req)
		k.expect(t, protocol.NewError(c.id, "", protocol.CodeBadRequest))
	}
	k.s.mu.Lock()
	st := k.s.pools["runner"].Stats()
	held := len(k.s.spawns)
	k.s.mu.Unlock()
	if st.Free != st.Size-1 || st.Quarantined != 0 || held != 1 {
		t.Fatalf("after the refusals: pool %+v, %d spawns held; want the first spawn's uid alone taken", st, held)
	}
	k.measuredAtLeast(t, "a", 1)

	k.release(t, spawnID)
	k.replies(t, spawnID)
	if m := k.measure(t, "a"); m["type"] != protocol.TypeError || m["code"] != protocol.CodeUnmeasured {
		t.Fatalf("a released spawn's place was measured %v", m)
	}
	assertRetired(t, k, uid)
}

// A place is measured from its spawn's readings as whose it is: a refused
// assign changes nothing of it, a drop leaves it, and neither the kill of the spawn's processes nor its leader's exit
// frees it before its `released`, here held back until after both.
func TestAPlaceIsMeasuredFromItsSpawnUntilItsRelease(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	path := filepath.Join(k.s.cfg.Kept.Root, "vlt_placed")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m1", path, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	k.s.handle(k.c, parsed(t, `{"v":8,"type":"place","id":"pl","kind":"program","athanor":"ath-1","subject":"mcp-1"}`))
	k.expect(t, placedOf("pl", protocol.KindProgram))
	k.s.handleSpawn(k.c, keptRequest(t, k.attach, "pl", "exec "+k.helper+" hold 4 60", path, nil))
	spawned := k.reply(t)
	if spawned["type"] != protocol.TypeSpawned {
		t.Fatalf("spawn: %v", spawned)
	}
	spawnID := spawned["spawn_id"].(string)
	rc := k.accept(t)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "held\n") })

	first := asMeasured(t, k.measuredAtLeast(t, "pl", 4<<20))
	whose := protocol.Whose{Kind: protocol.KindProgram, Athanor: "ath-1", Subject: "mcp-1"}
	if want := protocol.NewMeasured("measure-pl", whose, first.Reading, first.AgeMs); first != want {
		t.Fatalf("measured %+v, want %+v", first, want)
	}

	// A session's role assigns nothing, and the drop of a named place is not
	// answered: the next reply after the assign's refusal is the measure's,
	// whose the place was.
	k.s.handle(k.c, parsed(t, `{"v":8,"type":"assign","id":"as","place":"pl","kind":"terminal","athanor":"ath-2"}`))
	k.expect(t, protocol.NewError("as", "", protocol.CodeBadRequest))
	k.s.handle(k.c, parsed(t, `{"v":8,"type":"drop","place":"pl"}`))
	sameReading := func(when string) {
		t.Helper()
		got := asMeasured(t, k.measure(t, "pl"))
		if want := protocol.NewMeasured("measure-pl", whose, first.Reading, got.AgeMs); got != want || got.AgeMs < first.AgeMs {
			t.Fatalf("%s: measured %+v, want %+v aged at least %d ms", when, got, want, first.AgeMs)
		}
	}
	sameReading("after an assign and a drop")

	// The uid's lock holds its retirement back before its last step, after
	// its processes are killed and its leader's exit is reported.
	lock := k.s.keptLock(uid)
	lock.Lock()
	unlock := sync.OnceFunc(lock.Unlock)
	t.Cleanup(unlock)
	k.release(t, spawnID)
	if exited := k.reply(t); exited["type"] != protocol.TypeExited || exited["spawn_id"] != spawnID {
		t.Fatalf("after the release: %v", exited)
	}
	sameReading("after its exit, before its release")
	unlock()
	if released := k.reply(t); released["type"] != protocol.TypeReleased || released["spawn_id"] != spawnID {
		t.Fatalf("after its exit: %v", released)
	}
	if m := k.measure(t, "pl"); m["type"] != protocol.TypeError || m["code"] != protocol.CodeUnmeasured {
		t.Fatalf("a released spawn's place was measured %v", m)
	}
}

// One group's read that does not return delays no other's: every pass reads
// each spawn's group on its own, the held group is not read again while its
// read is out, and the other's reading advances pass after pass.
func TestAHeldReadDelaysNoOtherSpawnsReading(t *testing.T) {
	k, client := placesKeeper(t)
	held, other := &cgroup.Group{}, &cgroup.Group{}
	began, gate := make(chan struct{}), make(chan struct{})
	var heldReads, otherReads atomic.Int32
	readsAs(t, func(g *cgroup.Group) (cgroup.Use, error) {
		if g == held {
			if heldReads.Add(1) == 1 {
				close(began)
			}
			<-gate
			return cgroup.Use{Bytes: 64 << 20}, nil
		}
		return cgroup.Use{Bytes: uint64(otherReads.Add(1)) << 20}, nil
	})
	every := readEvery
	readEvery = time.Millisecond
	t.Cleanup(func() { readEvery = every })

	write(t, client,
		`{"v":8,"type":"place","id":"p","kind":"run"}`,
		`{"v":8,"type":"place","id":"q","kind":"run"}`)
	k.expect(t, placedRunner("p"), placedRunner("q"))
	k.spawnedIn(t, "p", &spawn{id: strings.Repeat("a", 32), group: held})
	k.spawnedIn(t, "q", &spawn{id: strings.Repeat("b", 32), group: other})
	stop, stopped := make(chan struct{}), make(chan struct{})
	go func() { k.s.reader(stop); close(stopped) }()
	t.Cleanup(func() { close(stop); <-stopped })
	t.Cleanup(func() { close(gate) })
	select {
	case <-began:
	case <-time.After(5 * time.Second):
		t.Fatal("the held group was never read")
	}

	// The channel is read within ten seconds of the keeper's making.
	for deadline := time.Now().Add(3 * time.Second); ; time.Sleep(5 * time.Millisecond) {
		m := k.measure(t, "q")
		if bytes, ok := m["bytes"].(float64); ok && bytes >= 3<<20 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("while one group's read was held the other place answered %v; its reading never advanced to 3 MiB", m)
		}
	}
	if m := k.measure(t, "p"); m["type"] != protocol.TypeError || m["code"] != protocol.CodeUnmeasured {
		t.Fatalf("the place whose read is held answered %v; want it unmeasured", m)
	}
	if n := heldReads.Load(); n != 1 {
		t.Fatalf("the held group was read %d times; want once, its read still out", n)
	}
}

// A read of a group the kernel serves ends, with an error once the group is
// removed, wherever the removal falls: memory.stat opened before it reads an
// error from the kernel, and a read begun after it finds no group. The
// reader's pass over a spawn whose group went ends so and stores nothing.
func TestAReadOfARemovedGroupEndsWithAnError(t *testing.T) {
	k := boundedKeeper(t)
	group, err := k.c.role.groups.Create(cgroup.SpawnName(randomHex(16)), 64<<20, cgroup.CPUPeriod)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = group.Remove() })
	// The tmpfs pages stay charged to the group once their writer has
	// exited, so the group reads as in use until it is removed.
	file, err := os.CreateTemp("/dev/shm", "cyfr-read-")
	if err != nil {
		t.Fatal(err)
	}
	_ = file.Close()
	t.Cleanup(func() { _ = os.Remove(file.Name()) })
	writer, dir := k.runIn(t, group, "head -c 4194304 /dev/zero > "+file.Name())
	k.awaitExit(t, writer)
	if used, err := group.Used(); err != nil || used.Bytes < 4<<20 {
		t.Fatalf("the group before its removal read %+v, %v; want at least 4 MiB", used, err)
	}
	stat, err := os.Open(filepath.Join(dir, "memory.stat"))
	if err != nil {
		t.Fatal(err)
	}
	defer stat.Close()
	if placed := k.place(t, "p", k.kind()); placed["type"] != protocol.TypePlaced {
		t.Fatalf("place answered %v", placed)
	}
	sp := &spawn{id: randomHex(16), group: group}
	k.spawnedIn(t, "p", sp)
	// It leaves as a retirement's last step has it leave, before the
	// keeper's cleanup, which retires every spawn held, finds it.
	t.Cleanup(func() {
		k.s.mu.Lock()
		delete(k.s.spawns, sp.id)
		delete(k.c.places, sp.place)
		k.s.mu.Unlock()
	})
	if err := group.Remove(); err != nil {
		t.Fatal(err)
	}

	ends := func(what string, read func() error) {
		t.Helper()
		ended := make(chan error, 1)
		go func() { ended <- read() }()
		select {
		case err := <-ended:
			if err == nil {
				t.Fatalf("%s read no error", what)
			}
			t.Logf("%s: %v", what, err)
		case <-time.After(10 * time.Second):
			t.Fatalf("%s did not return within 10 s", what)
		}
	}
	ends("a read of memory.stat opened before its group's removal", func() error {
		_, err := io.ReadAll(stat)
		return err
	})
	ends("Used of a removed group", func() error {
		_, err := group.Used()
		return err
	})
	passed := make(chan struct{})
	go func() { k.s.read()(); close(passed) }()
	select {
	case <-passed:
	case <-time.After(10 * time.Second):
		t.Fatal("the reader's pass over a spawn whose group was removed did not end within 10 s")
	}
	if m := k.measure(t, "p"); m["type"] != protocol.TypeError || m["code"] != protocol.CodeUnmeasured {
		t.Fatalf("the place of a spawn whose group was removed answered %v; want it unmeasured", m)
	}
}

// removalRefused makes every removal of a group fail busy, as one a process
// still holds fails, until the function it answers is called.
// leaveOwned writes a file at path owned by uid, as something the uid
// left behind.
func leaveOwned(t *testing.T, path string, uid int) {
	t.Helper()
	if err := os.WriteFile(path, []byte("x\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chown(path, uid, uid); err != nil {
		t.Fatal(err)
	}
}

func removalRefused(t *testing.T) (allow func()) {
	var refused atomic.Bool
	refused.Store(true)
	before := removeGroup
	removeGroup = func(g *cgroup.Group) error {
		if refused.Load() {
			return unix.EBUSY
		}
		return before(g)
	}
	t.Cleanup(func() { removeGroup = before })
	return func() { refused.Store(false) }
}

// A retired spawn whose group cannot be removed is not released: its place
// stays, measured from the group, which still holds tmpfs pages here, and
// its pooled uid goes to no other spawn, until the reader's retry removes
// the group, which frees the place and the uid and sends the `released`.
func TestASpawnWhoseGroupStaysKeepsItsPlaceUntilARetryRemovesIt(t *testing.T) {
	for _, kept := range []bool{false, true} {
		t.Run(fmt.Sprintf("kept %t", kept), func(t *testing.T) {
			var k *keeper
			var spawnID, group string
			var uid int
			if kept {
				k = keptKeeper(t)
				uid = testKeptFirst
				path := filepath.Join(k.s.cfg.Kept.Root, "vlt_unremoved")
				if made := k.homeRequest(t, protocol.TypeHomeMake, "m", path, uid); made["type"] != protocol.TypeHomeMade {
					t.Fatalf("home_make: %v", made)
				}
				spawnID, _ = k.spawnKept(t, "a", "exec sleep 60", path, uid)
				group = cgroup.SpawnName(spawnID)
			} else {
				k = boundedKeeper(t)
				spawnID, uid, _ = k.spawn(t, "a", "exec sleep 60", map[string]string{}, false)
				group = cgroup.Name(uid)
			}
			k.s.mu.Lock()
			sp := k.s.spawns[spawnID]
			k.s.mu.Unlock()
			// Pages of a tmpfs file stay charged to the group that wrote
			// them once their writer has exited, and no retirement of the
			// spawn removes a file of root's.
			file, err := os.CreateTemp("/dev/shm", "cyfr-held-")
			if err != nil {
				t.Fatal(err)
			}
			_ = file.Close()
			t.Cleanup(func() { _ = os.Remove(file.Name()) })
			writer, _ := k.runIn(t, sp.group, "head -c 4194304 /dev/zero > "+file.Name())
			k.awaitExit(t, writer)
			allow := removalRefused(t)
			k.release(t, spawnID)
			awaitRetired(t, sp)

			if told := k.toldSoFar(t); len(told) != 1 || told[0]["type"] != protocol.TypeExited {
				t.Fatalf("a spawn whose group stays was told %v; want its exit and no release", told)
			}
			k.measuredAtLeast(t, "a", 4<<20)
			if again := k.place(t, "a", k.kind()); again["type"] != protocol.TypeError || again["code"] != protocol.CodeBadRequest {
				t.Fatalf("a place of its id answered %v; want it refused, the place still held", again)
			}
			k.s.mu.Lock()
			st := k.s.pools["runner"].Stats()
			k.s.mu.Unlock()
			if !kept && (st.Free != st.Size-1 || st.Quarantined != 0) {
				t.Fatalf("pool %+v while the group stays; want its uid lent to no other spawn", st)
			}
			// The spawn is still held: a release of it waits for the
			// retirement's own `released`, and nothing answers it now.
			k.release(t, spawnID)
			k.s.retryRemovals()()
			if told := k.toldSoFar(t); len(told) != 0 {
				t.Fatalf("a release, then a retry that failed, told %v; want nothing", told)
			}

			allow()
			k.s.retryRemovals()()
			if released := k.reply(t); released["type"] != protocol.TypeReleased || released["spawn_id"] != spawnID {
				t.Fatalf("the retry that removed the group told %v; want the spawn's release", released)
			}
			if m := k.measure(t, "a"); m["type"] != protocol.TypeError || m["code"] != protocol.CodeUnmeasured {
				t.Fatalf("a released spawn's place was measured %v", m)
			}
			if _, err := os.Stat(filepath.Join(k.c.role.groups.Dir(), group)); err == nil {
				t.Fatalf("group %s outlived the retry that removed it", group)
			}
			if !kept {
				assertRetired(t, k, uid)
			}
		})
	}
}

// wire is reply as the client reads it.
func wire(t *testing.T, reply any) map[string]any {
	t.Helper()
	line, err := json.Marshal(reply)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(line, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

// refusedMade reads, whole, the refusal of the spawn request id asked for,
// refused once the keeper made it: under that id and the spawn id the keeper
// gave it, which it answers.
func (k *keeper) refusedMade(t *testing.T, id, code string) string {
	t.Helper()
	refused := k.reply(t)
	spawnID, _ := refused["spawn_id"].(string)
	if spawnID == "" || !reflect.DeepEqual(refused, wire(t, protocol.NewError(id, spawnID, code))) {
		t.Fatalf("spawn %s answered %v; want its refusal %s under its id and the spawn id the keeper gave it", id, refused, code)
	}
	return spawnID
}

// A spawn refused once the keeper made it is refused under its spawn id and
// later released under it, once its retirement removed its group: while the
// group stays its place is held and nothing more of it is told, after the
// retirement ended too, and the retry that removes the group frees the place
// and sends its one `released`, with no `exited` before it. A spawn refused
// before the keeper made anything of it is refused under its id alone, its
// place freed at once, and is told nothing more.
func TestARefusedLaunchIsReleasedOnceItsGroupIsRemoved(t *testing.T) {
	for _, kept := range []bool{false, true} {
		t.Run(fmt.Sprintf("kept %t", kept), func(t *testing.T) {
			var k *keeper
			var req *protocol.Request
			if kept {
				k = keptKeeper(t)
				path := filepath.Join(k.s.cfg.Kept.Root, "vlt_refused")
				if made := k.homeRequest(t, protocol.TypeHomeMake, "m", path, testKeptFirst); made["type"] != protocol.TypeHomeMade {
					t.Fatalf("home_make: %v", made)
				}
				req = keptRequest(t, k.attach, "r", "true", path, nil)
			} else {
				k = boundedKeeper(t)
				req = spawnRequest(t, k.attach, "r", "true", map[string]string{}, false, 64<<20)
			}
			allow := removalRefused(t)
			req.Argv = []string{"/nonexistent/cyfr-command"}
			k.handleSpawn(t, req)
			spawnID := k.refusedMade(t, "r", protocol.CodeExecFailed)
			k.s.mu.Lock()
			var made *spawn
			if p := k.c.places["r"]; p != nil {
				made = p.spawn
			}
			k.s.mu.Unlock()
			if made == nil || made.id != spawnID {
				t.Fatalf("the refused spawn's place names %+v; want the spawn %s made in it", made, spawnID)
			}

			early := spawnRequest(t, k.attach, "e", "true", map[string]string{}, false, 64<<20)
			early.Pool = "absent"
			k.handleSpawn(t, early)
			k.expect(t, protocol.NewError("e", "", protocol.CodeUnknownPool))
			if again := k.place(t, "e", k.kind()); again["type"] != protocol.TypePlaced {
				t.Fatalf("a place of the early refusal's id answered %v; want it placed, the place freed at once", again)
			}

			awaitRetired(t, made)
			if told := k.toldSoFar(t); len(told) != 0 {
				t.Fatalf("while the refused spawn's group stays the keeper told %v; want nothing", told)
			}
			if again := k.place(t, "r", k.kind()); again["type"] != protocol.TypeError || again["code"] != protocol.CodeBadRequest {
				t.Fatalf("a place of the refused spawn's id answered %v once its retirement left the group; want it refused, the place still held", again)
			}

			allow()
			k.s.retryRemovals()()
			if told := k.toldSoFar(t); !reflect.DeepEqual(told, []map[string]any{wire(t, protocol.NewReleased(spawnID))}) {
				t.Fatalf("the retry that removed the refused spawn's group told %v; want its one release", told)
			}
			if again := k.place(t, "r", k.kind()); again["type"] != protocol.TypePlaced {
				t.Fatalf("a place of the refused spawn's id answered %v once it was released; want it placed", again)
			}
			if !kept {
				assertRetired(t, k, testPoolFirst)
			}
		})
	}
}

// A pooled uid quarantined while its group stays goes back to its pool only
// once the group is gone: a sweep that finds the uid clean leaves it
// quarantined until the retry removed the group, and the next returns it.
func TestAQuarantinedUIDWhoseGroupStaysIsNotReturnedBySweep(t *testing.T) {
	k := boundedKeeper(t)
	pinned := filepath.Join(k.s.roots.Dirs[0], "pinned")
	if err := os.Mkdir(pinned, 0o777); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(pinned, 0o777); err != nil {
		t.Fatal(err)
	}
	spawnID, uid, rc := k.spawn(t, "left", `echo started; sleep 600`, map[string]string{}, false)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "started\n") })
	// A space sees no writable place outside its home: the test leaves the
	// uid's entry there itself.
	leaveOwned(t, filepath.Join(pinned, "left"), uid)
	// The uid can no longer remove what it left there.
	if err := os.Chmod(pinned, 0o555); err != nil {
		t.Fatal(err)
	}
	k.s.mu.Lock()
	sp := k.s.spawns[spawnID]
	k.s.mu.Unlock()
	allow := removalRefused(t)
	k.release(t, spawnID)
	awaitRetired(t, sp)

	if err := os.Chmod(pinned, 0o777); err != nil {
		t.Fatal(err)
	}
	k.s.sweep()
	k.s.mu.Lock()
	st := k.s.pools["runner"].Stats()
	k.s.mu.Unlock()
	if st.Free != st.Size-1 || st.Quarantined != 1 {
		t.Fatalf("pool %+v after a sweep found uid %d clean with its group still there; want it quarantined", st, uid)
	}
	if told := k.toldSoFar(t); len(told) != 1 || told[0]["type"] != protocol.TypeExited {
		t.Fatalf("a spawn whose group stays was told %v; want its exit and no release", told)
	}

	allow()
	k.s.retryRemovals()()
	if released := k.reply(t); released["type"] != protocol.TypeReleased || released["spawn_id"] != spawnID {
		t.Fatalf("the retry that removed the group told %v; want the spawn's release", released)
	}
	k.s.sweep()
	assertRetired(t, k, uid)
}
