// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package guard is the control between an island's keeper and its egress
// guard (cyfr-guard.sh beside this file, whose header is the rule list):
// the keeper names, for one spawn uid, the only addresses it may reach,
// and the guard installs that uid's rules or clears them.
//
// The guard serves it as `cyfr-locus guard-control <socket> <ranges>` once its
// rules are in, on a Unix socket in a directory of root's own, mode 0700,
// on a volume the island's service mounts read-only: only root reaches
// it, and in the service that is the keeper alone. Each message is one
// JSON object on one line, carrying `"v": 1` and a `type`:
//
//	{"v":1,"type":"hello","netns":"net:[…]"}        guard, on connect
//	{"v":1,"type":"admit","uid":…,"addresses":[…]}  keeper
//	{"v":1,"type":"clear","uid":…}                  keeper
//	{"v":1,"type":"admitted","uid":…}               guard
//	{"v":1,"type":"cleared","uid":…}                guard
//	{"v":1,"type":"refused","uid":…,"reason":…}     guard
//
// The hello names the network namespace the guard's rules judge, as
// /proc/self/ns/net links to it; a keeper whose own differs is not behind
// that guard (a guard that restarted took a new namespace, and the
// service still runs in the old one) and takes none of its answers.
//
// `admit` gives the uid, which must lie in one of the guard's spawn
// ranges (its <ranges>), exactly the addresses named, 1..MaxAddresses
// canonical IP addresses with no zone, and refuses it every other public
// address; it replaces whatever the uid held. `clear` returns the uid to
// the island's rule. Each is answered once its rules are installed and
// recorded for the guard's health check, or refused with a reason, in
// which case the uid is left refused every public address. Requests are
// applied one at a time, in the order they arrive.
//
// A connection that ends leaves every uid it admitted, and did not clear
// since, refused every public address: the keeper that spoke over it is
// gone, and with it every spawn it admitted, so nothing is opened by its
// loss. The uid's next spawn sets its rules again.
package guard

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"strconv"
	"strings"
	"time"
)

// Version is the version every message carries as `v`.
const Version = 1

// Message types.
const (
	TypeHello    = "hello"
	TypeAdmit    = "admit"
	TypeClear    = "clear"
	TypeAdmitted = "admitted"
	TypeCleared  = "cleared"
	TypeRefused  = "refused"
)

const (
	// MaxAddresses is the most addresses one admit names.
	MaxAddresses = 1024
	// MaxLineBytes is the longest line either side reads, its newline
	// excluded: an admit of MaxAddresses IPv6 addresses fits.
	MaxLineBytes = 64 << 10
	// MaxUID is the highest uid a request may name: (uid_t)-1 is no uid.
	MaxUID = 4294967294
	// applyTimeout bounds one run of the guard script, which installs one
	// request's rules.
	applyTimeout = 30 * time.Second
)

// Message is any message of the control; Type selects its members.
type Message struct {
	V         int      `json:"v"`
	Type      string   `json:"type"`
	Netns     string   `json:"netns,omitempty"`
	UID       *uint64  `json:"uid,omitempty"`
	Addresses []string `json:"addresses,omitempty"`
	Reason    string   `json:"reason,omitempty"`
}

// Encode renders a message as one line.
func Encode(m Message) ([]byte, error) {
	m.V = Version
	data, err := json.Marshal(m)
	if err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}

// Decode reads one line as a message: one object, of this version, with
// no member it does not know.
func Decode(line []byte) (Message, error) {
	var m Message
	dec := json.NewDecoder(bytes.NewReader(line))
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

// ParseRequest reads a keeper's request: an admit with a uid and its
// canonical addresses, or a clear with a uid alone.
func ParseRequest(line []byte) (Message, error) {
	m, err := Decode(line)
	if err != nil {
		return Message{}, err
	}
	if m.UID == nil || *m.UID < 1 || *m.UID > MaxUID {
		return Message{}, fmt.Errorf("uid must be within 1..%d", uint64(MaxUID))
	}
	if m.Netns != "" || m.Reason != "" {
		return Message{}, errors.New("a request carries only uid and, for an admit, addresses")
	}
	switch m.Type {
	case TypeAdmit:
		if len(m.Addresses) == 0 || len(m.Addresses) > MaxAddresses {
			return Message{}, fmt.Errorf("addresses must hold 1..%d addresses", MaxAddresses)
		}
		for i, a := range m.Addresses {
			if _, err := CanonicalAddress(a); err != nil {
				return Message{}, fmt.Errorf("addresses[%d]: %w", i, err)
			}
		}
	case TypeClear:
		if m.Addresses != nil {
			return Message{}, errors.New("a clear names no addresses")
		}
	default:
		return Message{}, errors.New("type must be admit or clear")
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

// Range is one spawn range of the guard's, inclusive.
type Range struct{ First, Last uint64 }

// ParseRanges reads the guard's spawn ranges: comma-separated
// `<first>-<last>`.
func ParseRanges(text string) ([]Range, error) {
	var out []Range
	for _, part := range strings.Split(text, ",") {
		first, last, ok := strings.Cut(part, "-")
		a, aerr := strconv.ParseUint(first, 10, 32)
		b, berr := strconv.ParseUint(last, 10, 32)
		if !ok || aerr != nil || berr != nil || a < 1 || a > b || b > MaxUID {
			return nil, fmt.Errorf("%q is not <first>-<last>", part)
		}
		out = append(out, Range{a, b})
	}
	return out, nil
}

// Holds reports whether some range holds uid.
func Holds(ranges []Range, uid uint64) bool {
	for _, r := range ranges {
		if r.First <= uid && uid <= r.Last {
			return true
		}
	}
	return false
}

// readLine reads one line of at most MaxLineBytes, without its newline.
func readLine(r *bufio.Reader) ([]byte, error) {
	var line []byte
	for {
		chunk, err := r.ReadSlice('\n')
		if len(line)+len(chunk) > MaxLineBytes+1 {
			return nil, errors.New("a line longer than the control allows")
		}
		line = append(line, chunk...)
		switch {
		case err == nil:
			return line[:len(line)-1], nil
		case errors.Is(err, bufio.ErrBufferFull):
			continue
		default:
			return nil, err
		}
	}
}
