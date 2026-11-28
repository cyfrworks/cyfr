// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package pinned is Prima.PinnedTarget in Go: the address CYFR validated
// for one outbound request of a guest, as egress_pin answers it, and the
// args that ask for one. Prima's module is the one definition, and
// tests/fixtures/host_api.json holds this package to it.
package pinned

import (
	"net/netip"
	"regexp"
	"strings"

	"github.com/cyfr/locus/keeper/internal/wire/network"
	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
)

// Purposes are the purposes a runner asks a pin for, a fresh list each
// call; attached is CYFR's own and not among them.
func Purposes() []string { return []string{"fetch", "stream", "redirect"} }

// Refusals are the refusals an egress_pin answer names, a fresh list each
// call.
func Refusals() []string {
	return []string{"domain", "denied", "metadata", "resolution", "redirect_credentials", "malformed"}
}

// Pin is a pin as its answer spells it.
type Pin struct {
	ID        string
	IP        string
	Family    int
	Scheme    string
	Port      int
	Host      string
	ExpiresAt uint64
}

var (
	idPattern = regexp.MustCompile(`\A[A-Za-z0-9_-]{1,128}\z`)
	label     = `[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?`
	hostname  = regexp.MustCompile(`\A` + label + `(?:\.` + label + `)*\.?\z`)
	members   = []string{"id", "ip", "family", "scheme", "port", "host", "expires_at"}
)

// ValidID is whether id is a pin id: 1 to 128 characters of unpadded
// base64url text.
func ValidID(id string) bool { return idPattern.MatchString(id) }

// Family is the family of an IP literal as Prima.PinnedTarget reads one,
// and ok false for text that is no IP literal, which has none: 4 for a
// dotted quad of four decimal octets without leading zeros, 6 for an IPv6
// address, which may carry a zone after its first % only when its first
// group is fe80 or ff02, its second 0, and it embeds no IPv4 address; a
// zone that begins with 0 is a decimal number up to 65535, and any other
// zone any text. That is Erlang's inet:parse_strict_address/1, without
// the sign it reads in a field, which Prima refuses before any zone.
func Family(ip string) (family int, ok bool) {
	address, zone, zoned := strings.Cut(ip, "%")
	a, err := netip.ParseAddr(address)
	if err != nil || a.Zone() != "" {
		return 0, false
	}
	if !zoned {
		if a.Is4() {
			return 4, true
		}
		return 6, true
	}
	if a.Is4() || strings.Contains(address, ".") {
		return 0, false
	}
	b := a.As16()
	first, second := uint16(b[0])<<8|uint16(b[1]), uint16(b[2])<<8|uint16(b[3])
	if (first != 0xfe80 && first != 0xff02) || second != 0 {
		return 0, false
	}
	if strings.HasPrefix(zone, "0") {
		n := 0
		for i := 0; i < len(zone); i++ {
			if zone[i] < '0' || zone[i] > '9' {
				return 0, false
			}
			if n = n*10 + int(zone[i]-'0'); n > 65535 {
				return 0, false
			}
		}
	}
	return 6, true
}

// validHost is whether host is a pin's host: a hostname of labels of
// letters, digits, _ and -, none starting or ending with -, at most 63
// characters each and 253 in all, with an optional final dot; or an IPv6
// address in brackets, its first ] its last character, read as the pin's
// ip is.
func validHost(host string) bool {
	if rest, bracketed := strings.CutPrefix(host, "["); bracketed && len(rest) > 1 {
		literal, after, closed := strings.Cut(rest, "]")
		family, ok := Family(literal)
		return closed && after == "" && ok && family == 6
	}
	return len(host) >= 1 && len(host) <= 253 && !strings.Contains(host, "\n") && hostname.MatchString(host)
}

// Read reads a pin as Prima.PinnedTarget.read/1 does: exactly its seven
// members; an id; an IP literal and the family, an integer, that is its;
// an http or https scheme; an integer port of 1 to 65535; a hostname or
// bracketed IPv6 literal; and an expiry of 0 to 2^53 − 1.
func Read(v any) (Pin, bool) {
	o, ok := v.(map[string]any)
	if !ok || len(o) != len(members) {
		return Pin{}, false
	}
	for _, m := range members {
		if _, has := o[m]; !has {
			return Pin{}, false
		}
	}
	var p Pin
	var okID, okIP, okScheme, okHost bool
	p.ID, okID = o["id"].(string)
	p.IP, okIP = o["ip"].(string)
	p.Scheme, okScheme = o["scheme"].(string)
	p.Host, okHost = o["host"].(string)
	family, okFamily := wirejson.Uint(o["family"], 6)
	port, okPort := wirejson.Uint(o["port"], 65535)
	expires, okExpires := wirejson.Uint(o["expires_at"], wirejson.MaxSafeInteger)
	// Uint bounds both; the bound is said again where each is converted.
	if !(okID && okIP && okScheme && okHost && okFamily && okPort && okExpires) || family > 6 || port > 65535 {
		return Pin{}, false
	}
	p.Family, p.Port, p.ExpiresAt = int(family), int(port), expires
	// A pin is read only when its address parsed: an ip that is no IP
	// literal has no family, whatever family the pin declares.
	parsed, isAddress := Family(p.IP)
	if !isAddress || parsed != p.Family || !ValidID(p.ID) || (p.Scheme != "http" && p.Scheme != "https") ||
		p.Port < 1 || !validHost(p.Host) {
		return Pin{}, false
	}
	return p, true
}

// Expired is whether the pin may no longer be used at now (Unix ms): past
// its expiry.
func (p Pin) Expired(now int64) bool { return now >= 0 && uint64(now) > p.ExpiresAt }

// RequestArgs are the args of an egress_pin request for url with purpose,
// naming the pin from (empty for none) for a redirect and for nothing
// else, or false for a request Prima.PinnedTarget.read_request/1 would
// refuse.
func RequestArgs(url, purpose, from string) (map[string]any, bool) {
	args := map[string]any{"url": url, "purpose": purpose}
	if from != "" {
		args["from"] = from
	}
	if !ReadRequest(args) {
		return nil, false
	}
	return args, true
}

// ReadRequest is whether args are an egress_pin request's: exactly url
// and purpose, and from for a redirect alone; a purpose a runner asks; a
// from that is a pin id; and an http or https URL with a host and no user
// information.
func ReadRequest(args map[string]any) bool {
	url, okURL := args["url"].(string)
	purpose, okPurpose := args["purpose"].(string)
	if !okURL || !okPurpose {
		return false
	}
	known := false
	for _, p := range Purposes() {
		known = known || p == purpose
	}
	if !known {
		return false
	}
	if purpose == "redirect" {
		from, isText := args["from"].(string)
		if len(args) != 3 || !isText || !ValidID(from) {
			return false
		}
	} else if len(args) != 2 {
		return false
	}
	_, ok := network.ParseURL(url)
	return ok
}
