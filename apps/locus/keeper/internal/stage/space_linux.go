// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package stage

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/pool"
)

// A space's processes and files. The stage, in the space's user, network
// and IPC namespace, clones the space's first process into a pid, mount and
// cgroup namespace of its own, once the keeper has placed the stage in its
// group: that group is the cgroup namespace's root. The first process
// builds the space's files under Root, pivots into them, drops every
// capability, installs the space's filter and executes itself again as the
// space's init, which holds nothing: it starts the command, passes it the
// signals the stage passes down, reaps every process left to it, and ends
// with the command, which ends every process of the space.

// Root is where a space's first process builds its files, in its own mount
// namespace. The container's AppArmor profile (cyfr-locus) allows a mount
// there and nowhere else, and the image makes the directory.
const Root = "/var/lib/locus/space"

// The arguments after `stage` that start a space's first process, the same
// for the keeper's start-time proof, the space's init, and the stage's
// waiter.
const (
	FirstArg      = "first"
	FirstProbeArg = "first-probe"
	InitArg       = "init"
	WaitArg       = "wait"
)

// waitExitFD is the waiter's end of the init's exit pipe.
const waitExitFD = 3

// Descriptors of a space's first process and its init besides the
// command's stdio: the spec, in a memory file read from its start; the
// status pipe, which closes when the command has executed; the control
// channel, the relay and a pty spawn's terminal socket at the stage's own
// numbers; and the pipe on which the init says how the command ended.
const (
	spaceSpecFD   = 3
	spaceStatusFD = 4
	spaceExitFD   = 8
)

// passedSignals are the signals the keeper may send a spawn: the stage's
// waiter and the init pass each down to the command alone, so a program
// that ends its own children first, as a driver closes its browser before
// it says bye, is not overtaken. A SIGKILL ends the waiter, and the space
// with it.
var passedSignals = []os.Signal{unix.SIGTERM, unix.SIGINT, unix.SIGHUP, unix.SIGQUIT, unix.SIGUSR1, unix.SIGUSR2}

// keptOut are the root's entries a space is never given from its
// container: each is made fresh, or left out. /var holds every home and
// kept home, and a space's own is bound back alone.
var keptOut = map[string]bool{"proc": true, "sys": true, "dev": true, "tmp": true, "run": true, "var": true,
	"mnt": true, "root": true, "home": true, "media": true, "srv": true, "boot": true, "lost+found": true}

// devices are the nodes bound from the container's /dev into a space's.
var devices = []string{"null", "zero", "full", "random", "urandom", "tty"}

// enter is the stage's last part: it clones the space's first process,
// which runs the command, drops every capability of its own, installs the
// space's filter and executes itself as the space's waiter (Wait). It
// returns only when a step fails. home is the spec's home, bound into the space, or "" for
// the keeper's start-time proof, which executes nothing. status is the
// stage's status pipe: the first process and the init write a reason there
// and the init closes it once the command has executed.
func enter(spec []byte, home string, control, relay, terminal bool, uid, gid int, status *os.File) error {
	memfd, err := unix.MemfdCreate("space-spec", unix.MFD_CLOEXEC)
	if err != nil {
		return fmt.Errorf("the spec's memory file: %w", err)
	}
	specFile := os.NewFile(uintptr(memfd), "space-spec")
	defer specFile.Close()
	if _, err := specFile.Write(spec); err != nil {
		return fmt.Errorf("the spec's memory file: %w", err)
	}
	exitR, exitW, err := os.Pipe()
	if err != nil {
		return err
	}
	defer exitR.Close()
	self, err := os.Readlink("/proc/self/exe")
	if err != nil {
		return fmt.Errorf("the stage's binary: %w", err)
	}
	files := []uintptr{0, 1, 2, specFile.Fd(), status.Fd(), ^uintptr(0), ^uintptr(0), ^uintptr(0), exitW.Fd()}
	if control {
		files[ControlFD] = ControlFD
	}
	if relay {
		files[RelayFD] = RelayFD
	}
	if terminal {
		files[TerminalFD] = TerminalFD
	}
	arg := FirstArg
	if home == "" {
		arg = FirstProbeArg
	}
	pid, err := syscall.ForkExec("/proc/self/exe", []string{"cyfr-locus", "stage", arg}, &syscall.ProcAttr{
		Dir:   "/",
		Env:   []string{},
		Files: files,
		Sys: &syscall.SysProcAttr{
			Pdeathsig:  syscall.SIGKILL,
			Cloneflags: unix.CLONE_NEWPID | unix.CLONE_NEWNS | unix.CLONE_NEWCGROUP,
		},
	})
	_ = exitW.Close()
	if err != nil {
		return fmt.Errorf("cloning the space's first process: %w", err)
	}
	// From here only the space holds the command's stdio and channels.
	if err := leaveToSpace(control, relay, terminal); err != nil {
		_ = unix.Kill(pid, unix.SIGKILL)
		return err
	}
	if err := dropCapabilities(); err != nil {
		_ = unix.Kill(pid, unix.SIGKILL)
		return fmt.Errorf("capabilities: %w", err)
	}
	if err := checkCredentials(uid, gid); err != nil {
		_ = unix.Kill(pid, unix.SIGKILL)
		return fmt.Errorf("credentials: %w", err)
	}
	if err := installSpaceFilter(); err != nil {
		_ = unix.Kill(pid, unix.SIGKILL)
		return fmt.Errorf("seccomp: %w", err)
	}
	// Capabilities belong to a thread, and only this one has dropped its
	// own: the stage executes itself again as the space's waiter, which
	// takes this thread's credentials and filter alone. The status pipe,
	// close-on-exec here, is the first process's and the init's from here.
	if err := unix.Dup3(int(exitR.Fd()), waitExitFD, 0); err != nil {
		_ = unix.Kill(pid, unix.SIGKILL)
		return fmt.Errorf("the exit pipe: %w", err)
	}
	err = syscall.Exec(self, []string{"cyfr-locus", "stage", WaitArg, strconv.Itoa(pid)}, []string{})
	_ = unix.Kill(pid, unix.SIGKILL)
	return fmt.Errorf("executing the space's waiter %s: %w", self, err)
}

// Wait runs `cyfr-locus stage wait <pid>`: the stage once it holds nothing,
// outside the space's processes, the parent of the space's first process
// <pid>. It passes the keeper's signals down to it, waits for it, and ends
// as the command ended, as the init says on the exit pipe at waitExitFD.
func Wait() int {
	if len(os.Args) != 4 {
		return ExitFailed
	}
	pid, err := strconv.Atoi(os.Args[3])
	if err != nil || pid <= 0 {
		return ExitFailed
	}
	signals := make(chan os.Signal, 8)
	signal.Notify(signals, passedSignals...)
	go func() {
		for s := range signals {
			_ = unix.Kill(pid, s.(syscall.Signal))
		}
	}()
	var ws unix.WaitStatus
	for {
		_, err := unix.Wait4(pid, &ws, 0, nil)
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil {
			return ExitFailed
		}
		break
	}
	word, _ := io.ReadAll(io.LimitReader(os.NewFile(waitExitFD, "exit"), 64))
	return endAs(string(word), ws)
}

// leaveToSpace gives the stage's own stdio up for /dev/null and closes its
// control channel, relay and terminal socket, which the space's first
// process now holds.
func leaveToSpace(control, relay, terminal bool) error {
	null, err := unix.Open(os.DevNull, unix.O_RDWR|unix.O_CLOEXEC, 0)
	if err != nil {
		return fmt.Errorf("%s: %w", os.DevNull, err)
	}
	defer unix.Close(null)
	for fd := 0; fd <= 2; fd++ {
		if err := unix.Dup3(null, fd, 0); err != nil {
			return fmt.Errorf("stdio: %w", err)
		}
	}
	if control {
		_ = unix.Close(ControlFD)
	}
	if relay {
		_ = unix.Close(RelayFD)
	}
	if terminal {
		_ = unix.Close(TerminalFD)
	}
	return nil
}

// endAs ends the stage as the command ended, so the keeper reaps the stage
// with the command's status: the init's word when it said one, otherwise
// the first process's own end. It returns only an exit code.
func endAs(word string, first unix.WaitStatus) int {
	var kind string
	var n int
	if _, err := fmt.Sscanf(word, "%s %d", &kind, &n); err == nil {
		switch kind {
		case "exit":
			return n
		case "signal":
			raise(unix.Signal(n))
			return 128 + n
		}
	}
	if first.Signaled() {
		raise(first.Signal())
		return 128 + int(first.Signal())
	}
	return first.ExitStatus()
}

// kernelSigaction is the kernel's struct sigaction on the 64-bit
// architectures the space's filter describes (amd64, arm64 and s390x).
type kernelSigaction struct {
	handler  uintptr
	flags    uint64
	restorer uintptr
	mask     uint64
}

// raise ends this process by sig, as the command was ended: the signal's
// disposition is set to the kernel's default, which the Go runtime's own
// handler would not give a crash signal, it is unblocked, and no core is
// written.
func raise(sig unix.Signal) {
	_ = unix.Setrlimit(unix.RLIMIT_CORE, &unix.Rlimit{})
	var act kernelSigaction
	_, _, _ = unix.RawSyscall6(unix.SYS_RT_SIGACTION, uintptr(sig), uintptr(unsafe.Pointer(&act)), 0, 8, 0, 0)
	var set unix.Sigset_t
	set.Val[0] = 1 << (uint(sig) - 1)
	_ = unix.PthreadSigmask(unix.SIG_UNBLOCK, &set, nil)
	_ = unix.Kill(os.Getpid(), sig)
}

// First runs `cyfr-locus stage first` and `cyfr-locus stage first-probe`:
// the space's first process, pid 1 of its pid namespace, holding the
// stage's capabilities inside the space's user namespace alone. It leaves
// the keeper's process group, builds the space's files and pivots into
// them, drops every capability set, installs the space's filter, and
// executes itself again as the init. The probe stops before that, with 0.
func First(probe bool) int {
	runtime.LockOSThread()
	status := os.NewFile(spaceStatusFD, "status")
	fail := func(format string, args ...any) int {
		fmt.Fprintf(status, format, args...)
		return ExitFailed
	}
	var spec Spec
	if !probe {
		var err error
		if spec, err = readSpaceSpec(); err != nil {
			return fail("%v", err)
		}
	}
	if _, err := unix.Setsid(); err != nil {
		return fail("the space's session: %v", err)
	}
	// The init is this binary at its own path, which the space sees, so
	// the space's process list names it.
	self, err := os.Readlink("/proc/self/exe")
	if err != nil {
		return fail("the stage's binary: %v", err)
	}
	if err := buildFiles(spec.Home); err != nil {
		return fail("the space's files: %v", err)
	}
	if spec.Terminal {
		if err := openTerminal(); err != nil {
			return fail("the space's terminal: %v", err)
		}
	}
	if err := dropCapabilities(); err != nil {
		return fail("capabilities: %v", err)
	}
	if err := installSpaceFilter(); err != nil {
		return fail("seccomp: %v", err)
	}
	if probe {
		return 0
	}
	err = syscall.Exec(self, []string{"cyfr-locus", "stage", InitArg}, []string{})
	return fail("executing the space's init %s: %v", self, err)
}

// readSpaceSpec reads the spec the stage wrote to the space's memory file.
func readSpaceSpec() (Spec, error) {
	data, err := io.ReadAll(io.NewSectionReader(os.NewFile(spaceSpecFD, "space-spec"), 0, 4*MaxSpecBytes))
	if err != nil {
		return Spec{}, fmt.Errorf("spec: %w", err)
	}
	spec, err := decodeSpec(data)
	if err != nil {
		return Spec{}, err
	}
	return spec, nil
}

// mount mounts as unix.Mount does, naming what failed.
func mount(source, target, fstype string, flags uintptr, data string) error {
	if err := unix.Mount(source, target, fstype, flags, data); err != nil {
		return fmt.Errorf("mount %s on %s (%s): %w", source, target, fstype, err)
	}
	return nil
}

// setAttr sets mount attributes on the mount at path, and with recursive on
// every mount below it.
func setAttr(path string, set uint64, recursive bool) error {
	flags := 0
	if recursive {
		flags = unix.AT_RECURSIVE
	}
	if err := unix.MountSetattr(unix.AT_FDCWD, path, uint(flags), &unix.MountAttr{Attr_set: set}); err != nil {
		return fmt.Errorf("mount_setattr %s: %w", path, err)
	}
	return nil
}

// bind binds source and every mount below it at the same path under Root,
// read-only unless writable, and never with setuid.
func bind(source string, writable bool) error {
	target := filepath.Join(Root, source)
	if err := os.MkdirAll(target, 0o755); err != nil {
		return err
	}
	if err := mount(source, target, "", unix.MS_BIND|unix.MS_REC, ""); err != nil {
		return err
	}
	set := uint64(unix.MOUNT_ATTR_NOSUID)
	if !writable {
		set |= unix.MOUNT_ATTR_RDONLY
	}
	return setAttr(target, set, true)
}

// buildFiles builds the space's files under Root and pivots into them: the
// container's root, its directories bound read-only but for those it never
// gives a space; a fresh /proc of the space's processes; a read-only sysfs
// and, read-only, the cgroup tree whose root is the space's own group; its
// own /dev with the container's few device nodes, its own terminals and
// /dev/shm; its own /tmp, /var/tmp and /run; and its home, writable, at its
// path, the only home it sees. The root itself is read-only once pivoted.
func buildFiles(home string) error {
	steps := []func() error{
		func() error { return mount("", "/", "", unix.MS_REC|unix.MS_PRIVATE, "") },
		func() error { return mount("space", Root, "tmpfs", unix.MS_NOSUID|unix.MS_NODEV, "mode=0755,size=4m") },
		bindContainerRoot,
		func() error {
			for _, dir := range []string{"proc", "sys", "dev", "tmp", "run", "var/tmp", ".old"} {
				if err := os.MkdirAll(filepath.Join(Root, dir), 0o755); err != nil {
					return err
				}
			}
			return nil
		},
		func() error {
			return mount("proc", Root+"/proc", "proc", unix.MS_NOSUID|unix.MS_NODEV|unix.MS_NOEXEC, "")
		},
		func() error {
			if err := mount("sysfs", Root+"/sys", "sysfs", unix.MS_NOSUID|unix.MS_NODEV|unix.MS_NOEXEC|unix.MS_RDONLY, ""); err != nil {
				return err
			}
			if err := mount("cgroup2", Root+"/sys/fs/cgroup", "cgroup2", unix.MS_NOSUID|unix.MS_NODEV|unix.MS_NOEXEC, ""); err != nil {
				return err
			}
			return setAttr(Root+"/sys/fs/cgroup", unix.MOUNT_ATTR_RDONLY, false)
		},
		func() error {
			for _, t := range []struct{ dir, opts string }{
				{"tmp", "mode=1777"}, {"var/tmp", "mode=1777"}, {"run", "mode=0755,size=16m"}, {"dev", "mode=0755,size=64k"},
			} {
				flags := uintptr(unix.MS_NOSUID | unix.MS_NODEV)
				if t.dir == "dev" {
					flags = unix.MS_NOSUID
				}
				if err := mount("space-"+strings.ReplaceAll(t.dir, "/", "-"), filepath.Join(Root, t.dir), "tmpfs", flags, t.opts); err != nil {
					return err
				}
			}
			return nil
		},
		buildDev,
		func() error {
			if home == "" {
				return nil
			}
			return bind(home, true)
		},
		func() error {
			if err := unix.PivotRoot(Root, Root+"/.old"); err != nil {
				return fmt.Errorf("pivot_root: %w", err)
			}
			if err := os.Chdir("/"); err != nil {
				return err
			}
			if err := unix.Unmount("/.old", unix.MNT_DETACH); err != nil {
				return fmt.Errorf("unmounting the container's root: %w", err)
			}
			if err := os.Remove("/.old"); err != nil {
				return err
			}
			return setAttr("/", unix.MOUNT_ATTR_RDONLY, false)
		},
	}
	for _, step := range steps {
		if err := step(); err != nil {
			return err
		}
	}
	return nil
}

// bindContainerRoot gives the space the container's root: each directory
// but those in keptOut bound read-only at its path, each symbolic link
// made again. Its other entries are left out.
func bindContainerRoot() error {
	entries, err := os.ReadDir("/")
	if err != nil {
		return err
	}
	for _, e := range entries {
		name := e.Name()
		if keptOut[name] {
			continue
		}
		if e.Type()&os.ModeSymlink != 0 {
			to, err := os.Readlink("/" + name)
			if err == nil {
				err = os.Symlink(to, filepath.Join(Root, name))
			}
			if err != nil {
				return err
			}
			continue
		}
		if !e.IsDir() {
			continue
		}
		if err := bind("/"+name, false); err != nil {
			return err
		}
	}
	return nil
}

// buildDev fills the space's /dev: the container's null, zero, full,
// random, urandom and tty nodes, a terminal instance of its own with its
// ptmx, its own /dev/shm, and the usual links into /proc.
func buildDev() error {
	for _, node := range devices {
		target := Root + "/dev/" + node
		f, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY, 0o666)
		if err != nil {
			return err
		}
		_ = f.Close()
		if err := mount("/dev/"+node, target, "", unix.MS_BIND, ""); err != nil {
			return err
		}
	}
	for _, dir := range []string{"pts", "shm"} {
		if err := os.Mkdir(Root+"/dev/"+dir, 0o755); err != nil {
			return err
		}
	}
	if err := mount("devpts", Root+"/dev/pts", "devpts", unix.MS_NOSUID|unix.MS_NOEXEC, "newinstance,ptmxmode=0666,mode=0620"); err != nil {
		return err
	}
	if err := mount("space-shm", Root+"/dev/shm", "tmpfs", unix.MS_NOSUID|unix.MS_NODEV, "mode=1777"); err != nil {
		return err
	}
	for name, to := range map[string]string{"ptmx": "pts/ptmx", "fd": "/proc/self/fd", "stdin": "/proc/self/fd/0",
		"stdout": "/proc/self/fd/1", "stderr": "/proc/self/fd/2"} {
		if err := os.Symlink(to, Root+"/dev/"+name); err != nil {
			return err
		}
	}
	return nil
}

// openTerminal opens a terminal of the space's own, in its devpts: its
// slave becomes this process's stdin, stdout and stderr, which the init
// gives the command, and its master is handed up over TerminalFD to the
// keeper, which sets its size and gives it to the relay.
func openTerminal() error {
	master, err := unix.Open("/dev/ptmx", unix.O_RDWR|unix.O_NOCTTY|unix.O_CLOEXEC, 0)
	if err != nil {
		return fmt.Errorf("ptmx: %w", err)
	}
	defer unix.Close(master)
	unlock := 0
	if _, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(master), unix.TIOCSPTLCK, uintptr(unsafe.Pointer(&unlock))); errno != 0 {
		return fmt.Errorf("unlocking it: %w", errno)
	}
	n, err := unix.IoctlGetUint32(master, unix.TIOCGPTN)
	if err != nil {
		return fmt.Errorf("its number: %w", err)
	}
	slave, err := unix.Open("/dev/pts/"+strconv.FormatUint(uint64(n), 10), unix.O_RDWR|unix.O_NOCTTY|unix.O_CLOEXEC, 0)
	if err != nil {
		return fmt.Errorf("its slave: %w", err)
	}
	defer unix.Close(slave)
	for fd := 0; fd <= 2; fd++ {
		if err := unix.Dup3(slave, fd, 0); err != nil {
			return fmt.Errorf("stdio: %w", err)
		}
	}
	if err := unix.Sendmsg(TerminalFD, []byte{'t'}, unix.UnixRights(master), nil, 0); err != nil {
		return fmt.Errorf("handing its master up: %w", err)
	}
	return unix.Close(TerminalFD)
}

// Init runs `cyfr-locus stage init`: the space's pid 1 once it holds
// nothing. It sets the spec's limits and umask, starts the command in a
// session of its own, which takes its terminal as its controlling one when
// it has one, with its control channel on fd 3 and a relay space's relay on
// fd 4, and closes the status pipe once the command has executed. It then
// passes the signals it is sent to the command, reaps every
// process left to it, and when the command ends says how on its exit pipe
// and ends, which ends every process of the space.
func Init() int {
	status := os.NewFile(spaceStatusFD, "status")
	fail := func(format string, args ...any) int {
		fmt.Fprintf(status, format, args...)
		return ExitFailed
	}
	// Every descriptor of the init's own is close-on-exec: the command is
	// given its stdio and, at 3 and 4, its control channel and relay alone.
	for _, fd := range []int{spaceStatusFD, spaceExitFD, ControlFD, RelayFD, TerminalFD} {
		if _, err := unix.FcntlInt(uintptr(fd), unix.F_SETFD, unix.FD_CLOEXEC); err != nil && !errors.Is(err, unix.EBADF) {
			return fail("descriptors: %v", err)
		}
	}
	spec, err := readSpaceSpec()
	if err != nil {
		return fail("%v", err)
	}
	_ = unix.Close(spaceSpecFD)
	signals := make(chan os.Signal, 8)
	signal.Notify(signals, passedSignals...)

	syscall.Umask(0o077)
	if err := setLimits(spec.Limits); err != nil {
		return fail("rlimits: %v", err)
	}
	path, err := spec.LookPath(spec.Argv[0])
	if err != nil {
		return fail("exec: %v", err)
	}
	files := []uintptr{0, 1, 2}
	if spec.Control {
		files = append(files, ControlFD)
	}
	if spec.Reach == pool.ReachRelay {
		if err := checkSocket(RelayFD); err != nil {
			return fail("relay: %v", err)
		}
		if !spec.Control {
			files = append(files, ^uintptr(0))
		}
		files = append(files, RelayFD)
	}
	_, terminal := unix.IoctlGetTermios(0, unix.TCGETS)
	command, err := syscall.ForkExec(path, spec.Argv, &syscall.ProcAttr{
		Dir:   spec.Home,
		Env:   spec.Environ(),
		Files: files,
		Sys:   &syscall.SysProcAttr{Setsid: true, Setctty: terminal == nil, Ctty: 0},
	})
	if err != nil {
		return fail("exec %s: %v", path, err)
	}
	_ = status.Close()
	for _, fd := range []int{ControlFD, RelayFD} {
		_ = unix.Close(fd)
	}
	go func() {
		for s := range signals {
			_ = unix.Kill(command, s.(syscall.Signal))
		}
	}()
	exit := os.NewFile(spaceExitFD, "exit")
	for {
		var ws unix.WaitStatus
		got, err := unix.Wait4(-1, &ws, 0, nil)
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil {
			return ExitFailed
		}
		if got != command {
			continue
		}
		if ws.Signaled() {
			fmt.Fprintf(exit, "signal %d", int(ws.Signal()))
			return 128 + int(ws.Signal())
		}
		fmt.Fprintf(exit, "exit %s", strconv.Itoa(ws.ExitStatus()))
		return ws.ExitStatus()
	}
}
