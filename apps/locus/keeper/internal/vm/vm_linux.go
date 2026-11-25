// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package vm

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
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
	"syscall"
	"time"

	"github.com/cyfr/locus/keeper/internal/cgroup"
)

// KVM is the device a machine needs, which the Locus container is given by
// `--device /dev/kvm` and by nothing else.
const KVM = "/dev/kvm"

// ErrNoKVM reports a container that was not given KVM: no machine runs.
var ErrNoKVM = errors.New("this container was given no " + KVM)

// Bounds of a machine's start and end.
const (
	// apiWait bounds the VMM's API socket's appearing.
	apiWait = 2 * time.Second
	// ReadyWait bounds a cold boot to the agent's Hello: P12's boots took
	// 0.67 s, so this is a guest that is not coming.
	ReadyWait = 10 * time.Second
	// EndWait bounds the machine's end after its control connection ends,
	// before its VMM is killed.
	EndWait = 5 * time.Second
	// dialAgain is the pause between two connections the agent refused
	// while it was not yet listening.
	dialAgain = 20 * time.Millisecond
)

// Config is one machine.
type Config struct {
	// Device is the image's programs, attached read only as the root.
	Device string
	// VCPUs and MemoryMiB are the guest's processors and memory. The
	// memory is a ceiling, touched only as it is used.
	VCPUs     int
	MemoryMiB int
	// UID is the VMM's. Its group is the keeper's (gid 0), so the keeper,
	// holding no capability over files, reaches the VMM's sockets while no
	// other user does, and its one supplementary group is KVM's.
	UID uint32
	// Group holds the VMM from before it allocates the guest's memory.
	Group *cgroup.Group
	// BootArgs is the guest kernel's command line, BootArgs() unless a
	// measurement asks otherwise.
	BootArgs string
	// Console takes the VMM's output and the guest's console.
	Console io.Writer
}

// Machine is a running VMM and its guest.
type Machine struct {
	id   string
	dir  string
	cmd  *exec.Cmd
	done chan struct{}
	// started is when the VMM was told to boot the guest.
	started time.Time
}

// Start starts the VMM in its group, under its uid, and boots the guest.
// The caller's umask must leave the group's write bit (the check's is
// 0007): the VMM's sockets are made under it, and the keeper reaches them
// as their group.
func Start(cfg Config) (*Machine, error) {
	var st syscall.Stat_t
	if err := syscall.Stat(KVM, &st); err != nil {
		return nil, ErrNoKVM
	}
	if cfg.Group == nil || cfg.UID == 0 || cfg.VCPUs < 1 || cfg.MemoryMiB < 128 || cfg.Device == "" {
		return nil, errors.New("vm: a machine needs a group, a uid other than root's, a processor, 128 MiB and a device")
	}
	if cfg.BootArgs == "" {
		cfg.BootArgs = BootArgs()
	}
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return nil, err
	}
	m := &Machine{id: hex.EncodeToString(raw[:]), done: make(chan struct{})}
	if err := os.Mkdir(Root, 0o710); err != nil && !errors.Is(err, os.ErrExist) {
		return nil, fmt.Errorf("vm: the machines' folder: %w", err)
	}
	if err := os.Chmod(Root, 0o710); err != nil {
		return nil, fmt.Errorf("vm: the machines' folder: %w", err)
	}
	m.dir = filepath.Join(Root, m.id)
	if err := os.Mkdir(m.dir, 0o770); err != nil {
		return nil, fmt.Errorf("vm: the machine's folder: %w", err)
	}
	if err := os.Chmod(m.dir, 0o770); err != nil {
		_ = os.RemoveAll(m.dir)
		return nil, err
	}
	m.cmd = exec.Command(Firecracker, "--api-sock", m.api(), "--id", m.id, "--level", "Warning")
	m.cmd.Stdout, m.cmd.Stderr = cfg.Console, cfg.Console
	m.cmd.Env = []string{}
	m.cmd.SysProcAttr = &syscall.SysProcAttr{
		Setsid:     true,
		Credential: &syscall.Credential{Uid: cfg.UID, Gid: 0, Groups: []uint32{st.Gid}},
		Pdeathsig:  syscall.SIGKILL,
	}
	if err := m.cmd.Start(); err != nil {
		_ = os.RemoveAll(m.dir)
		return nil, fmt.Errorf("vm: starting the VMM: %w", err)
	}
	go func() {
		_ = m.cmd.Wait()
		close(m.done)
	}()
	// The VMM waits for its API before it allocates anything of the
	// guest's, so its group holds every page of the guest's from the first.
	if err := cfg.Group.Add(m.cmd.Process.Pid); err != nil {
		m.Kill()
		return nil, fmt.Errorf("vm: the VMM's group: %w", err)
	}
	if err := m.configure(cfg); err != nil {
		m.Kill()
		return nil, err
	}
	return m, nil
}

// ID is the machine's own, which names its folder.
func (m *Machine) ID() string { return m.id }

// Done closes when the VMM has exited and been reaped.
func (m *Machine) Done() <-chan struct{} { return m.done }

// State is the VMM's end, once Done has closed.
func (m *Machine) State() *os.ProcessState { return m.cmd.ProcessState }

// Started is when the guest was booted.
func (m *Machine) Started() time.Time { return m.started }

// Kill ends the VMM, and with it the guest, at once, waits for its reaping
// and removes its folder.
func (m *Machine) Kill() {
	_ = m.cmd.Process.Kill()
	<-m.done
	m.remove()
}

// Wait waits up to d for the VMM's own end, and kills it after that. It
// reports whether the VMM ended by itself.
func (m *Machine) Wait(d time.Duration) bool {
	select {
	case <-m.done:
		m.remove()
		return true
	case <-time.After(d):
		m.Kill()
		return false
	}
}

func (m *Machine) remove() { _ = os.RemoveAll(m.dir) }

func (m *Machine) api() string   { return filepath.Join(m.dir, "api.sock") }
func (m *Machine) vsock() string { return filepath.Join(m.dir, "vsock.sock") }

// configure gives the VMM its guest over its API and boots it.
func (m *Machine) configure(cfg Config) error {
	deadline := time.Now().Add(apiWait)
	for {
		if _, err := os.Stat(m.api()); err == nil {
			break
		}
		select {
		case <-m.done:
			return errors.New("vm: the VMM ended before its API was up")
		default:
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("vm: the VMM's API was not up within %s", apiWait)
		}
		time.Sleep(dialAgain)
	}
	client := &http.Client{
		Timeout: apiWait,
		Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", m.api())
		}},
	}
	defer client.CloseIdleConnections()
	for _, put := range []struct {
		path string
		body any
	}{
		{"/machine-config", map[string]any{"vcpu_count": cfg.VCPUs, "mem_size_mib": cfg.MemoryMiB}},
		{"/boot-source", map[string]any{"kernel_image_path": Kernel, "boot_args": cfg.BootArgs}},
		{"/drives/programs", map[string]any{"drive_id": "programs", "path_on_host": cfg.Device, "is_root_device": true, "is_read_only": true}},
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

// Dial connects to port in the guest, waiting up to d for the agent to
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
	conn, err := net.DialTimeout("unix", m.vsock(), time.Until(deadline))
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

// End asks the guest's first process to end the machine: its keeper stops,
// ending every role and space, and the guest resets. It reports whether
// the VMM ended by itself within d, and kills it otherwise.
func (m *Machine) End(d time.Duration) bool {
	if conn, err := m.Dial(EndPort, d); err == nil {
		_ = conn.Close()
	}
	return m.Wait(d)
}

// Control is the host's control connection to the guest: the agent's
// Hello, then the guest keeper's channel.
type Control struct {
	Hello Hello
	conn  net.Conn
	lines *bufio.Reader
}

// Connect opens the control connection within ReadyWait of the boot and
// reads the agent's Hello.
func (m *Machine) Connect() (*Control, error) {
	left := ReadyWait - time.Since(m.started)
	conn, err := m.Dial(ControlPort, left)
	if err != nil {
		return nil, err
	}
	_ = conn.SetReadDeadline(time.Now().Add(left))
	r := bufio.NewReader(conn)
	line, err := r.ReadBytes('\n')
	if err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("vm: the guest agent's hello: %w", err)
	}
	_ = conn.SetReadDeadline(time.Time{})
	h, err := ParseHello(line)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	return &Control{Hello: h, conn: conn, lines: r}, nil
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

// Next reads the guest keeper's next line, waiting at most d.
func (c *Control) Next(d time.Duration) ([]byte, error) {
	_ = c.conn.SetReadDeadline(time.Now().Add(d))
	return c.lines.ReadBytes('\n')
}

// Close ends the control connection, and with it the guest.
func (c *Control) Close() error { return c.conn.Close() }
