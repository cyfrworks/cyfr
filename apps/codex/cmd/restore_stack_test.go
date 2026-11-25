// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"archive/tar"
	"bytes"
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

// The put-back writes the storage and the database through one-off
// containers of the restored service's image, as the read does but for
// what it writes: the binds the put-back replaces (the storage root's, one
// under it and the database's, here the root's) writable and every other
// mount of the service read only, one outside the storage among them,
// holding no capability but writing past permissions, never pulling, with
// no network or log; each asks that its container not outlive it.
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
	mounts := " --mount type=bind,source=" + filepath.Join(r.project, "data") + ",target=/app/data" +
		" --mount type=bind,source=" + filepath.Join(r.project, "aqua") + ",target=/app/seed/aqua,readonly" +
		" --mount type=bind,source=" + nested + ",target=/app/data/components" +
		" --mount type=bind,source=" + extra + ",target=/app/extra,readonly " + stackImage
	tarArgs := " -x -f - -C /app/data --no-same-owner --no-overwrite-dir"
	want := []string{
		head + " -i --entrypoint xargs" + mounts + " -0 -r rm -rf --",
		head + " -i --entrypoint tar" + mounts + tarArgs,
		head + " --entrypoint rm" + mounts + " -f -- /app/data/cyfr.db-shm /app/data/cyfr.db-wal",
		head + " -i --entrypoint tar" + mounts + tarArgs,
		head + " -i --entrypoint tar" + mounts + tarArgs,
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
		{"after the clear", "2 0"},
		{"in the middle of the storage", "2 3"},
		{"before the database", "3 0"},
	} {
		t.Run(c.name, func(t *testing.T) {
			r := newRestoreScenario(t, shippedCompose(t), nil, nil)
			r.edit("data/blobs/x", "rewritten")
			r.edit("data/blobs/new", "written after the snapshot")
			r.edit("data/cyfr.db", "migrated database")
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
		r.edit("data/cyfr.db", "migrated database")
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
}
