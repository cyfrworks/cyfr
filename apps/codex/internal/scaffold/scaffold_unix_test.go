// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package scaffold

import (
	"io/fs"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// A tree written under a narrow umask stays readable by the account the
// stack's containers read it as: every directory, tarball entry or parent
// made for a file, 0755, and every file its tarball's mode.
func TestWriteKeepsTheTreeReadableUnderAnyUmask(t *testing.T) {
	t.Chdir(t.TempDir())
	saved := syscall.Umask(0o077)
	t.Cleanup(func() { syscall.Umask(saved) })
	r := &Release{entries: []entry{
		{name: "aqua", dir: true},
		{name: "aqua/roles", dir: true},
		{name: "aqua/roles/shipped.md", mode: 0o644, data: []byte("a role")},
		{name: "aqua/skills/shipped/SKILL.md", mode: 0o644, data: []byte("a scroll, its parents absent from the tarball")},
	}}
	if err := r.Write(false); err != nil {
		t.Fatal(err)
	}
	if err := filepath.WalkDir("aqua", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		want := fs.FileMode(0o644)
		if d.IsDir() {
			want = 0o755
		}
		if info.Mode().Perm() != want {
			t.Errorf("%s is mode %o, want %o", path, info.Mode().Perm(), want)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

// A file at the name is the operator's: MakeDir answers the conflict and
// leaves the file's mode, there and for a directory beneath it.
func TestMakeDirRefusesAnExistingFileWithoutChangingIt(t *testing.T) {
	t.Chdir(t.TempDir())
	if err := os.WriteFile("held", []byte("operator data"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"held", "held/below"} {
		err := MakeDir(name)
		info, statErr := os.Stat("held")
		if statErr != nil {
			t.Fatal(statErr)
		}
		if err == nil || info.Mode().Perm() != 0o600 {
			t.Errorf("MakeDir(%s) answered %v and left mode %o", name, err, info.Mode().Perm())
		}
	}
}

// A directory that exists keeps its mode.
func TestMakeDirLeavesWhatExists(t *testing.T) {
	t.Chdir(t.TempDir())
	if err := os.Mkdir("narrow", 0o700); err != nil {
		t.Fatal(err)
	}
	if err := MakeDir("narrow"); err != nil {
		t.Fatal(err)
	}
	if err := MakeDir("narrow/made"); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat("narrow")
	if err != nil || info.Mode().Perm() != 0o700 {
		t.Errorf("narrow is mode %o (%v)", info.Mode().Perm(), err)
	}
}
