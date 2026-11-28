// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package authority is what a worker service reads of the authority an
// assignment carries (Prima.Authority.from_wire/1): the limits of the
// node its cursor stands on (Prima.Authority.limits/1), and its edge's
// egress, which the relay checks a runner's request against again. It
// refuses what Prima refuses in those parts and reads nothing else of the
// authority: the rest is CYFR's, which made and signed the assignment and
// verifies it when the runner attaches, and the policy's grammar keeps one
// definition, Prima's. tests/fixtures/authority_wire.json holds what both
// sides read alike, and marks the cases whose refusal lies in a part the
// service carries unread.
package authority

import (
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/cyfr/locus/keeper/internal/wire/limits"
	"github.com/cyfr/locus/keeper/internal/wire/network"
)

// ErrRefused is an authority whose read parts Prima refuses.
var ErrRefused = errors.New("invalid_authority")

// Authority is what a worker service reads of an authority.
type Authority struct {
	Limits limits.Limits
	// Egress is the edge's egress; an authority without resources has an
	// empty one, which allows nothing.
	Egress Egress
}

// Egress is an edge's egress lists, as written.
type Egress struct {
	Domains, Methods, Schemes, PrivateIPs []string
}

// Read reads an authority, a decoded JSON object: its cursor, unbound or
// bound to a node of its policy, that node's limits, and its resources'
// egress.
func Read(v any) (Authority, error) {
	wire, ok := v.(map[string]any)
	if !ok {
		return Authority{}, ErrRefused
	}
	var a Authority
	switch cursor := wire["cursor"].(type) {
	case string:
		if cursor != "unbound" {
			return Authority{}, ErrRefused
		}
		a.Limits = limits.Zero()
	case map[string]any:
		// A bound cursor names its node; any other member it carries is
		// read past, as Prima.Authority.from_wire/1 reads it.
		ref, isText := cursor["bound"].(string)
		if !isText || ref == "" {
			return Authority{}, ErrRefused
		}
		policy, _ := wire["policy"].(map[string]any)
		nodes, _ := policy["nodes"].(map[string]any)
		node, isNode := nodes[ref].(map[string]any)
		if !isNode {
			return Authority{}, ErrRefused
		}
		l, err := limits.Read(node["limits"])
		if err != nil {
			return Authority{}, ErrRefused
		}
		a.Limits = l
	default:
		return Authority{}, ErrRefused
	}
	switch resources := wire["resources"].(type) {
	case nil:
	case map[string]any:
		e, err := readEgress(resources)
		if err != nil {
			return Authority{}, err
		}
		a.Egress = e
	default:
		return Authority{}, ErrRefused
	}
	return a, nil
}

// readEgress reads an edge's egress as Prima.Authority.Blob reads it: no
// egress, or an object of domains, methods, schemes and private_ips and
// nothing else, each absent or null for none, or a list of strings, kept
// as written.
func readEgress(edge map[string]any) (Egress, error) {
	raw, given := edge["egress"]
	if !given {
		return Egress{}, nil
	}
	o, ok := raw.(map[string]any)
	if !ok {
		return Egress{}, ErrRefused
	}
	var e Egress
	lists := map[string]*[]string{"domains": &e.Domains, "methods": &e.Methods, "schemes": &e.Schemes, "private_ips": &e.PrivateIPs}
	for name := range o {
		if _, known := lists[name]; !known {
			return Egress{}, ErrRefused
		}
	}
	for name, list := range lists {
		switch items := o[name].(type) {
		case nil:
		case []any:
			*list = make([]string, len(items))
			for i, item := range items {
				s, isText := item.(string)
				if !isText {
					return Egress{}, ErrRefused
				}
				(*list)[i] = s
			}
		default:
			return Egress{}, ErrRefused
		}
	}
	return e, nil
}

// AllowsDomain is whether host is one of the egress's domains, as
// Prima.Network.domain_allowed?/2 matches them.
func (e Egress) AllowsDomain(host string) bool { return network.DomainAllowed(host, e.Domains) }

// AllowsScheme is whether scheme is one of the egress's schemes, exactly.
func (e Egress) AllowsScheme(scheme string) bool {
	for _, s := range e.Schemes {
		if s == scheme {
			return true
		}
	}
	return false
}

// AllowsMethod is whether method is one of the egress's methods, each
// compared upcased as Elixir's String.upcase/1 upcases it
// (Locus.Runtime.EdgeGuard.check_method/2). A relay frame's method is one
// of network.Methods(), which the caller checks first.
func (e Egress) AllowsMethod(method string) bool {
	m := upcase(method)
	for _, allowed := range e.Methods {
		if upcase(allowed) == m {
			return true
		}
	}
	return false
}

// specialUpper is every character Elixir's String.upcase/1 upcases
// otherwise than Go's unicode.ToUpper: Unicode's SpecialCasing, a
// character upcased to more than one (ß to SS, ŉ to ʼN, the ligatures),
// for Elixir 1.20.4 against Go 1.27.4, every scalar value compared.
var specialUpper = map[rune]string{
	0x00df: "SS",
	0x0149: "\u02bcN",
	0x01f0: "J\u030c",
	0x0390: "\u0399\u0308\u0301",
	0x03b0: "\u03a5\u0308\u0301",
	0x0587: "\u0535\u0552",
	0x1e96: "H\u0331",
	0x1e97: "T\u0308",
	0x1e98: "W\u030a",
	0x1e99: "Y\u030a",
	0x1e9a: "A\u02be",
	0x1f50: "\u03a5\u0313",
	0x1f52: "\u03a5\u0313\u0300",
	0x1f54: "\u03a5\u0313\u0301",
	0x1f56: "\u03a5\u0313\u0342",
	0x1f80: "\u1f08\u0399",
	0x1f81: "\u1f09\u0399",
	0x1f82: "\u1f0a\u0399",
	0x1f83: "\u1f0b\u0399",
	0x1f84: "\u1f0c\u0399",
	0x1f85: "\u1f0d\u0399",
	0x1f86: "\u1f0e\u0399",
	0x1f87: "\u1f0f\u0399",
	0x1f88: "\u1f08\u0399",
	0x1f89: "\u1f09\u0399",
	0x1f8a: "\u1f0a\u0399",
	0x1f8b: "\u1f0b\u0399",
	0x1f8c: "\u1f0c\u0399",
	0x1f8d: "\u1f0d\u0399",
	0x1f8e: "\u1f0e\u0399",
	0x1f8f: "\u1f0f\u0399",
	0x1f90: "\u1f28\u0399",
	0x1f91: "\u1f29\u0399",
	0x1f92: "\u1f2a\u0399",
	0x1f93: "\u1f2b\u0399",
	0x1f94: "\u1f2c\u0399",
	0x1f95: "\u1f2d\u0399",
	0x1f96: "\u1f2e\u0399",
	0x1f97: "\u1f2f\u0399",
	0x1f98: "\u1f28\u0399",
	0x1f99: "\u1f29\u0399",
	0x1f9a: "\u1f2a\u0399",
	0x1f9b: "\u1f2b\u0399",
	0x1f9c: "\u1f2c\u0399",
	0x1f9d: "\u1f2d\u0399",
	0x1f9e: "\u1f2e\u0399",
	0x1f9f: "\u1f2f\u0399",
	0x1fa0: "\u1f68\u0399",
	0x1fa1: "\u1f69\u0399",
	0x1fa2: "\u1f6a\u0399",
	0x1fa3: "\u1f6b\u0399",
	0x1fa4: "\u1f6c\u0399",
	0x1fa5: "\u1f6d\u0399",
	0x1fa6: "\u1f6e\u0399",
	0x1fa7: "\u1f6f\u0399",
	0x1fa8: "\u1f68\u0399",
	0x1fa9: "\u1f69\u0399",
	0x1faa: "\u1f6a\u0399",
	0x1fab: "\u1f6b\u0399",
	0x1fac: "\u1f6c\u0399",
	0x1fad: "\u1f6d\u0399",
	0x1fae: "\u1f6e\u0399",
	0x1faf: "\u1f6f\u0399",
	0x1fb2: "\u1fba\u0399",
	0x1fb3: "\u0391\u0399",
	0x1fb4: "\u0386\u0399",
	0x1fb6: "\u0391\u0342",
	0x1fb7: "\u0391\u0342\u0399",
	0x1fbc: "\u0391\u0399",
	0x1fc2: "\u1fca\u0399",
	0x1fc3: "\u0397\u0399",
	0x1fc4: "\u0389\u0399",
	0x1fc6: "\u0397\u0342",
	0x1fc7: "\u0397\u0342\u0399",
	0x1fcc: "\u0397\u0399",
	0x1fd2: "\u0399\u0308\u0300",
	0x1fd3: "\u0399\u0308\u0301",
	0x1fd6: "\u0399\u0342",
	0x1fd7: "\u0399\u0308\u0342",
	0x1fe2: "\u03a5\u0308\u0300",
	0x1fe3: "\u03a5\u0308\u0301",
	0x1fe4: "\u03a1\u0313",
	0x1fe6: "\u03a5\u0342",
	0x1fe7: "\u03a5\u0308\u0342",
	0x1ff2: "\u1ffa\u0399",
	0x1ff3: "\u03a9\u0399",
	0x1ff4: "\u038f\u0399",
	0x1ff6: "\u03a9\u0342",
	0x1ff7: "\u03a9\u0342\u0399",
	0x1ffc: "\u03a9\u0399",
	0xfb00: "FF",
	0xfb01: "FI",
	0xfb02: "FL",
	0xfb03: "FFI",
	0xfb04: "FFL",
	0xfb05: "ST",
	0xfb06: "ST",
	0xfb13: "\u0544\u0546",
	0xfb14: "\u0544\u0535",
	0xfb15: "\u0544\u053b",
	0xfb16: "\u054e\u0546",
	0xfb17: "\u0544\u053d",
}

// upcase is s upcased as Elixir's String.upcase/1 does in its default
// mode: each character's uppercase, a special one's as Elixir spells it,
// and a byte that is no UTF-8 kept as it is, as Elixir keeps it, never
// read as U+FFFD.
func upcase(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		switch u, special := specialUpper[r]; {
		case r == utf8.RuneError && size == 1:
			b.WriteByte(s[i])
		case special:
			b.WriteString(u)
		default:
			b.WriteRune(unicode.ToUpper(r))
		}
		i += size
	}
	return b.String()
}

// RequestBytes is what a request holds as the relay counts it against the
// node's max_request_size: its body, URL, and every header's name and
// value (Locus.Runtime.EdgeGuard.check_request_size/2).
func RequestBytes(url string, headers [][2]string, body []byte) uint64 {
	n := uint64(len(body) + len(url))
	for _, h := range headers {
		n += uint64(len(h[0]) + len(h[1]))
	}
	return n
}
