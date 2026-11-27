// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package stage

import (
	"os"
	"os/exec"
	"strings"
	"syscall"
	"testing"
	"unsafe"

	"golang.org/x/sys/unix"
)

// A person's machine's space is given the tun device at its own path,
// /dev/net/tun, where the VMM opens it, by the recursive bind the Locus
// profile allows into the space (a plain one it refuses), and nothing else
// of /dev/net. As root in a user and mount namespace of the test's own, as
// a stage builds its space: keeper-ci's real-kernel step, under the
// profile, given /dev/net/tun.
func TestAPersonsMachineSpaceHasTheTunDeviceAtItsOwnPath(t *testing.T) {
	if os.Getenv("CYFR_STAGE_TUN") == "1" {
		tunSpace(t)
		return
	}
	if os.Getuid() != 0 {
		t.Skip("building a space's /dev at its root needs root")
	}
	if _, err := os.Stat("/dev/net/tun"); err != nil {
		t.Skipf("this host has no /dev/net/tun: %v", err)
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestAPersonsMachineSpaceHasTheTunDeviceAtItsOwnPath$", "-test.count=1", "-test.v")
	cmd.Env = append(os.Environ(), "CYFR_STAGE_TUN=1")
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags:  syscall.CLONE_NEWUSER | syscall.CLONE_NEWNS,
		UidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: 0, Size: 1}},
		GidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: 0, Size: 1}},
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%s (%v)", out, err)
	}
	if !strings.Contains(string(out), "--- PASS") {
		t.Fatalf("the space's side did not pass:\n%s", out)
	}
}

func tunSpace(t *testing.T) {
	if err := unix.Mount("", "/", "", unix.MS_REC|unix.MS_PRIVATE, ""); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(Root, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := unix.Mount("space", Root, "tmpfs", unix.MS_NOSUID|unix.MS_NODEV, "mode=0755,size=4m"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(Root+"/dev", 0o755); err != nil {
		t.Fatal(err)
	}
	if err := unix.Mount("space-dev", Root+"/dev", "tmpfs", unix.MS_NOSUID, "mode=0755,size=64k"); err != nil {
		t.Fatal(err)
	}
	if err := buildDev(false, true); err != nil {
		t.Fatalf("the space's /dev: %v", err)
	}
	info, err := os.Lstat(Root + "/dev/net/tun")
	if err != nil || info.Mode()&os.ModeCharDevice == 0 {
		t.Fatalf("the space's /dev/net/tun is %v (%v), not the device", info, err)
	}
	fd, err := unix.Open(Root+"/dev/net/tun", unix.O_RDWR|unix.O_CLOEXEC, 0)
	if err != nil {
		t.Fatalf("opening the space's /dev/net/tun: %v", err)
	}
	defer unix.Close(fd)
	var features uint32
	if _, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), unix.TUNGETFEATURES, uintptr(unsafe.Pointer(&features))); errno != 0 || features&unix.IFF_TAP == 0 {
		t.Fatalf("the space's /dev/net/tun is no tun device: %v, features %#x", errno, features)
	}
	entries, err := os.ReadDir(Root + "/dev/net")
	if err != nil || len(entries) != 1 || entries[0].Name() != "tun" {
		t.Fatalf("the space's /dev/net holds %v (%v), not tun alone", entries, err)
	}
	if _, err := os.Lstat(Root + "/dev/tun"); !os.IsNotExist(err) {
		t.Fatalf("the space holds a /dev/tun: %v", err)
	}
}
