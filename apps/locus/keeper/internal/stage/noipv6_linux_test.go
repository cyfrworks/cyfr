// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package stage

import (
	"os"
	"os/exec"
	"strings"
	"syscall"
	"testing"

	"golang.org/x/sys/unix"
)

// A person's machine's space mounts its own proc and holds no IPv6 in its
// network namespace, on the links it has and the ones it gets later; any
// other space's proc leaves IPv6 as the namespace has it. As root in a
// user, mount, network and process namespace of the test's own, as a
// stage's first process builds its space: keeper-ci's real-kernel step,
// under the Locus profile, which refuses the same write through /proc/sys.
func TestAPersonsMachineSpaceHoldsNoIPv6(t *testing.T) {
	if machine := os.Getenv("CYFR_STAGE_NOIPV6"); machine != "" {
		ipv6Space(t, machine == "machine")
		return
	}
	if os.Getuid() != 0 {
		t.Skip("building a space's proc at its root needs root")
	}
	for _, kind := range []string{"machine", "space"} {
		cmd := exec.Command(os.Args[0], "-test.run=^TestAPersonsMachineSpaceHoldsNoIPv6$", "-test.count=1", "-test.v")
		cmd.Env = append(os.Environ(), "CYFR_STAGE_NOIPV6="+kind)
		cmd.SysProcAttr = &syscall.SysProcAttr{
			Cloneflags:  syscall.CLONE_NEWUSER | syscall.CLONE_NEWNS | syscall.CLONE_NEWNET | syscall.CLONE_NEWPID,
			UidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: 0, Size: 1}},
			GidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: 0, Size: 1}},
		}
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("%s: %s (%v)", kind, out, err)
		}
		if !strings.Contains(string(out), "--- PASS") {
			t.Fatalf("the %s's side did not pass:\n%s", kind, out)
		}
	}
}

func ipv6Space(t *testing.T, machine bool) {
	if err := unix.Mount("", "/", "", unix.MS_REC|unix.MS_PRIVATE, ""); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(Root, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := unix.Mount("space", Root, "tmpfs", unix.MS_NOSUID|unix.MS_NODEV, "mode=0755,size=4m"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(Root+"/proc", 0o755); err != nil {
		t.Fatal(err)
	}
	if err := spaceProc(machine); err != nil {
		t.Fatalf("the space's proc: %v", err)
	}
	want := "0"
	if machine {
		want = "1"
	}
	// lo stands for the links the namespace holds as the space is built,
	// default for the ones it gets after.
	for _, conf := range []string{"all", "default", "lo"} {
		v, err := os.ReadFile("/proc/sys/net/ipv6/conf/" + conf + "/disable_ipv6")
		if err != nil || strings.TrimSpace(string(v)) != want {
			t.Fatalf("machine %t: %s's disable_ipv6 reads %q (%v), not %s", machine, conf, strings.TrimSpace(string(v)), err, want)
		}
	}
}
