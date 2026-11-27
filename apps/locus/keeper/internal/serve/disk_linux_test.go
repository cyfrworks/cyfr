// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/internal/frame"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/procfs"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// homeAnswer reads replies until the one answering the home request id,
// passing over the `exited` and `released` of the sessions it ended, each
// of which must be one of ended's.
func (k *keeper) homeAnswer(t *testing.T, id string, ended ...string) map[string]any {
	t.Helper()
	for {
		m := k.reply(t)
		if m["id"] == id {
			return m
		}
		if sid, _ := m["spawn_id"].(string); (m["type"] != protocol.TypeExited && m["type"] != protocol.TypeReleased) || !slices.Contains(ended, sid) {
			t.Fatalf("waiting for %s's answer: %v", id, m)
		}
	}
}

// retireOf sends a home_reset or home_retire of the kept home id and
// answers its reply.
func (k *keeper) retireOf(t *testing.T, typ, reqID, id string, ended ...string) map[string]any {
	t.Helper()
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: typ, ID: reqID, Home: id})
	return k.homeAnswer(t, reqID, ended...)
}

// The vectors' home_elsewhere: a home made on one athanor's disk is
// refused to another's, and nothing changes: its folder, its record and
// the other athanor's having no disk.
func TestAHomeOnOneDiskIsRefusedToAnother(t *testing.T) {
	var v struct {
		HomeElsewhere struct{ Made, Again, Reply json.RawMessage } `json:"home_elsewhere"`
	}
	data, err := os.ReadFile("../../../../../tests/fixtures/keeper_protocol.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	k := keptKeeper(t)
	made, rerr := protocol.ParseRequest(v.HomeElsewhere.Made)
	if rerr != nil {
		t.Fatal(rerr.Detail)
	}
	again, rerr := protocol.ParseRequest(v.HomeElsewhere.Again)
	if rerr != nil {
		t.Fatal(rerr.Detail)
	}
	k.s.handle(k.c, made)
	if m := k.reply(t); m["type"] != protocol.TypeHomeMade || m["uid"] != float64(testKeptFirst) {
		t.Fatalf("the first make: %v", m)
	}
	k.s.handle(k.c, again)
	var want map[string]any
	_ = json.Unmarshal(v.HomeElsewhere.Reply, &want)
	if m := k.reply(t); !reflect.DeepEqual(m, want) {
		t.Fatalf("the make for another athanor answered %v, want %v", m, want)
	}
	if err := home.CheckKeptHome(k.s.cfg.Kept.HomePath(made.Athanor, made.Home), testKeptFirst); err != nil {
		t.Fatalf("the home on its own disk: %v", err)
	}
	if _, err := os.Lstat(k.s.cfg.Kept.DiskPath(again.Athanor)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the other athanor's disk: %v", err)
	}
	disks, err := k.s.cfg.Kept.LoadDisks()
	if err != nil || len(disks) != 1 || !reflect.DeepEqual(disks[made.Athanor].Homes, []string{made.Home}) {
		t.Fatalf("the records: %+v %v", disks, err)
	}
}

// A kept spawn is live from the step that finds its uid not retiring,
// before its home's measure: held at that measure, under the uid's lock,
// it keeps the uid from retiring when the person's last other session
// ends, so no scrub of the person runs to end it as it starts; let go, it
// runs on.
func TestASpawnHeldAtItsMeasureHoldsThePersonsScrubOff(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	k.share("ath_held", "vlt_a", "vlt_b")
	a, b := k.keptPath("vlt_a"), k.keptPath("vlt_b")
	for i, path := range []string{a, b} {
		if made := k.homeRequest(t, protocol.TypeHomeMake, "m"+string(rune('a'+i)), path, uid); made["type"] != protocol.TypeHomeMade {
			t.Fatalf("home_make: %v", made)
		}
	}
	other, rc := k.spawnKept(t, "b1", `echo ready; sleep 600`, b, uid)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "ready\n") })

	at, gate := make(chan struct{}), make(chan struct{})
	var reached, opened sync.Once
	open := func() { opened.Do(func() { close(gate) }) }
	t.Cleanup(open)
	k.s.measuring = func(path string) {
		if path == a {
			reached.Do(func() { close(at) })
			<-gate
		}
	}
	if placed := k.placeOf(t, "a1", k.kind(), "ath_held"); placed["type"] != protocol.TypePlaced {
		t.Fatalf("place: %v", placed)
	}
	bound := uint64(1 << 40)
	go k.s.handleSpawn(k.c, keptRequest(t, k.attach, "a1", `echo after; sleep 600`, a, &bound))
	select {
	case <-at:
	case <-time.After(10 * time.Second):
		t.Fatal("the spawn never reached its home's measure")
	}
	// The person's last other session ends while the spawn is held.
	k.release(t, other)
	k.s.mu.Lock()
	retiring, live := k.s.keptRetiring[uid], k.s.keptLive[uid]
	k.s.mu.Unlock()
	open()
	if retiring != nil || live != 1 {
		t.Fatalf("with a session of the person starting, its uid is retiring %t with %d live: a scrub would end it", retiring != nil, live)
	}
	var spawned string
	released := false
	for spawned == "" || !released {
		m := k.reply(t)
		switch {
		case m["id"] == "a1" && m["type"] == protocol.TypeSpawned:
			spawned = m["spawn_id"].(string)
		case m["spawn_id"] == other && m["type"] == protocol.TypeReleased:
			released = true
		case m["spawn_id"] == other && m["type"] == protocol.TypeExited:
		default:
			t.Fatalf("waiting for the held spawn and the other's end: %v", m)
		}
	}
	rcA := k.accept(t)
	rcA.readUntil(t, func() bool { return strings.Contains(string(rcA.got[frame.StreamStdout]), "after\n") })
	if got := pidsOf(t, uid, "sleep"); len(got) != 1 {
		t.Fatalf("the held spawn's sleep after the other's end: %v", got)
	}
	k.release(t, spawned)
	k.releasedPair(t, spawned)
}

// A kept-homes root wherever its operator puts it, here under /opt, which
// the container's directories bind into every space, shows a space nothing
// of the volume but the path to its own home: the stage covers the root.
// The person's other program finds its sibling's sign-in absent, the root
// holds its own disk alone and no record, and a pooled spawn finds the root
// empty.
func TestAKeptRootAnywhereShowsASpaceItsOwnHomeAlone(t *testing.T) {
	k := routedKeeper(t)
	if err := os.MkdirAll("/opt", 0o755); err != nil {
		t.Fatal(err)
	}
	base, err := os.MkdirTemp("/opt", "cyfr-kept-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(base) })
	if err := os.Chmod(base, 0o755); err != nil {
		t.Fatal(err)
	}
	k.keepHomesAt(t, filepath.Join(base, "kept"))
	root := k.s.cfg.Kept.Root
	uid := testKeptFirst
	k.share("ath_opt", "vlt_one", "vlt_two")
	one, two := k.keptPath("vlt_one"), k.keptPath("vlt_two")
	disk := filepath.Base(filepath.Dir(filepath.Dir(one)))
	for i, path := range []string{one, two} {
		if made := k.homeRequest(t, protocol.TypeHomeMake, "m"+string(rune('a'+i)), path, uid); made["type"] != protocol.TypeHomeMade {
			t.Fatalf("home_make %s: %v", path, made)
		}
	}
	_, rcA := k.spawnKept(t, "a", `echo one-secret > "$HOME/signin" && echo written; sleep 600`, one, uid)
	rcA.readUntil(t, func() bool { return strings.Contains(string(rcA.got[frame.StreamStdout]), "written\n") })
	look := `cat "` + one + `/signin" 2>/dev/null || echo unread; echo "root:$(ls -A ` + root + ` | tr '\n' ' ')"; ` +
		`echo "disk:$(ls -A ` + root + `/` + disk + ` 2>/dev/null | tr '\n' ' ')"; echo "records:$(ls -A ` + root + `/.disks 2>&1 | grep -c 'No such')"; echo done; sleep 600`
	_, rcB := k.spawnKept(t, "b", look, two, uid)
	rcB.readUntil(t, func() bool { return strings.Contains(string(rcB.got[frame.StreamStdout]), "done\n") })
	if out, want := string(rcB.got[frame.StreamStdout]), "unread\nroot:"+disk+" \ndisk:programs \nrecords:1\ndone\n"; out != want {
		t.Fatalf("the person's other program, with the root under /opt, saw\n%q\nwant\n%q", out, want)
	}
	_, _, rcP := k.spawn(t, "p", `echo "root:$(ls -A `+root+` | wc -l)"; cat "`+one+`/signin" 2>/dev/null || echo unread; echo done`, map[string]string{}, false)
	rcP.readUntil(t, func() bool { return strings.Contains(string(rcP.got[frame.StreamStdout]), "done\n") })
	if out, want := string(rcP.got[frame.StreamStdout]), "root:0\nunread\ndone\n"; out != want {
		t.Fatalf("a pooled spawn, with the root under /opt, saw\n%q\nwant\n%q", out, want)
	}
}

// A kept spawn runs only in a place of its disk's own person: one whose
// place names another athanor, or none, is refused before anything of it
// is made, with no packs that the place's claim would refuse first, and its
// place is freed. The home's own person then spawns in it.
func TestAKeptSpawnInAnotherPersonsPlaceIsRefused(t *testing.T) {
	k := keptKeeper(t)
	path := k.keptPath("vlt_theirs")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m", path, testKeptFirst); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	for name, place := range map[string]func(id string) map[string]any{
		"another person's": func(id string) map[string]any { return k.placeOf(t, id, k.kind(), "ath_someone-else") },
		"nobody's":         func(id string) map[string]any { return k.place(t, id, k.kind()) },
	} {
		id := "x-" + strings.ReplaceAll(strings.Split(name, " ")[0], "'", "")
		if placed := place(id); placed["type"] != protocol.TypePlaced {
			t.Fatalf("%s place: %v", name, placed)
		}
		k.s.handleSpawn(k.c, keptRequest(t, k.attach, id, "echo ran", path, nil))
		if refused := k.reply(t); refused["type"] != protocol.TypeError || refused["code"] != protocol.CodeBadRequest || refused["spawn_id"] != nil {
			t.Fatalf("a kept spawn in %s place: %v", name, refused)
		}
		k.s.mu.Lock()
		_, held := k.c.places[id]
		live := k.s.keptLive[testKeptFirst]
		k.s.mu.Unlock()
		if held || live != 0 {
			t.Fatalf("a refused spawn in %s place left its place held %t and %d live", name, held, live)
		}
	}
	spawned, _ := k.spawnKept(t, "own", "echo ran; sleep 600", path, testKeptFirst)
	k.release(t, spawned)
	k.releasedPair(t, spawned)
}

// One person's programs share their disk's uid and its work folder: a
// tool one installs in /work is on the other's PATH; each home is its
// own. Retiring one program's home ends that program's session alone, by
// its group, and removes its folder alone: the other's session runs on,
// its home, /work and the uid stay, and the disk's record no longer holds
// the home. A reset empties one home under the same uid.
func TestRetiringOneHomeLeavesThePersonsOthers(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	k.share("ath_person", "vlt_one", "vlt_two")
	one, two := k.keptPath("vlt_one"), k.keptPath("vlt_two")
	disk := filepath.Dir(filepath.Dir(one))
	for i, path := range []string{one, two} {
		if made := k.homeRequest(t, protocol.TypeHomeMake, "m"+string(rune('a'+i)), path, uid); made["type"] != protocol.TypeHomeMade {
			t.Fatalf("home_make %s: %v", path, made)
		}
	}
	install := `mkdir -p /work/.local/bin && printf '#!/bin/sh\necho shared-tool\n' > /work/.local/bin/their-tool && chmod 0755 /work/.local/bin/their-tool && ` +
		`echo one > "$HOME/signin" && echo installed; sleep 600`
	a, rcA := k.spawnKept(t, "a", install, one, uid)
	rcA.readUntil(t, func() bool { return strings.Contains(string(rcA.got[frame.StreamStdout]), "installed\n") })
	b, rcB := k.spawnKept(t, "b", `their-tool; echo two > "$HOME/signin"; echo "path:$PATH"; echo ready; sleep 600`, two, uid)
	rcB.readUntil(t, func() bool { return strings.Contains(string(rcB.got[frame.StreamStdout]), "ready\n") })
	if out := string(rcB.got[frame.StreamStdout]); !strings.HasPrefix(out, "shared-tool\n") || !strings.Contains(out, "path:/opt/cyfr/bin:"+two+"/.local/bin:/work/.local/bin:") {
		t.Fatalf("the second program saw\n%s", out)
	}

	if retired := k.retireOf(t, protocol.TypeHomeRetire, "r1", "vlt_one", a); retired["type"] != protocol.TypeHomeRetired {
		t.Fatalf("home_retire: %v", retired)
	}
	if _, err := os.Lstat(one); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the retired home: %v", err)
	}
	k.s.mu.Lock()
	_, bLive := k.s.spawns[b]
	live := k.s.keptLive[uid]
	k.s.mu.Unlock()
	if !bLive || live != 1 {
		t.Fatalf("the other program's session after the retirement: held %t, %d live", bLive, live)
	}
	if c, err := procfs.ScanUID("/proc", uid, 0); err != nil || c.Live == 0 {
		t.Fatalf("the retirement ended the other program's processes: %+v %v", c, err)
	}
	for path, want := range map[string]string{filepath.Join(two, "signin"): "two\n", filepath.Join(disk, home.WorkDir, ".local", "bin", "their-tool"): "#!/bin/sh\necho shared-tool\n"} {
		if data, err := os.ReadFile(path); err != nil || string(data) != want {
			t.Fatalf("%s after the retirement: %q %v", path, data, err)
		}
	}
	disks, err := k.s.cfg.Kept.LoadDisks()
	if err != nil || !reflect.DeepEqual(disks["ath_person"], &home.Disk{Athanor: "ath_person", Form: home.FormDirectory, UID: uid, Homes: []string{"vlt_two"}}) {
		t.Fatalf("the record after the retirement: %+v %v", disks, err)
	}

	if reset := k.retireOf(t, protocol.TypeHomeReset, "r2", "vlt_two", b); reset["type"] != protocol.TypeHomeMade || reset["uid"] != float64(uid) {
		t.Fatalf("home_reset: %v", reset)
	}
	if entries, err := os.ReadDir(two); err != nil || len(entries) != 1 || entries[0].Name() != "tmp" {
		t.Fatalf("the reset home holds %v, %v", entries, err)
	}
	if _, err := os.Stat(filepath.Join(disk, home.WorkDir, ".local", "bin", "their-tool")); err != nil {
		t.Fatalf("the work folder after a reset: %v", err)
	}
}

// A retirement waits for its sessions' processes to end, never for their
// output to be read: a session whose reader takes nothing, with more
// written than the relay's socket holds, is retired and its folder removed,
// and its `released` follows once its reader takes the rest.
func TestARetirementWaitsForNoReader(t *testing.T) {
	k := keptKeeper(t)
	path := k.keptPath("vlt_unread")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m", path, testKeptFirst); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	s, rc := k.spawnKept(t, "s", `head -c 16777216 /dev/zero; sleep 600`, path, testKeptFirst)
	done := make(chan struct{})
	go func() {
		k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeHomeRetire, ID: "r", Home: "vlt_unread"})
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(20 * time.Second):
		t.Fatal("the retirement waited on a reader that takes nothing")
	}
	if m := k.homeAnswer(t, "r", s); m["type"] != protocol.TypeHomeRetired {
		t.Fatalf("home_retire: %v", m)
	}
	if _, err := os.Lstat(path); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the retired home: %v", err)
	}
	rc.readUntil(t, func() bool { return rc.eof })
	for {
		m := k.reply(t)
		if m["spawn_id"] != s || (m["type"] != protocol.TypeExited && m["type"] != protocol.TypeReleased) {
			t.Fatalf("after its reader took the rest: %v", m)
		}
		if m["type"] == protocol.TypeReleased {
			break
		}
	}
}

// A readmission during a folder's retirement, a new home of the person's
// made while the retirement ends the old one's session, finishes that
// folder's alone: the new home is on the same disk, under the same uid,
// beside /work as it was.
func TestAReadmissionDuringAFoldersRetirementFindsTheDiskWhole(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	k.share("ath_back", "vlt_old", "vlt_new")
	old := k.keptPath("vlt_old")
	disk := filepath.Dir(filepath.Dir(old))
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m1", old, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	// Its session ignores TERM, so its end takes its grace: the readmission
	// lands while the retirement waits on it.
	s, rc := k.spawnKept(t, "s", `trap "" TERM; echo tool > /work/tool; echo ready; while :; do sleep 1; done`, old, uid)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "ready\n") })
	go func() {
		k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeHomeRetire, ID: "r", Home: "vlt_old"})
	}()
	deadline := time.Now().Add(10 * time.Second)
	for {
		k.s.mu.Lock()
		ending := k.s.keptEnding[uid]
		k.s.mu.Unlock()
		if ending > 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the retirement never began to end its session")
		}
		time.Sleep(10 * time.Millisecond) // sleep-ok: a bounded poll of the keeper's own state
	}
	go func() {
		k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeHomeMake, ID: "m2", Home: "vlt_new", Athanor: "ath_back"})
	}()
	answers := map[string]map[string]any{}
	for len(answers) < 2 {
		m := k.reply(t)
		if id, _ := m["id"].(string); id == "r" || id == "m2" {
			answers[id] = m
		} else if m["spawn_id"] != s {
			t.Fatalf("waiting for the retirement and the make: %v", m)
		}
	}
	if answers["r"]["type"] != protocol.TypeHomeRetired || answers["m2"]["type"] != protocol.TypeHomeMade || answers["m2"]["uid"] != float64(uid) {
		t.Fatalf("the retirement and the readmission answered %v", answers)
	}
	if _, err := os.Lstat(old); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the retired home: %v", err)
	}
	if err := home.CheckKeptHome(k.keptPath("vlt_new"), uid); err != nil {
		t.Fatalf("the new home: %v", err)
	}
	if data, err := os.ReadFile(filepath.Join(disk, home.WorkDir, "tool")); err != nil || string(data) != "tool\n" {
		t.Fatalf("the work folder: %q %v", data, err)
	}
	disks, err := k.s.cfg.Kept.LoadDisks()
	if err != nil || !reflect.DeepEqual(disks["ath_back"], &home.Disk{Athanor: "ath_back", Form: home.FormDirectory, UID: uid, Homes: []string{"vlt_new"}}) {
		t.Fatalf("the record: %+v %v", disks, err)
	}
}

// The person's full retirement, which kills every process of the disk's
// uid, never ends a session of theirs registered live: a session of the
// person's other program that started first holds it off, and one that
// starts while it runs waits for it and then runs on.
func TestThePersonsScrubNeverEndsALiveSession(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	k.share("ath_scrub", "vlt_a", "vlt_b")
	a, b := k.keptPath("vlt_a"), k.keptPath("vlt_b")
	for i, path := range []string{a, b} {
		if made := k.homeRequest(t, protocol.TypeHomeMake, "m"+string(rune('a'+i)), path, uid); made["type"] != protocol.TypeHomeMade {
			t.Fatalf("home_make: %v", made)
		}
	}

	// Seen by it: b's session is live as a's last ends, so no scrub runs.
	first, rc := k.spawnKept(t, "a1", `echo ready; sleep 600`, a, uid)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "ready\n") })
	other, rcB := k.spawnKept(t, "b1", `echo ready; sleep 600`, b, uid)
	rcB.readUntil(t, func() bool { return strings.Contains(string(rcB.got[frame.StreamStdout]), "ready\n") })
	k.release(t, first)
	k.releasedPair(t, first)
	k.s.mu.Lock()
	retiring := k.s.keptRetiring[uid]
	k.s.mu.Unlock()
	if retiring != nil {
		t.Fatal("the uid is retiring while the other program's session lives")
	}
	if got := pidsOf(t, uid, "sleep"); len(got) != 1 {
		t.Fatalf("the other program's sleep after the first's end: %v", got)
	}

	// Waits for it: the last session's child ignores TERM, so the uid is
	// retiring through its grace; a's next session waits and then runs.
	k.release(t, other)
	k.releasedPair(t, other)
	last, rcL := k.spawnKept(t, "b2", `(trap "" TERM; exec sleep 600) & echo forked; sleep 600`, b, uid)
	rcL.readUntil(t, func() bool { return strings.Contains(string(rcL.got[frame.StreamStdout]), "forked\n") })
	grace := int64(1500)
	k.s.handleRelease(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: last, GraceMs: &grace})
	deadline := time.Now().Add(10 * time.Second)
	for {
		k.s.mu.Lock()
		retiring = k.s.keptRetiring[uid]
		k.s.mu.Unlock()
		if retiring != nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the uid did not begin to retire")
		}
		time.Sleep(10 * time.Millisecond) // sleep-ok: a bounded poll of the keeper's own state
	}
	k.handleSpawn(t, keptRequest(t, k.attach, "a2", `echo after; sleep 600`, a, nil))
	var spawned map[string]any
	for spawned == nil {
		m := k.reply(t)
		switch {
		case m["spawn_id"] == last:
		case m["id"] == "a2" && m["type"] == protocol.TypeSpawned:
			spawned = m
		default:
			t.Fatalf("waiting for the next session: %v", m)
		}
	}
	select {
	case <-retiring:
	default:
		t.Fatal("the next session started before the uid's retirement ended")
	}
	rcN := k.accept(t)
	rcN.readUntil(t, func() bool { return strings.Contains(string(rcN.got[frame.StreamStdout]), "after\n") })
	if got := pidsOf(t, uid, "sleep"); len(got) != 1 {
		t.Fatalf("the next session's sleep after the retirement: %v", got)
	}
	k.release(t, spawned["spawn_id"].(string))
	k.releasedPair(t, spawned["spawn_id"].(string))
}

// A record write that fails after its rename, its record in place and its
// folder unsynced, leaves the keeper's index saying what the record on disk
// says: the make is refused, the uid the record names is drawn for no other
// person, the records read back with no two disks of one uid, and the
// person's next make makes their home under it.
func TestARecordInPlaceAfterAFailedWriteKeepsItsUID(t *testing.T) {
	k := keptKeeper(t)
	kept := k.s.cfg.Kept
	failed := false
	k.s.writeDisk = func(d home.Disk) error {
		if err := kept.WriteDisk(d); err != nil {
			return err
		}
		if !failed {
			failed = true
			return errors.New("the records' folder did not sync")
		}
		return nil
	}
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m1", k.keptPath("vlt_first"), 0); made["code"] != protocol.CodeInternal {
		t.Fatalf("a make whose record's write failed: %v", made)
	}
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m2", k.keptPath("vlt_second"), testKeptFirst+1); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("another person's make: %v", made)
	}
	disks, err := kept.LoadDisks()
	if err != nil || disks[k.athanorOf("vlt_first")].UID != testKeptFirst || disks[k.athanorOf("vlt_second")].UID != testKeptFirst+1 {
		t.Fatalf("the records: %+v %v", disks, err)
	}
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m3", k.keptPath("vlt_first"), testKeptFirst); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("the person's next make: %v", made)
	}
	if err := home.CheckKeptHome(k.keptPath("vlt_first"), testKeptFirst); err != nil {
		t.Fatal(err)
	}
}

// A keeper killed between a make's record and its folder leaves a home its
// record lists and no folder: the next keeper lists it, and its next make
// makes the folder under the recorded uid. One killed between a
// retirement's removal and its record leaves the same: the next keeper's
// retirement answers it retired and drops it from the record. A disk's
// uid recorded with no folder of it on the root is never drawn again.
func TestAKeeperKilledBetweenRecordAndFolderLeavesAHomeItSettles(t *testing.T) {
	k := keptKeeper(t)
	kept := k.s.cfg.Kept
	// The next keeper reads the records again.
	restart := func() {
		t.Helper()
		k.s.mu.Lock()
		k.s.disks, k.s.homeDisk = nil, nil
		k.s.mu.Unlock()
		if err := k.s.loadDisks(); err != nil {
			t.Fatal(err)
		}
	}
	// The make's record, written before its folder, and nothing after.
	if err := kept.WriteDisk(home.Disk{Athanor: "ath_killed", Form: home.FormDirectory, UID: testKeptFirst, Homes: []string{"vlt_made"}}); err != nil {
		t.Fatal(err)
	}
	restart()
	// The retirement's folder removed before its record, and nothing after.
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m", k.keptPath("vlt_gone"), testKeptFirst+1); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make beside a recorded uid with no folder: %v", made)
	}
	if err := os.RemoveAll(k.keptPath("vlt_gone")); err != nil {
		t.Fatal(err)
	}
	restart()
	list := k.homeRequest(t, protocol.TypeHomeList, "l", "", 0)
	if ids, _ := json.Marshal(list["ids"]); string(ids) != `["vlt_gone","vlt_made"]` {
		t.Fatalf("home_list after the keeper's death: %v", list)
	}
	if fresh := k.homeRequest(t, protocol.TypeHomeMake, "fresh", k.keptPath("vlt_fresh"), testKeptFirst+2); fresh["type"] != protocol.TypeHomeMade {
		t.Fatalf("a new person's disk beside a recorded uid with no folder: %v", fresh)
	}
	k.share("ath_killed", "vlt_made")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "again", k.keptPath("vlt_made"), testKeptFirst); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("the make again: %v", made)
	}
	if err := home.CheckKeptHome(k.keptPath("vlt_made"), testKeptFirst); err != nil {
		t.Fatalf("the home its record listed: %v", err)
	}
	if retired := k.retireOf(t, protocol.TypeHomeRetire, "r", "vlt_gone"); retired["type"] != protocol.TypeHomeRetired {
		t.Fatalf("the retirement again: %v", retired)
	}
	disks, err := kept.LoadDisks()
	if err != nil || len(disks[k.athanorOf("vlt_gone")].Homes) != 0 {
		t.Fatalf("the records: %+v %v", disks, err)
	}
}
