// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/frame"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/logx"
	"github.com/cyfr/locus/keeper/internal/pool"
	"github.com/cyfr/locus/keeper/internal/procfs"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

const (
	testKeptFirst = 39101
	testKeptLast  = 39104
)

// keptKeeper is a routed bounded keeper whose role is the kept one, keeping
// homes under a root it makes beside the scratch home root, as the shipped
// image does: owned by root and a group no role, pool or kept home holds,
// 1773.
func keptKeeper(t *testing.T) *keeper {
	t.Helper()
	k := routedKeeper(t)
	root := filepath.Join(filepath.Dir(k.homes), "kept")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(root, home.KeptRootMode.Perm()|os.ModeSticky); err != nil {
		t.Fatal(err)
	}
	k.s.cfg.Kept = &home.Kept{Root: root, First: testKeptFirst, Last: testKeptLast}
	k.c.role.spec.Kept = true
	if err := home.CheckKeptRoot(root, heldGID(k.s.cfg, []Account{k.c.role.account}, k.s.accounts)); err != nil {
		t.Fatal(err)
	}
	return k
}

// homeRequest sends a home request naming the kept home at path by its id
// and answers its reply; a home_make must be answered home_made with uid,
// the uid the draw gives the home.
func (k *keeper) homeRequest(t *testing.T, typ, id, path string, uid int) map[string]any {
	t.Helper()
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: typ, ID: id, Home: filepath.Base(path)})
	reply := k.reply(t)
	if typ == protocol.TypeHomeMake && reply["type"] == protocol.TypeHomeMade && reply["uid"] != float64(uid) {
		t.Fatalf("home_make %s of %s answered uid %v, want %d", id, path, reply["uid"], uid)
	}
	return reply
}

// keptRequest is the parsed request for a kept spawn of `/bin/sh -c script`
// in the kept home at path, in the place of its own id.
func keptRequest(t *testing.T, attach, id, script, path string, maxBytes *uint64) *protocol.Request {
	t.Helper()
	message := map[string]any{
		"v": protocol.Version, "type": protocol.TypeSpawn, "id": id, "place": id, "pool": "runner",
		"argv": []string{"/bin/sh", "-c", script}, "env": map[string]string{},
		"memory_bytes": 64 << 20, "cpu_quota": protocol.CPUPeriod,
		"attach":    map[string]string{"path": attach, "token": testToken},
		"home_mode": protocol.HomeKept, "home": filepath.Base(path),
	}
	if maxBytes != nil {
		message["home_max_bytes"] = *maxBytes
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

// spawnKept starts a kept spawn and answers its spawn id and its relay.
func (k *keeper) spawnKept(t *testing.T, id, script, path string, uid int) (string, *relayConn) {
	t.Helper()
	k.handleSpawn(t, keptRequest(t, k.attach, id, script, path, nil))
	spawned := k.reply(t)
	if spawned["type"] != protocol.TypeSpawned || spawned["id"] != id || int(spawned["uid"].(float64)) != uid {
		t.Fatalf("kept spawn %s answered %v", id, spawned)
	}
	return spawned["spawn_id"].(string), k.accept(t)
}

func (k *keeper) accept(t *testing.T) *relayConn {
	t.Helper()
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
	return rc
}

// releasedPair reads a spawn's exited and released replies.
func (k *keeper) releasedPair(t *testing.T, spawnID string) {
	t.Helper()
	got := map[string]bool{}
	for len(got) < 2 {
		m := k.reply(t)
		if m["spawn_id"] != spawnID {
			t.Fatalf("waiting for %s: %v", spawnID, m)
		}
		got[m["type"].(string)] = true
	}
	if !got[protocol.TypeExited] || !got[protocol.TypeReleased] {
		t.Fatalf("spawn %s: %v", spawnID, got)
	}
}

// A kept home is made by its own uid, 0700; two spawns of it share its uid
// and its files; releasing one leaves the other running; the home outlives
// both, is measured and refuses a spawn at its bound; home_retire ends the
// uid and removes it.
func TestAKeptHomeLivesUnderItsOwnUID(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	path := filepath.Join(k.s.cfg.Kept.Root, "vlt_home-a")

	if made := k.homeRequest(t, protocol.TypeHomeMake, "m1", path, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	if err := home.CheckKeptHome(path, uid); err != nil {
		t.Fatal(err)
	}
	// Making it again is done: the home is already its uid's.
	if again := k.homeRequest(t, protocol.TypeHomeMake, "m2", path, uid); again["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make again: %v", again)
	}

	first, rcA := k.spawnKept(t, "k1", `echo "$HOME $(id -u)"; echo kept > "$HOME/notes"; echo ready; sleep 60`, path, uid)
	rcA.readUntil(t, func() bool { return strings.Contains(string(rcA.got[frame.StreamStdout]), "ready\n") })
	if out := string(rcA.got[frame.StreamStdout]); !strings.HasPrefix(out, path+" "+strconv.Itoa(uid)+"\n") {
		t.Fatalf("the first spawn ran as %q", out)
	}
	second, rcB := k.spawnKept(t, "k2", `cat "$HOME/notes"; sleep 60`, path, uid)
	rcB.readUntil(t, func() bool { return strings.Contains(string(rcB.got[frame.StreamStdout]), "kept\n") })

	// Releasing the first ends its group alone.
	k.release(t, first)
	k.releasedPair(t, first)
	if c, err := procfs.ScanUID("/proc", uid, 0); err != nil || c.Live == 0 {
		t.Fatalf("releasing one spawn ended its sibling: %+v %v", c, err)
	}
	k.release(t, second)
	k.releasedPair(t, second)
	if c, err := procfs.ScanUID("/proc", uid, 0); err != nil || c.Total() != 0 {
		t.Fatalf("processes of kept uid %d after its last spawn: %+v %v", uid, c, err)
	}
	if data, err := os.ReadFile(filepath.Join(path, "notes")); err != nil || string(data) != "kept\n" {
		t.Fatalf("the home did not outlive its spawns: %q %v", data, err)
	}
	k.s.mu.Lock()
	held, live := len(k.s.spawns), k.s.keptLive[uid]
	free := k.s.pools["runner"].Stats().Free
	k.s.mu.Unlock()
	if held != 0 || live != 0 || free != testPoolLast-testPoolFirst+1 {
		t.Fatalf("after the kept spawns: %d held, %d live, %d free pooled uids", held, live, free)
	}

	measured := k.homeRequest(t, protocol.TypeHomeMeasure, "s1", path, uid)
	bytes, _ := measured["bytes"].(float64)
	if measured["type"] != protocol.TypeHomeMeasured || bytes <= 0 {
		t.Fatalf("home_measure: %v", measured)
	}
	over := uint64(bytes)
	k.handleSpawn(t, keptRequest(t, k.attach, "k3", "true", path, &over))
	if refused := k.reply(t); refused["type"] != protocol.TypeError || refused["code"] != protocol.CodeHomeOverCap {
		t.Fatalf("a spawn at its home's bound: %v", refused)
	}

	if retired := k.homeRequest(t, protocol.TypeHomeRetire, "r1", path, uid); retired["type"] != protocol.TypeHomeRetired {
		t.Fatalf("home_retire: %v", retired)
	}
	if _, err := os.Lstat(path); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the home outlived home_retire: %v", err)
	}
	// A home not made is absent to a measure, and retired already.
	if absent := k.homeRequest(t, protocol.TypeHomeMeasure, "s2", path, uid); absent["code"] != protocol.CodeHomeAbsent {
		t.Fatalf("home_measure of a retired home: %v", absent)
	}
	if retired := k.homeRequest(t, protocol.TypeHomeRetire, "r2", path, uid); retired["type"] != protocol.TypeHomeRetired {
		t.Fatalf("home_retire of a retired home: %v", retired)
	}
}

// A pooled uid's spawn is refused the kept home: the home is 0700 and its
// uid's.
func TestAPooledUIDCannotReadAKeptHome(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	path := filepath.Join(k.s.cfg.Kept.Root, "vlt_home-b")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m1", path, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	kept, rcK := k.spawnKept(t, "k1", `echo secret > "$HOME/notes"; echo done`, path, uid)
	rcK.readUntil(t, func() bool { return false })
	k.releasedPair(t, kept)

	spawnID, _, rc := k.spawn(t, "p1", `if cat `+path+`/notes; then echo read; else echo refused; fi; ls `+k.s.cfg.Kept.Root+` || echo unlisted`, map[string]string{}, false)
	rc.readUntil(t, func() bool { return false })
	out := string(rc.got[frame.StreamStdout])
	if strings.Contains(out, "secret") || !strings.Contains(out, "refused") || !strings.Contains(out, "unlisted") {
		t.Fatalf("a pooled uid read the kept home or listed the root:\n%s", out)
	}
	k.releasedPair(t, spawnID)
	if retired := k.homeRequest(t, protocol.TypeHomeRetire, "r1", path, uid); retired["type"] != protocol.TypeHomeRetired {
		t.Fatalf("home_retire: %v", retired)
	}
}

// A kept spawn names a made home: one not made is absent, an entry that is
// no home (a file, or a folder of a uid outside the range) a bad request,
// and a keeper that keeps no homes refuses it as unavailable.
func TestAKeptSpawnOfNoHomeIsRefused(t *testing.T) {
	k := keptKeeper(t)
	root := k.s.cfg.Kept.Root
	if err := os.WriteFile(filepath.Join(root, "vlt_file"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "vlt_roots"), 0o700); err != nil {
		t.Fatal(err)
	}
	for name, c := range map[string]struct {
		req  *protocol.Request
		code string
	}{
		"a home not made":                 {keptRequest(t, k.attach, "1", "true", filepath.Join(root, "vlt_absent"), nil), protocol.CodeHomeAbsent},
		"a file":                          {keptRequest(t, k.attach, "2", "true", filepath.Join(root, "vlt_file"), nil), protocol.CodeBadRequest},
		"a folder of a uid not the range": {keptRequest(t, k.attach, "3", "true", filepath.Join(root, "vlt_roots"), nil), protocol.CodeBadRequest},
	} {
		k.handleSpawn(t, c.req)
		if refused := k.reply(t); refused["type"] != protocol.TypeError || refused["code"] != c.code {
			t.Errorf("%s: %v", name, refused)
		}
		// The refusal freed the place the spawn named.
		if placed := k.place(t, c.req.Place, protocol.KindProgram); placed["type"] != protocol.TypePlaced {
			t.Errorf("%s: placing its place again answered %v", name, placed)
		}
	}
	k.s.cfg.Kept = nil
	k.handleSpawn(t, keptRequest(t, k.attach, "4", "true", filepath.Join(root, "vlt_absent"), nil))
	if refused := k.reply(t); refused["code"] != protocol.CodeUnavailable {
		t.Fatalf("a kept spawn of a keeper that keeps no homes: %v", refused)
	}
}

// Each new home takes the lowest uid of the range that no home owns: a
// retired home's uid is drawn again, a made home's make answers its own
// uid, and a range every uid of which a home owns makes none.
func TestAKeptHomeTakesTheLowestFreeUID(t *testing.T) {
	k := keptKeeper(t)
	root := k.s.cfg.Kept.Root
	for uid := testKeptFirst; uid <= testKeptLast; uid++ {
		path := filepath.Join(root, "vlt_n"+strconv.Itoa(uid))
		if made := k.homeRequest(t, protocol.TypeHomeMake, "m"+strconv.Itoa(uid), path, uid); made["type"] != protocol.TypeHomeMade {
			t.Fatalf("home_make %s: %v", path, made)
		}
	}
	if full := k.homeRequest(t, protocol.TypeHomeMake, "full", filepath.Join(root, "vlt_full"), 0); full["code"] != protocol.CodeCapacity {
		t.Fatalf("home_make with every uid owned: %v", full)
	}
	second := filepath.Join(root, "vlt_n"+strconv.Itoa(testKeptFirst+1))
	if made := k.homeRequest(t, protocol.TypeHomeMake, "again", second, testKeptFirst+1); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make of a made home: %v", made)
	}
	if retired := k.homeRequest(t, protocol.TypeHomeRetire, "r", second, 0); retired["type"] != protocol.TypeHomeRetired {
		t.Fatalf("home_retire: %v", retired)
	}
	if made := k.homeRequest(t, protocol.TypeHomeMake, "freed", filepath.Join(root, "vlt_freed"), testKeptFirst+1); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make after a retirement: %v", made)
	}
	list := k.homeRequest(t, protocol.TypeHomeList, "l", "", 0)
	if ids, _ := json.Marshal(list["ids"]); list["type"] != protocol.TypeHomes || list["next"] != nil ||
		string(ids) != `["vlt_freed","vlt_n39101","vlt_n39103","vlt_n39104"]` {
		t.Fatalf("home_list: %v", list)
	}
}

// A reset ends every process of the home's uid and leaves the home empty
// under that same uid, which no draw takes meanwhile; a reset of a home not
// made leaves it absent.
func TestAKeptHomeResetEmptiesItUnderItsUID(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	path := filepath.Join(k.s.cfg.Kept.Root, "vlt_home-reset")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m1", path, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	spawned, rc := k.spawnKept(t, "k1", `echo kept > "$HOME/notes"; echo ready; sleep 600`, path, uid)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "ready\n") })
	// The reset's answer and its spawn's end, killed by it, come in either
	// order.
	k.s.handle(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeHomeReset, ID: "x1", Home: filepath.Base(path)})
	got := map[string]map[string]any{}
	for len(got) < 3 {
		m := k.reply(t)
		got[m["type"].(string)] = m
	}
	if reset := got[protocol.TypeHomeMade]; reset["id"] != "x1" || reset["uid"] != float64(uid) ||
		got[protocol.TypeExited]["spawn_id"] != spawned || got[protocol.TypeReleased]["spawn_id"] != spawned {
		t.Fatalf("home_reset beside its spawn's end: %v", got)
	}
	if c, err := procfs.ScanUID("/proc", uid, 0); err != nil || c.Total() != 0 {
		t.Fatalf("processes of kept uid %d after its reset: %+v %v", uid, c, err)
	}
	// Empty: nothing but the tmp folder every make makes (home.Make).
	if entries, err := os.ReadDir(path); err != nil || len(entries) != 1 || entries[0].Name() != "tmp" || home.CheckKeptHome(path, uid) != nil {
		t.Fatalf("the home after its reset: %v %v", entries, err)
	}

	absent := filepath.Join(k.s.cfg.Kept.Root, "vlt_home-never")
	if reset := k.homeRequest(t, protocol.TypeHomeReset, "x2", absent, 0); reset["type"] != protocol.TypeHomeRetired {
		t.Fatalf("home_reset of a home not made: %v", reset)
	}
	if _, err := os.Lstat(absent); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("a reset made a home not made: %v", err)
	}
	if retired := k.homeRequest(t, protocol.TypeHomeRetire, "r1", path, uid); retired["type"] != protocol.TypeHomeRetired {
		t.Fatalf("home_retire: %v", retired)
	}
}

// ptySize is a spawn's pty of rows by cols.
func ptySize(rows, cols uint64) *protocol.PtySize {
	return &protocol.PtySize{Rows: &rows, Cols: &cols}
}

// A pty spawn's stdin, stdout and stderr are a terminal of the rows and
// columns it asked for, its controlling terminal; its stdout frames carry
// the terminal, and its stderr ends at once.
func TestAPtySpawnRunsOnATerminal(t *testing.T) {
	k := routedKeeper(t)
	req := spawnRequest(t, k.attach, "t1", `tty; [ -t 0 ] && [ -t 2 ] && echo isatty; stty size; IFS= read -r line; echo "got:$line"`, map[string]string{}, false, 64<<20)
	req.Pty = ptySize(40, 120)
	k.handleSpawn(t, req)
	spawned := k.reply(t)
	if spawned["type"] != protocol.TypeSpawned {
		t.Fatalf("pty spawn: %v", spawned)
	}
	rc := k.accept(t)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "40 120") })
	rc.send(t, frame.StreamStdin, []byte("hello\n"))
	rc.readUntil(t, func() bool { return false })
	out := string(rc.got[frame.StreamStdout])
	for _, want := range []string{"/dev/pts/", "isatty", "40 120", "got:hello"} {
		if !strings.Contains(out, want) {
			t.Errorf("the terminal lacks %q:\n%s", want, out)
		}
	}
	if len(rc.got[frame.StreamStderr]) != 0 || !rc.ended[frame.StreamStderr] {
		t.Fatalf("a pty spawn's stderr: %q ended %t", rc.got[frame.StreamStderr], rc.ended[frame.StreamStderr])
	}
	k.releasedPair(t, spawned["spawn_id"].(string))
}

// A resize reaches a pty spawn's terminal: the command reads the new size,
// and the keeper answers nothing.
func TestAResizeReachesAPtySpawnsTerminal(t *testing.T) {
	k := routedKeeper(t)
	req := spawnRequest(t, k.attach, "t2", `stty size; read x; stty size`, map[string]string{}, false, 64<<20)
	req.Pty = ptySize(24, 80)
	k.handleSpawn(t, req)
	spawned := k.reply(t)
	if spawned["type"] != protocol.TypeSpawned {
		t.Fatalf("pty spawn: %v", spawned)
	}
	spawnID := spawned["spawn_id"].(string)
	rc := k.accept(t)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "24 80") })
	resize, rerr := protocol.ParseRequest([]byte(`{"v":5,"type":"resize","spawn_id":"` + spawnID + `","rows":50,"cols":132}`))
	if rerr != nil {
		t.Fatal(rerr.Detail)
	}
	k.s.handle(k.c, resize)
	rc.send(t, frame.StreamStdin, []byte("\n"))
	rc.readUntil(t, func() bool { return false })
	if out := string(rc.got[frame.StreamStdout]); !strings.Contains(out, "24 80") || !strings.Contains(out, "50 132") {
		t.Fatalf("the terminal before and after the resize:\n%s", out)
	}
	k.releasedPair(t, spawnID)
}

// A kept spawn takes no file-size limit of its own (protocol.KeptUnbounded):
// its home grows past the 256 MiB ceiling, which a pooled spawn still has.
// The file is made sparse, so neither spawn's memory bound is reached.
func TestAKeptSpawnWritesPastTheFileSizeCeilingAndAPooledOneCannot(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	path := filepath.Join(k.s.cfg.Kept.Root, "vlt_home-big")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m1", path, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	grow := `truncate -s 300M "$HOME/big" && echo grew || echo refused; sleep 60`

	kept, rc := k.spawnKept(t, "big", grow, path, uid)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "\n") })
	if out := string(rc.got[frame.StreamStdout]); out != "grew\n" {
		t.Fatalf("a kept spawn growing a file past 256 MiB printed %q", out)
	}
	k.release(t, kept)
	k.releasedPair(t, kept)

	pooled, _, rcP := k.spawn(t, "small", grow, map[string]string{}, false)
	rcP.readUntil(t, func() bool { return strings.Contains(string(rcP.got[frame.StreamStdout]), "\n") })
	if out := string(rcP.got[frame.StreamStdout]); out != "refused\n" {
		t.Fatalf("a pooled spawn growing a file past 256 MiB printed %q", out)
	}
	k.release(t, pooled)
	k.releasedPair(t, pooled)

	if retired := k.homeRequest(t, protocol.TypeHomeRetire, "r1", path, uid); retired["type"] != protocol.TypeHomeRetired {
		t.Fatalf("home_retire: %v", retired)
	}
}

// A kept uid follows a pooled uid's discipline: from the release of its
// last spawn it is retiring, and no new home's draw takes it, until every
// process of it is gone, a child that ignores SIGTERM included; then it is
// free.
func TestAKeptUIDIsRetiringUntilEveryProcessOfItIsGone(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	a := filepath.Join(k.s.cfg.Kept.Root, "vlt_home-turn-a")
	b := filepath.Join(k.s.cfg.Kept.Root, "vlt_home-turn-b")
	c := filepath.Join(k.s.cfg.Kept.Root, "vlt_home-turn-c")
	d := filepath.Join(k.s.cfg.Kept.Root, "vlt_home-turn-d")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m1", a, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}

	// The uid runs a's spawn, whose child ignores SIGTERM. Its home's folder
	// goes, so the uid is no home's owner: live, it is still no new home's.
	spawned, rc := k.spawnKept(t, "turn", `(trap "" TERM; exec sleep 600) & echo forked; sleep 600`, a, uid)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "forked\n") })
	if err := os.RemoveAll(a); err != nil {
		t.Fatal(err)
	}
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m2", b, uid+1); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make of another home beside a live uid: %v", made)
	}

	// Released, it is retiring at once: its child outlives the grace of a
	// SIGTERM it ignores, and the uid is no new home's until it is killed.
	grace := int64(2000)
	k.s.handleRelease(k.c, &protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: spawned, GraceMs: &grace})
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m3", c, uid+2); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make beside a retiring uid: %v", made)
	}
	k.releasedPair(t, spawned)
	deadline := time.Now().Add(30 * time.Second)
	for {
		k.s.mu.Lock()
		retiring := k.s.keptRetiring[uid]
		k.s.mu.Unlock()
		if retiring == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the uid is still retiring")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if c, err := procfs.ScanUID("/proc", uid, 0); err != nil || c.Total() != 0 {
		t.Fatalf("processes of kept uid %d once it retired: %+v %v", uid, c, err)
	}
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m4", d, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make on the retired uid: %v", made)
	}
	for i, path := range []string{b, c, d} {
		if retired := k.homeRequest(t, protocol.TypeHomeRetire, "r"+strconv.Itoa(i), path, uid); retired["type"] != protocol.TypeHomeRetired {
			t.Fatalf("home_retire: %v", retired)
		}
	}
}

// A kept uid whose retirement cannot finish (something of it outside its
// home that it cannot remove) is quarantined: no new home's draw and no
// spawn takes it, until the sweeper's retry finds nothing left. A space sees no
// writable place outside its home, so the test leaves the entry itself.
func TestAKeptUIDWhoseRetirementCannotFinishIsQuarantined(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst
	path := filepath.Join(k.s.cfg.Kept.Root, "vlt_home-quarantine")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m1", path, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	pinned := filepath.Join(k.s.roots.Dirs[0], "pinned")
	if err := os.Mkdir(pinned, 0o777); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(pinned, 0o777); err != nil {
		t.Fatal(err)
	}
	leaveOwned(t, filepath.Join(pinned, "left"), uid)
	spawned, rc := k.spawnKept(t, "left", `echo started; sleep 600`, path, uid)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "started\n") })
	// The uid can no longer remove what it left there.
	if err := os.Chmod(pinned, 0o555); err != nil {
		t.Fatal(err)
	}
	k.release(t, spawned)
	k.releasedPair(t, spawned)
	deadline := time.Now().Add(60 * time.Second)
	for {
		k.s.mu.Lock()
		_, quarantined := k.s.keptQuarantined[uid]
		k.s.mu.Unlock()
		if quarantined {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the uid was not quarantined")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m2", filepath.Join(k.s.cfg.Kept.Root, "vlt_home-other"), uid+1); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make beside a quarantined uid: %v", made)
	}
	k.handleSpawn(t, keptRequest(t, k.attach, "again", "true", path, nil))
	if busy := k.reply(t); busy["code"] != protocol.CodeUIDBusy {
		t.Fatalf("a spawn on a quarantined uid: %v", busy)
	}

	if err := os.Chmod(pinned, 0o777); err != nil {
		t.Fatal(err)
	}
	k.s.sweepKept()
	k.s.mu.Lock()
	_, quarantined := k.s.keptQuarantined[uid]
	k.s.mu.Unlock()
	if quarantined {
		t.Fatal("the sweeper's retry left the uid quarantined")
	}
	if retired := k.homeRequest(t, protocol.TypeHomeRetire, "r1", path, uid); retired["type"] != protocol.TypeHomeRetired {
		t.Fatalf("home_retire: %v", retired)
	}
}

// A new home's uid is the lowest that nothing takes: no folder or process
// (home.Kept.Taken), no make or reset in flight, and no state of the
// keeper's own, retiring, quarantined or live; the uid drawn is held until
// its make ends. None needs root.
func TestANewHomesUIDIsTheLowestNothingHolds(t *testing.T) {
	s := &server{cfg: Config{Kept: &home.Kept{Root: "/k", First: 10, Last: 16}}}
	s.keptMaps()
	s.keptLive[10] = 1
	s.keptRetiring[11] = make(chan struct{})
	s.keptQuarantined[12] = "/k/q"
	s.keptMaking[13] = true
	taken := map[int]bool{14: true}
	var drawn []int
	for {
		uid, ok := s.pickKept(taken)
		if !ok {
			break
		}
		drawn = append(drawn, uid)
	}
	if !reflect.DeepEqual(drawn, []int{15, 16}) {
		t.Fatalf("drew %v", drawn)
	}
	s.unmakeKept(15)
	if uid, ok := s.pickKept(taken); !ok || uid != 15 {
		t.Fatalf("after its make ended, drew %d %t", uid, ok)
	}
}

// channelServer is a server on one end of a socketpair, keeping homes under
// kept, and a reader of what it sends.
func channelServer(t *testing.T, kept *home.Kept) (*server, *client, *protocol.LineReader) {
	t.Helper()
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	ours, theirs := os.NewFile(uintptr(fds[0]), "channel"), os.NewFile(uintptr(fds[1]), "client-channel")
	t.Cleanup(func() { ours.Close(); theirs.Close() })
	s := &server{cfg: Config{Kept: kept}, log: logx.NewWriter(io.Discard, "cyfr-locus", false)}
	c := testClient(ours, pool.Spec{Name: "backends", Reach: pool.ReachRouted}, Account{})
	c.role.spec.Kept = true
	return s, c, protocol.NewLineReader(theirs)
}

// home_list answers the homes in byte order, a page of at most
// MaxHomeListIDs naming its last as next while more follow, and the page
// after an id begins past it; an entry that is no home is not listed, and
// a root that cannot be listed is unavailable. None needs root.
func TestHomeListPagesTheHomesInOrder(t *testing.T) {
	me := os.Getuid()
	kept := &home.Kept{Root: t.TempDir(), First: me, Last: me}
	var want []string
	for i := 0; i < protocol.MaxHomeListIDs+3; i++ {
		id := fmt.Sprintf("vlt_%04d", i)
		want = append(want, id)
		if err := os.Mkdir(filepath.Join(kept.Root, id), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(kept.Root, "vlt_file"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	s, c, replies := channelServer(t, kept)
	list := func(after string) protocol.Homes {
		t.Helper()
		s.handle(c, &protocol.Request{V: protocol.Version, Type: protocol.TypeHomeList, ID: "l", After: after})
		line, _, err := replies.Next()
		if err != nil {
			t.Fatal(err)
		}
		var page protocol.Homes
		if err := json.Unmarshal(line, &page); err != nil || page.Type != protocol.TypeHomes {
			t.Fatalf("home_list answered %s: %v", line, err)
		}
		return page
	}
	first := list("")
	if !reflect.DeepEqual(first.IDs, want[:protocol.MaxHomeListIDs]) || first.Next != want[protocol.MaxHomeListIDs-1] {
		t.Fatalf("the first page: %d ids, next %q", len(first.IDs), first.Next)
	}
	second := list(first.Next)
	if !reflect.DeepEqual(second.IDs, want[protocol.MaxHomeListIDs:]) || second.Next != "" {
		t.Fatalf("the second page: %v, next %q", second.IDs, second.Next)
	}
	if last := list(want[len(want)-1]); len(last.IDs) != 0 || last.Next != "" {
		t.Fatalf("the page after the last home: %+v", last)
	}

	kept.Root = filepath.Join(kept.Root, "absent")
	s.handle(c, &protocol.Request{V: protocol.Version, Type: protocol.TypeHomeList, ID: "l"})
	line, _, _ := replies.Next()
	if want := `{"v":5,"type":"error","id":"l","code":"unavailable"}`; string(line) != want {
		t.Fatalf("a list of a root that cannot be read: %s", line)
	}
}
