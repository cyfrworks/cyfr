// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"archive/tar"
	"bytes"
	"context"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"
)

// shortLog is the fake docker's log with each run through the stack as
// "STACK read|write PROGRAM ARGS", its mounts and flags left out
// (TestTheRestoreWritesThroughTheStack holds them), and a removal of one's
// container as "rm --force NAME".
func (r *restoreScenario) shortLog() []string {
	name := regexp.MustCompile(`cyfr-(snapshot-read|restore-write)-[0-9a-f]{12}`)
	var log []string
	for _, line := range r.log() {
		kind := "read"
		if strings.Contains(line, "cyfr-restore-write-") {
			kind = "write"
		}
		switch {
		case strings.HasPrefix(line, "rm --force cyfr-"):
			line = "rm --force NAME"
		case strings.HasPrefix(line, "run --rm --name cyfr-") && name.MatchString(line):
			_, rest, _ := strings.Cut(line, " --entrypoint ")
			program, _, _ := strings.Cut(rest, " ")
			_, args, _ := strings.Cut(rest, " "+stackImage+" ")
			line = strings.TrimSpace("STACK " + kind + " " + program + " " + args)
		}
		log = append(log, line)
	}
	return log
}

// stackWrites are the scenario's runs through the stack that write, in
// order, each container's name as NAME.
func (r *restoreScenario) stackWrites() []string {
	var writes []string
	for _, line := range r.namedLog() {
		if strings.HasPrefix(line, "run ") && strings.Contains(line, " --name NAME ") && strings.Contains(line, "DAC_OVERRIDE") {
			writes = append(writes, line)
		}
	}
	return writes
}

// writableIn answers the targets a run through the stack mounts
// writable.
func writableIn(line string) []string {
	var out []string
	for _, field := range strings.Split(line, " --mount ")[1:] {
		spec, _, _ := strings.Cut(field, " ")
		if strings.HasSuffix(spec, ",readonly") {
			continue
		}
		_, target, _ := strings.Cut(spec, ",target=")
		out = append(out, target)
	}
	return out
}

// The put-back writes the storage and the database through one-off
// containers of the restored service's image, as the read does but for
// what it writes, holding no capability but writing past permissions,
// never pulling, with no network or log, every mount of the service read
// only but those that write writes: the clear and the storage's archive
// the storage root's bind and one under it, the database's writes (its
// staged file and log, their sync, the old log's and index's removal, the
// renames, the folder's sync) the bind the database lies on; one outside
// the storage stays read only throughout. Each asks that its container
// not outlive it.
func TestTheRestoreWritesThroughTheStack(t *testing.T) {
	nested, extra := t.TempDir(), t.TempDir()
	r := newRestoreScenario(t, shippedCompose(t), nil, func(s *updateScenario) {
		s.addVolume(map[string]any{"type": "bind", "source": nested, "target": "/app/data/components"})
		s.addVolume(map[string]any{"type": "bind", "source": extra, "target": "/app/extra"})
	})
	if out, err := r.restore(false); err != nil {
		t.Fatalf("restore: %v\n%s", err, out)
	}
	head := "run --rm --name NAME --pull never --network none --log-driver none --user 0:0 --cap-drop ALL --cap-add DAC_OVERRIDE --security-opt no-new-privileges --read-only"
	mounts := func(storage bool) string {
		ro := map[bool]string{true: "", false: ",readonly"}
		return " --mount type=bind,source=" + filepath.Join(r.project, "data") + ",target=/app/data" +
			" --mount type=bind,source=" + filepath.Join(r.project, "aqua") + ",target=/app/seed/aqua,readonly" +
			" --mount type=bind,source=" + nested + ",target=/app/data/components" + ro[storage] +
			" --mount type=bind,source=" + extra + ",target=/app/extra,readonly " + stackImage
	}
	tarArgs := " -x -f - -C /app/data --no-same-owner --no-overwrite-dir"
	want := []string{
		head + " -i --entrypoint xargs" + mounts(true) + " -0 -r rm -rf --",
		head + " -i --entrypoint tar" + mounts(true) + tarArgs,
		head + " -i --entrypoint tar" + mounts(false) + tarArgs,
		head + " --entrypoint sync" + mounts(false) + " -- /app/data/.cyfr.db.restore /app/data/.cyfr.db-wal.restore",
		head + " --entrypoint rm" + mounts(false) + " -f -- /app/data/cyfr.db-shm /app/data/cyfr.db-wal",
		head + " --entrypoint mv" + mounts(false) + " -f -T -- /app/data/.cyfr.db.restore /app/data/cyfr.db",
		head + " --entrypoint mv" + mounts(false) + " -f -T -- /app/data/.cyfr.db-wal.restore /app/data/cyfr.db-wal",
		head + " --entrypoint sync" + mounts(false) + " -- /app/data",
	}
	if got := r.stackWrites(); !slices.Equal(got, want) {
		t.Errorf("the put-back wrote with\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	for _, c := range r.engine.calls {
		name := ""
		if i := slices.Index(c.Args, "--name"); i >= 0 && stackReadCall(c.Args) {
			name = c.Args[i+1]
		}
		if c.RemoveOnEnd != name {
			t.Errorf("docker %s asks to remove %q, want %q", strings.Join(c.Args, " "), c.RemoveOnEnd, name)
		}
	}
}

// With the database on a bind of its own beside the storage, the clear
// and the storage's archive write the storage alone, and the database's
// writes the database's bind alone.
func TestEachWriteThroughTheStackWritesOnlyItsOwnPlace(t *testing.T) {
	dbdir := t.TempDir()
	r := newRestoreScenario(t, shippedCompose(t), map[string]string{"CYFR_DATABASE_PATH": "/db/cyfr.db"}, func(s *updateScenario) {
		s.addVolume(map[string]any{"type": "bind", "source": dbdir, "target": "/db"})
		if err := os.WriteFile(filepath.Join(dbdir, "cyfr.db"), []byte(sqliteBytes), 0o644); err != nil {
			t.Fatal(err)
		}
	})
	r.answer("eval.db", filepath.Join(dbdir, "cyfr.db"))
	if out, err := r.restore(true); err != nil {
		t.Fatalf("restore: %v\n%s", err, out)
	}
	writes := r.stackWrites()
	if len(writes) == 0 {
		t.Fatal("nothing was written through the stack")
	}
	for _, line := range writes {
		want := []string{"/db"}
		if strings.Contains(line, "--entrypoint xargs") || strings.Contains(line, "-C /app/data ") {
			want = []string{"/app/data"}
		}
		if got := writableIn(line); !slices.Equal(got, want) {
			t.Errorf("%s\nmounts %v writable, want %v", line, got, want)
		}
	}
	if got := read(t, filepath.Join(dbdir, "cyfr.db")); got != sqliteBytes {
		t.Errorf("the database holds %q", got)
	}
}

// The clear's list is cyfr's, computed from the stack's listing: every
// entry under the storage root, each tree once by its topmost entry, but
// never a mount's target, a directory on the way to one or to a kept
// entry, the database's files or the engine's state (each with all
// beneath it), by which file they are; names with spaces, line breaks and
// leading dashes are entries like any other, and a link is removed as
// itself.
func TestTheClearListsOnlyWhatTheRestorePutsBack(t *testing.T) {
	entry := func(p string, kind byte, id string) stackEntry { return stackEntry{path: p, kind: kind, id: id} }
	listing := []stackEntry{
		entry("/app/data", 'd', "1"),
		entry("/app/data/blobs", 'd', "2"),
		entry("/app/data/blobs/x", 'f', "3"),
		entry("/app/data/with space", 'f', "4"),
		entry("/app/data/line\nbreak", 'f', "5"),
		entry("/app/data/-dash", 'f', "6"),
		entry("/app/data/out", 'l', "7"),
		entry("/app/data/cyfr.db", 'f', "db"),
		entry("/app/data/cyfr.db-wal", 'f', "wal"),
		entry("/app/data/other-name.db", 'f', "db"),
		entry("/app/data/deep", 'd', "8"),
		entry("/app/data/deep/mount", 'd', "9"),
		entry("/app/data/deep/mount/inside", 'f', "10"),
		entry("/app/data/deep/beside", 'f', "11"),
		entry("/app/data/file-mount", 'f', "12"),
		entry("/app/data/state", 'd', "state"),
		entry("/app/data/state/lock", 'f', "13"),
		entry("/app/data/keep", 'd', "14"),
		entry("/app/data/keep/live.db", 'f', "db2"),
		entry("/app/data/keep/old", 'f', "15"),
	}
	w := &restoreWrite{
		targets: map[string]byte{"/app/data/deep/mount": 'd', "/app/data/file-mount": 'f'},
		walls:   map[string]bool{"/app/data": true, "/app/data/deep": true, "/app/data/keep": true},
		kept:    []string{"/app/data/cyfr.db", "/app/data/cyfr.db-wal", "/app/data/other-name.db", "/app/data/state", "/app/data/keep/live.db"},
	}
	got := clearList(listing, "/app/data", w)
	want := []string{"/app/data/blobs", "/app/data/with space", "/app/data/line\nbreak", "/app/data/-dash", "/app/data/out", "/app/data/deep/mount/inside", "/app/data/deep/beside", "/app/data/keep/old"}
	if !slices.Equal(got, want) {
		t.Errorf("the clear lists\n%q\nwant\n%q", got, want)
	}
}

// snapshotStorage makes a snapshot's storage/ of entries: "" a directory,
// "-> target" a link, anything else a file of those bytes.
func snapshotStorage(t *testing.T, entries map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	names := slices.Sorted(func(yield func(string) bool) {
		for name := range entries {
			if !yield(name) {
				return
			}
		}
	})
	for _, name := range names {
		p := filepath.Join(dir, filepath.FromSlash(name))
		content := entries[name]
		var err error
		switch {
		case content == "":
			err = os.MkdirAll(p, 0o755)
		case strings.HasPrefix(content, "-> "):
			err = os.Symlink(strings.TrimPrefix(content, "-> "), p)
		default:
			if err = os.MkdirAll(filepath.Dir(p), 0o755); err == nil {
				err = os.WriteFile(p, []byte(content), 0o644)
			}
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// The stream cyfr builds from the snapshot's storage, which the person may
// have edited, lands in the storage root alone, before tar's own guard: a
// link planted in storage/ goes as the link it is, with nothing under it,
// every name relative, clean and under a directory the stream or the root
// holds before it, files 0600, directories 0700, all root's; a mount that
// is one file is left to be written in place. A file where a folder must
// be, an entry where the database's files or the engine's state lie, or a
// kind of entry other than a mount's at its place refuses the stream.
func TestTheStreamCyfrBuildsLandsInTheStorageAlone(t *testing.T) {
	outside := t.TempDir()
	w := &restoreWrite{
		targets: map[string]byte{"/app/data/components": 'd', "/app/data/single": 'f'},
		walls:   map[string]bool{"/app/data": true, "/app/data/db": true},
		kept:    []string{"/app/data/db/cyfr.db", "/app/data/db/cyfr.db-wal", "/app/data/db/cyfr.db-shm", "/app/data/state"},
	}
	src := snapshotStorage(t, map[string]string{
		"blobs/x":          "blob",
		"planted":          "-> " + outside,
		"components/c":     "component",
		"single":           "one file",
		"db/beside":        "beside the database",
		"climb":            "-> ../../etc",
		"-dash/with space": "odd names",
	})
	root, err := os.OpenRoot(src)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	var buf bytes.Buffer
	var inPlace []string
	if err := w.storageArchive(&buf, root, "/app/data", io.Discard, &inPlace); err != nil {
		t.Fatalf("the stream refused %v", err)
	}
	if !slices.Equal(inPlace, []string{"single"}) {
		t.Errorf("written in place: %v, want [single]", inPlace)
	}
	tr := tar.NewReader(&buf)
	dirs := map[string]bool{".": true, "db": true}
	var names []string
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		name := strings.TrimSuffix(h.Name, "/")
		names = append(names, name)
		if !fs.ValidPath(name) || !dirs[filepath.ToSlash(filepath.Dir(name))] {
			t.Errorf("%q lies in no directory the stream or the root holds before it", h.Name)
		}
		if h.Uid != 0 || h.Gid != 0 {
			t.Errorf("%s is owned by %d:%d", h.Name, h.Uid, h.Gid)
		}
		switch h.Typeflag {
		case tar.TypeDir:
			dirs[name] = true
			if h.Mode != 0o700 {
				t.Errorf("%s is %o", h.Name, h.Mode)
			}
		case tar.TypeReg:
			if h.Mode != 0o600 {
				t.Errorf("%s is %o", h.Name, h.Mode)
			}
		case tar.TypeSymlink:
		default:
			t.Errorf("%s is of type %c", h.Name, h.Typeflag)
		}
	}
	want := []string{"-dash", "-dash/with space", "blobs", "blobs/x", "climb", "components", "components/c", "db", "db/beside", "planted"}
	if !slices.Equal(names, want) {
		t.Errorf("the stream holds %q, want %q", names, want)
	}

	for _, c := range []struct {
		name    string
		entries map[string]string
		says    string
	}{
		{"a file where a folder is", map[string]string{"db": "a file"}, "The snapshot's storage holds db, which is not a directory, where the storage holds one"},
		{"a link where a folder is", map[string]string{"db": "-> " + outside}, "The snapshot's storage holds db, which is not a directory, where the storage holds one"},
		{"a file at a folder mount", map[string]string{"components": "a file"}, "The snapshot's storage holds components, which is not a directory, where a mount of the cyfr service is one"},
		{"a link at a file mount", map[string]string{"single": "-> " + outside}, "The snapshot's storage holds single, which is not a file, where a mount of the cyfr service is one"},
		{"the database", map[string]string{"db/cyfr.db": "another database"}, "The snapshot's storage holds db/cyfr.db, where the database's files or the access engine's state lie"},
		{"under the state", map[string]string{"state/lock": "a lock"}, "The snapshot's storage holds state, where the database's files or the access engine's state lie"},
	} {
		t.Run(c.name, func(t *testing.T) {
			root, err := os.OpenRoot(snapshotStorage(t, c.entries))
			if err != nil {
				t.Fatal(err)
			}
			defer root.Close()
			err = w.storageArchive(io.Discard, root, "/app/data", io.Discard, new([]string))
			if err == nil || !strings.HasPrefix(err.Error(), c.says) {
				t.Errorf("the stream answered %v, want %q", err, c.says)
			}
		})
	}
}

// A snapshot whose storage would write where the put-back must not, a
// link planted where the database's folder is, is refused once the stack
// is stopped, before any part is put back.
func TestRestoreRefusesAStorageThatWouldWriteThroughALink(t *testing.T) {
	outside := t.TempDir()
	r := newRestoreScenario(t, shippedCompose(t), map[string]string{"CYFR_DATABASE_PATH": "/app/data/db/cyfr.db"}, func(s *updateScenario) {
		s.edit("data/db/cyfr.db", sqliteBytes)
	})
	r.edit("data/blobs/x", "rewritten")
	db := filepath.Join(r.dir, "storage", "db")
	if err := os.RemoveAll(db); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, db); err != nil {
		t.Fatal(err)
	}
	before := read(t, filepath.Join(r.project, "docker-compose.yml"))
	out, err := r.restore(true)
	if err == nil || !strings.Contains(err.Error(), "The snapshot's storage holds db, which is not a directory, where the storage holds one") || !strings.Contains(err.Error(), "nothing of the snapshot was put back") {
		t.Fatalf("restore answered %v\n%s", err, out)
	}
	r.stoppedUndeclared()
	r.configAsBefore(before, string(r.live))
	if got := read(t, filepath.Join(r.project, "data", "blobs", "x")); got != "rewritten" {
		t.Errorf("a part was put back: blobs/x holds %q", got)
	}
	if writes := r.stackWrites(); len(writes) > 0 {
		t.Errorf("the refused restore wrote:\n%s", strings.Join(writes, "\n"))
	}
	if entries, _ := os.ReadDir(outside); len(entries) > 0 {
		t.Errorf("behind the link: %v", entries)
	}
}

// storageIs fails unless the scenario's data/ holds what the snapshot it
// took holds of the storage and the database, nothing else of the
// storage, as main's put-back left it.
func (r *restoreScenario) storageIs(extra map[string]string) {
	r.t.Helper()
	want := map[string]string{
		"blobs": "", "blobs/x": "blob", "components": "", "components/acme": "", "components/acme/c.wasm": "component-bytes",
		"current": "-> components/acme", "cyfr.db": sqliteBytes, "cyfr.db-wal": "sqlite-wal",
	}
	for k, v := range extra {
		if v == "<absent>" {
			delete(want, k)
			continue
		}
		want[k] = v
	}
	got := map[string]string{}
	data := filepath.Join(r.project, "data")
	filepath.WalkDir(data, func(p string, d fs.DirEntry, err error) error {
		if err != nil || p == data {
			return nil
		}
		rel, _ := filepath.Rel(data, p)
		switch {
		case d.IsDir():
			got[filepath.ToSlash(rel)] = ""
		case d.Type()&fs.ModeSymlink != 0:
			link, _ := os.Readlink(p)
			got[filepath.ToSlash(rel)] = "-> " + link
		default:
			b, _ := os.ReadFile(p)
			got[filepath.ToSlash(rel)] = string(b)
		}
		return nil
	})
	if !mapsEqual(got, want) {
		r.t.Errorf("data/ holds\n%q\nwant\n%q", got, want)
	}
}

func mapsEqual(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if w, ok := b[k]; !ok || w != v {
			return false
		}
	}
	return true
}

// Between the clear and the last write the storage is half made: a helper
// killed after the clear, in the middle of the storage or before the
// database ends the restore with the stack stopped and barred, its
// container removed, and the same restore run again puts every part back,
// whole.
func TestARestoreWhoseHelperIsKilledPutsEveryPartBackWhenRunAgain(t *testing.T) {
	for _, c := range []struct{ name, kill string }{
		{"after the clear", "2 x"},
		{"in the middle of the storage", "2 3"},
		{"before the database", "3 x"},
		// The staged database half written: the one in place is the old
		// one, whole.
		{"in the middle of the database", "3 0"},
	} {
		t.Run(c.name, func(t *testing.T) {
			r := newRestoreScenario(t, shippedCompose(t), nil, nil)
			r.edit("data/blobs/x", "rewritten")
			r.edit("data/blobs/new", "written after the snapshot")
			r.edit("data/cyfr.db", migratedDatabase)
			r.edit("data/cyfr.db-shm", "migrated shm")
			r.answer("write.kill", c.kill)
			out, err := r.restore(true)
			if err == nil || !strings.Contains(err.Error(), "Putting the snapshot back failed") || !strings.Contains(err.Error(), "run 'cyfr restore "+r.dir+"' again, which puts every part back from the start") {
				t.Fatalf("restore answered %v\n%s", err, out)
			}
			r.barred()
			if !slices.Contains(r.shortLog(), "rm --force NAME") {
				t.Errorf("the killed helper's container was not removed:\n%s", strings.Join(r.shortLog(), "\n"))
			}
			if got := read(t, filepath.Join(r.project, "data", "cyfr.db")); got != migratedDatabase && got != sqliteBytes {
				t.Errorf("the killed restore left the database %q, neither the old one nor the new one", got)
			}
			for _, name := range []string{"write.kill", "write.count"} {
				os.Remove(filepath.Join(r.fake, name))
			}
			if out, err := r.restore(true); err != nil {
				t.Fatalf("the restore run again: %v\n%s", err, out)
			}
			if _, barred := restoreBarred(filepath.Join(r.project, ".env")); barred {
				t.Errorf("the restore run again left the bar up")
			}
			r.storageIs(nil)
		})
	}
}

// A write that takes nothing for the stall bound is ended, its container
// removed, and the restore fails with the stack stopped and barred.
func TestARestoreWhoseWriteStallsIsEnded(t *testing.T) {
	saved := stackReadStall
	stackReadStall = 300 * time.Millisecond
	t.Cleanup(func() { stackReadStall = saved })
	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	r.answer("write.stall", "")
	out, err := r.restore(true)
	if err == nil || !strings.Contains(err.Error(), "the stack's write of its storage made no progress for 300ms, so it was ended") {
		t.Fatalf("restore answered %v\n%s", err, out)
	}
	r.barred()
	if !slices.Contains(r.shortLog(), "rm --force NAME") {
		t.Errorf("the stalled helper's container was not removed:\n%s", strings.Join(r.shortLog(), "\n"))
	}
}

// A restore onto a machine without the snapshot's image says so and pulls
// it before anything is put back; a pull that fails refuses with nothing
// of the snapshot put back and the two files as they were.
func TestRestorePullsTheSnapshotsImageWhenItIsNotThere(t *testing.T) {
	t.Run("pulled", func(t *testing.T) {
		r := newRestoreScenario(t, shippedCompose(t), nil, nil)
		r.answer("image.exit", "1")
		out, err := r.restore(true)
		if err != nil {
			t.Fatalf("restore: %v\n%s", err, out)
		}
		if !strings.Contains(out, "The snapshot's image "+stackImage+" is not on this machine; pulling it...") {
			t.Errorf("the restore did not say it pulls:\n%s", out)
		}
		log := r.shortLog()
		pulled, wrote := slices.Index(log, "pull "+stackImage), slices.IndexFunc(log, func(l string) bool { return strings.HasPrefix(l, "STACK ") })
		if pulled < 0 || wrote < pulled {
			t.Errorf("the image was not pulled before the stack ran:\n%s", strings.Join(log, "\n"))
		}
	})
	t.Run("refused", func(t *testing.T) {
		r := newRestoreScenario(t, shippedCompose(t), nil, nil)
		r.edit("data/blobs/x", "rewritten")
		r.answer("image.exit", "1")
		r.answer("pull.exit", "1")
		before := read(t, filepath.Join(r.project, "docker-compose.yml"))
		out, err := r.restore(true)
		if err == nil || !strings.Contains(err.Error(), "docker pull "+stackImage+" failed") || !strings.Contains(err.Error(), "nothing of the snapshot was put back") {
			t.Fatalf("restore answered %v\n%s", err, out)
		}
		r.stoppedUndeclared()
		r.configAsBefore(before, string(r.live))
		if got := read(t, filepath.Join(r.project, "data", "blobs", "x")); got != "rewritten" {
			t.Errorf("a part was put back: blobs/x holds %q", got)
		}
	})
}

// A restore onto a project with no data/ yet, as on a new machine, makes
// the storage root's source as the person, and a nested bind's source and
// its mount point in the root, and puts every part back.
func TestRestoreMakesAMissingStorageRoot(t *testing.T) {
	nested := filepath.Join(t.TempDir(), "components")
	r := newRestoreScenario(t, shippedCompose(t), nil, func(s *updateScenario) {
		if err := os.Rename(filepath.Join(s.project, "data", "components"), nested); err != nil {
			t.Fatal(err)
		}
		if err := os.Mkdir(filepath.Join(s.project, "data", "components"), 0o755); err != nil {
			t.Fatal(err)
		}
		s.addVolume(map[string]any{"type": "bind", "source": nested, "target": "/app/data/components"})
	})
	for _, dir := range []string{filepath.Join(r.project, "data"), nested} {
		if err := os.RemoveAll(dir); err != nil {
			t.Fatal(err)
		}
	}
	out, err := r.restore(true)
	if err != nil {
		t.Fatalf("restore: %v\n%s", err, out)
	}
	if !strings.Contains(out, "No database is at /app/data/cyfr.db yet") {
		t.Errorf("the restore did not say no database is there:\n%s", out)
	}
	r.storageIs(map[string]string{"components/acme": "<absent>", "components/acme/c.wasm": "<absent>"})
	if got := read(t, filepath.Join(nested, "acme", "c.wasm")); got != "component-bytes" {
		t.Errorf("the nested bind holds %q", got)
	}
}

// The database reached through a second bind of the storage's own folder
// is kept out of the clear by which file it is, and put back once at the
// place the service opens it; so is the engine's state linked into data/.
func TestRestoreKeepsTheDatabaseAndTheStateWhereverTheyAreMounted(t *testing.T) {
	t.Run("the database", func(t *testing.T) {
		r := newRestoreScenario(t, shippedCompose(t), map[string]string{"CYFR_DATABASE_PATH": "/db/cyfr.db"}, func(s *updateScenario) {
			s.addVolume(map[string]any{"type": "bind", "source": filepath.Join(s.project, "data"), "target": "/db"})
		})
		r.edit("data/cyfr.db", migratedDatabase)
		if out, err := r.restore(true); err != nil {
			t.Fatalf("restore: %v\n%s", err, out)
		}
		for _, line := range r.shortLog() {
			if strings.HasPrefix(line, "STACK write rm") && strings.Contains(line, "/app/data/cyfr.db") {
				t.Errorf("the restore removed the database through the storage's spelling: %s", line)
			}
		}
		if list := read(t, filepath.Join(r.fake, "clear.list")); strings.Contains(list, "cyfr.db") {
			t.Errorf("the clear listed the database's files: %q", list)
		}
		r.storageIs(nil)
	})
	t.Run("the state", func(t *testing.T) {
		r := newRestoreScenario(t, shippedCompose(t), nil, func(s *updateScenario) {
			s.edit(".cyfr/sub/state", "at the snapshot")
			// Its mount point in data/, as the stack's start made it.
			if err := os.Mkdir(filepath.Join(s.project, "data", "sub"), 0o755); err != nil {
				t.Fatal(err)
			}
			s.addVolume(map[string]any{"type": "bind", "source": filepath.Join(s.project, ".cyfr", "sub"), "target": "/app/data/sub"})
		})
		if _, err := os.Lstat(filepath.Join(r.dir, "storage", "sub")); err == nil {
			t.Errorf("the snapshot holds the engine's state bound at /app/data/sub")
		}
		r.edit(".cyfr/sub/state", "written since")
		if out, err := r.restore(true); err != nil {
			t.Fatalf("restore: %v\n%s", err, out)
		}
		if got := read(t, filepath.Join(r.project, ".cyfr", "sub", "state")); got != "written since" {
			t.Errorf("the engine's state under .cyfr/sub holds %q", got)
		}
		if list := read(t, filepath.Join(r.fake, "clear.list")); strings.Contains(list, "/app/data/sub") {
			t.Errorf("the clear listed the engine's state: %q", list)
		}
	})
}

// A database on a file bind of its own is written in place, its mount
// point not being a thing to rename over; a restore killed half way
// through it leaves it half written, and the same restore run again finds
// the bar it left, says the database does not answer for its live slots,
// and puts it back whole.
func TestARestoreKilledInADatabaseWrittenInPlacePutsItBackWhenRunAgain(t *testing.T) {
	r := newRestoreScenario(t, shippedCompose(t), map[string]string{"CYFR_DATABASE_PATH": "/db/main.db", "CYFR_STORAGE": "s3"}, func(s *updateScenario) {
		for _, suffix := range []string{"", "-wal"} {
			s.addVolume(map[string]any{"type": "bind", "source": filepath.Join(s.project, "data", "cyfr.db"+suffix), "target": "/db/main.db" + suffix})
		}
	})
	r.edit("data/cyfr.db", migratedDatabase)
	r.answer("write.kill", "@of=/db/main.db bs 0")
	out, err := r.restore(true)
	if err == nil || !strings.Contains(err.Error(), "Putting the snapshot back failed") {
		t.Fatalf("restore answered %v\n%s", err, out)
	}
	r.barred()
	if got := read(t, filepath.Join(r.project, "data", "cyfr.db")); got != sqliteBytes[:len(sqliteBytes)/2] {
		t.Fatalf("the killed write left the database %q, not half written:\n%s\n%s", got, out, strings.Join(r.shortLog(), "\n"))
	}
	out, err = r.restore(true)
	if err != nil {
		t.Fatalf("the restore run again: %v\n%s", err, out)
	}
	if !strings.Contains(out, "The SQLite database at /db/main.db does not answer for its live slots") {
		t.Errorf("the restore run again did not say why it went on:\n%s", out)
	}
	if got := read(t, filepath.Join(r.project, "data", "cyfr.db")); got != sqliteBytes {
		t.Errorf("the restore run again left the database %q", got)
	}
}

// A database that does not answer for its live slots still refuses a
// restore that did not find the bar up: only a restore cut short may have
// left it so.
func TestADatabaseThatDoesNotAnswerRefusesARestoreNotCutShort(t *testing.T) {
	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	r.edit("data/cyfr.db", "not a database")
	before := read(t, filepath.Join(r.project, "docker-compose.yml"))
	out, err := r.restore(true)
	if err == nil || !strings.Contains(err.Error(), "The offline roster read") || !strings.Contains(err.Error(), "nothing of the snapshot was put back") {
		t.Fatalf("restore answered %v\n%s", err, out)
	}
	r.stoppedUndeclared()
	r.configAsBefore(before, string(r.live))
}

// An empty file is no database: a restore onto a new machine whose
// database's file bind has no source yet makes it, as the person, and
// says no database is there yet instead of reading live slots out of it;
// for a database on a bind of its own, and for one on a file bind under
// the storage root, whose mount point is made the same way.
func TestARestoreOntoANewMachineReadsNoDatabaseOutOfAnEmptyFile(t *testing.T) {
	t.Run("on a bind of its own", func(t *testing.T) {
		r := newRestoreScenario(t, shippedCompose(t), map[string]string{"CYFR_DATABASE_PATH": "/db/main.db", "CYFR_STORAGE": "s3"}, func(s *updateScenario) {
			for _, suffix := range []string{"", "-wal"} {
				s.addVolume(map[string]any{"type": "bind", "source": filepath.Join(s.project, "data", "cyfr.db"+suffix), "target": "/db/main.db" + suffix})
			}
		})
		for _, suffix := range []string{"", "-wal", "-shm"} {
			os.Remove(filepath.Join(r.project, "data", "cyfr.db"+suffix))
		}
		out, err := r.restore(true)
		if err != nil {
			t.Fatalf("restore: %v\n%s", err, out)
		}
		if !strings.Contains(out, "No database is at /db/main.db yet") {
			t.Errorf("the restore read live slots from the empty file it made itself:\n%s", out)
		}
		if got := read(t, filepath.Join(r.project, "data", "cyfr.db")); got != sqliteBytes {
			t.Errorf("the database holds %q", got)
		}
	})
	t.Run("on a file bind under the storage root", func(t *testing.T) {
		db := filepath.Join(t.TempDir(), "cyfr.db")
		r := newRestoreScenario(t, shippedCompose(t), nil, func(s *updateScenario) {
			if err := os.Rename(filepath.Join(s.project, "data", "cyfr.db"), db); err != nil {
				t.Fatal(err)
			}
			// Its mount point in data/, as the stack's start made it.
			s.edit("data/cyfr.db", "")
			s.addVolume(map[string]any{"type": "bind", "source": db, "target": "/app/data/cyfr.db"})
		})
		r.answer("eval.db", db)
		for _, p := range []string{filepath.Join(r.project, "data"), db} {
			if err := os.RemoveAll(p); err != nil {
				t.Fatal(err)
			}
		}
		out, err := r.restore(true)
		if err != nil {
			t.Fatalf("restore: %v\n%s", err, out)
		}
		if !strings.Contains(out, "No database is at /app/data/cyfr.db yet") {
			t.Errorf("the restore read live slots from the empty file it made itself:\n%s", out)
		}
		if got := read(t, db); got != sqliteBytes {
			t.Errorf("the database holds %q", got)
		}
	})
}

// trickle gives n bytes, one every d.
type trickle struct {
	n int
	d time.Duration
}

func (t *trickle) Read(b []byte) (int, error) {
	if t.n == 0 {
		return 0, io.EOF
	}
	time.Sleep(t.d) // sleep-ok: a standard input that comes slowly is what the test is of
	t.n--
	b[0] = 'x'
	return 1, nil
}

// A write that keeps taking its standard input but gives nothing back, as
// tar writing the storage does, is not ended as stalled: the bytes it
// takes are its progress.
func TestAWriteThatTakesItsInputIsNotStalled(t *testing.T) {
	saved := stackReadStall
	stackReadStall = 300 * time.Millisecond
	t.Cleanup(func() { stackReadStall = saved })
	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	e, err := openEngine(r.project)
	if err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	u := &updater{ctx: context.Background(), command: "restore", out: &out, errOut: &out, engine: e, config: &stackConfig{
		image: stackImage, mounts: []composeMount{{Type: "bind", Source: filepath.Join(r.project, "data"), Target: "/app/data"}},
	}}
	err = u.runStack(context.Background(), stackCall{stdin: &trickle{n: 30, d: 50 * time.Millisecond}, writable: []string{"/app/data"}}, "dd", "of=/app/data/slow", "bs=1M", "conv=fsync", "status=none")
	if err != nil {
		t.Fatalf("the slow write: %v\n%s", err, out.String())
	}
	if got := read(t, filepath.Join(r.project, "data", "slow")); got != strings.Repeat("x", 30) {
		t.Errorf("wrote %q", got)
	}
}
