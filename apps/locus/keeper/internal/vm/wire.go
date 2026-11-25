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
// port in the guest, and the guest agent answers only a peer whose CID is
// the host's. Nothing on the host listens for the guest, so no process in
// the guest, a session's included, has a way to the host but the two
// connections the host opens:
//
//   - ControlPort, once for the guest's life: the agent's Hello line, then
//     the keeper protocol (package protocol) between the host and the
//     guest's keeper, line for line. Its end, from either side, ends the
//     guest: the agent exits, the guest's keeper loses its client and ends
//     every space, and the guest's init powers the machine off.
//   - AttachPort, once for each spawn: the host's first frame is the
//     spawn's attach token (frame.StreamAttach), the agent pairs it with
//     the spawn's relay that presented the same token on GuestAttachPath,
//     and the two are joined byte for byte.
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
	// HostCID is the host's address on every vsock device.
	HostCID uint32 = 2
	// GuestCID is the guest's address on its machine's vsock device.
	GuestCID uint32 = 3
)

// The guest's side of its keeper, as cmd/cyfr-guest starts it.
const (
	// GuestAttachPath is the Unix socket the guest's keeper's relays
	// connect to with their spawn's attach token: the host names it in
	// each spawn it asks the guest for.
	GuestAttachPath = "/run/locus/attach.sock"
	// GuestPool is the guest keeper's one pool, which the host names in
	// each spawn. It is a relay pool, so a space in it has no route: the
	// guest's guard, and with it routed spaces, come with a person's
	// sessions (plan V2).
	GuestPool = "backends"
	// GuestPoolSpec is that pool on the guest keeper's command line: the
	// backend uids the image already defines.
	GuestPoolSpec = GuestPool + ":20001-20032:relay"
	// GuestHomeRoot is the guest keeper's home root, a tmpfs of the
	// guest's own.
	GuestHomeRoot = "/var/lib/locus/homes"
	// GuestClientUser runs the guest agent's relay, as the release runs as
	// it in the Locus container.
	GuestClientUser = "locus"
	// GuestAgent is the guest agent's path in the image's programs, which
	// the kernel runs as the guest's first process.
	GuestAgent = "/usr/local/bin/cyfr-guest"
	// GuestKeeper is the keeper's path in the image's programs.
	GuestKeeper = "/usr/local/bin/cyfr-locus"
)

// The guest's files in the Locus image.
const (
	// Firecracker is the pinned VMM (Dockerfile.locus checks its digest).
	Firecracker = "/usr/lib/cyfr/guest/firecracker"
	// Kernel is the guest kernel, built in Dockerfile.locus from the
	// pinned source with apps/locus/guest/kernel.config.
	Kernel = "/usr/lib/cyfr/guest/vmlinux"
	// Root is where each machine's working files are: its VMM's API and
	// vsock sockets, in a folder of its own. It is under /var, which no
	// space is given (package stage's keptOut).
	Root = "/var/lib/locus/vm"
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
//     wall is its own kernel.
//   - panic=-1: a guest whose first process dies resets at once, so its
//     machine ends rather than waits.
func bootArgs(reportFromOrder0 bool) string {
	args := []string{"console=ttyS0", "quiet", "reboot=k", "panic=-1", "lsm=landlock,yama",
		"i8042.noaux", "i8042.nomux", "i8042.nopnp", "i8042.dumbkbd"}
	if reportFromOrder0 {
		args = append(args, "page_reporting.page_reporting_order=0")
	}
	return strings.Join(append(args, "init="+GuestAgent), " ")
}

// BootArgs is the guest kernel's command line.
func BootArgs() string { return bootArgs(true) }
