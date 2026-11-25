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
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/pool"
	"github.com/cyfr/locus/keeper/internal/protocol"
	"github.com/cyfr/locus/keeper/internal/retire"
	"github.com/cyfr/locus/keeper/internal/stage"
)

// KVM is the device a machine needs, which the Locus container is given by
// `--device /dev/kvm` and by nothing else.
const KVM = "/dev/kvm"

// ErrNoKVM reports a container that was not given KVM: no machine runs.
var ErrNoKVM = errors.New("this container was given no " + KVM)

// Bounds of a machine's start and end.
const (
	// stageWait bounds the VMM's stage from its start to the VMM's exec.
	stageWait = 10 * time.Second
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
	// UID is the VMM's, its own (MachineUID).
	UID int
	// Group holds the VMM, its stage and its space from before the VMM is
	// executed: the group of UID (cgroup.Name), as the stage requires.
	Group *cgroup.Group
	// BootArgs is the guest kernel's command line, BootArgs(Console != nil)
	// unless a measurement asks otherwise.
	BootArgs string
	// Console takes the VMM's output and the guest's serial console, for
	// guest-check's diagnosis; it should keep a bounded part of what it is
	// given. A machine that serves has none: its VMM's output goes to
	// /dev/null and its guest is booted with no console.
	Console io.Writer
}

// Machine is a running VMM and its guest.
type Machine struct {
	id  string
	dir string
	uid int
	gid int
	cmd *exec.Cmd
	// done closes when the VMM's stage, which ends as the VMM ends, has
	// exited and been reaped.
	done chan struct{}
	// started is when the VMM was told to boot the guest.
	started time.Time
	device  *Device
	// console closes when the console's copier has read its last byte.
	console chan struct{}
	// clear ends what is left of the machine's uid and removes its folder
	// (runRetire), at its end.
	clear    func() error
	ended    sync.Once
	leftOver error
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
// Start takes cfg.Device: it is closed at the machine's end, or on an
// error.
func Start(cfg Config) (*Machine, error) {
	m, err := start(cfg)
	if err != nil && cfg.Device != nil && (m == nil || m.cmd == nil || m.cmd.Process == nil) {
		_ = cfg.Device.Close()
	}
	if err != nil {
		return nil, err
	}
	return m, nil
}

// start is Start; a machine it answers with an error has its stage
// started when its device is closed already (Kill).
func start(cfg Config) (*Machine, error) {
	var st syscall.Stat_t
	if err := syscall.Stat(KVM, &st); err != nil {
		return nil, ErrNoKVM
	}
	if cfg.Group == nil || cfg.UID <= 0 || cfg.VCPUs < 1 || cfg.MemoryMiB < 128 || cfg.Device == nil {
		return nil, errors.New("vm: a machine needs a group, a uid other than root's, a processor, 128 MiB and a device")
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
	name, err := home.NewName(cfg.UID)
	if err != nil {
		return nil, err
	}
	m := &Machine{id: name, dir: filepath.Join(Root, name), uid: cfg.UID, gid: int(st.Gid), device: cfg.Device,
		done: make(chan struct{})}
	m.clear = func() error { return runRetire(m.uid, m.gid, m.dir) }
	spec := stage.Spec{UID: m.uid, GID: m.gid, User: MachineUser, HomeRoot: Root, Home: m.dir,
		Argv:   []string{Firecracker, "--api-sock", m.api(), "--id", m.id, "--level", "Warning"},
		Limits: machineLimits, Reach: pool.ReachRelay, Cgroup: cfg.Group.Path(), Machine: cfg.Device.Path}
	if err := spec.Validate(); err != nil {
		return nil, fmt.Errorf("vm: the VMM's space: %w", err)
	}
	if err := m.startStage(self, spec, cfg.Group, cfg.Console); err != nil {
		return m, err
	}
	if err := m.configure(cfg); err != nil {
		m.Kill()
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
// and hands it its spec, in that order, as the keeper does a spawn's, and
// waits for the VMM's exec. It leaves nothing running on an error.
func (m *Machine) startStage(self string, spec stage.Spec, group *cgroup.Group, console io.Writer) error {
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
	// The space's relay: the keeper keeps no end of it.
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
	go func() {
		_ = m.cmd.Wait()
		close(m.done)
	}()
	fail := func(err error) error {
		m.Kill()
		return err
	}
	if err := stage.MapIDs(m.cmd.Process.Pid, spec.UID, spec.GID); err != nil {
		return fail(fmt.Errorf("vm: the VMM's ids: %w", err))
	}
	if err := group.Add(m.cmd.Process.Pid); err != nil {
		return fail(fmt.Errorf("vm: the VMM's group: %w", err))
	}
	_ = specW.SetWriteDeadline(time.Now().Add(stageWait))
	if _, err := specW.Write(data); err != nil {
		return fail(fmt.Errorf("vm: the VMM's spec: %w", err))
	}
	_ = specW.Close()
	_ = statusW.Close()
	_ = statusR.SetReadDeadline(time.Now().Add(stageWait))
	reason, err := io.ReadAll(io.LimitReader(statusR, 4096))
	if err != nil {
		return fail(fmt.Errorf("vm: the VMM's stage: %w", err))
	}
	if len(reason) > 0 {
		return fail(fmt.Errorf("vm: the VMM's stage: %s", reason))
	}
	return nil
}

// ID is the machine's own, which names its folder.
func (m *Machine) ID() string { return m.id }

// Done closes when the VMM has exited and been reaped.
func (m *Machine) Done() <-chan struct{} { return m.done }

// State is the VMM's end, once Done has closed.
func (m *Machine) State() *os.ProcessState { return m.cmd.ProcessState }

// Started is when the guest was booted.
func (m *Machine) Started() time.Time { return m.started }

// Left is what the machine's end could not clear, its uid's processes or
// its folder, or nil, once the machine has ended.
func (m *Machine) Left() error { return m.leftOver }

// Kill ends the VMM, and with it the guest, at once, waits for its reaping
// and clears what it held.
func (m *Machine) Kill() {
	_ = m.cmd.Process.Kill()
	<-m.done
	m.remove()
}

// remove clears what the machine held, once: every process of its uid and
// its folder, by `cyfr-locus retire` as that uid as a spawn's are, the
// console's last bytes, and its device's lock.
func (m *Machine) remove() {
	m.ended.Do(func() {
		if m.clear != nil {
			m.leftOver = m.clear()
		}
		if m.console != nil {
			select {
			case <-m.console:
			case <-time.After(consoleWait):
			}
		}
		if m.device != nil {
			_ = m.device.Close()
		}
	})
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
	for _, put := range []struct {
		path string
		body any
	}{
		{"/machine-config", map[string]any{"vcpu_count": cfg.VCPUs, "mem_size_mib": cfg.MemoryMiB}},
		{"/boot-source", map[string]any{"kernel_image_path": Kernel, "boot_args": cfg.BootArgs}},
		{"/drives/programs", map[string]any{"drive_id": "programs", "path_on_host": cfg.Device.Path, "is_root_device": true, "is_read_only": true}},
		{"/vsock", map[string]any{"guest_cid": GuestCID, "uds_path": m.vsock()}},
		// The balloon is there for free-page reporting alone: it is never
		// inflated.
		{"/balloon", map[string]any{"amount_mib": 0, "deflate_on_oom": true, "free_page_reporting": true}},
		{"/actions", map[string]any{"action_type": "InstanceStart"}},
	} {
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
	select {
	case <-m.done:
		m.remove()
		return EndOwnExit
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
		m.remove()
		if acked {
			return EndAcknowledged
		}
		return EndOwnExit
	case <-timer.C:
		m.Kill()
		return EndKilled
	}
}

// Control is the host's control connection to the guest: the relay's
// Hello, then the guest keeper's channel, each line within the keeper
// protocol's bound.
type Control struct {
	Hello Hello
	conn  net.Conn
	lines *protocol.LineReader
}

// ErrLineTooLong is a line from the guest past protocol.MaxLineBytes.
var ErrLineTooLong = fmt.Errorf("vm: the guest sent a line longer than %d bytes", protocol.MaxLineBytes)

// Connect opens the control connection within ReadyWait of the boot and
// reads the relay's Hello.
func (m *Machine) Connect() (*Control, error) {
	left := ReadyWait - time.Since(m.started)
	conn, err := m.Dial(ControlPort, left)
	if err != nil {
		return nil, err
	}
	c := &Control{conn: conn, lines: protocol.NewLineReader(conn)}
	line, err := c.Next(left)
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

// Send writes one keeper protocol line.
func (c *Control) Send(v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	_, err = c.conn.Write(append(b, '\n'))
	return err
}

// Next reads the guest keeper's next line, without its newline, waiting at
// most d; a line past the bound is refused, unread.
func (c *Control) Next(d time.Duration) ([]byte, error) {
	_ = c.conn.SetReadDeadline(time.Now().Add(d))
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
