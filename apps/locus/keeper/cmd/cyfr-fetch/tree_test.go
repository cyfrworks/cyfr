// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"archive/tar"
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"syscall"
	"testing"
	"time"
)

// A program that is a tree of files, as Cursor's agent is: one top folder
// holding its own runtime and the script that runs it (`--tree=ENTRY`).

func dir(name string) entry {
	return entry{tar.Header{Name: name, Typeflag: tar.TypeDir, Mode: 0o755}, ""}
}

func plainFile(name, body string) entry {
	return entry{tar.Header{Name: name, Typeflag: tar.TypeReg, Mode: 0o644}, body}
}

func tree(t *testing.T, extra ...entry) []byte {
	t.Helper()
	return tarGz(t, append([]entry{dir("dist-package/"), file("dist-package/cursor-agent", script),
		plainFile("dist-package/index.js", "js"), file("dist-package/node", "node"),
		plainFile("dist-package/node_modules/piscina/package.json", "{}")}, extra...)...)
}

func (o *origin) pinnedTree(path string, body []byte) program {
	p := o.pinned(path, body)
	p.entry = "cursor-agent"
	return p
}

// every is each path under root with its mode, folders marked with a /.
func every(t *testing.T, root string) []string {
	t.Helper()
	var out []string
	_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil || path == root {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		if info.IsDir() {
			rel += "/"
		}
		out = append(out, rel+" "+info.Mode().Perm().String())
		return nil
	})
	sort.Strings(out)
	return out
}

func TestATreeIsUnpackedWholeAndRunByItsEntry(t *testing.T) {
	archive := tree(t)
	o := serveFiles(t, map[string][]byte{"/agent-cli-package.tar.gz": archive})
	home := t.TempDir()
	var notice bytes.Buffer
	p := o.pinnedTree("/agent-cli-package.tar.gz", archive)
	path, err := o.fetcher(&notice).install(home, p)
	if err != nil {
		t.Fatalf("install: %v", err)
	}
	if path != filepath.Join(folder(home, p.sum), "agy", "cursor-agent") {
		t.Fatalf("run by its entry: %s", path)
	}
	want := []string{"agy/ -rwx------", "agy/cursor-agent -rwx------", "agy/index.js -rw-------", "agy/node -rwx------",
		"agy/node_modules/ -rwx------", "agy/node_modules/piscina/ -rwx------", "agy/node_modules/piscina/package.json -rw-------"}
	if got := every(t, folder(home, p.sum)); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("the tree whole under its top folder, alone in the version folder:\n%s", strings.Join(got, "\n"))
	}
	if body, _ := os.ReadFile(path); string(body) != script {
		t.Fatalf("the entry's bytes: %q", body)
	}
	again, err := o.fetcher(&notice).install(home, p)
	if err != nil || again != path || o.hits.Load() != 1 || notice.String() != "cyfr-fetch: fetching agy 1.5.16\n" {
		t.Fatalf("an installed tree is run with no fetch: %s %v %d %q", again, err, o.hits.Load(), notice.String())
	}
}

// Nothing outside the top folder, no link of any kind and no special file
// is unpacked: each such archive installs nothing and leaves nothing.
func TestATreeThatLeavesItsFolderOrHoldsNoPlainFileIsRefused(t *testing.T) {
	for label, archive := range map[string][]byte{
		"a link inside":      tree(t, entry{tar.Header{Name: "dist-package/lib", Typeflag: tar.TypeSymlink, Linkname: "node"}, ""}),
		"a link out":         tree(t, entry{tar.Header{Name: "dist-package/etc", Typeflag: tar.TypeSymlink, Linkname: "/etc"}, ""}),
		"a hard link":        tree(t, entry{tar.Header{Name: "dist-package/again", Typeflag: tar.TypeLink, Linkname: "dist-package/node"}, ""}),
		"a fifo":             tree(t, entry{tar.Header{Name: "dist-package/pipe", Typeflag: tar.TypeFifo, Mode: 0o644}, ""}),
		"a device":           tree(t, entry{tar.Header{Name: "dist-package/null", Typeflag: tar.TypeChar, Mode: 0o644, Devmajor: 1, Devminor: 3}, ""}),
		"an absolute name":   tree(t, plainFile("/etc/cyfr-test", "x")),
		"a step up":          tree(t, plainFile("dist-package/../outside", "x")),
		"a dot step":         tree(t, plainFile("dist-package/./x", "x")),
		"an empty step":      tree(t, plainFile("dist-package//x", "x")),
		"two top folders":    tree(t, plainFile("other/x", "x")),
		"a file at the top":  tarGz(t, file("cursor-agent", script)),
		"a name twice":       tree(t, plainFile("dist-package/index.js", "again")),
		"a file then folder": tree(t, dir("dist-package/index.js/")),
		"no entry":           tarGz(t, dir("dist-package/"), plainFile("dist-package/index.js", "js")),
		"an entry not run":   tarGz(t, dir("dist-package/"), plainFile("dist-package/cursor-agent", script)),
		"empty":              tarGz(t),
	} {
		o := serveFiles(t, map[string][]byte{"/cli.tar.gz": archive})
		home := t.TempDir()
		_, err := o.fetcher(io.Discard).install(home, o.pinnedTree("/cli.tar.gz", archive))
		if err == nil || !strings.Contains(err.Error(), "nothing was installed") {
			t.Fatalf("%s: refused expected, got %v", label, err)
		}
		if n := names(t, folder(home, sum(archive))); len(n) != 0 {
			t.Fatalf("%s: nothing stays: %v", label, n)
		}
		if _, err := os.Lstat("/etc/cyfr-test"); err == nil {
			t.Fatalf("%s: nothing is written outside", label)
		}
	}
}

func TestATreePastItsBoundsIsRefused(t *testing.T) {
	archive := tree(t, plainFile("dist-package/big", strings.Repeat("x", 4096)))
	o := serveFiles(t, map[string][]byte{"/cli.tar.gz": archive})
	for label, limits := range map[string]func(*fetcher){
		"its files' size": func(f *fetcher) { f.maxProgram = 4096 },
		"its entries":     func(f *fetcher) { f.maxEntries = 5 },
	} {
		home := t.TempDir()
		f := o.fetcher(io.Discard)
		limits(&f)
		if _, err := f.install(home, o.pinnedTree("/cli.tar.gz", archive)); err == nil || !strings.Contains(err.Error(), "nothing was installed") {
			t.Fatalf("%s: refused expected, got %v", label, err)
		}
		if n := names(t, folder(home, sum(archive))); len(n) != 0 {
			t.Fatalf("%s: nothing stays: %v", label, n)
		}
	}
}

func TestALeftoverTreeFolderIsRemoved(t *testing.T) {
	archive := tree(t)
	o := serveFiles(t, map[string][]byte{"/cli.tar.gz": archive})
	home := t.TempDir()
	left := filepath.Join(folder(home, sum(archive)), tempPrefix+"tree-interrupted", "node_modules")
	if err := os.MkdirAll(left, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(left, "half"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := o.fetcher(io.Discard).install(home, o.pinnedTree("/cli.tar.gz", archive)); err != nil {
		t.Fatalf("install: %v", err)
	}
	if n := names(t, folder(home, sum(archive))); len(n) != 1 || n[0] != "agy" {
		t.Fatalf("the interrupted tree is gone: %v", n)
	}
}

// An installed tree whose folder on the way to its entry, or the entry
// itself, is a link is not run.
func TestAnInstalledTreeReachedThroughALinkIsRefused(t *testing.T) {
	for label, make := range map[string]func(t *testing.T, version string){
		"the entry a link": func(t *testing.T, version string) {
			mustMkdir(t, filepath.Join(version, "agy"))
			mustLink(t, "/bin/sh", filepath.Join(version, "agy", "cursor-agent"))
		},
		"a folder on the way a link": func(t *testing.T, version string) {
			elsewhere := t.TempDir()
			if err := os.WriteFile(filepath.Join(elsewhere, "run"), []byte(script), 0o755); err != nil {
				t.Fatal(err)
			}
			mustMkdir(t, filepath.Join(version, "agy"))
			mustLink(t, elsewhere, filepath.Join(version, "agy", "bin"))
		},
	} {
		archive := tree(t)
		o := serveFiles(t, map[string][]byte{"/cli.tar.gz": archive})
		home := t.TempDir()
		make(t, folder(home, sum(archive)))
		p := o.pinnedTree("/cli.tar.gz", archive)
		if label == "a folder on the way a link" {
			p.entry = "bin/run"
		}
		if _, err := o.fetcher(io.Discard).install(home, p); err == nil || !strings.Contains(err.Error(), "is not run") {
			t.Fatalf("%s: refused expected, got %v", label, err)
		}
		if o.hits.Load() != 0 {
			t.Fatalf("%s: nothing is fetched over it", label)
		}
	}
}

func mustMkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o700); err != nil {
		t.Fatal(err)
	}
}

func mustLink(t *testing.T, target, path string) {
	t.Helper()
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}
}

func TestATreeIsNamedBeforeItsDownloads(t *testing.T) {
	amd := "amd64=https://downloads.example/lab/v/linux/x64/agent-cli-package.tar.gz#" + hash
	p, err := parse([]string{"cursor-agent", "2026.11.22-e9042b2", "--tree=cursor-agent", amd, "--", "--disable-auto-update"}, "amd64")
	if err != nil || p.entry != "cursor-agent" || p.name != "cursor-agent" || strings.Join(p.args, " ") != "--disable-auto-update" {
		t.Fatalf("a tree's entry and the program's own arguments: %+v %v", p, err)
	}
	if p, err := parse([]string{"agy", "1.5.16", "--tree=bin/agy-2.x", amd}, "amd64"); err != nil || p.entry != "bin/agy-2.x" {
		t.Fatalf("an entry deeper in the tree: %+v %v", p, err)
	}
	for _, args := range [][]string{
		{"agy", "1.5.16", "--tree=", amd},
		{"agy", "1.5.16", "--tree=../agy", amd},
		{"agy", "1.5.16", "--tree=/bin/sh", amd},
		{"agy", "1.5.16", "--tree=bin//agy", amd},
		{"agy", "1.5.16", "--tree=bin/", amd},
		{"agy", "1.5.16", "--tree=.agy", amd},
		{"agy", "1.5.16", "--tree=" + strings.Repeat("a", 256), amd},
		{"agy", "1.5.16", "--tree=agy", "amd64=https://downloads.example/agy#" + hash},
	} {
		var bad usageError
		if _, err := parse(args, "amd64"); err == nil || !errors.As(err, &bad) {
			t.Fatalf("%q: a usage error expected, got %v", args, err)
		}
	}
}

// The command runs an installed tree's entry in its place, argv[0] the
// program's name.
func TestTheCommandRunsAnInstalledTreesEntry(t *testing.T) {
	home := t.TempDir()
	self, err := os.ReadFile("/proc/self/exe")
	if err != nil {
		t.Fatal(err)
	}
	entryDir := filepath.Join(folder(home, hash), "agy", "bin")
	mustMkdir(t, entryDir)
	if err := os.WriteFile(filepath.Join(entryDir, "run"), self, 0o755); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(os.Args[0], "agy", "1.5.16", "--tree=bin/run", runtime.GOARCH+"=https://storage.example.invalid/cli.tar.gz#"+hash, "--", "acp")
	cmd.Env = append(os.Environ(), "CYFR_FETCH_TEST_MAIN=1", "HOME="+home, "CYFR_FETCH_TEST_MARK=kept")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil || string(out) != "agy\x00acp\x00mark=kept" || stderr.Len() != 0 {
		t.Fatalf("the tree's entry runs in its place: %q %v %s", out, err, stderr.String())
	}
}

// Every folder and file made counts against the bound, the folders one
// name implies among them; a name given twice, a folder's too, is refused.
func TestATreesBoundsCountWhatItMakes(t *testing.T) {
	for label, c := range map[string]struct {
		archive []byte
		limit   int
	}{
		"one name implying its folders": {tarGz(t, dir("dist-package/"), file("dist-package/a/b/c/d/cursor-agent", script)), 4},
		"a folder named twice":          {tree(t, dir("dist-package/")), maxEntries},
		"a nested folder named twice":   {tree(t, dir("dist-package/lib/"), dir("dist-package/lib/")), maxEntries},
	} {
		o := serveFiles(t, map[string][]byte{"/cli.tar.gz": c.archive})
		home := t.TempDir()
		f := o.fetcher(io.Discard)
		f.maxEntries = c.limit
		p := o.pinnedTree("/cli.tar.gz", c.archive)
		if strings.HasPrefix(label, "one name") {
			p.entry = "a/b/c/d/cursor-agent"
		}
		if _, err := f.install(home, p); err == nil || !strings.Contains(err.Error(), "nothing was installed") {
			t.Fatalf("%s: refused expected, got %v", label, err)
		}
		if n := names(t, folder(home, sum(c.archive))); len(n) != 0 {
			t.Fatalf("%s: nothing stays: %v", label, n)
		}
	}
}

// Sizes are added with no overflow: a sum past the bound, however reached,
// and a negative size are refused.
func TestATreesSizesAddWithoutOverflow(t *testing.T) {
	const most = int64(^uint64(0) >> 1)
	for _, c := range []struct {
		total, size, bound int64
		ok                 bool
	}{
		{2, 3, 10, true}, {5, 5, 10, true}, {5, 6, 10, false},
		{1, most, most, false}, {most - 1, 2, most, false}, {0, -1, 10, false},
	} {
		if got, ok := added(c.total, c.size, c.bound); ok != c.ok || (ok && got != c.total+c.size) {
			t.Fatalf("added(%d, %d, %d) = %d %v", c.total, c.size, c.bound, got, ok)
		}
	}
}

// What a run interrupted after its rename left beside the installed tree,
// its download and its staging, is swept by the next run, which finds the
// tree there and fetches nothing.
func TestARunInterruptedAfterItsInstallLeavesNothingForLong(t *testing.T) {
	archive := tree(t)
	o := serveFiles(t, map[string][]byte{"/cli.tar.gz": archive})
	home := t.TempDir()
	p := o.pinnedTree("/cli.tar.gz", archive)
	if _, err := o.fetcher(io.Discard).install(home, p); err != nil {
		t.Fatal(err)
	}
	version := folder(home, p.sum)
	if err := os.WriteFile(filepath.Join(version, tempPrefix+"0123456789abcdef"), archive, 0o600); err != nil {
		t.Fatal(err)
	}
	mustMkdir(t, filepath.Join(version, tempPrefix+"tree-interrupted", "node_modules"))
	if _, err := o.fetcher(io.Discard).install(home, p); err != nil {
		t.Fatalf("the installed tree runs: %v", err)
	}
	if n := names(t, version); len(n) != 1 || n[0] != "agy" || o.hits.Load() != 1 {
		t.Fatalf("the download and the staging are gone, and nothing was fetched again: %v %d", n, o.hits.Load())
	}
}

// A run that waited on the lock while another installed, the other
// interrupted after its rename, sweeps what that run left before it
// returns: nothing of the download stays.
func TestARunThatWaitedSweepsWhatAnInterruptedInstallLeft(t *testing.T) {
	archive := tree(t)
	o := serveFiles(t, map[string][]byte{"/cli.tar.gz": archive})
	home := t.TempDir()
	p := o.pinnedTree("/cli.tar.gz", archive)
	version := folder(home, p.sum)
	mustMkdir(t, version)
	first, err := os.Open(version)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	if err := syscall.Flock(int(first.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	var info syscall.Stat_t
	if err := syscall.Fstat(int(first.Fd()), &info); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, err := o.fetcher(io.Discard).install(home, p)
		done <- err
	}()
	// A bounded wait for the kernel to list the second run's lock as
	// blocked on the folder; sleep-ok: /proc/locks has no notification.
	waiting := fmt.Sprintf(":%d ", info.Ino)
	for deadline := time.Now().Add(10 * time.Second); ; {
		locks, _ := os.ReadFile("/proc/locks")
		if strings.Contains(string(locks), "-> FLOCK") && strings.Contains(string(locks), waiting) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the second run never waited on the folder's lock")
		}
		time.Sleep(10 * time.Millisecond) // sleep-ok: polling /proc/locks
	}
	// The first run, interrupted after its rename: its tree in place, its
	// download beside it.
	mustMkdir(t, filepath.Join(version, "agy"))
	if err := os.WriteFile(filepath.Join(version, "agy", "cursor-agent"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(version, tempPrefix+"0123456789abcdef"), archive, 0o600); err != nil {
		t.Fatal(err)
	}
	_ = syscall.Flock(int(first.Fd()), syscall.LOCK_UN)
	if err := <-done; err != nil {
		t.Fatalf("the second run runs the first's install: %v", err)
	}
	if n := names(t, version); len(n) != 1 || n[0] != "agy" || o.hits.Load() != 0 {
		t.Fatalf("nothing of the download stays, and nothing was fetched: %v %d", n, o.hits.Load())
	}
}
