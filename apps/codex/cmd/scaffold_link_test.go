// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/scaffold"
)

// plantFolderLink makes link a symbolic link to target, skipping the test
// on a system that makes none for this account (Windows without the
// privilege or developer mode), where no install holds such a link either.
func plantFolderLink(t *testing.T, target, link string) {
	t.Helper()
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("this system makes no symbolic link here: %v", err)
	}
}

// outsideWit makes wit/ in the working directory a link to a folder outside
// it that holds cyfr/added.wit, and answers that folder.
func outsideWit(t *testing.T) string {
	t.Helper()
	outside := t.TempDir()
	if err := os.MkdirAll(filepath.Join(outside, "cyfr"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(outside, "cyfr", "added.wit"), []byte("another directory's file\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	plantFolderLink(t, outside, "wit")
	return outside
}

// witRelease is a real scaffold release that writes wit/cyfr/added.wit.
func witRelease(t *testing.T) *scaffold.Release {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	body := []byte("package cyfr:added;\n")
	for _, h := range []*tar.Header{
		{Name: "wit/", Typeflag: tar.TypeDir, Mode: 0o755},
		{Name: "wit/cyfr/added.wit", Typeflag: tar.TypeReg, Mode: 0o644, Size: int64(len(body))},
	} {
		if err := tw.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
		if h.Typeflag == tar.TypeReg {
			if _, err := tw.Write(body); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := errors.Join(tw.Close(), gz.Close()); err != nil {
		t.Fatal(err)
	}
	r, err := scaffold.Parse(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// checkedScaffold is the scenario's scaffold whose Check is a real
// release's, so the update meets the project's folders as they are.
type checkedScaffold struct {
	fakeScaffold
	real *scaffold.Release
}

func (c checkedScaffold) Check() error { return c.real.Check() }

// An update whose scaffold writes in a folder linked outside the project
// refuses after the pulls and before anything is stopped, snapshotted or
// written, naming the folder and what to do.
func TestUpdateRefusesAFolderLinkedOutsideBeforeTheStop(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	outside := outsideWit(t)
	real := witRelease(t)
	fetchScaffold = func(v string) (scaffoldRelease, error) {
		s.scaffold++
		return checkedScaffold{fakeScaffold{s, v}, real}, nil
	}
	out, err := s.run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "wit is a link cyfr does not write through: make wit a real folder, or a relative link to a folder inside the install; nothing was changed") {
		t.Fatalf("update answered %v\n%s", err, out)
	}
	s.nothingStopped()
	s.noBackups()
	s.composeUnchanged()
	if s.hasCall("SCAFFOLD WRITE") {
		t.Error("the scaffold was written")
	}
	if got, _ := os.ReadFile(filepath.Join(outside, "cyfr", "added.wit")); string(got) != "another directory's file\n" {
		t.Errorf("the file outside reads %q", got)
	}
}

// The snapshot reads no scaffold file through a folder linked outside the
// project, and reads through one that stays inside it.
func TestSnapshotReadsNoScaffoldFileThroughAFolderLinkedOutside(t *testing.T) {
	t.Chdir(t.TempDir())
	outsideWit(t)
	dst := filepath.Join(t.TempDir(), "scaffold")
	if err := copyScaffold([]string{"wit/cyfr/added.wit"}, dst); err == nil {
		t.Error("the snapshot read through the link")
	}
	if _, err := os.Lstat(filepath.Join(dst, "wit", "cyfr", "added.wit")); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("the snapshot holds another directory's file (%v)", err)
	}

	t.Chdir(t.TempDir())
	if err := os.MkdirAll(filepath.Join("interfaces", "cyfr"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join("interfaces", "cyfr", "added.wit"), []byte("ours\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	plantFolderLink(t, "interfaces", "wit")
	dst = filepath.Join(t.TempDir(), "scaffold")
	if err := copyScaffold([]string{"wit/cyfr/added.wit"}, dst); err != nil {
		t.Fatalf("copyScaffold through a link inside the project: %v", err)
	}
	if got, err := os.ReadFile(filepath.Join(dst, "wit", "cyfr", "added.wit")); err != nil || string(got) != "ours\n" {
		t.Errorf("the snapshot holds %q (%v)", got, err)
	}
}

// cyfr init stops on a folder linked outside the project, as it stops on
// an unverified release, rather than warning and going on.
func TestInitStopsOnAFolderLinkedOutside(t *testing.T) {
	t.Chdir(t.TempDir())
	outsideWit(t)
	refusal := witRelease(t).Write(false)
	var warn bytes.Buffer
	err := scaffoldDownloadFailure("0.9.0", fmt.Errorf("extract: %w", refusal), &warn)
	if err == nil || !errors.Is(err, scaffold.ErrLinkNotFollowed) || !strings.HasSuffix(err.Error(), "; no scaffold file was written") || warn.Len() != 0 {
		t.Fatalf("init answered %v and warned %q", err, warn.String())
	}
}
