// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux && amd64

package outer

import (
	"encoding/binary"
	"encoding/json"
	"os"
	"slices"
	"strings"
	"testing"

	"golang.org/x/net/bpf"
	"golang.org/x/sys/unix"
)

const (
	allow  = unix.SECCOMP_RET_ALLOW
	kill   = unix.SECCOMP_RET_KILL_PROCESS
	eperm  = unix.SECCOMP_RET_ERRNO | uint32(unix.EPERM)
	enosys = unix.SECCOMP_RET_ERRNO | uint32(unix.ENOSYS)
)

// locusCaps are the Locus container's capabilities (Dockerfile.locus): it
// drops every one and adds these.
var locusCaps = []string{"CAP_SETUID", "CAP_SETGID", "CAP_KILL"}

// testRelease is a kernel past every minKernel keeper.json names.
const testRelease = "6.12.0-cyfr"

// keeperProfile is the profile the host's Locus container runs under.
func keeperProfile(t *testing.T) []byte {
	t.Helper()
	profile, err := os.ReadFile("../../seccomp/keeper.json")
	if err != nil {
		t.Fatal(err)
	}
	return profile
}

// seccompData is struct seccomp_data for a call on x86-64 as the BPF
// machine of these tests reads it: the machine loads each 32-bit word in
// network order, where the kernel's filter loads it in the machine's own,
// so each word is written big-endian, at the place x86-64 keeps it, a
// 64-bit argument's low word first.
func seccompData(nr, arch uint32, args ...uint64) []byte {
	data := make([]byte, 64)
	binary.BigEndian.PutUint32(data[dataNR:], nr)
	binary.BigEndian.PutUint32(data[dataArch:], arch)
	for i, arg := range args {
		binary.BigEndian.PutUint32(data[dataArgs+8*i:], uint32(arg))
		binary.BigEndian.PutUint32(data[dataArgs+8*i+4:], uint32(arg>>32))
	}
	return data
}

// decider runs a compiled filter over the calls it is shown.
func decider(t *testing.T, raw []bpf.RawInstruction) func(nr, arch uint32, args ...uint64) uint32 {
	t.Helper()
	program, ok := bpf.Disassemble(raw)
	if !ok {
		t.Fatal("the filter does not disassemble")
	}
	vm, err := bpf.NewVM(program)
	if err != nil {
		t.Fatal(err)
	}
	return func(nr, arch uint32, args ...uint64) uint32 {
		got, err := vm.Run(seccompData(nr, arch, args...))
		if err != nil {
			t.Fatal(err)
		}
		return uint32(got)
	}
}

func compileKeeper(t *testing.T, caps []string, release string) func(nr uint32, args ...uint64) uint32 {
	t.Helper()
	raw, err := Compile(keeperProfile(t), amd64Table(t), caps, release)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("the filter is %d instructions", len(raw))
	decide := decider(t, raw)
	return func(nr uint32, args ...uint64) uint32 { return decide(nr, unix.AUDIT_ARCH_X86_64, args...) }
}

type decision struct {
	what string
	nr   uint32
	args []uint64
	want uint32
}

func checkDecisions(t *testing.T, decide func(uint32, ...uint64) uint32, decisions []decision) {
	t.Helper()
	for _, d := range decisions {
		if got := decide(d.nr, d.args...); got != d.want {
			t.Errorf("%s: %#x, want %#x", d.what, got, d.want)
		}
	}
}

// Under keeper.json, a container holding the Locus container's
// capabilities is allowed and refused each call as Docker would decide it,
// and a call whose int argument hides a refused value behind a high word is
// refused as the kernel will read it. keeper.json's clone rule masks only
// CLONE_NEWUTS: clone is allowed unless its flags hold that bit, so a clone
// into a mount namespace is allowed and one into a UTS namespace is not.
func TestKeeperProfileDecidesTheLocusContainersCalls(t *testing.T) {
	decide := compileKeeper(t, locusCaps, testRelease)
	const thread = unix.CLONE_VM | unix.CLONE_FS | unix.CLONE_FILES | unix.CLONE_SIGHAND | unix.CLONE_THREAD |
		unix.CLONE_SYSVSEM | unix.CLONE_SETTLS | unix.CLONE_PARENT_SETTID | unix.CLONE_CHILD_CLEARTID
	fork := uint64(unix.SIGCHLD)
	checkDecisions(t, decide, []decision{
		{"read", unix.SYS_READ, nil, allow},
		{"socket(AF_INET)", unix.SYS_SOCKET, []uint64{unix.AF_INET, unix.SOCK_STREAM}, allow},
		{"socket(AF_VSOCK)", unix.SYS_SOCKET, []uint64{unix.AF_VSOCK, unix.SOCK_STREAM}, eperm},
		{"socket(AF_VSOCK behind a high word)", unix.SYS_SOCKET, []uint64{1<<32 | unix.AF_VSOCK, unix.SOCK_STREAM}, eperm},
		{"socket(AF_INET behind a high word)", unix.SYS_SOCKET, []uint64{1<<32 | unix.AF_INET, unix.SOCK_STREAM}, allow},
		{"io_uring_setup, which no rule names", unix.SYS_IO_URING_SETUP, nil, eperm},
		{"clone3, refused ENOSYS by its own rule", unix.SYS_CLONE3, nil, enosys},
		{"unshare", unix.SYS_UNSHARE, []uint64{unix.CLONE_NEWUSER}, eperm},
		{"setns", unix.SYS_SETNS, nil, eperm},
		{"mount, whose rule excludes CAP_SYS_ADMIN", unix.SYS_MOUNT, nil, allow},
		{"clone of a thread", unix.SYS_CLONE, []uint64{thread}, allow},
		{"clone of a process", unix.SYS_CLONE, []uint64{fork}, allow},
		{"clone into a mount namespace", unix.SYS_CLONE, []uint64{fork | unix.CLONE_NEWNS}, allow},
		{"clone into a UTS namespace", unix.SYS_CLONE, []uint64{fork | unix.CLONE_NEWUTS}, eperm},
		{"clone into a UTS namespace with a high word", unix.SYS_CLONE, []uint64{1<<32 | fork | unix.CLONE_NEWUTS}, eperm},
		{"personality(PER_LINUX)", unix.SYS_PERSONALITY, []uint64{0}, allow},
		{"personality(PER_LINUX32)", unix.SYS_PERSONALITY, []uint64{8}, allow},
		{"personality(UNAME26)", unix.SYS_PERSONALITY, []uint64{0x20000}, allow},
		{"personality(query)", unix.SYS_PERSONALITY, []uint64{0xffffffff}, allow},
		{"personality(1)", unix.SYS_PERSONALITY, []uint64{1}, eperm},
		{"personality(PER_LINUX with a high word)", unix.SYS_PERSONALITY, []uint64{1 << 32}, eperm},
		{"ptrace, on a kernel past its minKernel", unix.SYS_PTRACE, nil, allow},
		{"arch_prctl, which the profile allows on amd64", unix.SYS_ARCH_PRCTL, nil, allow},
		{"chroot, which needs CAP_SYS_CHROOT", unix.SYS_CHROOT, nil, eperm},
		{"a number no call has", 1000, nil, eperm},
		{"an x32 call", x32SyscallBit | unix.SYS_READ, nil, kill},
	})
	raw, err := Compile(keeperProfile(t), amd64Table(t), locusCaps, testRelease)
	if err != nil {
		t.Fatal(err)
	}
	if got := decider(t, raw)(unix.SYS_READ, unix.AUDIT_ARCH_I386); got != kill {
		t.Errorf("a call under i386's numbers: %#x, want %#x", got, kill)
	}
}

// A rule includes a container only when it holds every capability the rule
// lists, and excludes it when it holds any: with CAP_SYS_ADMIN, clone3 and
// clone into any namespace follow Docker's CAP_SYS_ADMIN rule, which
// allows them, and the rules that exclude CAP_SYS_ADMIN drop away. unshare
// stays refused: keeper.json takes it out of that rule.
func TestKeeperProfileFollowsTheContainersCapabilities(t *testing.T) {
	decide := compileKeeper(t, append(slices.Clone(locusCaps), "CAP_SYS_ADMIN"), testRelease)
	checkDecisions(t, decide, []decision{
		{"clone3", unix.SYS_CLONE3, nil, allow},
		{"clone into a UTS namespace", unix.SYS_CLONE, []uint64{uint64(unix.SIGCHLD) | unix.CLONE_NEWUTS}, allow},
		{"mount", unix.SYS_MOUNT, nil, allow},
		{"unshare", unix.SYS_UNSHARE, nil, eperm},
		{"chroot", unix.SYS_CHROOT, nil, eperm},
	})
}

// A rule with a minKernel applies only on a kernel that reaches it: before
// 4.8, ptrace is refused to a container without CAP_SYS_PTRACE.
func TestKeeperProfileFollowsTheKernel(t *testing.T) {
	decide := compileKeeper(t, locusCaps, "4.4.0-generic")
	checkDecisions(t, decide, []decision{
		{"ptrace", unix.SYS_PTRACE, nil, eperm},
		{"read", unix.SYS_READ, nil, allow},
	})
}

// Every call of the kernel's table is decided as keeper.json's rules say:
// each name of its first rule, the outright allow list, is allowed; the
// other names its rules allow outright for this container are allowed; the
// calls decided on their arguments are allowed with every argument zero
// (socket(0), clone(0) and personality(PER_LINUX)); clone3 is ENOSYS; and
// every call no applicable rule names is refused. A run test that ended a
// number early or late would fail here.
func TestKeeperProfileDecidesEveryCallOfTheTable(t *testing.T) {
	var parsed profile
	if err := json.Unmarshal(keeperProfile(t), &parsed); err != nil {
		t.Fatal(err)
	}
	first := parsed.Syscalls[0]
	if first.Action != "SCMP_ACT_ALLOW" || first.Args != nil || first.Includes != nil || first.Excludes != nil {
		t.Fatalf("keeper.json's first rule is not its outright allow list: %+v", first)
	}
	want := map[string]uint32{}
	for _, name := range first.Names {
		want[name] = allow
	}
	for _, name := range []string{"ptrace", "process_vm_readv", "process_vm_writev", "arch_prctl", "modify_ldt",
		"mount", "umount2", "pivot_root", "mount_setattr", "socket", "clone", "personality"} {
		want[name] = allow
	}
	want["clone3"] = enosys
	decide := compileKeeper(t, locusCaps, testRelease)
	for name, nr := range amd64Calls {
		expected, ok := want[name]
		if !ok {
			expected = eperm
		}
		if got := decide(nr); got != expected {
			t.Errorf("%s (%d) with zero arguments: %#x, want %#x", name, nr, got, expected)
		}
	}
}

// A name an applicable rule lists that the kernel's table lacks is skipped,
// as libseccomp skips a name the architecture does not know: keeper.json's
// 32-bit calls are absent from x86-64's table. A rule that does not apply
// is not counted.
func TestKeeperProfileSkipsNamesTheTableLacks(t *testing.T) {
	decided, err := resolve(keeperProfile(t), amd64Table(t), locusCaps, testRelease)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("%d names skipped: %s", len(decided.skipped), strings.Join(decided.skipped, " "))
	for _, name := range decided.skipped {
		if _, ok := amd64Calls[name]; ok {
			t.Errorf("%s is skipped though the table numbers it", name)
		}
	}
	for _, name := range []string{"chown32", "_llseek", "socketcall", "mmap2"} {
		if !slices.Contains(decided.skipped, name) {
			t.Errorf("%s is not skipped", name)
		}
	}
	for _, name := range []string{"arm_fadvise64_64", "s390_runtime_instr", "open_by_handle_at", "acct"} {
		if slices.Contains(decided.skipped, name) {
			t.Errorf("%s, whose rule does not apply, is counted as skipped", name)
		}
	}
}

// Whatever the filter cannot apply as Docker would is refused, never
// compiled to a filter that allows more.
func TestCompileRefusesWhatItCannotApply(t *testing.T) {
	table := amd64Table(t)
	for what, profile := range map[string]string{
		"a profile cut short":             `{"defaultAction": "SCMP_ACT_ERRNO", "syscalls": [`,
		"data after the profile":          `{"defaultAction": "SCMP_ACT_ERRNO", "syscalls": []} {}`,
		"no default action":               `{"syscalls": [{"names": ["read"], "action": "SCMP_ACT_ALLOW"}]}`,
		"an unknown field":                `{"defaultAction": "SCMP_ACT_ERRNO", "listenerPath": "/run/l", "syscalls": []}`,
		"an unknown rule field":           `{"defaultAction": "SCMP_ACT_ERRNO", "syscalls": [{"name": "read", "action": "SCMP_ACT_ALLOW"}]}`,
		"an unknown default action":       `{"defaultAction": "SCMP_ACT_LOG", "syscalls": []}`,
		"an unknown action":               `{"defaultAction": "SCMP_ACT_ERRNO", "syscalls": [{"names": ["read"], "action": "SCMP_ACT_TRACE"}]}`,
		"an unknown action, inapplicable": `{"defaultAction": "SCMP_ACT_ERRNO", "syscalls": [{"names": ["read"], "action": "SCMP_ACT_KILL", "includes": {"arches": ["s390x"]}}]}`,
		"an unknown comparison":           `{"defaultAction": "SCMP_ACT_ERRNO", "syscalls": [{"names": ["socket"], "action": "SCMP_ACT_ALLOW", "args": [{"index": 0, "value": 1, "op": "SCMP_CMP_BOGUS"}]}]}`,
		"an ordered comparison":           `{"defaultAction": "SCMP_ACT_ERRNO", "syscalls": [{"names": ["socket"], "action": "SCMP_ACT_ALLOW", "args": [{"index": 0, "value": 40, "op": "SCMP_CMP_LT"}]}]}`,
		"a seventh argument":              `{"defaultAction": "SCMP_ACT_ERRNO", "syscalls": [{"names": ["socket"], "action": "SCMP_ACT_ALLOW", "args": [{"index": 6, "value": 1, "op": "SCMP_CMP_EQ"}]}]}`,
		"two conditions on one argument":  `{"defaultAction": "SCMP_ACT_ERRNO", "syscalls": [{"names": ["socket"], "action": "SCMP_ACT_ALLOW", "args": [{"index": 0, "value": 1, "op": "SCMP_CMP_EQ"}, {"index": 0, "value": 2, "op": "SCMP_CMP_EQ"}]}]}`,
		"a valueTwo beside EQ":            `{"defaultAction": "SCMP_ACT_ERRNO", "syscalls": [{"names": ["socket"], "action": "SCMP_ACT_ALLOW", "args": [{"index": 0, "value": 1, "valueTwo": 2, "op": "SCMP_CMP_EQ"}]}]}`,
		"a conditional refusal":           `{"defaultAction": "SCMP_ACT_ALLOW", "syscalls": [{"names": ["socket"], "action": "SCMP_ACT_ERRNO", "args": [{"index": 0, "value": 40, "op": "SCMP_CMP_EQ"}]}]}`,
		"two actions for one call": `{"defaultAction": "SCMP_ACT_ERRNO", "syscalls": [{"names": ["clone3"], "action": "SCMP_ACT_ERRNO", "errnoRet": 38},
			{"names": ["clone3"], "action": "SCMP_ACT_ALLOW", "args": [{"index": 1, "value": 88, "op": "SCMP_CMP_EQ"}]}]}`,
		"errno 0":                 `{"defaultAction": "SCMP_ACT_ERRNO", "defaultErrnoRet": 0, "syscalls": []}`,
		"an errno past MAX_ERRNO": `{"defaultAction": "SCMP_ACT_ERRNO", "syscalls": [{"names": ["read"], "action": "SCMP_ACT_ERRNO", "errnoRet": 65537}]}`,
		"an errno beside ALLOW":   `{"defaultAction": "SCMP_ACT_ERRNO", "syscalls": [{"names": ["read"], "action": "SCMP_ACT_ALLOW", "errnoRet": 1}]}`,
		"a malformed minKernel":   `{"defaultAction": "SCMP_ACT_ERRNO", "syscalls": [{"names": ["read"], "action": "SCMP_ACT_ALLOW", "includes": {"minKernel": "4"}}]}`,
		"an empty minKernel":      `{"defaultAction": "SCMP_ACT_ERRNO", "syscalls": [{"names": ["read"], "action": "SCMP_ACT_ALLOW", "excludes": {"minKernel": ""}}]}`,
		"a rule naming no call":   `{"defaultAction": "SCMP_ACT_ERRNO", "syscalls": [{"names": [], "action": "SCMP_ACT_ALLOW"}]}`,
	} {
		if raw, err := Compile([]byte(profile), table, locusCaps, testRelease); err == nil {
			t.Errorf("%s: compiled to %d instructions", what, len(raw))
		}
	}
	profile := keeperProfile(t)
	if _, err := Compile(profile, map[string]uint32{}, locusCaps, testRelease); err == nil {
		t.Error("an empty table compiled")
	}
	if _, err := Compile(profile, table, []string{"SYS_ADMIN"}, testRelease); err == nil {
		t.Error("a capability not named CAP_* compiled")
	}
	if _, err := Compile(profile, table, locusCaps, "linux"); err == nil {
		t.Error("a release without a version compiled")
	}
}

// A rule whose action is the default's is skipped, as runc skips it, so it
// conflicts with no other; a rule's SCMP_ACT_ERRNO without errnoRet is
// EPERM, as runc makes it, whatever the profile's defaultErrnoRet; and an
// unconditional rule decides its call over a conditional one of the same
// action.
func TestCompileFollowsRuncsActions(t *testing.T) {
	profile := `{"defaultAction": "SCMP_ACT_ERRNO", "defaultErrnoRet": 38, "syscalls": [
		{"names": ["read"], "action": "SCMP_ACT_ALLOW"},
		{"names": ["read"], "action": "SCMP_ACT_ERRNO", "errnoRet": 38, "args": [{"index": 0, "value": 3, "op": "SCMP_CMP_EQ"}]},
		{"names": ["write"], "action": "SCMP_ACT_ERRNO"},
		{"names": ["close"], "action": "SCMP_ACT_ALLOW", "args": [{"index": 0, "value": 3, "op": "SCMP_CMP_EQ"}]},
		{"names": ["close"], "action": "SCMP_ACT_ALLOW"}]}`
	raw, err := Compile([]byte(profile), amd64Table(t), locusCaps, testRelease)
	if err != nil {
		t.Fatal(err)
	}
	decide := decider(t, raw)
	on := func(nr uint32, args ...uint64) uint32 { return decide(nr, unix.AUDIT_ARCH_X86_64, args...) }
	checkDecisions(t, on, []decision{
		{"read(3)", unix.SYS_READ, []uint64{3}, allow},
		{"write", unix.SYS_WRITE, nil, eperm},
		{"close(4)", unix.SYS_CLOSE, []uint64{4}, allow},
		{"getpid", unix.SYS_GETPID, nil, enosys},
	})
}

// A rule's includes need every capability they list and its excludes drop
// it on any one, as moby/profiles' setupSeccomp reads them. keeper.json's
// rules each list one, so this profile lists two.
func TestCompileReadsCapabilitiesAsDocker(t *testing.T) {
	profile := `{"defaultAction": "SCMP_ACT_ERRNO", "syscalls": [
		{"names": ["chroot"], "action": "SCMP_ACT_ALLOW", "includes": {"caps": ["CAP_SYS_CHROOT", "CAP_SYS_ADMIN"]}},
		{"names": ["acct"], "action": "SCMP_ACT_ALLOW", "excludes": {"caps": ["CAP_SYS_PACCT", "CAP_SYS_ADMIN"]}}]}`
	for _, c := range []struct {
		caps         []string
		chroot, acct uint32
	}{
		{nil, eperm, allow},
		{[]string{"CAP_SYS_CHROOT"}, eperm, allow},
		{[]string{"CAP_SYS_CHROOT", "CAP_SYS_ADMIN"}, allow, eperm},
		{[]string{"CAP_SYS_PACCT"}, eperm, eperm},
	} {
		raw, err := Compile([]byte(profile), amd64Table(t), c.caps, testRelease)
		if err != nil {
			t.Fatal(err)
		}
		decide := decider(t, raw)
		if got := decide(unix.SYS_CHROOT, unix.AUDIT_ARCH_X86_64); got != c.chroot {
			t.Errorf("holding %v, chroot: %#x, want %#x", c.caps, got, c.chroot)
		}
		if got := decide(unix.SYS_ACCT, unix.AUDIT_ARCH_X86_64); got != c.acct {
			t.Errorf("holding %v, acct: %#x, want %#x", c.caps, got, c.acct)
		}
	}
}
