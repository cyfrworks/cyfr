// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package account

import (
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// Refusal is a shape refused as Prima refuses it: Reason is Prima's name
// (invalid_field, wrong_signer, ...), Field the field it names when it
// names one, Kind the unknown kind an entry named, and Index the entry a
// chain refused.
type Refusal struct {
	Reason string
	Field  string
	Kind   string
	Index  int
}

func (r *Refusal) Error() string {
	switch {
	case r.Field != "":
		return r.Reason + " " + r.Field
	case r.Kind != "":
		return r.Reason + " " + r.Kind
	}
	return r.Reason
}

func refused(reason string) *Refusal { return &Refusal{Reason: reason} }

func invalid(field string) *Refusal { return &Refusal{Reason: "invalid_field", Field: field} }

var (
	hostShape       = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$`)
	digestShape     = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
	identifierShape = regexp.MustCompile(`^per_[0-9a-f]{64}$`)
	aaguidShape     = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	portShape       = regexp.MustCompile(`^(0|[1-9][0-9]{0,4})$`)
	pathShape       = regexp.MustCompile(`^(/[A-Za-z0-9._~!$&'()*+,;=:@%-]+)*$`)
)

// IsDigest is whether v is a sha256:<hex> digest: a kid, a hash or a head.
func IsDigest(v any) bool { s, ok := v.(string); return ok && digestShape.MatchString(s) }

// IsIdentifier is whether v is an account's identifier, per_<hex>.
func IsIdentifier(v any) bool { s, ok := v.(string); return ok && identifierShape.MatchString(s) }

// isAAGUID is whether v is a passkey's maker as the log spells it: a
// lowercase hyphenated UUID.
func isAAGUID(v any) bool { s, ok := v.(string); return ok && aaguidShape.MatchString(s) }

func isHost(s string) bool { return len(s) <= 253 && hostShape.MatchString(s) }

// origin is a home's one spelling: http or https, the lowercase host and
// a port only when it is not the scheme's default.
func origin(u *url.URL) (string, bool) {
	if (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.RawQuery != "" || u.ForceQuery ||
		u.Fragment != "" || u.Opaque != "" || !isHost(u.Hostname()) {
		return "", false
	}
	o := u.Scheme + "://" + u.Hostname()
	if p := u.Port(); p != "" {
		// A port has one spelling too, as the app's main reads it
		// (assets/account/encoding.js splitOrigin).
		if n, err := strconv.Atoi(p); err != nil || !portShape.MatchString(p) || n > maxPort {
			return "", false
		}
		if !(u.Scheme == "http" && p == "80") && !(u.Scheme == "https" && p == "443") {
			o += ":" + p
		}
	}
	return o, true
}

const (
	maxPort = 65535
	// maxPortDigits is as many digits as Prima's URI reader takes in a
	// port, leading zeros among them.
	maxPortDigits = 5
)

// CanonicalHome is the one spelling of a home written another way, as
// Prima.Identity.Encoding.canonical_home gives a CYFR its own
// (tests/fixtures/addresses.json, spelled): scheme and host lowercased in
// ASCII, the port read as at most five digits (a leading zero among them,
// an empty one the scheme's own), the scheme's default port and a
// trailing / dropped.
// It is for an address this side read from a setting or a person typed. A
// home on the wire is already in its spelling (IsHome).
func CanonicalHome(v string) (string, bool) {
	if len(v) > 300 || strings.ContainsAny(v, "?#") || strings.ContainsFunc(v, func(r rune) bool { return r > 0x7f }) {
		return "", false
	}
	u, err := url.Parse(strings.ToLower(v))
	if err != nil || (u.Path != "" && u.Path != "/") || u.RawPath != "" || !isHost(u.Hostname()) {
		return "", false
	}
	host := u.Hostname()
	if p := u.Port(); p != "" {
		n, err := strconv.Atoi(p)
		if err != nil || len(p) > maxPortDigits || n > maxPort {
			return "", false
		}
		host += ":" + strconv.Itoa(n)
	}
	u.Host = host
	return origin(u)
}

// IsHome is whether v names a home (a CYFR's origin) in its one spelling.
func IsHome(v any) bool {
	s, ok := v.(string)
	if !ok || len(s) > 300 || strings.Contains(s, "#") {
		return false
	}
	u, err := url.Parse(s)
	if err != nil {
		return false
	}
	o, ok := origin(u)
	return ok && s == o
}

// DirectoryOrigin is a directory URL's origin and host, its passkeys'
// relying party, when v is a directory URL: a home's origin and an
// optional path of segments with no trailing slash, at most 2048 bytes.
func DirectoryOrigin(v any) (string, string, bool) {
	s, ok := v.(string)
	if !ok || len(s) > 2048 || strings.Contains(s, "#") || strings.Contains(s, "?") {
		return "", "", false
	}
	u, err := url.Parse(s)
	if err != nil {
		return "", "", false
	}
	o, ok := origin(u)
	if !ok || !strings.HasPrefix(s, o) || !pathShape.MatchString(s[len(o):]) {
		return "", "", false
	}
	return o, u.Hostname(), true
}

// IsDirectoryURL is whether v is a directory URL (DirectoryOrigin).
func IsDirectoryURL(v any) bool { _, _, ok := DirectoryOrigin(v); return ok }

// fields holds m to exactly required and optional: an unknown field first,
// in sorted order, then a missing one, in required's order.
func fields(m map[string]any, required, optional []string) *Refusal {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	for _, k := range keys {
		if !slices.Contains(required, k) && !slices.Contains(optional, k) {
			return &Refusal{Reason: "unknown_field", Field: k}
		}
	}
	for _, k := range required {
		if _, ok := m[k]; !ok {
			return &Refusal{Reason: "missing_field", Field: k}
		}
	}
	return nil
}
