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
		a.Limits = limits.Zero
	case map[string]any:
		ref, isText := cursor["bound"].(string)
		if len(cursor) != 1 || !isText || ref == "" {
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

// AllowsMethod is whether method, one of a relay frame's methods
// (Prima.Destination.methods/0, uppercase ASCII), is one of the egress's
// methods, each compared upcased as Elixir's String.upcase/1 upcases it.
func (e Egress) AllowsMethod(method string) bool {
	m := upcase(method)
	for _, allowed := range e.Methods {
		if upcase(allowed) == m {
			return true
		}
	}
	return false
}

// spelledUpper are the characters Elixir upcases to ASCII letters in more
// than one (Unicode's SpecialCasing), which Go's unicode.ToUpper keeps.
// Every other character is upcased to an ASCII letter by both alike (a
// to z, and dotless ı and long ſ) or by neither, so an upcased name equals
// an ASCII method in Go exactly when it does in Elixir.
var spelledUpper = map[rune]string{
	'ß': "SS", 'ﬀ': "FF", 'ﬁ': "FI", 'ﬂ': "FL", 'ﬃ': "FFI", 'ﬄ': "FFL", 'ﬅ': "ST", 'ﬆ': "ST",
}

func upcase(s string) string {
	var b strings.Builder
	for _, r := range s {
		if u, spelled := spelledUpper[r]; spelled {
			b.WriteString(u)
			continue
		}
		b.WriteRune(unicode.ToUpper(r))
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
