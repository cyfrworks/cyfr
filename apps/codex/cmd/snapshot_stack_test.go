// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"archive/tar"
	"bytes"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// The snapshot reads the storage through a one-off container of the image
// the cyfr service runs: never pulling, with no network, as the
// container's root holding no capability but reading past permissions,
// its entrypoint skipped, its root filesystem and the service's binds
// read only, tar archiving to cyfr's standard output.
func TestTheSnapshotReadsTheStorageThroughTheStack(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.backupScaffold()
	if out, err := s.backup(); err != nil {
		t.Fatalf("cyfr backup answered %v\n%s", err, out)
	}
	want := "run --rm --pull never --network none --user 0:0 --cap-drop ALL --cap-add DAC_READ_SEARCH --security-opt no-new-privileges --read-only --entrypoint tar" +
		" --mount type=bind,source=" + filepath.Join(s.project, "data") + ",target=/app/data,readonly " + stackImage +
		" --hard-dereference -C /app/data -cf - ."
	var reads []string
	for _, line := range s.log() {
		if strings.Contains(line, "--entrypoint tar") {
			reads = append(reads, line)
		}
	}
	if !slices.Equal(reads, []string{want}) {
		t.Errorf("the snapshot read the storage with %q, want once with %q", reads, want)
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
	root := &tar.Header{Name: "./", Typeflag: tar.TypeDir, Mode: 0o755}
	db := &tar.Header{Name: "./cyfr.db", Typeflag: tar.TypeReg, Mode: 0o644}
	for _, c := range []struct {
		name    string
		entries []*tar.Header
		says    string
	}{
		{"an absolute name", []*tar.Header{root, db, {Name: "/escaped", Typeflag: tar.TypeReg, Mode: 0o644}}, `holds "/escaped", which lies outside /app/data`},
		{"a name that climbs", []*tar.Header{root, db, {Name: "./../escaped", Typeflag: tar.TypeReg, Mode: 0o644}}, `holds "./../escaped", which lies outside /app/data`},
		{"an entry under a link", []*tar.Header{root, db, {Name: "./out", Typeflag: tar.TypeSymlink, Linkname: "%s"}, {Name: "./out/escaped", Typeflag: tar.TypeReg, Mode: 0o644}}, "holds /app/data/out/escaped in no directory it holds before it"},
		{"an entry in no directory before it", []*tar.Header{root, db, {Name: "./later/escaped", Typeflag: tar.TypeReg, Mode: 0o644}}, "holds /app/data/later/escaped in no directory it holds before it"},
		{"a hard link", []*tar.Header{root, db, {Name: "./hard", Typeflag: tar.TypeLink, Linkname: "./cyfr.db"}}, "holds /app/data/hard as a hard link"},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := newUpdateScenario(t, shippedCompose(t), nil)
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
		s.answer("tar.out", archive(t, root, db, &tar.Header{Name: "./pipe", Typeflag: tar.TypeFifo, Mode: 0o644}))
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
// naming what to run.
func TestAFailedStackReadNamesWhatToRun(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.answer("tar.exit", "125")
	out, err := s.backup()
	if err == nil || !strings.Contains(err.Error(), "a stack that never ran may lack the image: run 'cyfr up' or 'docker compose pull cyfr' first") || !strings.Contains(err.Error(), "The stack was started again") {
		t.Fatalf("cyfr backup answered %v:\n%s", err, out)
	}
}
