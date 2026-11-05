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
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/internal/frame"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/procfs"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

const (
	testKeptFirst = 39101
	testKeptLast  = 39104
)

// keptKeeper is a bounded keeper that keeps homes under a root it makes
// beside the scratch home root, as the shipped image does: owned by root
// and the client's group, 1773.
func keptKeeper(t *testing.T) *keeper {
	t.Helper()
	k := boundedKeeper(t)
	root := filepath.Join(filepath.Dir(k.homes), "kept")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chown(root, 0, k.s.client.GID); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(root, home.KeptRootMode.Perm()|os.ModeSticky); err != nil {
		t.Fatal(err)
	}
	if err := home.CheckKeptRoot(root, k.s.client.GID); err != nil {
		t.Fatal(err)
	}
	k.s.cfg.Kept = &home.Kept{Root: root, First: testKeptFirst, Last: testKeptLast}
	return k
}

func (k *keeper) homeRequest(t *testing.T, typ, id, path string, uid int) map[string]any {
	t.Helper()
	u := uint64(uid)
	k.s.handleHome(&protocol.Request{V: protocol.Version, Type: typ, ID: id, Path: path, UID: &u})
	return k.reply(t)
}

// keptRequest is the parsed request for a kept spawn of `/bin/sh -c script`.
func keptRequest(t *testing.T, attach, id, script, path string, uid int, maxBytes *uint64, pty bool) *protocol.Request {
	t.Helper()
	message := map[string]any{
		"v": protocol.Version, "type": protocol.TypeSpawn, "id": id, "pool": "runner",
		"argv": []string{"/bin/sh", "-c", script}, "env": map[string]string{},
		"memory_bytes": 64 << 20,
		"attach":       map[string]string{"path": attach, "token": testToken},
		"home_mode":    protocol.HomeKept, "home_path": path, "home_uid": uid,
	}
	if maxBytes != nil {
		message["home_max_bytes"] = *maxBytes
	}
	if pty {
		message["pty"] = true
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
	k.s.handleSpawn(keptRequest(t, k.attach, id, script, path, uid, nil, false))
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
	k.s.handleSpawn(keptRequest(t, k.attach, "k3", "true", path, uid, &over, false))
	if refused := k.reply(t); refused["type"] != protocol.TypeError || refused["code"] != protocol.CodeHomeOverCap {
		t.Fatalf("a spawn at its home's bound: %v", refused)
	}

	if retired := k.homeRequest(t, protocol.TypeHomeRetire, "r1", path, uid); retired["type"] != protocol.TypeHomeRetired {
		t.Fatalf("home_retire: %v", retired)
	}
	if _, err := os.Lstat(path); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the home outlived home_retire: %v", err)
	}
}

// A pooled uid's spawn is refused the kept home: the home is 0700 and its
// uid's.
func TestAPooledUIDCannotReadAKeptHome(t *testing.T) {
	k := keptKeeper(t)
	uid := testKeptFirst + 1
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

// A kept spawn's uid must be the range's and its home directly under the
// root and made; anything else is a bad request.
func TestAKeptSpawnOutsideItsRangeOrHomeIsRefused(t *testing.T) {
	k := keptKeeper(t)
	root := k.s.cfg.Kept.Root
	for name, req := range map[string]*protocol.Request{
		"a uid outside the range": keptRequest(t, k.attach, "1", "true", filepath.Join(root, "vlt_x"), testKeptLast+1, nil, false),
		"a home below another":    keptRequest(t, k.attach, "2", "true", filepath.Join(root, "a", "b"), testKeptFirst, nil, false),
		"a home not made":         keptRequest(t, k.attach, "3", "true", filepath.Join(root, "vlt_absent"), testKeptFirst, nil, false),
	} {
		k.s.handleSpawn(req)
		if refused := k.reply(t); refused["type"] != protocol.TypeError || refused["code"] != protocol.CodeBadRequest {
			t.Errorf("%s: %v", name, refused)
		}
	}
}

// A pty spawn's stdin, stdout and stderr are a terminal of 40 rows by 120
// columns, its controlling terminal; its stdout frames carry the terminal,
// and its stderr ends at once.
func TestAPtySpawnRunsOnATerminal(t *testing.T) {
	k := boundedKeeper(t)
	req := spawnRequest(t, k.attach, "t1", `tty; [ -t 0 ] && [ -t 2 ] && echo isatty; stty size; IFS= read -r line; echo "got:$line"`, map[string]string{}, false, 64<<20)
	pty := true
	req.Pty = &pty
	k.s.handleSpawn(req)
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
