// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package stage

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"unsafe"

	"golang.org/x/net/bpf"
	"golang.org/x/sys/unix"
)

// seccompData is struct seccomp_data as a filter on an architecture of the
// given byte order reads it. The kernel's filter loads each 32-bit word in
// the machine's own order, and the BPF machine of these tests in network
// order, so each word is written big-endian here, at the place the
// architecture keeps it: a 64-bit argument's low word first on a
// little-endian machine and second on a big-endian one.
func seccompData(bigEndian bool, nr, arch uint32, args ...uint64) []byte {
	data := make([]byte, 64)
	binary.BigEndian.PutUint32(data[0:], nr)
	binary.BigEndian.PutUint32(data[4:], arch)
	for i, arg := range args {
		low, high := 16+8*i, 16+8*i+4
		if bigEndian {
			low, high = high, low
		}
		binary.BigEndian.PutUint32(data[low:], uint32(arg))
		binary.BigEndian.PutUint32(data[high:], uint32(arg>>32))
	}
	return data
}

// The filter, run in a BPF machine over the call it is shown, decides every
// call as its comment says, on each architecture it describes: the order of
// clone's arguments and of a 64-bit argument's words is the architecture's.
func TestRunnerFilterDecidesEveryCall(t *testing.T) {
	calls := nativeSeccompCalls()
	const (
		allow  = unix.SECCOMP_RET_ALLOW
		kill   = unix.SECCOMP_RET_KILL_PROCESS
		eperm  = unix.SECCOMP_RET_ERRNO | uint32(unix.EPERM)
		enosys = unix.SECCOMP_RET_ERRNO | uint32(unix.ENOSYS)
		// What glibc's pthread_create and Go's runtime pass to clone.
		thread = unix.CLONE_VM | unix.CLONE_FS | unix.CLONE_FILES | unix.CLONE_SIGHAND |
			unix.CLONE_THREAD | unix.CLONE_SYSVSEM | unix.CLONE_SETTLS |
			unix.CLONE_PARENT_SETTID | unix.CLONE_CHILD_CLEARTID
		fork = uint64(unix.SIGCHLD)
	)
	namespaces := []uint64{unix.CLONE_NEWNS, unix.CLONE_NEWCGROUP, unix.CLONE_NEWUTS, unix.CLONE_NEWIPC,
		unix.CLONE_NEWUSER, unix.CLONE_NEWPID, unix.CLONE_NEWNET}
	for name, arch := range map[string]seccompArch{
		"amd64": {audit: unix.AUDIT_ARCH_X86_64, x32: true},
		"arm64": {audit: unix.AUDIT_ARCH_AARCH64},
		"s390x": {audit: unix.AUDIT_ARCH_S390X, cloneFlags: 1, bigEndian: true},
	} {
		t.Run(name, func(t *testing.T) {
			raw, err := runnerFilter(arch, calls)
			if err != nil {
				t.Fatal(err)
			}
			program, ok := bpf.Disassemble(raw)
			if !ok {
				t.Fatal("the filter does not disassemble")
			}
			vm, err := bpf.NewVM(program)
			if err != nil {
				t.Fatal(err)
			}
			order := arch.bigEndian
			// clone's flags in the argument the architecture reads them from,
			// a stack address in the other.
			clone := func(flags uint64) []byte {
				args := []uint64{flags, 0x7ffd0000}
				if arch.cloneFlags == 1 {
					args = []uint64{0x7ffd0000, flags}
				}
				return seccompData(order, calls.clone, arch.audit, args...)
			}
			decide := func(data []byte) uint32 {
				got, err := vm.Run(data)
				if err != nil {
					t.Fatal(err)
				}
				return uint32(got)
			}
			check := func(what string, data []byte, want uint32) {
				t.Helper()
				if got := decide(data); got != want {
					t.Errorf("%s: %#x, want %#x", what, got, want)
				}
			}
			for _, nr := range calls.refused {
				check("refused call", seccompData(order, nr, arch.audit), eperm)
			}
			for _, flag := range namespaces {
				check("clone with a namespace flag", clone(fork|flag), eperm)
				check("clone of a thread with a namespace flag", clone(thread|flag), eperm)
				// A namespace flag in the other argument is not clone's flags.
				other := []uint64{fork, flag}
				if arch.cloneFlags == 1 {
					other = []uint64{flag, fork}
				}
				check("clone with a namespace bit in its stack argument", seccompData(order, calls.clone, arch.audit, other...), allow)
			}
			check("clone of a thread", clone(thread), allow)
			check("clone of a process", clone(fork), allow)
			check("clone with a bit above the flags' low word", clone(fork|1<<40), allow)
			check("clone3", seccompData(order, calls.clone3, arch.audit), enosys)
			check("getpid", seccompData(order, unix.SYS_GETPID, arch.audit), allow)
			check("a call under another architecture's numbers", seccompData(order, unix.SYS_GETPID, unix.AUDIT_ARCH_I386), kill)
			if arch.x32 {
				check("an x32 call", seccompData(order, x32SyscallBit|unix.SYS_GETPID, arch.audit), kill)
			}
		})
	}
}

// The runner's filter on this architecture names the calls the stage's
// comment lists, each once.
func TestRunnerFilterNamesTheListedCalls(t *testing.T) {
	calls := nativeSeccompCalls()
	want := map[uint32]bool{
		unix.SYS_UNSHARE: true, unix.SYS_SETNS: true, unix.SYS_MOUNT: true, unix.SYS_UMOUNT2: true,
		unix.SYS_PIVOT_ROOT: true, unix.SYS_KEYCTL: true, unix.SYS_ADD_KEY: true, unix.SYS_REQUEST_KEY: true,
		unix.SYS_BPF: true, unix.SYS_USERFAULTFD: true, unix.SYS_PERF_EVENT_OPEN: true,
	}
	seen := map[uint32]bool{}
	for _, nr := range calls.refused {
		if !want[nr] || seen[nr] {
			t.Errorf("call %d is refused unexpectedly or twice", nr)
		}
		seen[nr] = true
	}
	if len(seen) != len(want) {
		t.Errorf("the filter refuses %d calls, want %d", len(seen), len(want))
	}
	if calls.clone != unix.SYS_CLONE || calls.clone3 != unix.SYS_CLONE3 {
		t.Errorf("clone and clone3 are %d and %d", calls.clone, calls.clone3)
	}
}

// helperEnv makes the test binary, run again, the helper process below.
const helperEnv = "CYFR_STAGE_SECCOMP_HELPER"

// kernelAnswers are the errnos the kernel gives, in the helper, to calls
// that are invalid whatever the host allows, so that without the filter
// each is EINVAL and only the filter answers otherwise.
type kernelAnswers struct {
	Unshare string `json:"unshare"`
	Clone   string `json:"clone"`
	Clone3  string `json:"clone3"`
	Threads int    `json:"threads"`
	Child   string `json:"child"`
}

func errnoName(err error) string {
	var errno syscall.Errno
	if errors.As(err, &errno) {
		return unix.ErrnoName(errno)
	}
	if err == nil {
		return "ok"
	}
	return err.Error()
}

// probeKernel makes the calls the answers record. Each namespace call
// carries the namespace flag beside a flag the kernel refuses with EINVAL
// before it would make anything, so no namespace is ever made.
func probeKernel() kernelAnswers {
	var answers kernelAnswers
	// unshare refuses a bit of clone's exit signal.
	_, _, errno := unix.RawSyscall(unix.SYS_UNSHARE, unix.CLONE_NEWUSER|1, 0, 0)
	answers.Unshare = errnoName(errnoOrNil(errno))
	// clone refuses CLONE_THREAD without CLONE_SIGHAND.
	_, _, errno = unix.RawSyscall6(unix.SYS_CLONE, unix.CLONE_NEWUSER|unix.CLONE_THREAD, 0, 0, 0, 0, 0)
	answers.Clone = errnoName(errnoOrNil(errno))
	// clone3 refuses a size smaller than its first version's.
	var args [8]uint64
	_, _, errno = unix.RawSyscall(unix.SYS_CLONE3, uintptr(unsafe.Pointer(&args[0])), 1, 0)
	answers.Clone3 = errnoName(errnoOrNil(errno))
	if tasks, err := os.ReadDir("/proc/self/task"); err == nil {
		answers.Threads = len(tasks)
	}
	answers.Child = errnoName(exec.Command("/bin/true").Run())
	return answers
}

func errnoOrNil(errno syscall.Errno) error {
	if errno == 0 {
		return nil
	}
	return errno
}

// The helper process: with `install` it sets no_new_privs and installs the
// runner's filter on its own thread, then executes itself as `filtered`,
// which runs whole under the filter, as a runner does after the stage's
// exec; without, it is the control. Either way the last process prints the
// kernel's answers.
func TestSeccompHelperProcess(t *testing.T) {
	switch os.Getenv(helperEnv) {
	case "":
		t.Skip("run by TestRunnerFilterInstalls")
	case "install":
		// no_new_privs and the filter belong to this thread, which execve
		// must run on.
		runtime.LockOSThread()
		if err := unix.Prctl(unix.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0); err != nil {
			t.Fatal(err)
		}
		if err := installRunnerFilter(); err != nil {
			t.Fatal(err)
		}
		t.Fatal(syscall.Exec(os.Args[0], os.Args, helperEnviron("filtered")))
	}
	out, _ := json.Marshal(probeKernel())
	os.Stdout.Write(append([]byte("answers:"), append(out, '\n')...))
	os.Exit(0)
}

// helperEnviron is this process's environment with the helper's mode set
// to `mode`, the variable named once: the first of two would win.
func helperEnviron(mode string) []string {
	env := []string{helperEnv + "=" + mode}
	for _, entry := range os.Environ() {
		if !strings.HasPrefix(entry, helperEnv+"=") {
			env = append(env, entry)
		}
	}
	return env
}

func runHelper(t *testing.T, mode string) kernelAnswers {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^TestSeccompHelperProcess$", "-test.count=1")
	cmd.Env = helperEnviron(mode)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("the %s helper: %v\n%s", mode, err, out)
	}
	for _, line := range strings.Split(string(out), "\n") {
		if rest, ok := strings.CutPrefix(line, "answers:"); ok {
			var answers kernelAnswers
			if err := json.Unmarshal([]byte(rest), &answers); err != nil {
				t.Fatal(err)
			}
			return answers
		}
	}
	t.Fatalf("the %s helper printed no answers\n%s", mode, out)
	return kernelAnswers{}
}

// seccompMode is the Seccomp: field of this process's /proc/self/status,
// "" where the kernel shows none.
func seccompMode(t *testing.T) string {
	t.Helper()
	status, err := os.ReadFile("/proc/self/status")
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(string(status), "\n") {
		if mode, ok := strings.CutPrefix(line, "Seccomp:"); ok {
			return strings.TrimSpace(mode)
		}
	}
	return ""
}

// Installed on a thread that holds no_new_privs, the filter stays with the
// program that thread executes: there the kernel never sees a namespace
// call (each is refused EPERM where, unfiltered, the kernel answers
// EINVAL), clone3 answers ENOSYS, and the program still runs threads and
// starts a child process.
//
// The control is the kernel's own answer only in a process no filter
// covers, since a filter outlives exec and covers every child. Under one,
// as under seccomp/keeper.json in keeper-ci.yml's real-kernel step, which
// itself refuses unshare and clone3, the test skips. That workflow runs it
// unfiltered as well and requires it to pass.
func TestRunnerFilterInstalls(t *testing.T) {
	if mode := seccompMode(t); mode != "" && mode != "0" {
		t.Skipf("this process already runs under seccomp (Seccomp: %s in /proc/self/status), so the control cannot show the kernel's own answers", mode)
	}
	control := runHelper(t, "control")
	if control.Unshare != "EINVAL" || control.Clone != "EINVAL" || control.Clone3 != "EINVAL" {
		t.Fatalf("unfiltered, the kernel answers %+v, not EINVAL to each invalid call", control)
	}
	filtered := runHelper(t, "install")
	want := kernelAnswers{Unshare: "EPERM", Clone: "EPERM", Clone3: "ENOSYS", Threads: filtered.Threads, Child: "ok"}
	if filtered != want {
		t.Fatalf("under the filter the kernel answers %+v, want %+v", filtered, want)
	}
	if filtered.Threads < 2 {
		t.Fatalf("under the filter the program runs %d threads", filtered.Threads)
	}
}
