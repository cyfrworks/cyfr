// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"archive/tar"
	"bytes"
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"
)

// namedLog is the fake docker's log, each run through the stack's
// container name as NAME.
func (s *updateScenario) namedLog() []string {
	name := regexp.MustCompile(`cyfr-(snapshot-read|restore-write)-[0-9a-f]{12}`)
	log := s.log()
	for i := range log {
		log[i] = name.ReplaceAllString(log[i], "NAME")
	}
	return log
}

// stackReads are the scenario's reads through the stack, in order, each
// read's container name as NAME.
func (s *updateScenario) stackReads() []string {
	var reads []string
	for _, line := range s.namedLog() {
		if strings.HasPrefix(line, "run ") && strings.Contains(line, " --name NAME ") {
			reads = append(reads, line)
		}
	}
	return reads
}

// stackRun is the start of the scenario's read through the stack that
// runs program, its name NAME: every mount of the cyfr service, read only.
func (s *updateScenario) stackRun(stdin bool, program string) string {
	line := "run --rm --name NAME --pull never --network none --log-driver none --user 0:0 --cap-drop ALL --cap-add DAC_READ_SEARCH --security-opt no-new-privileges --read-only"
	if stdin {
		line += " -i"
	}
	return line + " --entrypoint " + program +
		" --mount type=bind,source=" + filepath.Join(s.project, "data") + ",target=/app/data,readonly" +
		" --mount type=bind,source=" + filepath.Join(s.project, "aqua") + ",target=/app/seed/aqua,readonly " + stackImage
}

// placeReads are the scenario's reads through the stack before the stop,
// which place the database.
func (s *updateScenario) placeReads() []string {
	return []string{
		s.stackRun(false, "realpath") + " -e -- /app/data/cyfr.db",
		s.stackRun(false, "find") + ` /app/data -maxdepth 1 -printf %D %i %y %s %p\0`,
	}
}

// snapshotReads are the scenario's reads through the stack for the
// snapshot: the storage root's listing, the database's archive and the
// storage's.
func (s *updateScenario) snapshotReads() []string {
	return []string{
		s.stackRun(false, "find") + ` /app/data -printf %D %i %y %s %p\0`,
		s.stackRun(false, "tar") + " --dereference --hard-dereference -C / -cf - -- app/data/cyfr.db app/data/cyfr.db-wal",
		s.stackRun(true, "tar") + " --hard-dereference --no-recursion --null --verbatim-files-from -C / -cf - -T -",
	}
}

// The snapshot reads the storage through one-off containers of the image
// the cyfr service runs, each mount of the service read only, never
// pulling, with no network or log, as the container's root holding no
// capability but reading past permissions, its entrypoint skipped: before
// the stop it resolves the database's links (realpath) and looks at it;
// after it, it lists the storage root, archives the database and its log,
// and archives the storage root by the list it made.
func TestTheSnapshotReadsTheStorageThroughTheStack(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.backupScaffold()
	if out, err := s.backup(); err != nil {
		t.Fatalf("cyfr backup answered %v\n%s", err, out)
	}
	want := append(s.placeReads(), s.snapshotReads()...)
	if got := s.stackReads(); !slices.Equal(got, want) {
		t.Errorf("the snapshot read the storage with\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	log := s.log()
	if placed, stopped := slices.IndexFunc(log, func(l string) bool { return strings.Contains(l, "--entrypoint realpath") }), at(log, profiles+"stop"); placed < 0 || stopped < placed {
		t.Errorf("the database was not placed before the stop:\n%s", strings.Join(log, "\n"))
	}
	// Each read asks that its container not outlive it, by the name it
	// runs under; no other call of the backup asks it.
	for _, c := range s.engine.calls {
		name := ""
		if i := slices.Index(c.Args, "--name"); i >= 0 && stackReadCall(c.Args) {
			name = c.Args[i+1]
		}
		if c.RemoveOnEnd != name {
			t.Errorf("docker %s asks to remove %q, want %q", strings.Join(c.Args, " "), c.RemoveOnEnd, name)
		}
	}
}

// archive is a tar stream of entries, each written as given.
func archive(t *testing.T, entries ...*tar.Header) string {
	t.Helper()
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	for _, h := range entries {
		if h.Typeflag == tar.TypeReg && h.Size == 0 {
			h.Size = int64(len("bytes"))
		}
		if err := tw.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
		if h.Typeflag == tar.TypeReg {
			tw.Write([]byte("bytes"))
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.String()
}

// The stream comes from storage the server and its components write, so
// it is untrusted: a name that is absolute or climbs out, an entry under
// a link the stream holds, a hard link, and an entry in no directory the
// stream made before it each fail the snapshot, writing nothing outside
// the snapshot's folder; a device or a pipe is skipped and said.
func TestTheSnapshotRefusesAStreamThatLeavesItsFolder(t *testing.T) {
	root := &tar.Header{Name: "app/data/", Typeflag: tar.TypeDir, Mode: 0o755}
	for _, c := range []struct {
		name    string
		entries []*tar.Header
		says    string
	}{
		{"an absolute name", []*tar.Header{root, {Name: "/escaped", Typeflag: tar.TypeReg, Mode: 0o644}}, `holds "/escaped", which lies outside what it was asked for`},
		{"a name that climbs", []*tar.Header{root, {Name: "../escaped", Typeflag: tar.TypeReg, Mode: 0o644}}, `holds "../escaped", which lies outside what it was asked for`},
		{"a name outside the storage", []*tar.Header{root, {Name: "app/data/../../escaped", Typeflag: tar.TypeReg, Mode: 0o644}}, "holds /escaped, which is no part of a snapshot"},
		{"an entry under a link", []*tar.Header{root, {Name: "app/data/out", Typeflag: tar.TypeSymlink, Linkname: "%s"}, {Name: "app/data/out/escaped", Typeflag: tar.TypeReg, Mode: 0o644}}, "holds /app/data/out/escaped in no directory it holds before it"},
		{"an entry in no directory before it", []*tar.Header{root, {Name: "app/data/later/escaped", Typeflag: tar.TypeReg, Mode: 0o644}}, "holds /app/data/later/escaped in no directory it holds before it"},
		{"a hard link", []*tar.Header{root, {Name: "app/data/hard", Typeflag: tar.TypeLink, Linkname: "app/data/x"}}, "holds /app/data/hard as a hard link"},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := newUpdateScenario(t, shippedCompose(t), nil)
			s.backupScaffold()
			outside := t.TempDir()
			for _, h := range c.entries {
				h.Linkname = strings.ReplaceAll(h.Linkname, "%s", outside)
			}
			s.answer("tar.out", archive(t, c.entries...))
			out, err := s.backup()
			if err == nil || !strings.Contains(err.Error(), c.says) || !strings.Contains(err.Error(), "The snapshot failed") {
				t.Fatalf("cyfr backup answered %v, want the snapshot failed, saying %q:\n%s", err, c.says, out)
			}
			if entries, _ := os.ReadDir(outside); len(entries) != 0 {
				t.Errorf("the stream wrote %v outside the snapshot", entries)
			}
			if _, err := os.Lstat(filepath.Join(s.project, "backups", "escaped")); !errors.Is(err, fs.ErrNotExist) {
				t.Errorf("the stream wrote beside the snapshot (%v)", err)
			}
		})
	}
	t.Run("a pipe", func(t *testing.T) {
		s := newUpdateScenario(t, shippedCompose(t), nil)
		s.backupScaffold()
		s.answer("tar.out", archive(t, root, &tar.Header{Name: "app/data/pipe", Typeflag: tar.TypeFifo, Mode: 0o644}))
		out, err := s.backup()
		if err != nil || !strings.Contains(out, "Skipped /app/data/pipe, neither a file, a directory nor a link.\n") {
			t.Fatalf("cyfr backup answered %v:\n%s", err, out)
		}
		if _, err := os.Lstat(filepath.Join(s.snapshotDir(), "storage", "pipe")); !errors.Is(err, fs.ErrNotExist) {
			t.Errorf("the snapshot holds the pipe (%v)", err)
		}
	})
}

// A failed read through the stack, as with an image that is not on the
// machine (it never pulls), fails the snapshot and starts the stack again,
// naming what to run, and its container is ended and removed.
func TestAFailedStackReadNamesWhatToRun(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.backupScaffold()
	s.answer("tar.exit", "125")
	out, err := s.backup()
	if err == nil || !strings.Contains(err.Error(), "a stack that never ran may lack the image: run 'cyfr up' or 'docker compose pull cyfr' first") || !strings.Contains(err.Error(), "The stack was started again") {
		t.Fatalf("cyfr backup answered %v:\n%s", err, out)
	}
	s.removedTheStorageRead(t)
}

// removedTheStorageRead fails unless the storage's read, which did not
// finish, was ended and removed by its name after it.
func (s *updateScenario) removedTheStorageRead(t *testing.T) {
	t.Helper()
	log := s.log()
	name := regexp.MustCompile(`--name (cyfr-snapshot-read-[0-9a-f]{12})`)
	read, last := -1, ""
	for i, line := range log {
		if m := name.FindStringSubmatch(line); m != nil && strings.Contains(line, "-T -") {
			read, last = i, m[1]
		}
	}
	if read < 0 || !slices.Contains(log[read+1:], "rm --force "+last) {
		t.Errorf("the storage's read %q was not ended and removed:\n%s", last, strings.Join(log, "\n"))
	}
}

// A read that streams nothing for the stall bound is ended, its container
// ended and removed, and the snapshot fails with the stack started again;
// the bound is on progress, not on the copy's whole time.
func TestAStalledStackReadIsEnded(t *testing.T) {
	saved := stackReadStall
	t.Cleanup(func() { stackReadStall = saved })
	stackReadStall = 300 * time.Millisecond
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.backupScaffold()
	s.answer("tar.stall", "")
	out, err := s.backup()
	if err == nil || !strings.Contains(err.Error(), "the stack's read of its storage made no progress for 300ms, so it was ended") || !strings.Contains(err.Error(), "The stack was started again") {
		t.Fatalf("cyfr backup answered %v:\n%s", err, out)
	}
	s.removedTheStorageRead(t)
}

// An interrupt during the read does not cut it short: the read runs to
// its end as every step from the stop on does, and the update then ends
// at the next boundary, starting the old stack again with the snapshot
// complete.
func TestAnInterruptLetsTheStackReadFinish(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.backupScaffold()
	ctx, interrupt := context.WithCancel(context.Background())
	defer interrupt()
	saved := standInAsRoot
	t.Cleanup(func() { standInAsRoot = saved })
	reads := 0
	standInAsRoot = func() func() {
		// The interrupt arrives during the snapshot's first read.
		if reads++; reads == 3 {
			interrupt()
		}
		return func() {}
	}
	out, err := s.run(ctx)
	if err == nil || !strings.Contains(err.Error(), "interrupted during the snapshot (complete at") {
		t.Fatalf("cyfr update answered %v:\n%s", err, out)
	}
	if _, err := readSnapshot(s.snapshotDir()); err != nil {
		t.Errorf("the snapshot is not whole: %v", err)
	}
	if slices.ContainsFunc(s.log(), func(l string) bool { return strings.HasPrefix(l, "rm --force cyfr-snapshot-read-") }) {
		t.Errorf("a read that finished was removed by hand:\n%s", strings.Join(s.log(), "\n"))
	}
}
