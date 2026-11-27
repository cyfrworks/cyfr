// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package vm

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/guard"
	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/pool"
	"github.com/cyfr/locus/keeper/internal/procfs"
	"github.com/cyfr/locus/keeper/internal/protocol"
	"github.com/cyfr/locus/keeper/internal/retire"
	"github.com/cyfr/locus/keeper/internal/stage"
)

// KVM is the device a machine needs, which the Locus container is given by
// `--device /dev/kvm` and by nothing else.
const KVM = "/dev/kvm"

// ErrNoKVM reports a container that was not given KVM: no machine runs.
var ErrNoKVM = errors.New("this container was given no " + KVM)

// stageWait bounds the VMM's stage from its start to the VMM's exec, and
// a person's VM's space's handing its route up: a variable its tests
// shorten.
var stageWait = 10 * time.Second

// Bounds of a machine's start and end.
const (
	// sendWait bounds one line's write on a control connection.
	sendWait = 10 * time.Second
	// apiWait bounds the VMM's API socket's appearing.
	apiWait = 2 * time.Second
	// ReadyWait bounds a cold boot to the relay's Hello: P12's boots took
	// 0.67 s, so this is a guest that is not coming.
	ReadyWait = 10 * time.Second
	// EndWait bounds the machine's end after its control connection ends,
	// before its VMM is killed.
	EndWait = 5 * time.Second
	// retireWait bounds the retirement of the VMM's uid and its folder.
	retireWait = 15 * time.Second
	// groupSlackMiB is the VMM's own memory beside its guest's, which its
	// group's bound adds to the guest's.
	groupSlackMiB = 64
	// consoleWait bounds the console's last bytes after the VMM's end.
	consoleWait = 2 * time.Second
	// dialAgain is the pause between two connections the guest refused
	// while it was not yet listening.
	dialAgain = 20 * time.Millisecond
)

// machineLimits are the VMM's resource limits: a few threads and
// descriptors, and no file of its own past its sockets.
var machineLimits = protocol.Limits{Nofile: 256, Nproc: 64, Core: 0, Fsize: 1 << 20}

// Config is one machine.
type Config struct {
	// Device is the image's programs, attached read only as the root. The
	// machine holds it, and with it the device's shared lock, until its
	// VMM's end.
	Device *Device
	// VCPUs and MemoryMiB are the guest's processors and memory. The
	// memory is a ceiling, touched only as it is used.
	VCPUs     int
	MemoryMiB int
	// Groups is where the machine makes its group, which holds the VMM,
	// its stage and its space from before the VMM is executed, bounded to
	// the guest's memory and groupSlackMiB beside it and to its processors.
	Groups *cgroup.Manager
	// BootArgs is the guest kernel's command line, BootArgs(Console != nil)
	// unless a measurement asks otherwise.
	BootArgs string
	// Console takes the VMM's output and the guest's serial console, for
	// guest-check's diagnosis; it should keep a bounded part of what it is
	// given. A machine that serves has none: its VMM's output goes to
	// /dev/null and its guest is booted with no console.
	Console io.Writer
	// Disk is a person's disk image (home.FormImage), their VM's one
	// writable drive, directly under KeptRoot, the kept homes' root, which
	// every VMM's space is given covered, but for its own person's image.
	// Disk is "" for guest-check's machine, which has none; KeptRoot is
	// every machine's.
	Disk, KeptRoot string
	// UID is the uid a person's VM runs under: their disk's (home.Disk),
	// whose alone the image is, so it is the VMM's two walls, its mount
	// namespace and the image's owner. 0 allots one of MachineUIDs, as
	// guest-check's machines are given.
	UID int
	// Route makes a person's VM's route from its VMM's space's network
	// namespace, two name sockets and route netlink socket, which the
	// space hands up before the VMM is executed (package stage): the
	// guard's machine route (package guard), owned by the VMM's uid. The
	// machine boots with a card on its tap, the guest at the route's inner
	// address. nil for a machine with no network, whose space is a relay
	// space whose relay leads nowhere.
	Route func(uid int, netns, udp, tcp, nl *os.File) (Network, error)
}

// Network is a person's VM's route: the guest's address and its gateway,
// the guard's end, a /30's two hosts.
type Network struct {
	Inner, Gateway netip.Addr
}

// Machine is a running VMM and its guest.
type Machine struct {
	id  string
	dir string
	// uid is the VMM's, its person's disk's (Config.UID) or allotted from
	// MachineUIDs (allotted), and its alone until the machine's end gives
	// it back (takeUID).
	uid      int
	allotted bool
	gid      int
	group    *cgroup.Group
	cmd      *exec.Cmd
	// done closes when the VMM's stage, which ends as the VMM ends, has
	// exited and been reaped, and its waiter has cleared what the machine
	// held (remove): on any end, the VMM's own exit among them.
	done chan struct{}
	// started is when the VMM was told to boot the guest.
	started time.Time
	// network is a person's VM's route, its zero for none.
	network Network
	device  *Device
	// console closes when the console's copier has read its last byte.
	console chan struct{}
	// clear ends what is left of the machine's uid and removes its folder
	// (runRetire), at its end.
	clear func() error
	// mu guards how the machine ended: asked is that End or Kill began
	// it, exited that the VMM's stage was reaped, and how what End, Kill
	// or the waiter recorded first.
	mu     sync.Mutex
	asked  bool
	exited bool
	how    Ended
	// What the end found, once done has closed: what it could not clear,
	// the processes left in the group, and the group's processor time.
	leftOver  error
	leftProcs []int
	cpuUsec   uint64
	killedFor cgroup.Cause
	killedErr error
}

// machineUIDs is MachineUIDs' allotment in this keeper, and given the uids
// a person's VM runs under, each its disk's (Config.UID), while it runs.
var machineUIDs = struct {
	sync.Mutex
	p     *pool.Pool
	given map[int]bool
}{p: pool.New(MachineUIDs), given: map[int]bool{}}

// leftBy says the uid still runs a process or has a folder left under Root:
// no machine starts under it.
func leftBy(uid int) bool {
	c, err := procfs.ScanUID("/proc", uid, 0)
	if err != nil || c.Total() > 0 {
		return true
	}
	left, err := filepath.Glob(filepath.Join(Root, strconv.Itoa(uid)+"-*"))
	return err != nil || len(left) > 0
}

// takeUID is the uid one machine runs under: given, its person's disk's,
// which no other machine of this keeper holds and leftBy does not withhold;
// or, given 0, one of MachineUIDs that leftBy does not withhold. It says
// whether the uid was allotted, so the machine's end gives it back there.
func takeUID(given int) (uid int, allotted bool, err error) {
	machineUIDs.Lock()
	defer machineUIDs.Unlock()
	if given > 0 {
		if machineUIDs.given[given] || leftBy(given) {
			return 0, false, fmt.Errorf("vm: uid %d runs a machine or a process, or has a machine's folder left", given)
		}
		machineUIDs.given[given] = true
		return given, false, nil
	}
	uid, ok := machineUIDs.p.Allocate(leftBy)
	if !ok {
		return 0, false, fmt.Errorf("vm: every machine uid of %d-%d is in use", MachineUIDs.First, MachineUIDs.Last)
	}
	return uid, true, nil
}

// giveBack lets a machine's uid go: to the allotment, or out of given.
func giveBack(uid int, allotted bool) {
	machineUIDs.Lock()
	defer machineUIDs.Unlock()
	if allotted {
		_ = machineUIDs.p.Release(uid)
		return
	}
	delete(machineUIDs.given, uid)
}

// Start starts the VMM in a space the stage makes for it, as it makes a
// spawn's: a user, network, IPC, pid, mount and cgroup namespace of its
// own, under its own uid and with no group but /dev/kvm's, holding no
// capability, under the space's filter and no_new_privs, in its group from
// before it is executed. Its files are the container's directories read
// only, as every space's, less /var and /run: its machine's folder, made by
// the stage as its uid, the device, read only, and /dev/kvm are all it is
// given beside them; nothing of the kept homes or of another machine, and
// nothing writable but its folder and the space's own fresh mounts. It is
// the space every spawn has, the image's directories read only with it,
// built by the same code. Its relay leads nowhere. Firecracker's own filter then holds it tighter.
// Its uid is its own: a person's VM's their disk's, which owns their image
// alone and runs nothing else on the host (Config.UID), guest-check's one
// allotted from MachineUIDs; and so is its group, cgroup.Name of that uid.
// Start takes cfg.Device: it is closed at the machine's end, or on an
// error, as its group is removed and its uid given back.
func Start(cfg Config) (*Machine, error) {
	m, err := start(cfg)
	if err != nil {
		if m == nil {
			if cfg.Device != nil {
				_ = cfg.Device.Close()
			}
		} else if m.cmd == nil || m.cmd.Process == nil {
			// No stage ran, so no waiter clears the machine.
			m.remove()
		} else {
			m.Kill()
		}
		return nil, err
	}
	return m, nil
}

// start is Start; a machine it answers with an error is Start's to clear.
func start(cfg Config) (*Machine, error) {
	var st syscall.Stat_t
	if err := syscall.Stat(KVM, &st); err != nil {
		return nil, ErrNoKVM
	}
	if cfg.Groups == nil || cfg.VCPUs < 1 || cfg.MemoryMiB < 128 || cfg.Device == nil {
		return nil, errors.New("vm: a machine needs its groups, a processor, 128 MiB and a device")
	}
	if st.Gid == 0 {
		return nil, errors.New("vm: " + KVM + "'s group is root's, and a VMM holds no group but KVM's")
	}
	if cfg.BootArgs == "" {
		cfg.BootArgs = BootArgs(cfg.Console != nil)
	}
	self, err := os.Executable()
	if err != nil {
		return nil, err
	}
	if err := machinesRoot(); err != nil {
		return nil, err
	}
	uid, allotted, err := takeUID(cfg.UID)
	if err != nil {
		return nil, err
	}
	m := &Machine{uid: uid, allotted: allotted, gid: int(st.Gid), device: cfg.Device, done: make(chan struct{})}
	m.group, err = cfg.Groups.Create(cgroup.Name(uid), uint64(cfg.MemoryMiB+groupSlackMiB)<<20,
		uint64(cfg.VCPUs)*cgroup.CPUPeriod)
	if err != nil {
		return m, fmt.Errorf("vm: the machine's group: %w", err)
	}
	if m.id, err = home.NewName(uid); err != nil {
		return m, err
	}
	m.dir = filepath.Join(Root, m.id)
	m.clear = func() error { return runRetire(m.uid, m.gid, m.dir) }
	spec := stage.Spec{UID: m.uid, GID: m.gid, User: MachineUser, HomeRoot: Root, Home: m.dir,
		Argv:   []string{Firecracker, "--api-sock", m.api(), "--id", m.id, "--level", "Warning"},
		Limits: machineLimits, Reach: pool.ReachRelay, Cgroup: m.group.Path(), Machine: cfg.Device.Path,
		Disk: cfg.Disk, KeptRoot: cfg.KeptRoot}
	if cfg.Route != nil {
		spec.Reach = pool.ReachRouted
	}
	if err := spec.Validate(); err != nil {
		return m, fmt.Errorf("vm: the VMM's space: %w", err)
	}
	if err := m.startStage(self, spec, cfg); err != nil {
		return m, err
	}
	if err := m.configure(cfg); err != nil {
		return m, err
	}
	return m, nil
}

// machinesRoot makes Root a home root, root's and mode 1733, where each
// VMM's stage makes its folder as its uid, and no uid lists or reaches
// another's.
func machinesRoot() error {
	if err := os.Mkdir(Root, home.RootMode.Perm()); err != nil && !errors.Is(err, os.ErrExist) {
		return fmt.Errorf("vm: the machines' folder: %w", err)
	}
	if err := os.Chmod(Root, home.RootMode); err != nil {
		return fmt.Errorf("vm: the machines' folder: %w", err)
	}
	return home.CheckRoot(Root)
}

// startStage starts the VMM's stage, maps its ids, places it in its group
// and hands it its spec, in that order, as the keeper does a spawn's; a
// person's VM's stage then hands its space's namespace and name sockets up,
// and only once cfg.Route has made the route is it told to go on. It waits
// for the VMM's exec. A stage it started is Start's to kill on an error.
func (m *Machine) startStage(self string, spec stage.Spec, cfg Config) error {
	console := cfg.Console
	data, err := json.Marshal(spec)
	if err != nil {
		return err
	}
	var closers []io.Closer
	defer func() {
		for _, c := range closers {
			_ = c.Close()
		}
	}()
	specR, specW, err := os.Pipe()
	if err != nil {
		return err
	}
	statusR, statusW, err := os.Pipe()
	if err != nil {
		_ = specR.Close()
		_ = specW.Close()
		return err
	}
	closers = append(closers, specR, specW, statusR, statusW)
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return err
	}
	// The keeper's end is read by a deadline, as the keeper's own pairs are
	// (package serve's keeperPair): non-blocking, so the runtime polls it.
	if err := unix.SetNonblock(fds[1], true); err != nil {
		_ = unix.Close(fds[0])
		_ = unix.Close(fds[1])
		return err
	}
	// A relay space's relay leads nowhere: the keeper keeps no end of it.
	// A routed space's route socket is the stage's at the same descriptor,
	// and the keeper's end takes its namespace and name sockets.
	relay, nowhere := os.NewFile(uintptr(fds[0]), "relay"), os.NewFile(uintptr(fds[1]), "nowhere")
	closers = append(closers, relay, nowhere)
	null, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	closers = append(closers, null)
	out := null
	if console != nil {
		r, w, err := os.Pipe()
		if err != nil {
			return err
		}
		closers = append(closers, w)
		out = w
		m.console = make(chan struct{})
		go func() {
			defer close(m.console)
			defer r.Close()
			_, _ = io.Copy(console, r)
		}()
	}
	m.cmd = exec.Command(self, "stage")
	m.cmd.Args = []string{"cyfr-locus", "stage"}
	m.cmd.Env = []string{}
	m.cmd.Dir = "/"
	m.cmd.Stdin, m.cmd.Stdout, m.cmd.Stderr = null, out, out
	// The stage's descriptors: its spec and status pipes, no control
	// channel, and its relay (package stage).
	m.cmd.ExtraFiles = []*os.File{specR, statusW, nil, relay}
	m.cmd.SysProcAttr = stage.SpaceAttr()
	if err := m.cmd.Start(); err != nil {
		if m.console != nil {
			_ = out.Close()
			<-m.console
		}
		return fmt.Errorf("vm: starting the VMM's stage: %w", err)
	}
	go m.wait()
	if err := stage.MapIDs(m.cmd.Process.Pid, spec.UID, spec.GID); err != nil {
		return fmt.Errorf("vm: the VMM's ids: %w", err)
	}
	if err := m.group.Add(m.cmd.Process.Pid); err != nil {
		return fmt.Errorf("vm: the VMM's group: %w", err)
	}
	_ = specW.SetWriteDeadline(time.Now().Add(stageWait))
	if _, err := specW.Write(data); err != nil {
		return fmt.Errorf("vm: the VMM's spec: %w", err)
	}
	_ = specW.Close()
	_ = statusW.Close()
	if cfg.Route != nil {
		if err := m.route(nowhere, cfg.Route); err != nil {
			return err
		}
	}
	_ = statusR.SetReadDeadline(time.Now().Add(stageWait))
	reason, err := io.ReadAll(io.LimitReader(statusR, 4096))
	if err != nil {
		return fmt.Errorf("vm: the VMM's stage: %w", err)
	}
	if len(reason) > 0 {
		return fmt.Errorf("vm: the VMM's stage: %s", reason)
	}
	return nil
}

// route takes the namespace, two name sockets and route netlink socket a
// person's VM's space hands up on its route socket, conn, by a read
// deadline stageWait away, has fn make the route as the VMM's uid's, and
// tells the stage to go on. A space that hands nothing up by then is
// Start's to kill; what it hands up after is the socket's, closed with it.
func (m *Machine) route(conn *os.File, fn func(uid int, netns, udp, tcp, nl *os.File) (Network, error)) error {
	_ = conn.SetReadDeadline(time.Now().Add(stageWait))
	fds, err := stage.ReceiveDescriptors(conn, 4)
	if errors.Is(err, os.ErrDeadlineExceeded) {
		return fmt.Errorf("vm: the VMM's space handed up no route within %s", stageWait)
	}
	if err != nil {
		return fmt.Errorf("vm: the VMM's space's route: %w", err)
	}
	netns, udp, tcp := os.NewFile(uintptr(fds[0]), "netns"), os.NewFile(uintptr(fds[1]), "names-udp"), os.NewFile(uintptr(fds[2]), "names-tcp")
	nl := os.NewFile(uintptr(fds[3]), "netlink")
	n, err := fn(m.uid, netns, udp, tcp, nl)
	for _, f := range []*os.File{netns, udp, tcp, nl} {
		_ = f.Close()
	}
	if err != nil {
		return fmt.Errorf("vm: the machine's route: %w", err)
	}
	m.network = n
	_ = conn.SetWriteDeadline(time.Now().Add(stageWait))
	if _, err := conn.Write([]byte{stage.RouteGo}); err != nil {
		return fmt.Errorf("vm: telling the VMM's space its route is made: %w", err)
	}
	return nil
}

// wait is the VMM's waiter: once its stage is reaped it clears what the
// machine held, whoever ended it, and records an end that neither End nor
// Kill began as the VMM's own exit, before Done closes.
func (m *Machine) wait() {
	_ = m.cmd.Wait()
	m.mu.Lock()
	m.exited = true
	if !m.asked {
		m.how = EndOwnExit
	}
	m.mu.Unlock()
	m.remove()
	close(m.done)
}

// settle records how the machine ended unless an end is recorded already.
func (m *Machine) settle(how Ended) {
	m.mu.Lock()
	if m.how == "" {
		m.how = how
	}
	m.mu.Unlock()
}

// ID is the machine's own, which names its folder.
func (m *Machine) ID() string { return m.id }

// UID is the VMM's, the machine's own.
func (m *Machine) UID() int { return m.uid }

// Folder is the machine's folder, under Root.
func (m *Machine) Folder() string { return m.dir }

// Group is the machine's group while it runs; the machine's end removes it.
func (m *Machine) Group() *cgroup.Group { return m.group }

// Done closes when the VMM has exited and been reaped.
func (m *Machine) Done() <-chan struct{} { return m.done }

// State is the VMM's end, once Done has closed.
func (m *Machine) State() *os.ProcessState { return m.cmd.ProcessState }

// Started is when the guest was booted.
func (m *Machine) Started() time.Time { return m.started }

// Left is what the machine's end could not clear, its uid's processes, its
// folder or its group, or nil, once the machine has ended.
func (m *Machine) Left() error { return m.leftOver }

// LeftProcs are the processes the machine's end found in its group, once
// the machine has ended: none, unless Left says so.
func (m *Machine) LeftProcs() []int { return m.leftProcs }

// CPUUsec is the processor time the machine's group used, guest included,
// once the machine has ended.
func (m *Machine) CPUUsec() uint64 { return m.cpuUsec }

// KilledFor is what the kernel killed processes of the machine's group for,
// as its counters said at its end (cgroup.KilledFor), once the machine has
// ended.
func (m *Machine) KilledFor() (cgroup.Cause, error) { return m.killedFor, m.killedErr }

// PID is the VMM's process.
func (m *Machine) PID() int { return m.cmd.Process.Pid }

// HowEnded is how the machine ended, once Done has closed.
func (m *Machine) HowEnded() Ended {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.how
}

// Kill ends the VMM, and with it the guest, at once, and waits for its
// waiter to clear what it held.
func (m *Machine) Kill() {
	m.mu.Lock()
	if !m.exited && m.how == "" {
		m.how = EndKilled
	}
	m.asked = true
	m.mu.Unlock()
	_ = m.cmd.Process.Kill()
	<-m.done
}

// remove clears what the machine held, once, from its waiter (or from Start
// when no stage ran): every process of its uid and its folder, by
// `cyfr-locus retire` as that uid as a spawn's are, the console's last
// bytes, its group, its device's lock, and then its uid, given back only
// when nothing of the machine is left.
func (m *Machine) remove() {
	var left []error
	if m.clear != nil {
		if err := m.clear(); err != nil {
			left = append(left, err)
		}
	}
	if m.console != nil {
		select {
		case <-m.console:
		case <-time.After(consoleWait):
		}
	}
	if m.group != nil {
		m.cpuUsec = groupCPUUsec(m.group)
		// Read while its counters stand: what the kernel killed for.
		m.killedFor, m.killedErr = m.group.KilledFor()
		procs, err := m.group.Procs()
		switch {
		case err != nil:
			left = append(left, fmt.Errorf("the machine's group: %w", err))
		case len(procs) > 0:
			m.leftProcs = append([]int{}, procs...)
			left = append(left, fmt.Errorf("processes %v are left in the machine's group", procs))
		default:
			if err := m.group.Remove(); err != nil {
				left = append(left, fmt.Errorf("the machine's group: %w", err))
			}
		}
	}
	if m.device != nil {
		_ = m.device.Close()
	}
	m.leftOver = errors.Join(left...)
	if m.uid > 0 && m.leftOver == nil {
		giveBack(m.uid, m.allotted)
	}
}

// runRetire runs `cyfr-locus retire` as uid, which ends every process of
// the uid and removes path, its folder.
func runRetire(uid, gid int, path string) error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	spec, err := json.Marshal(retire.Spec{UID: uid, Paths: []string{path}})
	if err != nil {
		return err
	}
	specR, specW, err := os.Pipe()
	if err != nil {
		return err
	}
	defer specW.Close()
	cmd := exec.Command(self, "retire")
	cmd.Args = []string{"cyfr-locus", "retire"}
	cmd.Env = []string{}
	cmd.Dir = "/"
	cmd.Stderr = os.Stderr
	cmd.ExtraFiles = []*os.File{specR}
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setsid:     true,
		Credential: &syscall.Credential{Uid: uint32(uid), Gid: uint32(gid), Groups: []uint32{}},
		Pdeathsig:  syscall.SIGKILL,
	}
	if err := cmd.Start(); err != nil {
		_ = specR.Close()
		return fmt.Errorf("retiring the VMM's uid: %w", err)
	}
	_ = specR.Close()
	_ = specW.SetWriteDeadline(time.Now().Add(stageWait))
	_, _ = specW.Write(spec)
	_ = specW.Close()
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	select {
	case err = <-exited:
	case <-time.After(retireWait):
		_ = cmd.Process.Kill()
		err = <-exited
	}
	if err != nil {
		return fmt.Errorf("retiring the VMM's uid %d and its folder: %w", uid, err)
	}
	return nil
}

func (m *Machine) api() string   { return filepath.Join(m.dir, "api.sock") }
func (m *Machine) vsock() string { return filepath.Join(m.dir, "vsock.sock") }

// dialAs connects to the Unix socket at path as the VMM's uid and gid
// would (home.AsFileIDs): the machine's folder and its sockets are the
// VMM's uid's alone, and the keeper holds no capability over files.
func (m *Machine) dialAs(path string, timeout time.Duration) (net.Conn, error) {
	var conn net.Conn
	err := home.AsFileIDs(m.uid, m.gid, func() error {
		var err error
		conn, err = net.DialTimeout("unix", path, timeout)
		return err
	})
	if err != nil && conn != nil {
		_ = conn.Close()
		conn = nil
	}
	return conn, err
}

// Network is a person's VM's route, its zero for a machine with none.
func (m *Machine) Network() Network { return m.network }

// puts are the VMM's configuration, in its order: the guest's size, its
// kernel and command line, its drives, the image's programs first and a
// person's disk second (GuestDisk), a person's card on its tap, its vsock
// and the balloon.
func (m *Machine) puts(cfg Config) []put {
	args := cfg.BootArgs
	if m.network.Inner.IsValid() {
		args += " " + NetArg + "=" + m.network.Inner.String() + "," + m.network.Gateway.String()
	}
	ps := []put{
		{"/machine-config", map[string]any{"vcpu_count": cfg.VCPUs, "mem_size_mib": cfg.MemoryMiB}},
		{"/boot-source", map[string]any{"kernel_image_path": Kernel, "boot_args": args}},
		{"/drives/programs", map[string]any{"drive_id": "programs", "path_on_host": cfg.Device.Path, "is_root_device": true, "is_read_only": true}},
	}
	if cfg.Disk != "" {
		ps = append(ps, put{"/drives/disk", map[string]any{"drive_id": "disk", "path_on_host": cfg.Disk, "is_root_device": false, "is_read_only": false}})
	}
	if m.network.Inner.IsValid() {
		ps = append(ps, put{"/network-interfaces/eth0", map[string]any{"iface_id": "eth0", "host_dev_name": guard.MachineTap, "guest_mac": guard.GuestMAC.String()}})
	}
	return append(ps,
		put{"/vsock", map[string]any{"guest_cid": GuestCID, "uds_path": m.vsock()}},
		// The balloon is there for free-page reporting alone: it is never
		// inflated.
		put{"/balloon", map[string]any{"amount_mib": 0, "deflate_on_oom": true, "free_page_reporting": true}},
		put{"/actions", map[string]any{"action_type": "InstanceStart"}})
}

// put is one request of the VMM's API.
type put struct {
	path string
	body any
}

// configure gives the VMM its guest over its API and boots it.
func (m *Machine) configure(cfg Config) error {
	deadline := time.Now().Add(apiWait)
	client := &http.Client{
		Timeout: apiWait,
		Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			left := time.Until(deadline)
			if d, ok := ctx.Deadline(); ok && time.Until(d) < left {
				left = time.Until(d)
			}
			return m.dialAs(m.api(), left)
		}},
	}
	defer client.CloseIdleConnections()
	for {
		conn, err := m.dialAs(m.api(), apiWait)
		if err == nil {
			_ = conn.Close()
			break
		}
		select {
		case <-m.done:
			return errors.New("vm: the VMM ended before its API was up")
		default:
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("vm: the VMM's API was not up within %s: %w", apiWait, err)
		}
		time.Sleep(dialAgain)
	}
	deadline = time.Now().Add(apiWait)
	for _, put := range m.puts(cfg) {
		body, _ := json.Marshal(put.body)
		req, _ := http.NewRequest(http.MethodPut, "http://vmm"+put.path, bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		if put.path == "/actions" {
			m.started = time.Now()
		}
		resp, err := client.Do(req)
		if err != nil {
			return fmt.Errorf("vm: %s: %w", put.path, err)
		}
		answer, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		_ = resp.Body.Close()
		if resp.StatusCode/100 != 2 {
			return fmt.Errorf("vm: %s: %s %s", put.path, resp.Status, strings.TrimSpace(string(answer)))
		}
	}
	return nil
}

// Dial connects to port in the guest, waiting up to d for the guest to
// listen there.
func (m *Machine) Dial(port uint32, d time.Duration) (net.Conn, error) {
	deadline := time.Now().Add(d)
	for {
		conn, err := m.dialOnce(port, deadline)
		if err == nil {
			return conn, nil
		}
		select {
		case <-m.done:
			return nil, fmt.Errorf("vm: the machine ended: %w", err)
		default:
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("vm: port %d of the guest within %s: %w", port, d, err)
		}
		time.Sleep(dialAgain)
	}
}

// dialOnce is one connection through Firecracker's vsock socket: CONNECT,
// and the device's OK.
func (m *Machine) dialOnce(port uint32, deadline time.Time) (net.Conn, error) {
	conn, err := m.dialAs(m.vsock(), time.Until(deadline))
	if err != nil {
		return nil, err
	}
	_ = conn.SetDeadline(deadline)
	if _, err := fmt.Fprintf(conn, "CONNECT %d\n", port); err != nil {
		_ = conn.Close()
		return nil, err
	}
	// Byte by byte, so nothing past the device's line is read here.
	var line []byte
	one := make([]byte, 1)
	for len(line) < 64 {
		if _, err := conn.Read(one); err != nil {
			_ = conn.Close()
			return nil, err
		}
		line = append(line, one[0])
		if one[0] == '\n' {
			break
		}
	}
	if !bytes.HasPrefix(line, []byte("OK ")) {
		_ = conn.Close()
		return nil, fmt.Errorf("the vsock device answered %q", strings.TrimSpace(string(line)))
	}
	_ = conn.SetDeadline(time.Time{})
	return conn, nil
}

// Ended is how a machine ended.
type Ended string

const (
	// EndAcknowledged is an end the host asked for, which the guest's first
	// process acknowledged (EndAck), and on which the VMM ended by itself.
	EndAcknowledged Ended = "acknowledged"
	// EndOwnExit is the VMM's own exit, which no acknowledged request came
	// before: a crash of the VMM or of the guest.
	EndOwnExit Ended = "own exit"
	// EndKilled is a VMM that was still running past its bound and was
	// killed.
	EndKilled Ended = "killed"
)

// End asks the guest's first process to end the machine: its keeper stops,
// ending every role and space, and the guest resets. Within d the end is
// acknowledged and the VMM exits, or the VMM has exited of its own, or it
// is killed; End says which.
func (m *Machine) End(d time.Duration) Ended {
	m.mu.Lock()
	m.asked = true
	m.mu.Unlock()
	select {
	case <-m.done:
		m.settle(EndOwnExit)
		return m.HowEnded()
	default:
	}
	deadline := time.Now().Add(d)
	acked := false
	if conn, err := m.Dial(EndPort, d); err == nil {
		_ = conn.SetReadDeadline(deadline)
		answer := make([]byte, len(EndAck))
		_, err := io.ReadFull(conn, answer)
		acked = err == nil && string(answer) == EndAck
		_ = conn.Close()
	}
	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()
	select {
	case <-m.done:
		if acked {
			m.settle(EndAcknowledged)
		}
	case <-timer.C:
		m.Kill()
	}
	m.settle(EndOwnExit)
	return m.HowEnded()
}

// Control is the host's control connection to the guest: the relay's
// Hello, then the guest keeper's channel, each line within the keeper
// protocol's bound, read by a deadline the caller gives (Next).
type Control struct {
	Hello Hello
	conn  net.Conn
	lines *protocol.LineReader
	// sendMu keeps each line whole when several senders share it.
	sendMu sync.Mutex
}

// ErrLineTooLong is a line from the guest past protocol.MaxLineBytes.
var ErrLineTooLong = fmt.Errorf("vm: the guest sent a line longer than %d bytes", protocol.MaxLineBytes)

// Connect opens the control connection within ReadyWait of the boot and
// reads the relay's Hello.
func (m *Machine) Connect() (*Control, error) {
	return m.ConnectWithin(ReadyWait - time.Since(m.started))
}

// ConnectWithin opens a control connection and reads the relay's Hello,
// all within left: a running machine's next connection once the relay that
// served its last has ended and its keeper has started it again.
func (m *Machine) ConnectWithin(left time.Duration) (*Control, error) {
	conn, err := m.Dial(ControlPort, left)
	if err != nil {
		return nil, err
	}
	c := &Control{conn: conn, lines: protocol.NewLineReader(conn)}
	line, err := c.Next(time.Now().Add(left))
	if err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("vm: the guest's hello: %w", err)
	}
	h, err := ParseHello(line)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	c.Hello = h
	return c, nil
}

// Send writes one keeper protocol line, within sendWait: a guest that stops
// reading holds no sender past it.
func (c *Control) Send(v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	_ = c.conn.SetWriteDeadline(time.Now().Add(sendWait))
	_, err = c.conn.Write(append(b, '\n'))
	return err
}

// Next reads the guest keeper's next line, without its newline, by
// deadline, which a caller gives once for a whole exchange: a line that
// comes does not move it. A line past the bound is refused, unread.
func (c *Control) Next(deadline time.Time) ([]byte, error) {
	_ = c.conn.SetReadDeadline(deadline)
	line, tooLong, err := c.lines.Next()
	if err != nil {
		return nil, err
	}
	if tooLong {
		return nil, ErrLineTooLong
	}
	return line, nil
}

// Close ends the control connection.
func (c *Control) Close() error { return c.conn.Close() }
