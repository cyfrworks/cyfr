// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cyfr/locus/keeper/internal/frame"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/packview"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

const testAthanor = "ath_01a09fee-2c3d-7e4f-8a5b-6c7d8e9f0a1b"

// packStream is a generation's stream of the files, path to bytes, an
// executable one named by a trailing "*" on its path.
func packStream(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var lines []packview.Line
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	type entry struct {
		name string
		data []byte
		exec bool
	}
	var entries []entry
	for path, data := range files {
		exec := strings.HasSuffix(path, "*")
		path = strings.TrimSuffix(path, "*")
		sum := sha256.Sum256([]byte(data))
		lines = append(lines, packview.Line{Path: path, Size: int64(len(data)), SHA256: "sha256:" + hex.EncodeToString(sum[:]), Executable: exec})
		entries = append(entries, entry{path, []byte(data), exec})
	}
	if lines == nil {
		lines = []packview.Line{}
	}
	manifest, _ := json.Marshal(packview.Manifest{Files: lines})
	write := func(name string, data []byte, mode int64) {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: mode, Size: int64(len(data)), Typeflag: tar.TypeReg}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write(data); err != nil {
			t.Fatal(err)
		}
	}
	write(packview.ManifestName, manifest, 0o644)
	for _, e := range entries {
		mode := int64(0o644)
		if e.exec {
			mode = 0o755
		}
		write(e.name, e.data, mode)
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func setDigest(name string) string {
	sum := sha256.Sum256([]byte(name))
	return "sha256:" + hex.EncodeToString(sum[:])
}

func packsLine(t *testing.T, fields map[string]any) *protocol.Request {
	t.Helper()
	fields["v"] = protocol.Version
	line, err := json.Marshal(fields)
	if err != nil {
		t.Fatal(err)
	}
	req, rerr := protocol.ParseRequest(line)
	if rerr != nil {
		t.Fatal(rerr.Detail)
	}
	return req
}

// putAll sends a generation's stream in parts of the protocol's bound and
// answers every reply.
func putAll(t *testing.T, handle func(*protocol.Request) map[string]any, athanor, lifetime, digest string, stream []byte) []map[string]any {
	t.Helper()
	var parts [][]byte
	for len(stream) > protocol.MaxPackPartBytes {
		parts = append(parts, stream[:protocol.MaxPackPartBytes])
		stream = stream[protocol.MaxPackPartBytes:]
	}
	parts = append(parts, stream)
	var replies []map[string]any
	for i, part := range parts {
		replies = append(replies, handle(packsLine(t, map[string]any{
			"type": protocol.TypePacksPut, "id": "put", "athanor": athanor, "lifetime": lifetime, "digest": digest,
			"seq": i, "last": i == len(parts)-1, "data": base64.StdEncoding.EncodeToString(part),
		})))
	}
	return replies
}

// The kept role's packs requests reach the store: a hold of a generation
// not written is missing, a put's parts are taken and its last held, a
// hold then held; another role, and a keeper keeping no homes, refuse
// them as unavailable. None needs root.
func TestThePacksRequestsOfTheKeptRole(t *testing.T) {
	me := os.Getuid()
	kept := &home.Kept{Root: t.TempDir(), First: me, Last: me}
	s, c, replies := channelServer(t, kept)
	store := packview.New(filepath.Join(kept.Root, packview.DirName))
	s.packs = store
	t.Cleanup(func() { _ = os.Chmod(filepath.Join(kept.Root, packview.DirName), 0o700); chmodTree(kept.Root) })
	handle := func(req *protocol.Request) map[string]any {
		t.Helper()
		s.handle(c, req)
		line, _, err := replies.Next()
		if err != nil {
			t.Fatal(err)
		}
		var m map[string]any
		_ = json.Unmarshal(line, &m)
		return m
	}
	digest := setDigest("one")
	hold := func(lifetime string) map[string]any {
		return handle(packsLine(t, map[string]any{"type": protocol.TypePacksHold, "id": "h", "athanor": testAthanor, "lifetime": lifetime, "digest": digest}))
	}
	if r := hold("lt_1"); r["type"] != protocol.TypePacks || r["state"] != protocol.PacksMissing {
		t.Fatalf("a hold of a generation not written: %v", r)
	}
	big := strings.Repeat("x", protocol.MaxPackPartBytes+1)
	got := putAll(t, handle, testAthanor, "lt_1", digest, packStream(t, map[string]string{"p/a": big, "p/run*": "#!/bin/sh\n"}))
	if len(got) < 2 || got[0]["state"] != protocol.PacksTaken || got[len(got)-1]["state"] != protocol.PacksHeld {
		t.Fatalf("a put answered %v", got)
	}
	if r := hold("lt_2"); r["state"] != protocol.PacksHeld {
		t.Fatalf("a hold of the written generation: %v", r)
	}
	data, err := os.ReadFile(filepath.Join(store.Path(testAthanor, digest), "p", "a"))
	if err != nil || string(data) != big {
		t.Fatalf("the generation's file: %d bytes %v", len(data), err)
	}
	// A stream the store refuses is refused as packs_refused.
	bad := putAll(t, handle, testAthanor, "lt_3", setDigest("bad"), []byte("not a tar"))
	if last := bad[len(bad)-1]; last["type"] != protocol.TypeError || last["code"] != protocol.CodePacksRefused {
		t.Fatalf("a stream that is no archive: %v", bad)
	}

	// A put's first part while another put of its athanor is under way is
	// refused packs_busy, by its code, which its start meets by holding
	// again; the put under way goes on.
	part := func(lifetime string, seq int, last bool, data []byte) map[string]any {
		return handle(packsLine(t, map[string]any{
			"type": protocol.TypePacksPut, "id": "p-" + lifetime, "athanor": testAthanor, "lifetime": lifetime, "digest": setDigest("busy"),
			"seq": seq, "last": last, "data": base64.StdEncoding.EncodeToString(data),
		}))
	}
	busy := packStream(t, map[string]string{"p/a": "a"})
	if r := part("lt_7", 0, false, busy[:512]); r["state"] != protocol.PacksTaken {
		t.Fatalf("the first put's first part: %v", r)
	}
	if r := part("lt_8", 0, false, busy[:512]); r["type"] != protocol.TypeError || r["code"] != protocol.CodePacksBusy {
		t.Fatalf("another start's put while the first is under way: %v", r)
	}
	if r := part("lt_7", 1, true, busy[512:]); r["state"] != protocol.PacksHeld {
		t.Fatalf("the first put's last part: %v", r)
	}

	// A kept root that cannot take the packs' folder: the hold finds
	// nothing, and the put is refused unavailable, saying why in the log.
	blocked := t.TempDir()
	if err := os.WriteFile(filepath.Join(blocked, packview.DirName), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	s.packs = packview.New(filepath.Join(blocked, packview.DirName))
	if r := hold("lt_6"); r["type"] != protocol.TypePacks || r["state"] != protocol.PacksMissing {
		t.Fatalf("a hold where no packs' folder can be: %v", r)
	}
	if got := putAll(t, handle, testAthanor, "lt_6", digest, packStream(t, map[string]string{"p/a": "a"})); got[0]["type"] != protocol.TypeError || got[0]["code"] != protocol.CodeUnavailable {
		t.Fatalf("a put where no packs' folder can be: %v", got)
	}
	s.packs = store

	c.role.spec.Kept = false
	if r := hold("lt_4"); r["type"] != protocol.TypeError || r["code"] != protocol.CodeUnavailable {
		t.Fatalf("a hold of a role that keeps no homes: %v", r)
	}
	c.role.spec.Kept = true
	s.cfg.Kept, s.packs = nil, nil
	if r := hold("lt_5"); r["type"] != protocol.TypeError || r["code"] != protocol.CodeUnavailable {
		t.Fatalf("a hold of a keeper that keeps no homes: %v", r)
	}
}

// chmodTree makes every folder under root writable, so a test's temporary
// folder can be removed past a generation's read-only ones.
func chmodTree(root string) {
	_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err == nil && info.IsDir() {
			_ = os.Chmod(path, 0o700)
		}
		return nil
	})
}

// A kept spawn that names its person's generation sees it read only at
// /run/cyfr/scrolls, as written, its executable runnable; a write there
// fails; a spawn that names none sees no such folder; a spawn naming
// another athanor's generation than its place's, or one not written, is
// refused; and the generation stays while the spawn runs, through another
// start's hold of another digest (packview's tests hold the rest of the
// cleanup rule).
func TestASpaceSeesItsPersonsPacksReadOnly(t *testing.T) {
	k := keptKeeper(t)
	store := packview.New(filepath.Join(k.s.cfg.Kept.Root, packview.DirName))
	k.s.packs = store
	uid := testKeptFirst
	path := filepath.Join(k.s.cfg.Kept.Root, "vlt_packs")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m1", path, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	handle := func(req *protocol.Request) map[string]any {
		t.Helper()
		k.s.handle(k.c, req)
		return k.reply(t)
	}
	digest := setDigest("scrolls")
	stream := packStream(t, map[string]string{"pstack/skills/one/SKILL.md": "# one\n", "pstack/bin/hello*": "#!/bin/sh\necho hello from a pack\n"})
	if got := putAll(t, handle, testAthanor, "lt_1", digest, stream); got[len(got)-1]["state"] != protocol.PacksHeld {
		t.Fatalf("the put: %v", got)
	}

	placeOf := func(id, athanor string) {
		t.Helper()
		k.s.handle(k.c, parsed(t, `{"v":7,"type":"place","id":"`+id+`","kind":"program","athanor":"`+athanor+`"}`))
		if placed := k.reply(t); placed["type"] != protocol.TypePlaced {
			t.Fatalf("place %s: %v", id, placed)
		}
	}
	withPacks := func(id, script, athanor, digest string) *protocol.Request {
		req := keptRequest(t, k.attach, id, script, path, nil)
		req.Packs = &protocol.SpawnPacks{Athanor: athanor, Digest: digest}
		return req
	}

	script := `cat /run/cyfr/scrolls/pstack/skills/one/SKILL.md; /run/cyfr/scrolls/pstack/bin/hello; ` +
		`if touch /run/cyfr/scrolls/pstack/new 2>/dev/null; then echo wrote; else echo refused; fi; ` +
		`if mkdir /run/cyfr/scrolls/x 2>/dev/null; then echo made; else echo unmade; fi; ` +
		`grep ' /run/cyfr/scrolls ' /proc/self/mountinfo | grep -q ' ro,' && echo mounted-ro; echo ready; sleep 60`
	placeOf("k1", testAthanor)
	k.s.handleSpawn(k.c, withPacks("k1", script, testAthanor, digest))
	spawned := k.reply(t)
	if spawned["type"] != protocol.TypeSpawned {
		t.Fatalf("a spawn naming its packs: %v", spawned)
	}
	rc := k.accept(t)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "ready\n") })
	if out, want := string(rc.got[frame.StreamStdout]), "# one\nhello from a pack\nrefused\nunmade\nmounted-ro\nready\n"; out != want {
		t.Fatalf("the space saw\n%q\nwant\n%q\nstderr %q", out, want, rc.got[frame.StreamStderr])
	}

	// Another start's hold of another digest leaves the live one's.
	if r := handle(packsLine(t, map[string]any{"type": protocol.TypePacksHold, "id": "h", "athanor": testAthanor, "lifetime": "lt_2", "digest": setDigest("other")})); r["state"] != protocol.PacksMissing {
		t.Fatalf("another hold: %v", r)
	}
	if _, err := os.Stat(store.Path(testAthanor, digest)); err != nil {
		t.Fatalf("a live session's generation went at another start's hold: %v", err)
	}

	// No packs: no folder.
	placeOf("k2", testAthanor)
	k.s.handleSpawn(k.c, keptRequest(t, k.attach, "k2", `ls /run/cyfr/scrolls 2>/dev/null || echo none`, path, nil))
	plain := k.reply(t)
	rcPlain := k.accept(t)
	rcPlain.readUntil(t, func() bool { return false })
	if out := string(rcPlain.got[frame.StreamStdout]); out != "none\n" {
		t.Fatalf("a spawn naming no packs saw %q", out)
	}
	k.releasedPair(t, plain["spawn_id"].(string))

	// Another athanor's generation, and one not written, are refused.
	placeOf("k3", "ath_other")
	k.s.handleSpawn(k.c, withPacks("k3", "true", testAthanor, digest))
	if r := k.reply(t); r["type"] != protocol.TypeError || r["code"] != protocol.CodeBadRequest {
		t.Fatalf("a spawn of another athanor's place naming these packs: %v", r)
	}
	placeOf("k4", testAthanor)
	k.s.handleSpawn(k.c, withPacks("k4", "true", testAthanor, setDigest("unwritten")))
	unwritten := k.reply(t)
	if unwritten["type"] != protocol.TypeError || unwritten["code"] != protocol.CodeBadRequest {
		t.Fatalf("a spawn naming a generation not written: %v", unwritten)
	}
	// Refused once made, it is released, and nothing of it ran.
	if r := k.reply(t); r["type"] != protocol.TypeReleased || r["spawn_id"] != unwritten["spawn_id"] {
		t.Fatalf("after the refusal of a spawn naming a generation not written: %v", r)
	}
	k.release(t, spawned["spawn_id"].(string))
	k.releasedPair(t, spawned["spawn_id"].(string))
}

// Whose packs a spawn binds is decided at its claim of its place, under
// the one lock: a spawn naming another athanor's packs than its place's
// is refused and its place freed, and from a claim naming packs no assign
// gives the place another athanor, so the athanor checked is the athanor
// bound. None needs root.
func TestAClaimedPlaceKeepsItsPacksAthanor(t *testing.T) {
	me := os.Getuid()
	kept := &home.Kept{Root: t.TempDir(), First: me, Last: me}
	s, c, replies := channelServer(t, kept)
	s.packs = packview.New(filepath.Join(kept.Root, packview.DirName))
	handle := func(line string) map[string]any {
		t.Helper()
		s.handle(c, parsed(t, line))
		got, _, err := replies.Next()
		if err != nil {
			t.Fatal(err)
		}
		var m map[string]any
		_ = json.Unmarshal(got, &m)
		return m
	}
	packs := &protocol.SpawnPacks{Athanor: testAthanor, Digest: setDigest("claim")}
	if r := handle(`{"v":7,"type":"place","id":"p1","kind":"program","athanor":"` + testAthanor + `"}`); r["type"] != protocol.TypePlaced {
		t.Fatalf("place: %v", r)
	}
	if got, _ := s.claimPlace(c, &protocol.Request{Place: "p1", Packs: packs}); got != claimed {
		t.Fatalf("a claim naming its place's athanor's packs: %v", got)
	}
	if r := handle(`{"v":7,"type":"assign","id":"a1","place":"p1","kind":"program","athanor":"ath_other"}`); r["type"] != protocol.TypeError || r["code"] != protocol.CodeBadRequest {
		t.Fatalf("an assign of another athanor to a place whose spawn binds packs: %v", r)
	}
	s.mu.Lock()
	whose := c.places["p1"].whose.Athanor
	s.mu.Unlock()
	if whose != testAthanor {
		t.Fatalf("the place is %s's", whose)
	}
	if r := handle(`{"v":7,"type":"assign","id":"a2","place":"p1","kind":"program","athanor":"` + testAthanor + `","subject":"prg_2"}`); r["type"] != protocol.TypeAssigned {
		t.Fatalf("an assign keeping the athanor: %v", r)
	}

	if r := handle(`{"v":7,"type":"place","id":"p2","kind":"program","athanor":"ath_other"}`); r["type"] != protocol.TypePlaced {
		t.Fatalf("place: %v", r)
	}
	if got, _ := s.claimPlace(c, &protocol.Request{Place: "p2", Packs: packs}); got != claimOthersPacks {
		t.Fatalf("a claim naming another athanor's packs: %v", got)
	}
	s.mu.Lock()
	_, held := c.places["p2"]
	s.mu.Unlock()
	if held {
		t.Fatal("a place whose claim named another athanor's packs stays")
	}
}

// A generation goes with its place's final release: while processes of a
// spawn outlive its group's removal, which is retried, its place and its
// generation stay through another start's hold, and the retry that removes
// the group lets it go.
func TestAGenerationGoesWithItsPlacesFinalRelease(t *testing.T) {
	k := keptKeeper(t)
	store := packview.New(filepath.Join(k.s.cfg.Kept.Root, packview.DirName))
	k.s.packs = store
	uid := testKeptFirst
	path := filepath.Join(k.s.cfg.Kept.Root, "vlt_final")
	if made := k.homeRequest(t, protocol.TypeHomeMake, "m1", path, uid); made["type"] != protocol.TypeHomeMade {
		t.Fatalf("home_make: %v", made)
	}
	// The generation is on disk and held by no hold: only the spawn holds it.
	digest := setDigest("final")
	gen := store.Path(testAthanor, digest)
	if err := os.MkdirAll(filepath.Join(gen, "p"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(gen, "p", "a"), []byte("a\n"), 0o444); err != nil {
		t.Fatal(err)
	}
	for _, d := range []string{store.Dir(), filepath.Dir(gen)} {
		_ = os.Chmod(d, 0o711)
	}
	k.s.handle(k.c, parsed(t, `{"v":7,"type":"place","id":"k1","kind":"program","athanor":"`+testAthanor+`"}`))
	if placed := k.reply(t); placed["type"] != protocol.TypePlaced {
		t.Fatalf("place: %v", placed)
	}
	req := keptRequest(t, k.attach, "k1", `cat /run/cyfr/scrolls/p/a; echo ready; sleep 60`, path, nil)
	req.Packs = &protocol.SpawnPacks{Athanor: testAthanor, Digest: digest}
	k.s.handleSpawn(k.c, req)
	spawned := k.reply(t)
	if spawned["type"] != protocol.TypeSpawned {
		t.Fatalf("spawn: %v", spawned)
	}
	spawnID := spawned["spawn_id"].(string)
	rc := k.accept(t)
	rc.readUntil(t, func() bool { return strings.Contains(string(rc.got[frame.StreamStdout]), "ready\n") })
	k.s.mu.Lock()
	sp := k.s.spawns[spawnID]
	k.s.mu.Unlock()

	allow := removalRefused(t)
	k.release(t, spawnID)
	awaitRetired(t, sp)
	if told := k.toldSoFar(t); len(told) != 1 || told[0]["type"] != protocol.TypeExited {
		t.Fatalf("a spawn whose group stays was told %v; want its exit and no release", told)
	}
	hold := func(lifetime, d string) map[string]any {
		t.Helper()
		k.s.handle(k.c, packsLine(t, map[string]any{"type": protocol.TypePacksHold, "id": "h", "athanor": testAthanor, "lifetime": lifetime, "digest": d}))
		return k.reply(t)
	}
	if r := hold("lt_2", setDigest("other")); r["state"] != protocol.PacksMissing {
		t.Fatalf("another start's hold: %v", r)
	}
	if _, err := os.Stat(filepath.Join(gen, "p", "a")); err != nil {
		t.Fatalf("the generation of a spawn whose group stays went at another start's hold: %v", err)
	}

	allow()
	k.s.retryRemovals()()
	if r := k.reply(t); r["type"] != protocol.TypeReleased || r["spawn_id"] != spawnID {
		t.Fatalf("the retry that removed the group told %v", r)
	}
	if r := hold("lt_3", setDigest("other")); r["state"] != protocol.PacksMissing {
		t.Fatalf("the next hold: %v", r)
	}
	if _, err := os.Stat(gen); !os.IsNotExist(err) {
		t.Fatalf("the generation outlived its place's final release: %v", err)
	}
}
