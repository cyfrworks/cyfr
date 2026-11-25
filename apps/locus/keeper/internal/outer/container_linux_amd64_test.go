// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux && amd64

package outer

import (
	"encoding/json"
	"os"
	"reflect"
	"slices"
	"testing"

	"golang.org/x/sys/unix"
)

// containerProfile is the profile every service of the stack but Locus runs
// under (docker-compose.yml's container.seccomp.json): Docker's default with
// its comparisons corrected.
func containerProfile(t *testing.T) []byte {
	t.Helper()
	profile, err := os.ReadFile("../../seccomp/container.json")
	if err != nil {
		t.Fatal(err)
	}
	return profile
}

// dockerDefaultCaps are the capabilities Docker gives a container that
// neither drops nor adds one (moby's oci/caps DefaultCapabilities), which
// the cyfr service holds.
var dockerDefaultCaps = []string{
	"CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_FSETID", "CAP_FOWNER", "CAP_MKNOD", "CAP_NET_RAW", "CAP_SETGID",
	"CAP_SETUID", "CAP_SETFCAP", "CAP_SETPCAP", "CAP_NET_BIND_SERVICE", "CAP_SYS_CHROOT", "CAP_KILL", "CAP_AUDIT_WRITE",
}

// Under container.json, each service of docker-compose.yml that runs under
// it, holding its own capabilities, is refused an AF_VSOCK socket however
// the domain's high word is set, as the kernel reads only its low 32 bits,
// and keeps the families it uses; it is refused every namespace and mount,
// as Docker's default refuses them.
func TestContainerProfileDecidesEachServicesCalls(t *testing.T) {
	const thread = unix.CLONE_VM | unix.CLONE_FS | unix.CLONE_FILES | unix.CLONE_SIGHAND | unix.CLONE_THREAD |
		unix.CLONE_SYSVSEM | unix.CLONE_SETTLS | unix.CLONE_PARENT_SETTID | unix.CLONE_CHILD_CLEARTID
	fork := uint64(unix.SIGCHLD)
	for _, service := range []struct {
		name string
		caps []string
	}{
		{"cyfr, holding Docker's default capabilities", dockerDefaultCaps},
		{"locus-guard, holding NET_ADMIN alone", []string{"CAP_NET_ADMIN"}},
		{"caddy, holding NET_BIND_SERVICE alone", []string{"CAP_NET_BIND_SERVICE"}},
		{"tailscale, holding none", nil},
	} {
		t.Run(service.name, func(t *testing.T) {
			raw, err := Compile(containerProfile(t), amd64Table(t), service.caps, testRelease)
			if err != nil {
				t.Fatal(err)
			}
			decide := decider(t, raw)
			on := func(nr uint32, args ...uint64) uint32 { return decide(nr, unix.AUDIT_ARCH_X86_64, args...) }
			checkDecisions(t, on, []decision{
				{"read", unix.SYS_READ, nil, allow},
				{"socket(AF_INET)", unix.SYS_SOCKET, []uint64{unix.AF_INET, unix.SOCK_STREAM}, allow},
				{"socket(AF_INET6)", unix.SYS_SOCKET, []uint64{unix.AF_INET6, unix.SOCK_STREAM}, allow},
				{"socket(AF_UNIX)", unix.SYS_SOCKET, []uint64{unix.AF_UNIX, unix.SOCK_STREAM}, allow},
				{"socket(AF_NETLINK)", unix.SYS_SOCKET, []uint64{unix.AF_NETLINK, unix.SOCK_RAW}, allow},
				{"socket(AF_INET behind a high word)", unix.SYS_SOCKET, []uint64{1<<32 | unix.AF_INET, unix.SOCK_STREAM}, allow},
				{"socket(AF_VSOCK)", unix.SYS_SOCKET, []uint64{unix.AF_VSOCK, unix.SOCK_STREAM}, eperm},
				{"socket(AF_VSOCK behind a high word)", unix.SYS_SOCKET, []uint64{1<<32 | unix.AF_VSOCK, unix.SOCK_STREAM}, eperm},
				{"socket(AF_VSOCK behind every high bit)", unix.SYS_SOCKET, []uint64{0xffffffff_00000000 | unix.AF_VSOCK, unix.SOCK_STREAM}, eperm},
				{"socket(256), no family", unix.SYS_SOCKET, []uint64{256, unix.SOCK_STREAM}, eperm},
				{"socketpair(AF_UNIX)", unix.SYS_SOCKETPAIR, []uint64{unix.AF_UNIX, unix.SOCK_STREAM}, allow},
				{"socketpair(AF_VSOCK)", unix.SYS_SOCKETPAIR, []uint64{unix.AF_VSOCK, unix.SOCK_STREAM}, eperm},
				{"socketpair(AF_VSOCK behind a high word)", unix.SYS_SOCKETPAIR, []uint64{1<<32 | unix.AF_VSOCK, unix.SOCK_STREAM}, eperm},
				{"personality(PER_LINUX)", unix.SYS_PERSONALITY, []uint64{0}, allow},
				{"personality(PER_LINUX with a high word)", unix.SYS_PERSONALITY, []uint64{1 << 32}, allow},
				{"personality(1 with a high word)", unix.SYS_PERSONALITY, []uint64{1<<32 | 1}, eperm},
				{"clone of a thread", unix.SYS_CLONE, []uint64{thread}, allow},
				{"clone of a process", unix.SYS_CLONE, []uint64{fork}, allow},
				{"clone into a user namespace", unix.SYS_CLONE, []uint64{fork | unix.CLONE_NEWUSER}, eperm},
				{"clone into a mount namespace", unix.SYS_CLONE, []uint64{fork | unix.CLONE_NEWNS}, eperm},
				{"clone into a network namespace", unix.SYS_CLONE, []uint64{fork | unix.CLONE_NEWNET}, eperm},
				{"clone3, refused ENOSYS by its own rule", unix.SYS_CLONE3, nil, enosys},
				{"unshare", unix.SYS_UNSHARE, []uint64{unix.CLONE_NEWUSER}, eperm},
				{"setns", unix.SYS_SETNS, nil, eperm},
				{"mount", unix.SYS_MOUNT, nil, eperm},
				{"pivot_root", unix.SYS_PIVOT_ROOT, nil, eperm},
				{"io_uring_setup, which no rule names", unix.SYS_IO_URING_SETUP, nil, eperm},
			})
		})
	}
}

// container.json names no 32-bit sub-architecture beside either 64-bit
// one, so a container's filter takes no i386, x32 or 32-bit Arm call, and
// socketcall, which carries a socket's domain behind a pointer no filter
// reads, is not on its allow list. The compiler does not apply archMap (a
// person's machine takes 64-bit calls alone), so this reads the profile.
func TestContainerProfileNamesNo32BitCall(t *testing.T) {
	var parsed profile
	if err := json.Unmarshal(containerProfile(t), &parsed); err != nil {
		t.Fatal(err)
	}
	native := map[string]bool{}
	for _, a := range parsed.ArchMap {
		if a.Architecture == "SCMP_ARCH_X86_64" || a.Architecture == "SCMP_ARCH_AARCH64" {
			native[a.Architecture] = true
			if len(a.SubArchitectures) != 0 {
				t.Errorf("%s carries the sub-architectures %v", a.Architecture, a.SubArchitectures)
			}
		}
	}
	if len(native) != 2 {
		t.Errorf("the archMap names %v of x86-64 and aarch64", native)
	}
	for i, r := range parsed.Syscalls {
		if slices.Contains(r.Names, "socketcall") {
			t.Errorf("rule %d names socketcall", i)
		}
	}
}

// keeper.json is container.json and the keeper's three differences, and
// nothing else, so the two hand-kept copies of Docker's rules cannot part
// unseen: Docker's CAP_SYS_ADMIN rule without unshare and setns; Docker's
// two clone rules with every namespace but CLONE_NEWUTS taken out of the
// mask; and one rule more after them, allowing a space's mounts to a
// container without CAP_SYS_ADMIN. Comments are not compared.
func TestKeeperProfileIsTheContainerProfileAndItsThreeDifferences(t *testing.T) {
	const (
		dockerCloneMask = unix.CLONE_NEWNS | unix.CLONE_NEWCGROUP | unix.CLONE_NEWUTS | unix.CLONE_NEWIPC |
			unix.CLONE_NEWUSER | unix.CLONE_NEWPID | unix.CLONE_NEWNET
		keeperCloneMask = unix.CLONE_NEWUTS
	)
	keeper, container := withoutComments(t, keeperProfile(t)), withoutComments(t, containerProfile(t))
	var mountRule map[string]any
	if err := json.Unmarshal([]byte(`{"names": ["mount", "umount2", "pivot_root", "mount_setattr"],
		"action": "SCMP_ACT_ALLOW", "excludes": {"caps": ["CAP_SYS_ADMIN"]}}`), &mountRule); err != nil {
		t.Fatal(err)
	}
	var want []any
	var adminRules, cloneRules, mountRules int
	for _, r := range container["syscalls"].([]any) {
		rule := r.(map[string]any)
		includes, _ := rule["includes"].(map[string]any)
		switch {
		case includes != nil && reflect.DeepEqual(includes["caps"], []any{"CAP_SYS_ADMIN"}) && slices.Contains(rule["names"].([]any), any("unshare")):
			adminRules++
			rule["names"] = slices.DeleteFunc(rule["names"].([]any), func(n any) bool { return n == "unshare" || n == "setns" })
			want = append(want, rule)
		case reflect.DeepEqual(rule["names"], []any{"clone"}) && rule["args"] != nil:
			arg := rule["args"].([]any)[0].(map[string]any)
			if arg["value"] != float64(dockerCloneMask) {
				t.Fatalf("container.json's clone rule masks %v, not Docker's %d", arg["value"], dockerCloneMask)
			}
			cloneRules++
			arg["value"] = float64(keeperCloneMask)
			want = append(want, rule)
			if cloneRules == 2 {
				mountRules++
				want = append(want, mountRule)
			}
		default:
			want = append(want, rule)
		}
	}
	if adminRules != 1 || cloneRules != 2 || mountRules != 1 {
		t.Fatalf("container.json holds %d CAP_SYS_ADMIN rules with unshare and %d clone rules, want 1 and 2", adminRules, cloneRules)
	}
	container["syscalls"] = want
	if !reflect.DeepEqual(container, keeper) {
		got, _ := json.MarshalIndent(container, "", "\t")
		wantKeeper, _ := json.MarshalIndent(keeper, "", "\t")
		t.Errorf("keeper.json is not container.json and its three differences:\ncontainer.json with them:\n%s\nkeeper.json:\n%s", got, wantKeeper)
	}
}

// withoutComments decodes a profile with every rule's comment taken out.
func withoutComments(t *testing.T, raw []byte) map[string]any {
	t.Helper()
	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatal(err)
	}
	for _, r := range decoded["syscalls"].([]any) {
		delete(r.(map[string]any), "comment")
	}
	return decoded
}
