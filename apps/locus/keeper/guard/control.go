// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package guard is the control between an island's keeper and its egress
// guard, `cyfr-locus guard-control`, whose rules rules.go lists.
// Every build, every program's session and every role's service process
// runs in a space of its own (a user, network and IPC namespace the keeper
// made for it), and the guard gives each such routed space its one route:
// a veth pair whose inner end it places in the space's network namespace,
// the rules that hold what passes through it, and the answers to the
// space's names.
//
// The guard serves it once its rules are in, on a Unix socket of the
// seqpacket kind in a directory of root's own, mode 0700, on a volume the
// island's service mounts read-only: only root reaches it, and in the
// service that is the keeper alone. Each route is made in the IPv4 /16 the
// guard's static rules chose for routes. Each message is one packet
// holding one JSON object, carrying `"v": 4` and a `type`:
//
//	{"v":4,"type":"hello","netns":"net:[…]"}                                    guard, on connect
//	{"v":4,"type":"hello","netns":"net:[…]","machines":…}                       guard, on connect, routing no machine
//	{"v":4,"type":"admit","spawn_id":…,"reach":"island"}                        keeper, with three descriptors
//	{"v":4,"type":"admit","spawn_id":…,"reach":"hosts","addresses":[…]}         keeper, with three descriptors
//	{"v":4,"type":"admit","spawn_id":…,"reach":"role","port":…,"private":…}     keeper, with three descriptors
//	{"v":4,"type":"admit","spawn_id":…,"machine_uid":…,"reach":…}               keeper, with four descriptors
//	{"v":4,"type":"change","spawn_id":…,"reach":…,"addresses":[…]}              keeper
//	{"v":4,"type":"clear","spawn_id":…}                                         keeper
//	{"v":4,"type":"admitted","spawn_id":…}                                      guard
//	{"v":4,"type":"admitted","spawn_id":…,"inner":…,"gateway":…}                guard, to a machine's admit
//	{"v":4,"type":"changed","spawn_id":…}                                       guard
//	{"v":4,"type":"cleared","spawn_id":…}                                       guard
//	{"v":4,"type":"refused","spawn_id":…,"reason":…}                            guard
//	{"v":4,"type":"refused","spawn_id":…,"reason":…,"withdrawn":true}           guard, to a change
//
// The hello names the network namespace the guard's rules judge, as
// /proc/self/ns/net links to it; a keeper whose own differs is not behind
// that guard (a guard that restarted took a new namespace, and the
// service still runs in the old one) and takes none of its answers. A
// guard whose kernel cannot hold a machine's route to whole IPv4
// packets at its ingress says why in the hello's `machines`, and refuses
// every machine's admit; it serves every other route.
//
// An `admit` names the spawn by the keeper's `spawn_id` and carries, as
// SCM_RIGHTS in this order, the space's network namespace and its two name
// sockets: a UDP socket and a listening TCP socket, both of that
// namespace and bound to 127.0.0.11:53. Its `reach` is one of:
//
//   - `island`, the island's rule: every public address;
//   - `hosts`, exactly the 1..MaxAddresses canonical addresses `addresses`
//     names and no other public one;
//   - `role`, a role's service process listening on `port` (1..65535): the
//     island's rule out, and in, each new TCP connection to the guard's
//     own island addresses at that port, from the island's network or from
//     the guard's namespace itself, forwarded to the space at the same
//     port. One route holds a port at a time: a role admit naming a port
//     a route still holds is refused. A role whose `private` is true
//     reaches every private address as well, and core's host API, the one
//     address and port on the island's subnets the guard was started with
//     (CYFR_GUARD_HOST_API); a role whose `private` is false reaches
//     neither.
//
// A machine's admit, one naming `machine_uid`, is the route of a person's
// VM (package vm): its namespace is the VMM's space's, its two name
// sockets are bound to MachineNames:53 there, a fourth descriptor is a
// route netlink socket the space's stage opened there, and its reach is `none`,
// `island` or `hosts`, the union of what that person's live sessions are
// allowed, which a `change` replaces while the route stands; `none` and a
// `change` are a machine's alone. The guard makes the pair, gives its own
// end the gateway's address and leaves the inner end bare; it makes a tap,
// persistent and owned by machine_uid, moves it into the namespace as
// MachineTap, and joins it and the pair's inner end in a bridge,
// MachineBridge, which holds MachineNames and a host route to the inner
// address. The guest takes the inner address (`admitted` names it and the
// gateway), so the route's rules judge its traffic as a space's. The VMM
// attaches to the tap with no capability, as its owner.
//
// Under every reach, what the island refuses every space stays refused:
// the metadata addresses, the control plane, the island's own subnets
// (the host API apart, for a private role), every other space, and every
// private address the deployment does not name (for a role that is not
// private). The guard makes the pair, sets both ends' addresses, the
// space's default route and the route's rules, and serves the space's
// names on its sockets by asking the island's resolver; it answers
// `admitted` only once all of that is in, and `refused` with a reason,
// having made nothing that stays, otherwise. A `change` replaces a
// machine's route's reach in one step, answered `changed` once the new
// rules stand, or `refused`: with the old ones standing, or, saying
// `withdrawn`, with the route withdrawn, its rules in no known state, which
// ends the machine's route as a clear would. A `clear` withdraws the route
// the connection made for that spawn: the pair first, which ends every
// connection through it, then its sockets and rules, a role's forwarding
// with them, and answers `cleared` once all of it is gone, or `refused`
// where this connection made no route for the spawn or a part of it could
// not be removed. Requests are answered one at a time, in the order they
// arrive.
//
// A connection that ends withdraws every route made over it and not
// cleared since, established connections with them: the keeper that spoke
// over it is gone, or will kill every routed space before it dials again
// (Client), so a route never outlives the keeper's knowledge of it.
package guard

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"regexp"

	"github.com/cyfr/locus/keeper/internal/pool"
)

// Version is the version every message carries as `v`.
const Version = 4

// Message types.
const (
	TypeHello    = "hello"
	TypeAdmit    = "admit"
	TypeChange   = "change"
	TypeClear    = "clear"
	TypeAdmitted = "admitted"
	TypeChanged  = "changed"
	TypeCleared  = "cleared"
	TypeRefused  = "refused"
)

// An admit's reach.
const (
	// ReachIsland is the island's rule: every public address.
	ReachIsland = "island"
	// ReachHosts is exactly the addresses the admit names.
	ReachHosts = "hosts"
	// ReachRole is a role's service process: the island's rule, or with
	// private every private address and the host API as well, and its
	// port forwarded in from the island.
	ReachRole = "role"
	// ReachNone is a machine's with no live session: no public address.
	ReachNone = "none"
)

// What a machine's route makes in its VMM's namespace.
const (
	// MachineTap is the VM's tap there, which its VMM attaches to by name.
	MachineTap = "tap0"
	// MachineBridge joins the tap and the route's inner end.
	MachineBridge = "br0"
)

// MachineNames is the address a machine's two name sockets are bound to in
// its VMM's namespace, port 53, which the bridge holds (pool.MachineNames).
var MachineNames = netip.AddrFrom4(pool.MachineNames)

const (
	// MaxAddresses is the most addresses one admit names.
	MaxAddresses = 1024
	// MaxMessageBytes is the largest message either side reads: an admit
	// of MaxAddresses IPv6 addresses fits.
	MaxMessageBytes = 64 << 10
	// AdmitDescriptors is how many descriptors an admit carries: the
	// space's network namespace, its UDP and its TCP name socket; and
	// MachineDescriptors a machine's, which carries a route netlink socket
	// of that namespace beside them.
	AdmitDescriptors   = 3
	MachineDescriptors = 4
)

// spawnIDPattern is the keeper's spawn id: 32 lowercase hexadecimal digits.
var spawnIDPattern = regexp.MustCompile(`^[0-9a-f]{32}$`)

// Message is any message of the control; Type selects its members.
type Message struct {
	V         int      `json:"v"`
	Type      string   `json:"type"`
	Netns     string   `json:"netns,omitempty"`
	SpawnID   string   `json:"spawn_id,omitempty"`
	Reach     string   `json:"reach,omitempty"`
	Addresses []string `json:"addresses,omitempty"`
	// Port and Private are a role admit's, present exactly there.
	Port    *int  `json:"port,omitempty"`
	Private *bool `json:"private,omitempty"`
	// MachineUID is a machine's admit's: the uid of the VMM, which owns
	// the tap.
	MachineUID *int `json:"machine_uid,omitempty"`
	// Inner and Gateway are an admitted machine's route's two addresses,
	// the guest's and the guard's end's.
	Inner   string `json:"inner,omitempty"`
	Gateway string `json:"gateway,omitempty"`
	Reason  string `json:"reason,omitempty"`
	// Withdrawn is a refused change's: the route is withdrawn, its rules in
	// no known state, where without it the old reach stands.
	Withdrawn bool `json:"withdrawn,omitempty"`
	// Machines is a hello's alone: why the guard routes no person's
	// machine, absent where it routes them.
	Machines string `json:"machines,omitempty"`
}

// Encode renders a message as one packet.
func Encode(m Message) ([]byte, error) {
	m.V = Version
	return json.Marshal(m)
}

// Decode reads one packet as a message: one object, of this version, with
// no member it does not know.
func Decode(packet []byte) (Message, error) {
	var m Message
	dec := json.NewDecoder(bytes.NewReader(packet))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&m); err != nil {
		return Message{}, errors.New("not a message object")
	}
	if dec.More() {
		return Message{}, errors.New("trailing data after the message")
	}
	if m.V != Version {
		return Message{}, fmt.Errorf("v must be %d", Version)
	}
	return m, nil
}

// ParseRequest reads a keeper's request and the number of descriptors it
// came with: an admit with a spawn id, its reach, the addresses exactly
// when the reach is hosts, the port and private exactly when it is role,
// the machine's uid for a machine's, whose reach is none, island or hosts,
// and AdmitDescriptors descriptors; a change with a spawn id, a machine's
// reach and its addresses, and none; or a clear with a spawn id alone and
// none.
func ParseRequest(packet []byte, descriptors int) (Message, error) {
	m, err := Decode(packet)
	if err != nil {
		return Message{}, err
	}
	if !spawnIDPattern.MatchString(m.SpawnID) {
		return Message{}, errors.New("spawn_id must be 32 lowercase hexadecimal digits")
	}
	if m.Netns != "" || m.Reason != "" || m.Inner != "" || m.Gateway != "" || m.Withdrawn || m.Machines != "" {
		return Message{}, errors.New("a request carries only spawn_id and, for an admit, its reach and what the reach names")
	}
	switch m.Type {
	case TypeAdmit:
		want := AdmitDescriptors
		if m.MachineUID != nil {
			want = MachineDescriptors
		}
		if descriptors != want {
			return Message{}, fmt.Errorf("an admit carries %d descriptors, not %d", want, descriptors)
		}
		if m.Reach != ReachRole && (m.Port != nil || m.Private != nil) {
			return Message{}, errors.New("only a role admit names a port and private")
		}
		if m.MachineUID != nil {
			if *m.MachineUID < 1 || *m.MachineUID >= 1<<31 {
				return Message{}, errors.New("a machine's uid must be 1..2^31-1")
			}
			if m.Reach == ReachRole {
				return Message{}, errors.New("a machine's reach is none, island or hosts")
			}
		}
		if m.Reach == ReachNone && m.MachineUID == nil {
			return Message{}, errors.New("only a machine's route reaches none")
		}
		if err := checkReach(m); err != nil {
			return Message{}, err
		}
	case TypeChange:
		if descriptors != 0 {
			return Message{}, errors.New("a change carries no descriptors")
		}
		if m.Port != nil || m.Private != nil || m.MachineUID != nil {
			return Message{}, errors.New("a change names a spawn_id, a reach and its addresses alone")
		}
		if m.Reach == ReachRole {
			return Message{}, errors.New("a change's reach is none, island or hosts")
		}
		if err := checkReach(m); err != nil {
			return Message{}, err
		}
	case TypeClear:
		if descriptors != 0 {
			return Message{}, errors.New("a clear carries no descriptors")
		}
		if m.Reach != "" || m.Addresses != nil || m.Port != nil || m.Private != nil || m.MachineUID != nil {
			return Message{}, errors.New("a clear names a spawn_id alone")
		}
	default:
		return Message{}, errors.New("type must be admit, change or clear")
	}
	return m, nil
}

// checkReach checks a request's reach and what it names: island and none
// name no addresses, role its port and private, hosts 1..MaxAddresses
// canonical addresses, each once.
func checkReach(m Message) error {
	switch m.Reach {
	case ReachIsland, ReachNone:
		if m.Addresses != nil {
			return fmt.Errorf("a reach of %s names no addresses", m.Reach)
		}
	case ReachRole:
		if m.Addresses != nil {
			return errors.New("a role admit names no addresses")
		}
		if m.Port == nil || *m.Port < 1 || *m.Port > 65535 {
			return errors.New("a role admit's port must be 1..65535")
		}
		if m.Private == nil {
			return errors.New("a role admit says whether it is private")
		}
	case ReachHosts:
		if len(m.Addresses) == 0 || len(m.Addresses) > MaxAddresses {
			return fmt.Errorf("addresses must hold 1..%d addresses", MaxAddresses)
		}
		seen := map[string]bool{}
		for i, a := range m.Addresses {
			if _, err := CanonicalAddress(a); err != nil {
				return fmt.Errorf("addresses[%d]: %w", i, err)
			}
			if seen[a] {
				return fmt.Errorf("addresses[%d] repeats %s", i, a)
			}
			seen[a] = true
		}
	default:
		return errors.New("reach must be island, hosts, role or none")
	}
	return nil
}

// ParseAnswer reads the guard's answer to a request of type asked for
// spawnID: admitted to an admit, with a machine's two addresses or none,
// changed to a change, cleared to a clear, or refused with a reason, a
// change's saying whether its route is withdrawn, each naming that spawn.
// Any other message is refused.
func ParseAnswer(packet []byte, asked, spawnID string) (Message, error) {
	m, err := Decode(packet)
	if err != nil {
		return Message{}, err
	}
	if m.SpawnID != spawnID || m.Netns != "" || m.Reach != "" || m.Addresses != nil || m.Port != nil || m.Private != nil || m.MachineUID != nil || m.Machines != "" {
		return Message{}, fmt.Errorf("an answer naming spawn %q, not %q, or carrying more than it may", m.SpawnID, spawnID)
	}
	if (m.Inner != "") != (m.Gateway != "") || (m.Inner != "" && m.Type != TypeAdmitted) {
		return Message{}, errors.New("an answer names a machine's two addresses, both, and only when admitted")
	}
	if m.Withdrawn && (m.Type != TypeRefused || asked != TypeChange) {
		return Message{}, errors.New("only a change's refusal says its route is withdrawn")
	}
	for _, a := range []string{m.Inner, m.Gateway} {
		if addr, err := CanonicalAddress(a); a != "" && (err != nil || !addr.Is4()) {
			return Message{}, fmt.Errorf("a machine's address %q is not a canonical IPv4 address", a)
		}
	}
	switch {
	case m.Type == TypeRefused && m.Reason != "":
	case m.Type == TypeAdmitted && asked == TypeAdmit && m.Reason == "":
	case m.Type == TypeChanged && asked == TypeChange && m.Reason == "":
	case m.Type == TypeCleared && asked == TypeClear && m.Reason == "":
	default:
		return Message{}, fmt.Errorf("%s does not answer a %s", m.Type, asked)
	}
	return m, nil
}

// CanonicalAddress parses an address the guard installs: an IP address
// with no zone, written as netip writes it, an IPv4 address in its dotted
// form, never mapped into IPv6. Any other spelling is refused, so one
// address has one form on both sides.
func CanonicalAddress(text string) (netip.Addr, error) {
	addr, err := netip.ParseAddr(text)
	if err != nil {
		return netip.Addr{}, errors.New("not an IP address")
	}
	if addr.Zone() != "" || addr.Is4In6() || addr.String() != text {
		return netip.Addr{}, errors.New("not a canonical IP address without a zone")
	}
	return addr, nil
}

// ParseRange reads the guard's route range: an IPv4 /16, canonical.
func ParseRange(text string) (netip.Prefix, error) {
	p, err := netip.ParsePrefix(text)
	if err != nil || !p.Addr().Is4() || p.Bits() != 16 || p.Masked() != p || p.String() != text {
		return netip.Prefix{}, fmt.Errorf("%q is not an IPv4 /16", text)
	}
	return p, nil
}
