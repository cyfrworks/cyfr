// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/sys/unix"

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
		log:     logx.NewWriter(os.Stderr, "cyfr-locus", false),
		pools:   map[string]*pool.Pool{},
		spawns:  map[string]*spawn{},
		places:  map[string]*place{},
		waiters: map[int]*child{},
		channel: ours,
	}
	done := make(chan struct{})
	go func() { s.serveChannel(); close(done) }()
	t.Cleanup(func() { theirs.Close(); <-done; ours.Close() })
	return &keeper{s: s, channel: protocol.NewLineReader(theirs)}, theirs
}

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
// that claimed it is held once it starts.
func (k *keeper) spawnedIn(t *testing.T, id string, sp *spawn) {
	t.Helper()
	if !k.s.claimPlace(id) {
		t.Fatalf("place %s cannot be claimed", id)
	}
	k.s.mu.Lock()
	sp.place = id
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
		`{"v":3,"type":"place","id":"p","kind":"warm"}`,
		`{"v":3,"type":"place","id":"p","kind":"run","athanor":"ath-1"}`)
	k.expect(t, protocol.NewPlaced("p"), protocol.NewError("p", "", protocol.CodeBadRequest))
}

// A spawn refused after it claimed its place frees it before the refusal is
// sent: the place sent at once before it was the spawn's to claim, and the
// client may place that id again.
func TestARefusedSpawnFreesItsPlace(t *testing.T) {
	k, client := placesKeeper(t)
	write(t, client,
		`{"v":3,"type":"place","id":"p","kind":"build"}`,
		`{"v":3,"type":"spawn","id":"s","place":"p","pool":"runner","argv":["true"],"memory_bytes":67108864,"cpu_quota":100000,"attach":{"path":"/run/a.sock","token":"`+testToken+`"}}`)
	// This keeper enforces no bound: the spawn is refused for that, not for
	// its place.
	k.expect(t, protocol.NewPlaced("p"), protocol.NewError("s", "", protocol.CodeMemoryUnavailable))
	write(t, client, `{"v":3,"type":"measure","id":"m","place":"p"}`)
	k.expect(t, protocol.NewError("m", "", protocol.CodeUnmeasured))
	write(t, client, `{"v":3,"type":"place","id":"p","kind":"build"}`)
	k.expect(t, protocol.NewPlaced("p"))
}

// A drop frees a place no spawn named, the place sent at once before it
// applied first; a drop or an assign of a place the keeper does not hold
// sends nothing and holds nothing.
func TestADroppedPlaceIsGoneAndAnUnknownOneIsLeftAlone(t *testing.T) {
	k, client := placesKeeper(t)
	write(t, client,
		`{"v":3,"type":"place","id":"p","kind":"warm"}`,
		`{"v":3,"type":"drop","place":"p"}`)
	k.expect(t, protocol.NewPlaced("p"))
	write(t, client,
		`{"v":3,"type":"drop","place":"q"}`,
		`{"v":3,"type":"assign","place":"q","kind":"run"}`,
		`{"v":3,"type":"place","id":"p","kind":"warm"}`,
		`{"v":3,"type":"place","id":"q","kind":"warm"}`)
	k.expect(t, protocol.NewPlaced("p"), protocol.NewPlaced("q"))
}

// Assigns sent at once apply in the order sent: the place is the last's,
// an athanor or a subject it does not name cleared. A drop of a place a
// spawn named leaves it, measured.
func TestAPlaceIsWhoseItsLastAssignSays(t *testing.T) {
	k, client := placesKeeper(t)
	clock := clockAt(t, time.Unix(1_800_000_000, 0))
	readsAs(t, func(*cgroup.Group) (cgroup.Use, error) { return cgroup.Use{Bytes: 3 << 20}, nil })
	write(t, client,
		`{"v":3,"type":"place","id":"p","kind":"warm"}`,
		`{"v":3,"type":"assign","place":"p","kind":"run","athanor":"ath-1","subject":"run-1"}`,
		`{"v":3,"type":"assign","place":"p","kind":"warm","athanor":"ath-2"}`)
	k.expect(t, protocol.NewPlaced("p"))
	k.spawnedIn(t, "p", &spawn{id: strings.Repeat("a", 32)})
	k.s.read()
	clock.advance(250 * time.Millisecond)
	write(t, client,
		`{"v":3,"type":"drop","place":"p"}`,
		`{"v":3,"type":"measure","id":"m","place":"p"}`)
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

	write(t, client, `{"v":3,"type":"place","id":"p","kind":"run","athanor":"ath-1"}`)
	k.expect(t, protocol.NewPlaced("p"))
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
	write(t, client, `{"v":3,"type":"measure","id":"m1","place":"p"}`)
	k.expect(t, protocol.NewMeasured("m1", whose, protocol.Reading{Bytes: 5 << 20}, 1500))
	write(t, client, `{"v":3,"type":"place","id":"q","kind":"warm"}`)
	k.expect(t, protocol.NewPlaced("q"))
	write(t, client, `{"v":3,"type":"pool","id":"after","pool":"runner"}`)
	k.expect(t, protocol.NewError("after", "", protocol.CodeUnknownPool))
	clock.advance(time.Second)
	write(t, client, `{"v":3,"type":"measure","id":"m2","place":"p"}`)
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
	write(t, client, `{"v":3,"type":"place","id":"p","kind":"run"}`)
	k.expect(t, protocol.NewPlaced("p"))
	gone := &spawn{id: strings.Repeat("a", 32)}
	k.spawnedIn(t, "p", gone)
	read := make(chan struct{})
	go func() { k.s.read(); close(read) }()
	t.Cleanup(func() { <-read })
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
	delete(k.s.places, gone.place)
	k.s.mu.Unlock()
	write(t, client, `{"v":3,"type":"place","id":"p","kind":"build"}`)
	k.expect(t, protocol.NewPlaced("p"))
	k.spawnedIn(t, "p", &spawn{id: strings.Repeat("b", 32)})
	release()
	<-read

	write(t, client, `{"v":3,"type":"measure","id":"m","place":"p"}`)
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
		k.s.handleSpawn(req)
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

// A place is measured from its spawn's readings as whose it is at the
// moment: an assign changes whose it is and not its reading, a drop leaves
// it, and neither the kill of the spawn's processes nor its leader's exit
// frees it before its `released`, here held back until after both.
func TestAPlaceIsMeasuredFromItsSpawnUntilItsRelease(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	path := filepath.Join(k.s.cfg.Kept.Root, "vlt_placed")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m1", path, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	k.s.handle(parsed(t, `{"v":3,"type":"place","id":"pl","kind":"program","athanor":"ath-1","subject":"mcp-1"}`))
	k.expect(t, protocol.NewPlaced("pl"))
	k.s.handleSpawn(keptRequest(t, k.attach, "pl", "exec "+k.s.self+" hold 4 60", path, uid, nil))
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

	// Neither is answered: the next reply is the measure's.
	k.s.handle(parsed(t, `{"v":3,"type":"assign","place":"pl","kind":"terminal","athanor":"ath-2"}`))
	k.s.handle(parsed(t, `{"v":3,"type":"drop","place":"pl"}`))
	whose = protocol.Whose{Kind: protocol.KindTerminal, Athanor: "ath-2"}
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
