// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package vm runs a person's machine: a Firecracker microVM whose root is
// the image's programs, read only, whose kernel is CYFR's guest kernel, and
// whose first process is the guest agent, cmd/cyfr-guest. Inside it the
// keeper's own code, `cyfr-locus serve` from that read-only root, makes
// each session's space exactly as it does in the Locus container; the guest
// agent is that keeper's client, and carries its channel, unchanged, over
// vsock to the host.
//
// What crosses between host and guest, and the only way it crosses: the
// host connects, the guest never does. Firecracker's vsock device turns a
// connection to its Unix socket, after "CONNECT <port>\n", into one to that
// port in the guest, and the guest's first process, which alone makes
// vsock sockets, answers only a peer whose CID is the host's. Nothing on
// the host listens for the guest, and no process under the guest's keeper
// may make a vsock socket (the keeper's own system-call policy, which the
// first process installs before the keeper starts), so no process in the
// guest, a session's included, has a way to the host but the connections
// the host opens:
//
//   - ControlPort, once for each start of the guest keeper's role: the
//     relay's Hello line, then the keeper protocol (package protocol)
//     between the host and the guest's keeper, line for line, each line
//     within protocol.MaxLineBytes. Its end, from either side, ends the
//     relay, and the guest's keeper retires every space the role held and
//     starts the role again, as it does any role.
//   - EndPort, once: the guest's first process answers it alone with
//     EndAck, stops the guest's keeper, which ends its role and every
//     space, and resets the machine, on which its VMM ends.
//   - AttachPort, once for each spawn: the host's first frame is the
//     spawn's attach token (frame.StreamAttach), the relay pairs it with
//     the spawn's relay that presented the same token on GuestAttachPath,
//     and the two are joined byte for byte.
//
// The relay listens on ControlPort and AttachPort through listeners the
// first process made and hands it on GuestHandoffPath. A machine that
// serves has no serial console: its VMM's output goes nowhere, and the
// guest kernel is given no console (BootArgs). `cyfr-locus guest-check`
// alone boots with one and keeps a bounded tail of it for diagnosis.
//
// This file is the one definition both sides read; it builds everywhere
// so the guest agent's and the host's code agree by construction.
package vm

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

// The vsock ports the guest agent listens on, and the CIDs of each end.
const (
	ControlPort uint32 = 1024
	AttachPort  uint32 = 1025
	EndPort     uint32 = 1026
	// EndAck is the first process's answer on EndPort, the machine's end
	// acknowledged: what follows is the VMM's exit.
	EndAck = "ending\n"
	// HostCID is the host's address on every vsock device.
	HostCID uint32 = 2
	// GuestCID is the guest's address on its machine's vsock device.
	GuestCID uint32 = 3
)

// The guest's side of its keeper, as cmd/cyfr-guest starts it: the Locus
// container's own keeper, guard and role, one role of it.
const (
	// GuestRole is the guest keeper's one role, whose process is the
	// guest agent's relay (`cyfr-guest relay`): the image's backends role,
	// its uid the image's locus-backends and its port the role table's.
	GuestRole = "backends"
	// GuestRoleSpec is that role on the guest keeper's command line. Its
	// space is routed by the guest's guard as every role's is; with no
	// network card in the guest the route leads nowhere.
	GuestRoleSpec = GuestRole + ":10013:4101:" + GuestPool
	// GuestRoleKey is the role's key variable, which the keeper starts the
	// role for. The relay reads no key: the init gives it one of its own.
	GuestRoleKey = "LOCUS_BACKENDS_KEY"
	// GuestPool is the role's one pool, which the host names in each
	// spawn. It is a relay pool, so a space in it has no route at all: the
	// routed sessions of a person, and the host's guard of their machine,
	// are V2's.
	GuestPool = "backends"
	// GuestPoolSpec is that pool on the guest keeper's command line: the
	// backend uids the image already defines.
	GuestPoolSpec = GuestPool + ":20001-20032:relay"
	// GuestHomeRoot is the guest keeper's home root; the role's homes are
	// a tmpfs of the guest's own at GuestHomeRoot/GuestRole.
	GuestHomeRoot = "/var/lib/locus/homes"
	// GuestRunDir is the role's run folder, its uid's own, 0700, where the
	// keeper's relays reach the attach socket it listens on.
	GuestRunDir = "/run/locus/" + GuestRole
	// GuestAttachPath is that socket: the host names it in each spawn it
	// asks the guest for.
	GuestAttachPath = GuestRunDir + "/attach.sock"
	// GuestHandoffPath is where the guest's first process hands the
	// relay the vsock listeners it made for ControlPort and AttachPort,
	// to the role's uid alone: no process under the keeper makes one.
	GuestHandoffPath = GuestRunDir + "/vsock.sock"
	// GuestPolicy is the keeper's own system-call policy, the Locus
	// container's seccomp profile as the image carries it, and
	// GuestSyscalls the guest kernel's system-call table, by which the
	// first process compiles it (package outer).
	GuestPolicy   = "/etc/cyfr/keeper.json"
	GuestSyscalls = "/usr/lib/cyfr/guest/syscall_64.tbl"
	// GuestGuardControl is the guest's guard's control socket, which the
	// keeper proves the guard by at its boot and routes every role by.
	GuestGuardControl = "/run/cyfr-guard-control/guard.sock"
	// GuestAgent is the guest agent's path in the image's programs, which
	// the kernel runs as the guest's first process.
	GuestAgent = "/usr/local/bin/cyfr-guest"
	// GuestKeeper and GuestGuard are the keeper's and the guard's paths in
	// the image's programs.
	GuestKeeper = "/usr/local/bin/cyfr-locus"
	GuestGuard  = "/usr/local/bin/cyfr-guard"
)

// The guest's files in the Locus image.
const (
	// Firecracker is the pinned VMM (Dockerfile.locus checks its digest).
	Firecracker = "/usr/lib/cyfr/guest/firecracker"
	// Kernel is the guest kernel, built in Dockerfile.locus from the
	// pinned source with apps/locus/guest/kernel.config.
	Kernel = "/usr/lib/cyfr/guest/vmlinux"
	// Root is the machines' folders' root, a home root (mode 1733,
	// root's) on the container's /run/locus tmpfs, which a restart of the
	// container clears: each machine's folder is its VMM's space's home,
	// made by the stage as the VMM's uid, 0700, holding its API and vsock
	// sockets.
	Root = "/run/locus/machines"
	// MachineUID is the uid a machine's VMM runs as, its own: no pool,
	// role or kept home has it.
	MachineUID = 30201
	// MachineUser names it in its space.
	MachineUser = "locus-machine"
)

// HelloVersion is the version of the agent's Hello line, apart from the
// keeper protocol it precedes.
const HelloVersion = 1

// Hello is the guest agent's first line on the control connection: who
// answers, by the guest kernel's boot identity, which is new at every boot,
// so a reply from a guest that was replaced is told from its successor's.
type Hello struct {
	V      int    `json:"v"`
	Type   string `json:"type"`
	BootID string `json:"boot_id"`
}

// HelloType is Hello's type.
const HelloType = "hello"

var bootIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// NewHello is the Hello of the boot whose /proc/sys/kernel/random/boot_id
// reads raw.
func NewHello(raw string) (Hello, error) {
	id := strings.TrimSpace(raw)
	if !bootIDPattern.MatchString(id) {
		return Hello{}, fmt.Errorf("boot identity %q is not a UUID", id)
	}
	return Hello{V: HelloVersion, Type: HelloType, BootID: id}, nil
}

// ParseHello reads the agent's first line and refuses anything but a Hello
// of this version with a boot identity.
func ParseHello(line []byte) (Hello, error) {
	var h Hello
	if err := json.Unmarshal(line, &h); err != nil {
		return Hello{}, fmt.Errorf("the guest agent's hello: %w", err)
	}
	if h.V != HelloVersion || h.Type != HelloType {
		return Hello{}, fmt.Errorf("the guest agent's hello is %s, not a version %d %s", strings.TrimSpace(string(line)), HelloVersion, HelloType)
	}
	if !bootIDPattern.MatchString(h.BootID) {
		return Hello{}, fmt.Errorf("the guest agent's boot identity %q is not a UUID", h.BootID)
	}
	return h, nil
}

// bootArgs are the guest kernel's command line. Firecracker adds the root
// device itself (root=/dev/vda ro) and pci=off.
//   - page_reporting.page_reporting_order=0: the balloon's free-page
//     reporting reports free blocks of every size, so what a finished
//     session freed goes back to the host while the guest runs (P12: 82.5%
//     within 60 s); the kernel's own order reports only 2 MiB blocks, and
//     a session's memory is freed in smaller pieces (P12: 0.1%).
//   - i8042.noaux i8042.nomux i8042.nopnp i8042.dumbkbd: no probe of a
//     legacy keyboard controller's extra ports, about 450 ms of a boot
//     (P12: ready in 0.67 s against 1.12). The controller itself stays:
//     reboot=k resets the machine through it, which is how Firecracker
//     learns the guest has ended.
//   - lsm=landlock,yama: no SELinux or AppArmor label in the guest. The
//     keeper refuses a label that is not its own profile, and the guest's
//     wall is its own kernel. Yama is built in (apps/locus/guest).
//   - panic=-1: a guest whose first process dies resets at once, so its
//     machine ends rather than waits.
//   - console=ttyS0 only with console, for guest-check's diagnosis: a
//     machine that serves has none.
func bootArgs(reportFromOrder0, console bool) string {
	args := []string{"quiet", "reboot=k", "panic=-1", "lsm=landlock,yama",
		"i8042.noaux", "i8042.nomux", "i8042.nopnp", "i8042.dumbkbd"}
	if console {
		args = append([]string{"console=ttyS0"}, args...)
	}
	if reportFromOrder0 {
		args = append(args, "page_reporting.page_reporting_order=0")
	}
	return strings.Join(append(args, "init="+GuestAgent), " ")
}

// BootArgs is the guest kernel's command line, with a serial console only
// for a machine whose output is kept (Config.Console).
func BootArgs(console bool) string { return bootArgs(true, console) }
