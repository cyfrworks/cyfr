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
	"syscall"
	"time"

	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/frame"
	"github.com/cyfr/locus/keeper/internal/procfs"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// CheckUsage is `cyfr-locus guest-check`'s command line.
const CheckUsage = "cyfr-locus guest-check [--kernel-reporting] [-- <command> [args…]]"

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
	// checkUID is the check's VMM's uid: nobody, which owns nothing.
	checkUID = 65534
	// checkSpawnMemory is the bound of the check's one space.
	checkSpawnMemory = 1 << 30
	// stepWait bounds each step of the keeper protocol inside the guest.
	stepWait = 60 * time.Second
)

// defaultCommand is the check's space's command when none is given: it
// shows the space's root, which must be the image's programs bound from
// the guest's read-only root, its uid and its boot.
var defaultCommand = []string{"/bin/sh", "-c", "id -u; cat /proc/sys/kernel/random/boot_id; cat /proc/self/mountinfo"}

// Report is what the check found, one JSON object on standard output.
type Report struct {
	// Device is the image's programs' device the machine booted from;
	// DeviceMade is that this check made it, and DeviceMs how long this
	// check spent on it, making it or waiting for another start's making.
	Device     string `json:"device"`
	DeviceMade bool   `json:"device_made"`
	DeviceMs   int64  `json:"device_ms"`
	BootID     string `json:"boot_id"`
	// ReadyMs is from the guest's boot to the agent's Hello.
	ReadyMs int64 `json:"ready_ms"`
	// Spawned is the guest keeper's answer to the space's spawn.
	Spawned json.RawMessage `json:"spawned"`
	// Exited is its exit, and Stdout what it wrote.
	Exited json.RawMessage `json:"exited"`
	Stdout string          `json:"stdout"`
	Stderr string          `json:"stderr"`
	// Released is that the guest keeper released the space.
	Released bool `json:"released"`
	// EndedByItself is that the VMM ended within EndWait of the control
	// connection's end, without being killed.
	EndedByItself bool  `json:"ended_by_itself"`
	EndMs         int64 `json:"end_ms"`
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
	ReportFromOrder0 bool   `json:"report_from_order0"`
	Error            string `json:"error,omitempty"`
}

// CheckMain is `cyfr-locus guest-check`: it has the image's programs'
// device, making it if this image has none (Programs), boots one machine as
// the keeper would, under the Locus role's own confinement, says hello to its agent,
// has the guest's keeper make one space and end it, ends the machine, and
// reports. It is the boot check the keeper reads (plan V3) and the image
// case's entry (tests/locus-backends-image/vm.py).
func CheckMain(args []string) int {
	fs := flag.NewFlagSet("guest-check", flag.ContinueOnError)
	kernelReporting := fs.Bool("kernel-reporting", false, "report free pages from the kernel's own order, not 0 (a measurement's)")
	if err := fs.Parse(args); err != nil {
		fmt.Fprintln(os.Stderr, "usage: "+CheckUsage)
		return CheckUsageE
	}
	argv := fs.Args()
	if len(argv) == 0 {
		argv = defaultCommand
	}
	report := Report{ReportFromOrder0: !*kernelReporting}
	err := check(argv, &report)
	if err != nil {
		report.Error = err.Error()
	}
	out, _ := json.Marshal(report)
	fmt.Println(string(out))
	if err != nil {
		return CheckFailed
	}
	return CheckPassed
}

func check(argv []string, report *Report) error {
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
	// The VMM's sockets are made under this umask and reached by their
	// group, the keeper's (Config.UID).
	syscall.Umask(0o007)
	began := time.Now()
	device, made, err := Programs(&prefixed{w: os.Stderr, tag: "maker: "}).Device()
	report.DeviceMs = time.Since(began).Milliseconds()
	report.Device, report.DeviceMade = device, made
	if err != nil {
		return err
	}
	self, err := os.ReadFile("/proc/self/cgroup")
	if err != nil {
		return err
	}
	groups, err := cgroup.Delegate("/sys/fs/cgroup", self)
	if err != nil {
		return err
	}
	id, err := randomHex(16)
	if err != nil {
		return err
	}
	group, err := groups.Create(cgroup.SpawnName(id), (checkMemoryMiB+64)<<20, checkVCPUs*cgroup.CPUPeriod)
	if err != nil {
		return err
	}
	defer func() { _ = group.Remove() }()
	args := BootArgs()
	if !report.ReportFromOrder0 {
		args = bootArgs(false)
	}
	m, err := Start(Config{Device: device, VCPUs: checkVCPUs, MemoryMiB: checkMemoryMiB, UID: checkUID,
		Group: group, BootArgs: args, Console: &prefixed{w: os.Stderr, tag: "guest: "}})
	if err != nil {
		return err
	}
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

	spaceErr := space(m, c, argv, report)
	report.HeldBytes = groupNumber(group, "memory.current")
	report.PeakBytes = groupNumber(group, "memory.peak")

	// The control connection's end is the guest's: its keeper ends every
	// space and the guest resets.
	closed := time.Now()
	_ = c.Close()
	report.EndedByItself = m.Wait(EndWait)
	ended = true
	report.EndMs = time.Since(closed).Milliseconds()
	report.CPUUsec = cpuUsec(group)
	if procs, err := group.Procs(); err == nil {
		report.GroupProcs = append([]int{}, procs...)
	} else if spaceErr == nil {
		spaceErr = err
	}
	if spaceErr != nil {
		return spaceErr
	}
	if !report.EndedByItself {
		return errors.New("the machine did not end by itself after its control connection ended")
	}
	if len(report.GroupProcs) > 0 {
		return fmt.Errorf("processes %v are left in the machine's group", report.GroupProcs)
	}
	return nil
}

// space has the guest's keeper place and spawn one space, reads its output
// and waits for its exit and release.
func space(m *Machine, c *Control, argv []string, report *Report) error {
	place, err := randomHex(16)
	if err != nil {
		return err
	}
	token, err := randomHex(32)
	if err != nil {
		return err
	}
	if err := c.Send(protocol.Request{V: protocol.Version, Type: "place", ID: place, Kind: protocol.KindRun}); err != nil {
		return err
	}
	if line, err := expect(c, "placed", place); err != nil {
		return fmt.Errorf("placing the space: %w (%s)", err, line)
	}
	memory, quota := uint64(checkSpawnMemory), uint64(cgroup.CPUPeriod)
	spawn := protocol.Request{V: protocol.Version, Type: "spawn", ID: "s-" + place, Place: place, Pool: GuestPool,
		Argv: argv, MemoryBytes: &memory, CPUQuota: &quota,
		Attach: &protocol.Attach{Path: GuestAttachPath, Token: token}}
	if err := c.Send(spawn); err != nil {
		return err
	}
	// The host's half of the space's attach connection, by its token.
	attach, err := m.Dial(AttachPort, stepWait)
	if err != nil {
		return err
	}
	defer attach.Close()
	if err := frame.Write(attach, frame.StreamAttach, []byte(token)); err != nil {
		return err
	}
	line, err := expect(c, "spawned", "s-"+place)
	report.Spawned = json.RawMessage(strings.TrimSpace(string(line)))
	if err != nil {
		return fmt.Errorf("spawning the space: %w", err)
	}
	var stdout, stderr strings.Builder
	_ = attach.SetReadDeadline(time.Now().Add(stepWait))
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
	report.Stdout, report.Stderr = stdout.String(), stderr.String()
	exited, err := expect(c, "exited", "")
	report.Exited = json.RawMessage(strings.TrimSpace(string(exited)))
	if err != nil {
		return fmt.Errorf("the space's exit: %w", err)
	}
	if _, err := expect(c, "released", ""); err != nil {
		return fmt.Errorf("the space's release: %w", err)
	}
	report.Released = true
	return nil
}

// expect reads the guest keeper's lines until one of type typ (and of id,
// where one is given), and refuses an error line.
func expect(c *Control, typ, id string) ([]byte, error) {
	for {
		line, err := c.Next(stepWait)
		if err != nil {
			return line, err
		}
		var head struct {
			Type string          `json:"type"`
			ID   string          `json:"id"`
			Code json.RawMessage `json:"code"`
		}
		if err := json.Unmarshal(line, &head); err != nil {
			return line, err
		}
		if head.Type == "error" {
			return line, fmt.Errorf("the guest keeper refused it: %s", string(head.Code))
		}
		if head.Type == typ && (id == "" || head.ID == id) {
			return line, nil
		}
	}
}

// cpuUsec is the processor time a group's processes used, from its
// cpu.stat, or 0 where it cannot be read.
func cpuUsec(g *cgroup.Group) uint64 {
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

// prefixed marks the guest's console lines, and the maker's, on the check's
// standard error, a whole line at a time: the console arrives in pieces.
type prefixed struct {
	w       io.Writer
	tag     string
	pending []byte
}

func (p *prefixed) Write(b []byte) (int, error) {
	p.pending = append(p.pending, b...)
	for {
		i := strings.IndexByte(string(p.pending), '\n')
		if i < 0 {
			return len(b), nil
		}
		if _, err := io.WriteString(p.w, p.tag+string(p.pending[:i+1])); err != nil {
			return 0, err
		}
		p.pending = p.pending[i+1:]
	}
}
