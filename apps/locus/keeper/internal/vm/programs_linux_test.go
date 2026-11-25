// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package vm

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// bindsMode runs the test binary as the bound mounts test's child.
const bindsMode = "CYFR_VM_TEST_BINDS"

func TestMain(m *testing.M) {
	if job := os.Getenv(bindsMode); job != "" {
		os.Exit(bindsChild(job))
	}
	os.Exit(m.Run())
}

// testMaker is a Maker whose tool is a script: it marks that it began,
// fails when fail exists, waits while stop exists, and then writes its
// arguments to its output file. Its mount table is empty.
func testMaker(t *testing.T) (Maker, string) {
	t.Helper()
	dir := t.TempDir()
	tool := filepath.Join(dir, "tool")
	script := `#!/bin/sh
d=$(dirname "$0")
: > "$d/began"
[ -e "$d/fail" ] && exit 3
while [ -e "$d/stop" ]; do sleep 0.01; done # sleep-ok: the tool stands in for a slow maker until the test releases it
printf '%s\n' "$@" > "$2"
`
	if err := os.WriteFile(tool, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	volume := filepath.Join(dir, "guest")
	if err := os.Mkdir(volume, 0o755); err != nil {
		t.Fatal(err)
	}
	id := filepath.Join(dir, "image-digest")
	if err := os.WriteFile(id, []byte(digest+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	mounts := filepath.Join(dir, "mountinfo")
	if err := os.WriteFile(mounts, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	return Maker{Dir: volume, Digest: id, Tool: tool, Root: "/", Mounts: mounts,
		Wait: 5 * time.Second, Deadline: 30 * time.Second, Log: io.Discard}, dir
}

// device is mk's device, failing the test otherwise, closed at its end.
func device(t *testing.T, mk Maker) (*Device, bool) {
	t.Helper()
	dev, made, err := mk.Device()
	if err != nil {
		t.Fatalf("Device: %v", err)
	}
	t.Cleanup(func() { _ = dev.Close() })
	return dev, made
}

func names(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range entries {
		out = append(out, e.Name())
	}
	return out
}

// began waits, within a bound, for the tool's mark that a making began.
func began(t *testing.T, dir string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(filepath.Join(dir, "began")); err == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("no making began")
		}
		time.Sleep(10 * time.Millisecond) // sleep-ok: a bounded wait on the tool's mark
	}
}

func TestDeviceIsMadeOnceUnderAnImage(t *testing.T) {
	mk, _ := testMaker(t)
	dev, made := device(t, mk)
	if !made || dev.Path != filepath.Join(mk.Dir, digest+".sqfs") {
		t.Fatalf("first Device: %q %v", dev.Path, made)
	}
	args, _ := os.ReadFile(dev.Path)
	if want := strings.Join(MakeArgs("/", dev.Path+".tmp", nil), "\n") + "\n"; string(args) != want {
		t.Fatalf("the tool was given %q, want %q", args, want)
	}
	again, made := device(t, mk)
	if made || again.Path != dev.Path {
		t.Fatalf("second Device: %q %v", again.Path, made)
	}
	if got := names(t, mk.Dir); !slices.Equal(got, []string{".lock", digest + ".sqfs"}) {
		t.Fatalf("the volume holds %v", got)
	}
}

func TestMakeArgsStayOnTheRootsFilesystemAndLeaveOutItsMounts(t *testing.T) {
	args := MakeArgs("/", "/out", []string{"proc/*", "proc/.*", "etc/hosts"})
	if args[0] != "/" || args[1] != "/out" || !slices.Contains(args, "-one-file-system") || !slices.Contains(args, "-wildcards") {
		t.Fatalf("MakeArgs: %v", args)
	}
	if i := slices.Index(args, "-comp"); i < 0 || args[i+1] != "lz4" {
		t.Fatalf("MakeArgs compress otherwise: %v", args)
	}
	if i := slices.Index(args, "-e"); i < 0 || !slices.Equal(args[i+1:], []string{"proc/*", "proc/.*", "etc/hosts"}) {
		t.Fatalf("MakeArgs leave out otherwise: %v", args)
	}
	if slices.Contains(MakeArgs("/", "/out", nil), "-e") {
		t.Fatal("MakeArgs ends in an empty -e")
	}
}

// mountLine is a mountinfo line whose mount point is point, escaped as the
// kernel escapes it.
func mountLine(id int, point string) string {
	escaped := strings.NewReplacer(`\`, `\134`, " ", `\040`, "\t", `\011`, "\n", `\012`).Replace(point)
	return fmt.Sprintf("%d 1 8:1 / %s rw,relatime shared:1 - ext4 /dev/sda1 rw", id, escaped)
}

func TestTheDeviceLeavesOutEveryMountUnderItsRootByName(t *testing.T) {
	base := t.TempDir()
	root := filepath.Join(base, "root")
	for _, d := range []string{"proc/sys", "var/lib/locus/kept", "sp ace", "a\tb"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, f := range []string{"etc/hosts", "st*r[1]", `back\slash`} {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(root, f)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, f), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// Nothing inside proc may be looked at, as under a profile that denies
	// it; as root, nothing inside it may be left out on its own.
	proc := filepath.Join(root, "proc")
	t.Cleanup(func() { _ = os.Chmod(proc, 0o755) })
	if err := os.Chmod(proc, 0); err != nil {
		t.Fatal(err)
	}
	table := strings.Join([]string{
		mountLine(1, "/"),
		mountLine(2, root),
		// A mount point inside another, listed before it, is left out with
		// its folder's entries.
		mountLine(13, root+"/proc/sys"),
		mountLine(3, root+"/proc"),
		mountLine(4, root+"/var/lib/locus/kept"),
		mountLine(5, root+"/etc/hosts"),
		mountLine(6, root+"/sp ace"),
		mountLine(7, root+"/a\tb"),
		mountLine(8, root+"/st*r[1]"),
		mountLine(9, root+`/back\slash`),
		// A mount stacked on another's point is left out once.
		mountLine(10, root+"/proc"),
		// A sibling that begins with root's name is not under it.
		mountLine(11, root+"x"),
		// A mount whose point was removed is nothing of the walk's.
		mountLine(12, root+"/gone (deleted)"),
	}, "\n") + "\n"
	got, err := leftOut(root, []byte(table))
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"proc/*", "proc/.*", `var/lib/locus/kept/*`, `var/lib/locus/kept/.*`, "etc/hosts",
		`sp\ ace/*`, `sp\ ace/.*`, "a\\\tb/*", "a\\\tb/.*", `st\*r\[1\]`, `back\\slash`}
	if !slices.Equal(got, want) {
		t.Fatalf("leftOut:\n got %q\nwant %q", got, want)
	}
	if _, err := leftOut(root, []byte("1 2 8:1\n")); err == nil {
		t.Fatal("a mount table line without its mount point was taken")
	}
}

func TestANewImageReplacesTheOldDeviceOnceWhole(t *testing.T) {
	mk, _ := testMaker(t)
	old := filepath.Join(mk.Dir, strings.Repeat("f", 64)+".sqfs")
	leftover := filepath.Join(mk.Dir, strings.Repeat("e", 64)+".sqfs.tmp")
	for _, f := range []string{old, leftover} {
		if err := os.WriteFile(f, []byte("x"), 0o640); err != nil {
			t.Fatal(err)
		}
	}
	if _, made := device(t, mk); !made {
		t.Fatal("Device made nothing")
	}
	if got := names(t, mk.Dir); !slices.Equal(got, []string{".lock", digest + ".sqfs"}) {
		t.Fatalf("the volume holds %v", got)
	}
}

func TestAnOldDeviceGoesAtTheNextStartWithoutAMaking(t *testing.T) {
	mk, _ := testMaker(t)
	first, _ := device(t, mk)
	_ = first.Close()
	// A keeper that died after its rename left the old release's device
	// and another's temporary file.
	old := filepath.Join(mk.Dir, strings.Repeat("f", 64)+".sqfs")
	leftover := filepath.Join(mk.Dir, strings.Repeat("e", 64)+".sqfs.tmp")
	for _, f := range []string{old, leftover} {
		if err := os.WriteFile(f, []byte("previous release"), 0o640); err != nil {
			t.Fatal(err)
		}
	}
	if _, made := device(t, mk); made {
		t.Fatal("the device was made again")
	}
	if got := names(t, mk.Dir); !slices.Equal(got, []string{".lock", digest + ".sqfs"}) {
		t.Fatalf("the volume holds %v", got)
	}
}

func TestAHeldDeviceOutlivesAnotherReleaseAndGoesAfterItsHold(t *testing.T) {
	a, _ := testMaker(t)
	held, _ := device(t, a)
	b, _ := testMaker(t)
	b.Dir = a.Dir
	if err := os.WriteFile(b.Digest, []byte(strings.Repeat("e", 64)), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, made := device(t, b); !made {
		t.Fatal("the other release's device was not made")
	}
	if _, err := os.Stat(held.Path); err != nil {
		t.Fatalf("the held device: %v", err)
	}
	_ = held.Close()
	device(t, b)
	if got := names(t, a.Dir); !slices.Equal(got, []string{".lock", strings.Repeat("e", 64) + ".sqfs"}) {
		t.Fatalf("after its hold the volume holds %v", got)
	}
}

func TestAFailedMakingLeavesNoDeviceAndKeepsTheOld(t *testing.T) {
	mk, dir := testMaker(t)
	old := filepath.Join(mk.Dir, strings.Repeat("f", 64)+".sqfs")
	if err := os.WriteFile(old, []byte("x"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "fail"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := mk.Device(); err == nil {
		t.Fatal("a failed making was taken")
	}
	if got := names(t, mk.Dir); !slices.Equal(got, []string{".lock", filepath.Base(old)}) {
		t.Fatalf("the volume holds %v", got)
	}
}

func TestAMakingPastItsDeadlineIsKilledWithItsGroup(t *testing.T) {
	mk, _ := testMaker(t)
	tool := mk.Tool
	// The stand-in writes its output, leaves a child holding it, and never
	// ends: only its group's kill frees the output before makerOutputWait.
	mk.Tool = filepath.Join(filepath.Dir(tool), "slow")
	slow := "#!/bin/sh\n: > \"$2\"\nsleep 5 & # sleep-ok: the stand-in outlives its deadline\nsleep 5 # sleep-ok: the stand-in outlives its deadline\n"
	if err := os.WriteFile(mk.Tool, []byte(slow), 0o755); err != nil {
		t.Fatal(err)
	}
	mk.Deadline = 200 * time.Millisecond
	start := time.Now()
	_, _, err := mk.Device()
	if elapsed := time.Since(start); !errors.Is(err, ErrMakeDeadline) || elapsed > mk.Deadline+time.Second {
		t.Fatalf("the making ended after %s, deadline %s: %v", elapsed, mk.Deadline, err)
	}
	if got := names(t, mk.Dir); !slices.Equal(got, []string{".lock"}) {
		t.Fatalf("the volume holds %v", got)
	}
	mk.Tool, mk.Wait = tool, 0
	if _, made := device(t, mk); !made {
		t.Fatal("the next start did not make the device")
	}
}

func TestAStartWaitsForAnotherMakingAndTakesItsDevice(t *testing.T) {
	mk, dir := testMaker(t)
	stop := filepath.Join(dir, "stop")
	if err := os.WriteFile(stop, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	type result struct {
		dev  *Device
		made bool
		err  error
	}
	results := make(chan result, 2)
	var wg sync.WaitGroup
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			d, m, err := mk.Device()
			results <- result{d, m, err}
		}()
	}
	// One start is making; the other waits on the lock.
	began(t, dir)
	if err := os.Remove(stop); err != nil {
		t.Fatal(err)
	}
	wg.Wait()
	close(results)
	var made int
	for r := range results {
		if r.err != nil || r.dev.Path != filepath.Join(mk.Dir, digest+".sqfs") {
			t.Fatalf("a start: %+v", r)
		}
		_ = r.dev.Close()
		if r.made {
			made++
		}
	}
	if made != 1 {
		t.Fatalf("%d starts made the device", made)
	}
}

func TestAStartPastTheBoundIsRefusedWithItsReason(t *testing.T) {
	mk, dir := testMaker(t)
	if err := os.WriteFile(filepath.Join(dir, "stop"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	maker := make(chan error, 1)
	go func() {
		dev, _, err := mk.Device()
		if err == nil {
			_ = dev.Close()
		}
		maker <- err
	}()
	waiter := mk
	waiter.Wait = 200 * time.Millisecond
	began(t, dir)
	refused := make(chan error, 1)
	go func() { _, _, err := waiter.Device(); refused <- err }()
	select {
	case err := <-refused:
		if !errors.Is(err, ErrMaking) {
			t.Fatalf("a start past the bound: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a start past the bound was not refused")
	}
	_ = os.Remove(filepath.Join(dir, "stop"))
	if err := <-maker; err != nil {
		t.Fatalf("the maker: %v", err)
	}
}

func TestDeviceRefusesAnImageWithoutItsIdentity(t *testing.T) {
	mk, _ := testMaker(t)
	for _, raw := range []string{"", "not a digest", strings.Repeat("A", 64)} {
		if err := os.WriteFile(mk.Digest, []byte(raw), 0o644); err != nil {
			t.Fatal(err)
		}
		if _, _, err := mk.Device(); err == nil {
			t.Fatalf("identity %q was taken", raw)
		}
	}
	_ = os.Remove(mk.Digest)
	if _, _, err := mk.Device(); err == nil {
		t.Fatal("a missing identity was taken")
	}
}

// bindsJob is the bound mounts test's child's: the maker, and the binds it
// makes in its own mount namespace first, none when bubblewrap made them.
type bindsJob struct {
	Maker Maker
	Binds [][2]string
}

// The child's exits other than 0, beside a Go test binary's own 1 and 2.
const (
	childFailed  = 3
	childRefused = 4
)

// bindsChild binds the job's mounts and makes the device with them in its
// mount namespace's table.
func bindsChild(raw string) int {
	var job bindsJob
	if err := json.Unmarshal([]byte(raw), &job); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return childFailed
	}
	if len(job.Binds) > 0 {
		if err := unix.Mount("", "/", "", unix.MS_REC|unix.MS_PRIVATE, ""); err != nil {
			fmt.Fprintln(os.Stderr, "no mount:", err)
			return childRefused
		}
	}
	for _, b := range job.Binds {
		if err := unix.Mount(b[0], b[1], "", unix.MS_BIND, ""); err != nil {
			fmt.Fprintln(os.Stderr, "no mount:", err)
			return childRefused
		}
	}
	job.Maker.Log = os.Stderr
	dev, _, err := job.Maker.Device()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return childFailed
	}
	_ = dev.Close()
	return 0
}

// runChild runs cmd as the bound mounts test's child with job.
func runChild(t *testing.T, cmd *exec.Cmd, job bindsJob) ([]byte, error) {
	t.Helper()
	raw, err := json.Marshal(job)
	if err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	cmd.Env = append(os.Environ(), bindsMode+"="+string(raw))
	cmd.Stdout, cmd.Stderr = &out, &out
	err = cmd.Run()
	return out.Bytes(), err
}

// listing is what a device holds, each path relative to its root.
func listing(t *testing.T, path string) []string {
	t.Helper()
	out, err := exec.Command("unsquashfs", "-l", path).Output()
	if err != nil {
		t.Fatalf("unsquashfs: %v", err)
	}
	var got []string
	for line := range strings.Lines(string(out)) {
		if rel, ok := strings.CutPrefix(strings.TrimSuffix(line, "\n"), "squashfs-root"); ok {
			got = append(got, strings.TrimPrefix(rel, "/"))
		}
	}
	slices.Sort(got)
	return got
}

// The walk's -one-file-system compares device numbers, which a folder or a
// file bound from the root's own filesystem shares with the root: only the
// mount table names them.
func TestABindOfTheRootsOwnFilesystemStaysOutOfTheDevice(t *testing.T) {
	if _, err := os.Stat(Mksquashfs); err != nil {
		t.Skipf("this host has no %s: %v", Mksquashfs, err)
	}
	if _, err := exec.LookPath("unsquashfs"); err != nil {
		t.Skipf("this host has no unsquashfs: %v", err)
	}
	base := t.TempDir()
	root := filepath.Join(base, "root")
	// The folder's mount point is named so that, read as a pattern, it
	// would match its kept sibling "a x".
	folder, file := filepath.Join(root, "a *[x]"), filepath.Join(root, "etc", "hosts")
	for _, d := range []string{folder, filepath.Join(root, "a x"), filepath.Join(root, "etc"), filepath.Join(base, "bound")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for f, body := range map[string]string{
		filepath.Join(root, "a x", "kept"): "kept", filepath.Join(root, "etc", "kept"): "kept", file: "",
		filepath.Join(base, "bound", "secret"): "secret", filepath.Join(base, "bound", ".hidden"): "secret",
		filepath.Join(base, "bound-file"): "secret",
	} {
		if err := os.WriteFile(f, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	guest := filepath.Join(base, "guest")
	if err := os.Mkdir(guest, 0o755); err != nil {
		t.Fatal(err)
	}
	id := filepath.Join(base, "image-digest")
	if err := os.WriteFile(id, []byte(digest), 0o644); err != nil {
		t.Fatal(err)
	}
	job := bindsJob{
		Maker: Maker{Dir: guest, Digest: id, Tool: Mksquashfs, Root: root, Mounts: MountTable, Wait: time.Minute, Deadline: time.Minute},
		Binds: [][2]string{{filepath.Join(base, "bound"), folder}, {filepath.Join(base, "bound-file"), file}},
	}
	child := exec.Command(os.Args[0], "-test.run=^$")
	child.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags:  syscall.CLONE_NEWUSER | syscall.CLONE_NEWNS,
		UidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: os.Getuid(), Size: 1}},
		GidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: os.Getgid(), Size: 1}},
		Pdeathsig:   syscall.SIGKILL,
	}
	out, err := runChild(t, child, job)
	if child.ProcessState == nil && (errors.Is(err, syscall.EPERM) || errors.Is(err, syscall.EINVAL) || errors.Is(err, syscall.ENOSPC)) ||
		child.ProcessState != nil && child.ProcessState.ExitCode() == childRefused {
		// Ubuntu's AppArmor gives a plain process's user namespace no
		// capability and allows bubblewrap's, which makes the same binds.
		bwrap, lookErr := exec.LookPath("bwrap")
		if lookErr != nil {
			t.Skipf("this host gives the test no user and mount namespace of its own, and has no bubblewrap: %v %s", err, out)
		}
		args := []string{"--dev-bind", "/", "/"}
		for _, b := range job.Binds {
			args = append(args, "--bind", b[0], b[1])
		}
		bound := job
		bound.Binds = nil
		wrapped := exec.Command(bwrap, append(args, "--", os.Args[0], "-test.run=^$")...)
		wrappedOut, wrappedErr := runChild(t, wrapped, bound)
		// bubblewrap's own refusal exits 1, which the child never does.
		if wrapped.ProcessState == nil || wrapped.ProcessState.ExitCode() == 1 {
			t.Skipf("this host gives the test no user and mount namespace of its own: %v %s; bubblewrap: %v %s", err, out, wrappedErr, wrappedOut)
		}
		t.Logf("bubblewrap made the binds: the test's own namespace was refused: %v %s", err, out)
		out, err = wrappedOut, wrappedErr
	}
	if err != nil {
		t.Fatalf("the child: %v\n%s", err, out)
	}
	got := listing(t, filepath.Join(guest, digest+".sqfs"))
	if want := []string{"", "a *[x]", "a x", "a x/kept", "etc", "etc/kept"}; !slices.Equal(got, want) {
		t.Fatalf("the device holds %q, want %q", got, want)
	}
}
