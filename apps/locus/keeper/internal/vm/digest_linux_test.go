// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package vm

import (
	"os"
	"path/filepath"
	"testing"
)

// tree makes a folder holding one link of name to target and one file.
func tree(t *testing.T, name, target string) string {
	t.Helper()
	root := t.TempDir()
	if err := os.Symlink(target, filepath.Join(root, name)); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(root, "file")
	if err := os.WriteFile(file, []byte("contents"), 0o644); err != nil {
		t.Fatal(err)
	}
	// Its mode set whatever the umask, so a change of it is one.
	if err := os.Chmod(file, 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

func digestOf(t *testing.T, root string) string {
	t.Helper()
	d, err := ImageDigest(root, filepath.Join(root, "image-digest"))
	if err != nil {
		t.Fatal(err)
	}
	if !digestPattern.MatchString(d) {
		t.Fatalf("the digest %q is not a sha256", d)
	}
	return d
}

// The review's two links: one named "link -> middle" to "target", one named
// "link" to "middle -> target". Their fields cannot run together, so the
// two trees are two images.
func TestTwoLinksWhoseNameAndTargetRunTogetherAreTwoImages(t *testing.T) {
	a := digestOf(t, tree(t, "link -> middle", "target"))
	b := digestOf(t, tree(t, "link", "middle -> target"))
	if a == b {
		t.Fatalf("a link named %q to %q and one named %q to %q are one image, %s", "link -> middle", "target", "link", "middle -> target", a)
	}
}

// The same tree is the same image, its own digest file left out; a file's
// contents, mode or name changed is another.
func TestTheDigestIsTheTreesAndNothingElse(t *testing.T) {
	root := tree(t, "link", "target")
	before := digestOf(t, root)
	if err := os.WriteFile(filepath.Join(root, "image-digest"), []byte(before+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if again := digestOf(t, root); again != before {
		t.Fatalf("the same tree with its digest file is %s, not %s", again, before)
	}
	// In this order: a rename first would leave the contents' write to make
	// the file anew under the process's umask, 0600 under 077, and the
	// mode's change then changes nothing.
	for _, step := range []struct {
		what   string
		change func() error
	}{
		{"contents", func() error { return os.WriteFile(filepath.Join(root, "file"), []byte("other"), 0o644) }},
		{"mode", func() error { return os.Chmod(filepath.Join(root, "file"), 0o600) }},
		{"name", func() error { return os.Rename(filepath.Join(root, "file"), filepath.Join(root, "renamed")) }},
	} {
		what, change := step.what, step.change
		prev := digestOf(t, root)
		if err := change(); err != nil {
			t.Fatal(err)
		}
		if digestOf(t, root) == prev {
			t.Fatalf("a file's %s changed and the digest did not", what)
		}
	}
}
