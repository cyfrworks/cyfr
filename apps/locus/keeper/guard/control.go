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
// holding one JSON object, carrying `"v": 3` and a `type`:
//
//	{"v":3,"type":"hello","netns":"net:[…]"}                                    guard, on connect
//	{"v":3,"type":"admit","spawn_id":…,"reach":"island"}                        keeper, with three descriptors
//	{"v":3,"type":"admit","spawn_id":…,"reach":"hosts","addresses":[…]}         keeper, with three descriptors
//	{"v":3,"type":"admit","spawn_id":…,"reach":"role","port":…,"private":…}     keeper, with three descriptors
//	{"v":3,"type":"clear","spawn_id":…}                                         keeper
//	{"v":3,"type":"admitted","spawn_id":…}                                      guard
//	{"v":3,"type":"cleared","spawn_id":…}                                       guard
//	{"v":3,"type":"refused","spawn_id":…,"reason":…}                            guard
//
// The hello names the network namespace the guard's rules judge, as
// /proc/self/ns/net links to it; a keeper whose own differs is not behind
// that guard (a guard that restarted took a new namespace, and the
// service still runs in the old one) and takes none of its answers.
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
// Under every reach, what the island refuses every space stays refused:
// the metadata addresses, the control plane, the island's own subnets
// (the host API apart, for a private role), every other space, and every
// private address the deployment does not name (for a role that is not
// private). The guard makes the pair, sets both ends' addresses, the
// space's default route and the route's rules, and serves the space's
// names on its sockets by asking the island's resolver; it answers
// `admitted` only once all of that is in, and `refused` with a reason,
// having made nothing that stays, otherwise. A `clear` withdraws the route
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
)

// Version is the version every message carries as `v`.
const Version = 3

// Message types.
const (
	TypeHello    = "hello"
	TypeAdmit    = "admit"
	TypeClear    = "clear"
	TypeAdmitted = "admitted"
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
)

const (
	// MaxAddresses is the most addresses one admit names.
	MaxAddresses = 1024
	// MaxMessageBytes is the largest message either side reads: an admit
	// of MaxAddresses IPv6 addresses fits.
	MaxMessageBytes = 64 << 10
	// AdmitDescriptors is how many descriptors an admit carries: the
	// space's network namespace, its UDP and its TCP name socket.
	AdmitDescriptors = 3
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
	Port    *int   `json:"port,omitempty"`
	Private *bool  `json:"private,omitempty"`
	Reason  string `json:"reason,omitempty"`
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
// and AdmitDescriptors descriptors, or a clear with a spawn id alone and
// none.
func ParseRequest(packet []byte, descriptors int) (Message, error) {
	m, err := Decode(packet)
	if err != nil {
		return Message{}, err
	}
	if !spawnIDPattern.MatchString(m.SpawnID) {
		return Message{}, errors.New("spawn_id must be 32 lowercase hexadecimal digits")
	}
	if m.Netns != "" || m.Reason != "" {
		return Message{}, errors.New("a request carries only spawn_id and, for an admit, its reach and what the reach names")
	}
	switch m.Type {
	case TypeAdmit:
		if descriptors != AdmitDescriptors {
			return Message{}, fmt.Errorf("an admit carries %d descriptors, not %d", AdmitDescriptors, descriptors)
		}
		if m.Reach != ReachRole && (m.Port != nil || m.Private != nil) {
			return Message{}, errors.New("only a role admit names a port and private")
		}
		switch m.Reach {
		case ReachIsland:
			if m.Addresses != nil {
				return Message{}, errors.New("an admit of the island's reach names no addresses")
			}
		case ReachRole:
			if m.Addresses != nil {
				return Message{}, errors.New("a role admit names no addresses")
			}
			if m.Port == nil || *m.Port < 1 || *m.Port > 65535 {
				return Message{}, errors.New("a role admit's port must be 1..65535")
			}
			if m.Private == nil {
				return Message{}, errors.New("a role admit says whether it is private")
			}
		case ReachHosts:
			if len(m.Addresses) == 0 || len(m.Addresses) > MaxAddresses {
				return Message{}, fmt.Errorf("addresses must hold 1..%d addresses", MaxAddresses)
			}
			seen := map[string]bool{}
			for i, a := range m.Addresses {
				if _, err := CanonicalAddress(a); err != nil {
					return Message{}, fmt.Errorf("addresses[%d]: %w", i, err)
				}
				if seen[a] {
					return Message{}, fmt.Errorf("addresses[%d] repeats %s", i, a)
				}
				seen[a] = true
			}
		default:
			return Message{}, errors.New("reach must be island, hosts or role")
		}
	case TypeClear:
		if descriptors != 0 {
			return Message{}, errors.New("a clear carries no descriptors")
		}
		if m.Reach != "" || m.Addresses != nil || m.Port != nil || m.Private != nil {
			return Message{}, errors.New("a clear names a spawn_id alone")
		}
	default:
		return Message{}, errors.New("type must be admit or clear")
	}
	return m, nil
}

// ParseAnswer reads the guard's answer to a request of type asked for
// spawnID: admitted to an admit, cleared to a clear, or refused with a
// reason, each naming that spawn. Any other message is refused.
func ParseAnswer(packet []byte, asked, spawnID string) (Message, error) {
	m, err := Decode(packet)
	if err != nil {
		return Message{}, err
	}
	if m.SpawnID != spawnID || m.Netns != "" || m.Reach != "" || m.Addresses != nil || m.Port != nil || m.Private != nil {
		return Message{}, fmt.Errorf("an answer naming spawn %q, not %q, or carrying more than it may", m.SpawnID, spawnID)
	}
	switch {
	case m.Type == TypeRefused && m.Reason != "":
	case m.Type == TypeAdmitted && asked == TypeAdmit && m.Reason == "":
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
