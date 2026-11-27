// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package vm

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/frame"
	"github.com/cyfr/locus/keeper/internal/procfs"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// CheckUsage is `cyfr-locus guest-check`'s command line.
const CheckUsage = "cyfr-locus guest-check --kept-root <dir> [--kernel-reporting] [--beside] [-- <command> [args…]]"

// Exit statuses of the check: it ran and the report says what it found,
// or the command line, or the machine could not run.
const (
	CheckPassed = 0
	CheckFailed = 1
	CheckUsageE = 64
)

// The check's machine: two processors and the guest memory P12 measured.
const (
	checkVCPUs     = 2
	checkMemoryMiB = 2560
	// exchangeWait bounds the whole control exchange of the check's one
	// space, from its placing to its release, however many lines the guest
	// sends.
	exchangeWait = 3 * time.Minute
	// consoleTail is how much of the guest's console, and of the maker's
	// output, the check keeps: the last bytes, the rest dropped and said so.
	consoleTail = 64 << 10
	// outputBound is how much of the space's standard output, and of its
	// standard error, the check keeps: the first bytes, the rest counted.
	outputBound = 256 << 10
)

// keeperEnd is the guest keeper's own bound on its end, cyfr-guest's
// keeperStop, which the machine's end waits past.
const keeperEnd = 5 * time.Second

// defaultCommand is the check's space's command when none is given: it
// shows the space's uid, its boot, its IPv4 and IPv6 routes, which must be
// none, what the kernel answers it for socket(AF_VSOCK) and io_uring_setup
// (the return and errno of each, which the keeper's outer policy makes
// -1 and EPERM), and its root, which must be the image's programs bound
// from the guest's read-only root.
var defaultCommand = []string{"/bin/sh", "-c", "id -u; cat /proc/sys/kernel/random/boot_id; " +
	"echo routes $(awk 'NR > 1 && $1 != \"lo\"' /proc/net/route | wc -l) $(awk '$10 != \"lo\"' /proc/net/ipv6_route | wc -l); " +
	"perl -e 'my $p = \"\\0\" x 120; my $v = syscall(41, 40, 1, 0); my $ve = $! + 0; my $u = syscall(425, 1, $p); " +
	"print \"outer vsock $v $ve io_uring $u \", $! + 0, \"\\n\"'; " +
	"cat /proc/self/mountinfo"}

// Report is what the check found, one JSON object on standard output.
type Report struct {
	// Device is the image's programs' device the machine booted from;
	// DeviceMade is that this check made it, and DeviceMs how long this
	// check spent on it, making it or waiting for another start's making.
	Device     string `json:"device"`
	DeviceMade bool   `json:"device_made"`
	DeviceMs   int64  `json:"device_ms"`
	// UID is the machine's VMM's, allotted from MachineUIDs, and Folder
	// the machine's folder.
	UID    int    `json:"uid"`
	Folder string `json:"folder"`
	BootID string `json:"boot_id"`
	// ReadyMs is from the guest's boot to the agent's Hello.
	ReadyMs int64 `json:"ready_ms"`
	// Spawned is the guest keeper's answer to the space's spawn.
	Spawned json.RawMessage `json:"spawned"`
	// Exited is its exit, and Stdout and Stderr the first outputBound
	// bytes of what it wrote, StdoutDropped and StderrDropped how many
	// more.
	Exited        json.RawMessage `json:"exited"`
	Stdout        string          `json:"stdout"`
	Stderr        string          `json:"stderr"`
	StdoutDropped int64           `json:"stdout_dropped"`
	StderrDropped int64           `json:"stderr_dropped"`
	// VMM is how the VMM ran, read from the host while the guest served.
	VMM VMMView `json:"vmm"`
	// Released is that the guest keeper released the space.
	Released bool `json:"released"`
	// End is how the machine ended (Ended): acknowledged, the VMM's own
	// exit, or killed past its bound.
	End   Ended `json:"end"`
	EndMs int64 `json:"end_ms"`
	// GroupProcs are the processes left in the VMM's group after its end.
	GroupProcs []int `json:"group_procs"`
	// CPUUsec is the processor time the VMM's group used, guest included.
	CPUUsec uint64 `json:"cpu_usec"`
	// HeldBytes is what the VMM's group held when the space was released,
	// and PeakBytes the most it held: the difference is what the guest gave
	// back while it ran.
	HeldBytes uint64 `json:"held_bytes"`
	PeakBytes uint64 `json:"peak_bytes"`
	// ReportFromOrder0 is whether the guest reported free pages from order 0.
	ReportFromOrder0 bool `json:"report_from_order0"`
	// Beside is the second machine --beside booted beside this one in the
	// same keeper and ended before this one's space ran.
	Beside *Beside `json:"beside,omitempty"`
	Error  string  `json:"error,omitempty"`
}

// Beside is the machine booted beside the check's own: its uid, its
// folder, its boot and how it ended.
type Beside struct {
	UID    int    `json:"uid"`
	Folder string `json:"folder"`
	BootID string `json:"boot_id"`
	End    Ended  `json:"end"`
}

// VMMView is the VMM's process as the host's kernel shows it: its
// credentials, its filters and capabilities, as /proc/<pid>/status says
// them, and the mounts of its mount namespace.
type VMMView struct {
	UID        string  `json:"uid"`
	GID        string  `json:"gid"`
	Groups     string  `json:"groups"`
	NoNewPrivs string  `json:"no_new_privs"`
	Seccomp    string  `json:"seccomp"`
	CapEff     string  `json:"cap_eff"`
	CapBnd     string  `json:"cap_bnd"`
	Mounts     []Mount `json:"mounts"`
	Error      string  `json:"error,omitempty"`
}

// Mount is one mount of the VMM's namespace: where, whether it is mounted
// read-write ("rw") or read only ("ro"), and its filesystem's type.
type Mount struct {
	Point  string `json:"point"`
	Access string `json:"access"`
	Type   string `json:"type"`
}

// CheckMain is `cyfr-locus guest-check`: it has the image's programs'
// device, making it if this image has none (Programs), boots one machine as
// the keeper would, under the Locus role's own confinement, says hello to its agent,
// has the guest's keeper make one space and end it, ends the machine, and
// reports. With --beside it first boots a second machine beside the first,
// says hello to it and ends it: the first's space then shows that ending
// one machine leaves another running. It is the boot check the keeper reads (plan V3) and the image
// case's entry (tests/locus-backends-image/vm.py).
func CheckMain(args []string) int {
	fs := flag.NewFlagSet("guest-check", flag.ContinueOnError)
	kernelReporting := fs.Bool("kernel-reporting", false, "report free pages from the kernel's own order, not 0 (a measurement's)")
	beside := fs.Bool("beside", false, "boot a second machine beside the first and end it before the first's space")
	keptRoot := fs.String("kept-root", "", "the kept homes' root, which every machine's space covers (the keeper's --kept-homes)")
	if err := fs.Parse(args); err != nil || *keptRoot == "" {
		fmt.Fprintln(os.Stderr, "usage: "+CheckUsage)
		return CheckUsageE
	}
	argv := fs.Args()
	if len(argv) == 0 {
		argv = defaultCommand
	}
	report := Report{ReportFromOrder0: !*kernelReporting}
	console := &tail{max: consoleTail}
	maker := &tail{max: consoleTail}
	err := check(argv, *keptRoot, *beside, &report, console, maker)
	if err != nil {
		report.Error = err.Error()
	}
	maker.print(os.Stderr, "maker: ")
	console.print(os.Stderr, "guest: ")
	out, _ := json.Marshal(report)
	fmt.Println(string(out))
	if err != nil {
		return CheckFailed
	}
	return CheckPassed
}

func check(argv []string, keptRoot string, beside bool, report *Report, console, maker io.Writer) error {
	raw, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return err
	}
	st, err := procfs.ParseStatus(raw)
	if err != nil {
		return err
	}
	if err := procfs.CheckKeeperCaps(st); err != nil {
		return err
	}
	// The keeper's own groups: a space is given none (package stage).
	if err := syscall.Setgroups([]int{}); err != nil {
		return fmt.Errorf("clearing the supplementary groups: %w", err)
	}
	// Without KVM no machine runs, so no device is made for one.
	if _, err := os.Stat(KVM); err != nil {
		return ErrNoKVM
	}
	began := time.Now()
	device, made, err := Programs(maker).Device()
	report.DeviceMs = time.Since(began).Milliseconds()
	if err != nil {
		return err
	}
	report.Device, report.DeviceMade = device.Path, made
	// The machine takes the device, and closes it at its end; until Start
	// has it, the check does.
	held := device
	defer func() {
		if held != nil {
			_ = held.Close()
		}
	}()
	self, err := os.ReadFile("/proc/self/cgroup")
	if err != nil {
		return err
	}
	groups, err := cgroup.Delegate("/sys/fs/cgroup", self)
	if err != nil {
		return err
	}
	args := bootArgs(report.ReportFromOrder0, true)
	held = nil
	m, err := Start(Config{Device: device, VCPUs: checkVCPUs, MemoryMiB: checkMemoryMiB, Groups: groups,
		BootArgs: args, Console: console, KeptRoot: keptRoot})
	if err != nil {
		return err
	}
	report.UID, report.Folder = m.UID(), m.Folder()
	ended := false
	defer func() {
		if !ended {
			m.Kill()
		}
	}()
	c, err := m.Connect()
	if err != nil {
		return err
	}
	report.BootID = c.Hello.BootID
	report.ReadyMs = time.Since(m.Started()).Milliseconds()
	report.VMM = vmmView(m.Group())
	if beside {
		if report.Beside, err = besideMachine(groups, maker, keptRoot, report.ReportFromOrder0); err != nil {
			return err
		}
	}

	spaceErr := space(m, c, argv, report)
	report.HeldBytes = groupNumber(m.Group(), "memory.current")
	report.PeakBytes = groupNumber(m.Group(), "memory.peak")

	// The machine's end: the guest's first process stops its keeper, which
	// ends the role and every space, and resets the guest.
	_ = c.Close()
	closed := time.Now()
	report.End = m.End(EndWait + keeperEnd)
	ended = true
	report.EndMs = time.Since(closed).Milliseconds()
	report.CPUUsec = m.CPUUsec()
	report.GroupProcs = append([]int{}, m.LeftProcs()...)
	if spaceErr != nil {
		return spaceErr
	}
	if err := m.Left(); err != nil {
		return err
	}
	if report.End != EndAcknowledged {
		return fmt.Errorf("the machine's end was not the acknowledged one: %s", report.End)
	}
	if len(report.GroupProcs) > 0 {
		return fmt.Errorf("processes %v are left in the machine's group", report.GroupProcs)
	}
	return nil
}

// besideMachine boots a second machine in the same keeper, with a hold of
// its own on the device and no console, says hello to it and ends it, and
// refuses an end that was not the acknowledged one or left anything.
func besideMachine(groups *cgroup.Manager, maker io.Writer, keptRoot string, order0 bool) (*Beside, error) {
	device, _, err := Programs(maker).Device()
	if err != nil {
		return nil, err
	}
	m, err := Start(Config{Device: device, VCPUs: checkVCPUs, MemoryMiB: checkMemoryMiB, Groups: groups,
		BootArgs: bootArgs(order0, false), KeptRoot: keptRoot})
	if err != nil {
		return nil, fmt.Errorf("the machine beside: %w", err)
	}
	b := &Beside{UID: m.UID(), Folder: m.Folder()}
	c, err := m.Connect()
	if err != nil {
		m.Kill()
		return b, fmt.Errorf("the machine beside: %w", err)
	}
	b.BootID = c.Hello.BootID
	_ = c.Close()
	b.End = m.End(EndWait + keeperEnd)
	if err := m.Left(); err != nil {
		return b, fmt.Errorf("the machine beside: %w", err)
	}
	if b.End != EndAcknowledged {
		return b, fmt.Errorf("the machine beside's end was not the acknowledged one: %s", b.End)
	}
	return b, nil
}

// space has the guest's keeper place and spawn one space, reads its output
// and waits for its exit and release, all within one exchangeWait.
func space(m *Machine, c *Control, argv []string, report *Report) error {
	deadline := time.Now().Add(exchangeWait)
	place, err := randomHex(16)
	if err != nil {
		return err
	}
	token, err := randomHex(32)
	if err != nil {
		return err
	}
	// The guest's one role keeps sessions, so the space is placed as one.
	if err := c.Send(protocol.Request{V: protocol.Version, Type: "place", ID: place, Kind: protocol.KindProgram}); err != nil {
		return err
	}
	if line, err := expect(c, deadline, "placed", place, ""); err != nil {
		return fmt.Errorf("placing the space: %w (%s)", err, line)
	}
	spawn := protocol.Request{V: protocol.Version, Type: "spawn", ID: "s-" + place, Place: place, Pool: GuestPool,
		Argv: argv, Attach: &protocol.Attach{Path: GuestAttachPath, Token: token}}
	if err := c.Send(spawn); err != nil {
		return err
	}
	// The host's half of the space's attach connection, by its token.
	attach, err := m.Dial(AttachPort, time.Until(deadline))
	if err != nil {
		return err
	}
	defer attach.Close()
	if err := frame.Write(attach, frame.StreamAttach, []byte(token)); err != nil {
		return err
	}
	line, err := expect(c, deadline, "spawned", "s-"+place, "")
	report.Spawned = json.RawMessage(strings.TrimSpace(string(line)))
	if err != nil {
		return fmt.Errorf("spawning the space: %w", err)
	}
	var spawned struct {
		SpawnID string `json:"spawn_id"`
	}
	if err := json.Unmarshal(line, &spawned); err != nil || spawned.SpawnID == "" {
		return fmt.Errorf("the space's spawned line names no spawn: %s", line)
	}
	stdout, stderr := &bounded{max: outputBound}, &bounded{max: outputBound}
	_ = attach.SetReadDeadline(deadline)
	buf := make([]byte, frame.MaxPayload)
	for open := 2; open > 0; {
		stream, payload, err := frame.Read(attach, buf)
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return fmt.Errorf("reading the space's output: %w", err)
		}
		switch stream {
		case frame.StreamStdout:
			stdout.Write(payload)
		case frame.StreamStderr:
			stderr.Write(payload)
		default:
			continue
		}
		if len(payload) == 0 {
			open--
		}
	}
	report.Stdout, report.Stderr = stdout.buf.String(), stderr.buf.String()
	report.StdoutDropped, report.StderrDropped = stdout.dropped, stderr.dropped
	exited, err := expect(c, deadline, "exited", "", spawned.SpawnID)
	report.Exited = json.RawMessage(strings.TrimSpace(string(exited)))
	if err != nil {
		return fmt.Errorf("the space's exit: %w", err)
	}
	if _, err := expect(c, deadline, "released", "", spawned.SpawnID); err != nil {
		return fmt.Errorf("the space's release: %w", err)
	}
	report.Released = true
	return nil
}

// expect reads the guest keeper's lines until one of type typ, of id and
// of spawnID where each is given, by deadline however many other lines
// come first, and refuses an error line.
func expect(c *Control, deadline time.Time, typ, id, spawnID string) ([]byte, error) {
	for {
		line, err := c.Next(deadline)
		if err != nil {
			return line, err
		}
		var head struct {
			Type    string          `json:"type"`
			ID      string          `json:"id"`
			SpawnID string          `json:"spawn_id"`
			Code    json.RawMessage `json:"code"`
		}
		if err := json.Unmarshal(line, &head); err != nil {
			return line, err
		}
		if head.Type == "error" {
			return line, fmt.Errorf("the guest keeper refused it: %s", string(head.Code))
		}
		if head.Type == typ && (id == "" || head.ID == id) && (spawnID == "" || head.SpawnID == spawnID) {
			return line, nil
		}
	}
}

// groupCPUUsec is the processor time a group's processes used, from its
// cpu.stat, or 0 where it cannot be read.
func groupCPUUsec(g *cgroup.Group) uint64 {
	raw, err := os.ReadFile(filepath.Join("/sys/fs/cgroup", g.Path(), "cpu.stat"))
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(raw), "\n") {
		if v, ok := strings.CutPrefix(line, "usage_usec "); ok {
			n, _ := strconv.ParseUint(v, 10, 64)
			return n
		}
	}
	return 0
}

// groupNumber is one number a group's file holds, or 0 where it cannot be
// read.
func groupNumber(g *cgroup.Group, file string) uint64 {
	raw, err := os.ReadFile(filepath.Join("/sys/fs/cgroup", g.Path(), file))
	if err != nil {
		return 0
	}
	n, _ := strconv.ParseUint(strings.TrimSpace(string(raw)), 10, 64)
	return n
}

func randomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// tail keeps the last max bytes written to it, and counts what it dropped:
// the guest's console and the maker's output reach the check's standard
// error only through one, after the machine's end.
type tail struct {
	mu      sync.Mutex
	max     int
	buf     []byte
	dropped int64
}

func (t *tail) Write(b []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.buf = append(t.buf, b...)
	if over := len(t.buf) - t.max; over > 0 {
		t.dropped += int64(over)
		t.buf = append(t.buf[:0:0], t.buf[over:]...)
	}
	return len(b), nil
}

// print writes what t kept, each line marked with tag, after a line saying
// how much was dropped before it, if any was.
func (t *tail) print(w io.Writer, tag string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.dropped > 0 {
		fmt.Fprintf(w, "%s(the first %d bytes were dropped: the check keeps the last %d)\n", tag, t.dropped, t.max)
	}
	for _, line := range strings.SplitAfter(string(t.buf), "\n") {
		if line == "" {
			continue
		}
		if !strings.HasSuffix(line, "\n") {
			line += "\n"
		}
		_, _ = io.WriteString(w, tag+line)
	}
}

// bounded keeps the first max bytes written to it and counts the rest.
type bounded struct {
	max     int
	buf     strings.Builder
	dropped int64
}

func (b *bounded) Write(p []byte) (int, error) {
	keep := b.max - b.buf.Len()
	if keep > len(p) {
		keep = len(p)
	}
	if keep > 0 {
		b.buf.Write(p[:keep])
	}
	b.dropped += int64(len(p) - keep)
	return len(p), nil
}

// vmmView reads the VMM's process, the one of its group named
// firecracker, from the host's /proc.
func vmmView(group *cgroup.Group) VMMView {
	var v VMMView
	procs, err := group.Procs()
	if err != nil {
		v.Error = err.Error()
		return v
	}
	for _, pid := range procs {
		dir := filepath.Join("/proc", strconv.Itoa(pid))
		comm, err := os.ReadFile(filepath.Join(dir, "comm"))
		if err != nil || strings.TrimSpace(string(comm)) != "firecracker" {
			continue
		}
		status, err := os.ReadFile(filepath.Join(dir, "status"))
		if err != nil {
			v.Error = err.Error()
			return v
		}
		for _, line := range strings.Split(string(status), "\n") {
			name, value, ok := strings.Cut(line, ":")
			value = strings.Join(strings.Fields(value), " ")
			if !ok {
				continue
			}
			switch name {
			case "Uid":
				v.UID = value
			case "Gid":
				v.GID = value
			case "Groups":
				v.Groups = value
			case "NoNewPrivs":
				v.NoNewPrivs = value
			case "Seccomp":
				v.Seccomp = value
			case "CapEff":
				v.CapEff = value
			case "CapBnd":
				v.CapBnd = value
			}
		}
		mounts, err := os.ReadFile(filepath.Join(dir, "mountinfo"))
		if err != nil {
			v.Error = err.Error()
			return v
		}
		v.Mounts = []Mount{}
		for _, line := range strings.Split(string(mounts), "\n") {
			fields := strings.Fields(line)
			_, after, ok := strings.Cut(line, " - ")
			if len(fields) < 6 || !ok || len(strings.Fields(after)) == 0 {
				continue
			}
			v.Mounts = append(v.Mounts, Mount{Point: fields[4], Access: strings.Split(fields[5], ",")[0],
				Type: strings.Fields(after)[0]})
		}
		return v
	}
	v.Error = fmt.Sprintf("no process named firecracker in the VMM's group, of %v", procs)
	return v
}
