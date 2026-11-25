// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux && amd64

package outer

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"unsafe"

	"golang.org/x/sys/unix"
)

// helperEnv makes the test binary, run again, the helper process below; it
// holds the path of the syscall table the helper loads.
const helperEnv = "CYFR_OUTER_SECCOMP_HELPER"

// answers are the kernel's answers, an errno's name or "ok", to calls the
// filter decides. Each call without the filter is one the kernel answers
// itself: AF_VSOCK is EAFNOSUPPORT or a socket, io_uring_setup refuses
// zero entries with EINVAL, and clone3 refuses a size smaller than its
// first version's with EINVAL.
type answers struct {
	VSock string `json:"vsock"`
	// VSockHigh is socket(0x1_0000_0028), AF_VSOCK to the kernel.
	VSockHigh string `json:"vsock_high"`
	Inet      string `json:"inet"`
	IOURing   string `json:"io_uring"`
	Clone3    string `json:"clone3"`
}

// report is what the helper saw: the kernel's answers before the filter,
// after it on the thread that installed it, and after it on a thread that
// was running before.
type report struct {
	Before answers `json:"before"`
	After  answers `json:"after"`
	Elder  answers `json:"elder"`
}

func errnoName(errno syscall.Errno) string {
	if errno == 0 {
		return "ok"
	}
	return unix.ErrnoName(errno)
}

func socketAnswer(family uint64) string {
	fd, _, errno := unix.RawSyscall(unix.SYS_SOCKET, uintptr(family), unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if errno == 0 {
		unix.Close(int(fd))
	}
	return errnoName(errno)
}

func probe() answers {
	var params [120]byte // struct io_uring_params
	_, _, uring := unix.RawSyscall(unix.SYS_IO_URING_SETUP, 0, uintptr(unsafe.Pointer(&params[0])), 0)
	var args [8]uint64
	_, _, clone3 := unix.RawSyscall(unix.SYS_CLONE3, uintptr(unsafe.Pointer(&args[0])), 1, 0)
	return answers{
		VSock:     socketAnswer(unix.AF_VSOCK),
		VSockHigh: socketAnswer(1<<32 | unix.AF_VSOCK),
		Inet:      socketAnswer(unix.AF_INET),
		IOURing:   errnoName(uring),
		Clone3:    errnoName(clone3),
	}
}

// The helper process: it loads keeper.json's filter for the Locus
// container's capabilities against the table at $CYFR_OUTER_SECCOMP_HELPER
// and the running kernel, sets no_new_privs on its thread, installs the
// filter, and prints the kernel's answers.
func TestSeccompHelperProcess(t *testing.T) {
	tablePath := os.Getenv(helperEnv)
	if tablePath == "" {
		t.Skip("run by TestInstallHoldsEveryThread")
	}
	raw, err := Load("../../seccomp/keeper.json", tablePath, locusCaps)
	if err != nil {
		t.Fatal(err)
	}
	ready, ask, elder := make(chan struct{}), make(chan struct{}), make(chan answers)
	go func() {
		runtime.LockOSThread()
		close(ready)
		<-ask
		elder <- probe()
	}()
	<-ready
	seen := report{Before: probe()}
	// no_new_privs belongs to this thread, which Install must run on; TSYNC
	// gives it to the others with the filter.
	runtime.LockOSThread()
	if err := unix.Prctl(unix.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0); err != nil {
		t.Fatal(err)
	}
	if err := Install(raw); err != nil {
		t.Fatal(err)
	}
	seen.After = probe()
	close(ask)
	seen.Elder = <-elder
	out, _ := json.Marshal(seen)
	os.Stdout.Write(append([]byte("report:"), append(out, '\n')...))
	os.Exit(0)
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

// Installed on a real kernel, the compiled keeper.json holds every thread
// of the process, the one that installed it and one already running:
// socket(AF_VSOCK) is EPERM, also with the family behind a high word the
// kernel reads away, where the kernel itself answers EAFNOSUPPORT or makes
// the socket; socket(AF_INET) is made; io_uring_setup is EPERM where the
// kernel answers EINVAL; and clone3 is ENOSYS. Under a filter already (as
// under seccomp/keeper.json in keeper-ci.yml's real-kernel step) the
// kernel's own answers may be that filter's, which the log shows.
func TestInstallHoldsEveryThread(t *testing.T) {
	mode := seccompMode(t)
	if mode == "" {
		t.Skip("this kernel has no seccomp: /proc/self/status shows no Seccomp field")
	}
	tablePath := filepath.Join(t.TempDir(), "syscall_64.tbl")
	if err := os.WriteFile(tablePath, amd64TableText(), 0o600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestSeccompHelperProcess$", "-test.count=1")
	cmd.Env = append(os.Environ(), helperEnv+"="+tablePath)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("the helper: %v\n%s", err, out)
	}
	var seen report
	found := false
	for _, line := range strings.Split(string(out), "\n") {
		if rest, ok := strings.CutPrefix(line, "report:"); ok {
			if err := json.Unmarshal([]byte(rest), &seen); err != nil {
				t.Fatal(err)
			}
			found = true
		}
	}
	if !found {
		t.Fatalf("the helper printed no report\n%s", out)
	}
	t.Logf("Seccomp: %s; before the filter the kernel answers %+v", mode, seen.Before)
	want := answers{VSock: "EPERM", VSockHigh: "EPERM", Inet: "ok", IOURing: "EPERM", Clone3: "ENOSYS"}
	if seen.After != want {
		t.Errorf("under the filter the installing thread is answered %+v, want %+v", seen.After, want)
	}
	if seen.Elder != want {
		t.Errorf("under the filter a thread running before it is answered %+v, want %+v", seen.Elder, want)
	}
}
