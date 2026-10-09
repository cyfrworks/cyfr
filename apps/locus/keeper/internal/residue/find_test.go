// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package residue

import (
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"testing"
)

const (
	shmTable = `       key      shmid perms                  size  cpid  lpid nattch   uid   gid  cuid  cgid      atime      dtime      ctime                   rss                  swap
    123456          0   600                  4096    12    12      0 20001 20001 20001 20001          0          0 1789432727                     0                     0
    123457          1   666                  4096    13    13      1     0     0 20001 20001          0          0 1789432727                     0                     0
    123458          2   600                  4096    14    14      0 20002 20002 20002 20002          0          0 1789432727                     0                     0
`
	semTable = `       key      semid perms      nsems   uid   gid  cuid  cgid      otime      ctime
         0          5   600          1 20001 20001 20001 20001          0 1789432727
`
	msgTable = `       key      msqid perms      cbytes       qnum lspid lrpid   uid   gid  cuid  cgid      stime      rtime      ctime
         0          7   600           0          0     0     0 20002 20002 20001 20001          0          0 1789432727
`
)

func TestParseSysvipcFindsObjectsTheUidOwnsOrCreated(t *testing.T) {
	for _, c := range []struct {
		kind  string
		table string
		want  []IPC
	}{
		{"shm", shmTable, []IPC{{"shm", 0}, {"shm", 1}}},
		{"sem", semTable, []IPC{{"sem", 5}}},
		{"msg", msgTable, []IPC{{"msg", 7}}},
		{"shm", strings.SplitN(shmTable, "\n", 2)[0] + "\n", nil},
	} {
		got, err := ParseSysvipc(c.kind, []byte(c.table), 20001)
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %v, want %v", c.kind, got, c.want)
		}
	}
	for name, c := range map[string]struct{ kind, table string }{
		"unknown table":  {"sock", shmTable},
		"no uid column":  {"shm", "key shmid perms\n1 2 600\n"},
		"a short line":   {"sem", "key semid perms nsems uid gid cuid cgid\n0 5 600\n"},
		"a non-number":   {"sem", "key semid perms nsems uid gid cuid cgid\n0 x 600 1 1 1 1 1\n"},
		"swapped header": {"msg", strings.Replace(msgTable, "msqid", "semid", 1)},
	} {
		if _, err := ParseSysvipc(c.kind, []byte(c.table), 20001); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestFindIPCReadsEveryTableAndToleratesAKernelWithout(t *testing.T) {
	dir := realTempDir(t)
	for kind, table := range map[string]string{"shm": shmTable, "sem": semTable, "msg": msgTable} {
		if err := os.WriteFile(filepath.Join(dir, kind), []byte(table), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	got, err := FindIPC(dir, 20001)
	if err != nil {
		t.Fatal(err)
	}
	if want := []IPC{{"shm", 0}, {"shm", 1}, {"sem", 5}, {"msg", 7}}; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	if got, err := FindIPC(filepath.Join(dir, "absent"), 20001); err != nil || got != nil {
		t.Fatalf("no tables: %v %v", got, err)
	}
}

func TestFindReportsTheOutermostEntriesTheUidOwnsAndItsQueues(t *testing.T) {
	root := realTempDir(t)
	queues := t.TempDir()
	for _, p := range []string{"home/a/b", "tmp-file", "dir/sub"} {
		full := filepath.Join(root, p)
		if err := os.MkdirAll(filepath.Dir(full), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink("/", filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(queues, "q"), nil, 0o600); err != nil {
		t.Fatal(err)
	}

	found, err := Find(Roots{Dirs: []string{root, filepath.Join(root, "absent")}, Queues: queues}, t.TempDir(), os.Getuid())
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(found.Paths)
	want := []string{filepath.Join(root, "dir"), filepath.Join(root, "home"), filepath.Join(root, "link"), filepath.Join(root, "tmp-file")}
	if !reflect.DeepEqual(found.Paths, want) || found.Truncated || !reflect.DeepEqual(found.Queues, []string{"q"}) {
		t.Fatalf("found %+v", found)
	}

	other, err := Find(Roots{Dirs: []string{root}, Queues: queues}, t.TempDir(), os.Getuid()+1)
	if err != nil {
		t.Fatal(err)
	}
	if !other.Empty() {
		t.Fatalf("another uid left %+v", other)
	}
}

func TestFindStopsAtItsBounds(t *testing.T) {
	root := realTempDir(t)
	for i := 0; i <= MaxPaths; i++ {
		if err := os.WriteFile(filepath.Join(root, strconv.Itoa(i)), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	found, err := Find(Roots{Dirs: []string{root}}, t.TempDir(), os.Getuid())
	if err != nil {
		t.Fatal(err)
	}
	if len(found.Paths) != MaxPaths || !found.Truncated || found.Empty() {
		t.Fatalf("found %d paths, truncated %t", len(found.Paths), found.Truncated)
	}
}

// Walking into directories owned by others needs a second uid to own them.
func TestFindDescendsIntoDirectoriesOfOthersWithinItsDepth(t *testing.T) {
	if os.Getuid() != 0 {
		t.Skip("needs root to create entries owned by other uids")
	}
	root := realTempDir(t)
	const owner, other = 20001, 20002
	shared := filepath.Join(root, "shared")
	deep := shared
	for i := 0; i < maxDepth; i++ {
		deep = filepath.Join(deep, "d")
	}
	if err := os.MkdirAll(deep, 0o777); err != nil {
		t.Fatal(err)
	}
	if err := filepath.Walk(shared, func(p string, _ os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		return os.Chown(p, other, other)
	}); err != nil {
		t.Fatal(err)
	}
	near := filepath.Join(shared, "d", "left")
	if err := os.WriteFile(near, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chown(near, owner, owner); err != nil {
		t.Fatal(err)
	}

	found, err := Find(Roots{Dirs: []string{root}}, t.TempDir(), owner)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(found.Paths, []string{near}) || !found.Truncated {
		t.Fatalf("found %+v", found)
	}
}

func TestRemovePathDeletesATreeTheOwnerMadeUnwritable(t *testing.T) {
	root := realTempDir(t)
	h := filepath.Join(root, "home")
	deep := filepath.Join(h, "a", "b")
	if err := os.MkdirAll(deep, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(deep, "f"), []byte("x"), 0o000); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/", filepath.Join(h, "link")); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(deep, 0o000); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(h, "a"), 0o500); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(root, "file")
	if err := os.WriteFile(file, nil, 0o000); err != nil {
		t.Fatal(err)
	}

	for _, p := range []string{h, file} {
		if err := RemovePath(p, os.Getuid()); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Lstat(p); !os.IsNotExist(err) {
			t.Fatalf("%s still present: %v", p, err)
		}
		if err := RemovePath(p, os.Getuid()); err != nil {
			t.Fatalf("removing an absent %s: %v", p, err)
		}
	}
	if _, err := os.Lstat(root); err != nil {
		t.Fatalf("the parent went with its entries: %v", err)
	}
}

func TestRemovePathRefusesAnotherUidsEntryAndASymlinkedParent(t *testing.T) {
	if err := RemovePath(realTempDir(t), os.Getuid()+1); err == nil {
		t.Error("a directory owned by another uid was removed")
	}
	if err := RemovePath("relative/path", os.Getuid()); err == nil {
		t.Error("a relative path was accepted")
	}

	root := realTempDir(t)
	target := filepath.Join(root, "target")
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatal(err)
	}
	kept := filepath.Join(target, "kept")
	if err := os.WriteFile(kept, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	if err := RemovePath(filepath.Join(root, "link", "kept"), os.Getuid()); err == nil {
		t.Error("a path through a symbolic link was accepted")
	}
	if _, err := os.Lstat(kept); err != nil {
		t.Fatalf("the entry behind the link was removed: %v", err)
	}
}

func TestRemovePathNeedsNoReadPermissionOnTheParent(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("reaching an unreadable parent needs O_PATH")
	}
	if os.Getuid() == 0 {
		t.Skip("root reads every directory")
	}
	root := realTempDir(t)
	h := filepath.Join(root, "home")
	if err := os.MkdirAll(filepath.Join(h, "sub"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(root, 0o300); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(root, 0o700)

	if err := RemovePath(h, os.Getuid()); err != nil {
		t.Fatalf("removing a home under a write-and-search-only root: %v", err)
	}
	if _, err := os.Lstat(h); !os.IsNotExist(err) {
		t.Fatalf("home still present: %v", err)
	}
}

// realTempDir is a test directory reached through no symbolic link, which
// RemovePath refuses to follow.
func realTempDir(t *testing.T) string {
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestRemoveQueuesUnlinksTheNamedQueues(t *testing.T) {
	dir := realTempDir(t)
	for _, name := range []string{"mine", "kept"} {
		if err := os.WriteFile(filepath.Join(dir, name), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := RemoveQueues(dir, []string{"mine", "gone"}); err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 || entries[0].Name() != "kept" {
		t.Fatalf("left %v", entries)
	}
}
