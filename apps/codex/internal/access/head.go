// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package access owns how a server is reached: the access head every
// derived setting comes from, its canonical form and digest, the words a
// person reads for it, and the coherence check of a deployment's settings
// that the release applies at boot (Cyfr.RuntimeConfig.resolve_access/1).
// tests/fixtures/access.json binds this package and the release to one
// answer.
package access

import (
	"crypto/sha256"
	"encoding/hex"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// The kinds of browser address a server has (CYFR_BROWSER): none, its
// tailnet name through Tailscale Serve, a domain through Caddy, or a
// domain through the person's own proxy, which reaches the proxy listener
// published on this machine's loopback.
const (
	BrowserNone    = "none"
	BrowserTailnet = "tailnet"
	BrowserDomain  = "domain"
	BrowserProxy   = "proxy"
)

// Browsers are the kinds, in the order a person reads them.
var Browsers = []string{BrowserNone, BrowserTailnet, BrowserDomain, BrowserProxy}

// DefaultPublish is where the proxy listener is published with proxy
// when no other address is given.
const DefaultPublish = "127.0.0.1:4001"

// Head is the complete selection every access setting derives from. A
// string field that is empty is absent: it is omitted from the canonical
// form and from .env.
type Head struct {
	Browser   string   `json:"browser"`
	Host      string   `json:"host"`
	NodeID    string   `json:"node_id,omitempty"`
	PublicURL string   `json:"public_url,omitempty"`
	Port      int      `json:"port"`
	ACMEEmail string   `json:"acme_email,omitempty"`
	Publish   string   `json:"publish,omitempty"`
	Profiles  []string `json:"profiles"`
}

// Refusal is an access refusal: the code of its Prima.Refusal row, the
// row's class, and the payload its sentence is rendered from. No payload
// carries a secret.
type Refusal struct {
	Code    string
	Class   string
	Payload map[string]string
}

// classes are the Prima.Refusal classes of the codes this package refuses
// with; the vectors hold both sides to them.
var classes = map[string]string{
	"access_source_conflict":        "conflict",
	"access_assertion_from_file":    "forbidden",
	"access_missing":                "setup_required",
	"access_unknown_browser":        "invalid_argument",
	"access_none_mismatch":          "invalid_argument",
	"access_tailnet_host_invalid":   "invalid_argument",
	"access_tailnet_node_invalid":   "invalid_argument",
	"access_domain_host_invalid":    "invalid_argument",
	"access_public_url_mismatch":    "invalid_argument",
	"access_key_outside_browser":    "invalid_argument",
	"access_setting_invalid":        "invalid_argument",
	"access_bind_not_loopback":      "forbidden",
	"access_proxy_trust_missing":    "setup_required",
	"access_invalid":                "invalid_argument",
	"access_option_outside_browser": "invalid_argument",
	"tailnet_not_joined":            "setup_required",
	"tailnet_node_id_unsupported":   "invalid_argument",
}

func (r *Refusal) Error() string {
	keys := make([]string, 0, len(r.Payload))
	for k := range r.Payload {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	parts := []string{r.Code}
	for _, k := range keys {
		parts = append(parts, k+"="+r.Payload[k])
	}
	return "access: " + strings.Join(parts, " ")
}

func refuse(code string, payload map[string]string) *Refusal {
	if payload == nil {
		payload = map[string]string{}
	}
	class, ok := classes[code]
	if !ok {
		class = "internal"
	}
	return &Refusal{Code: code, Class: class, Payload: payload}
}

// Profiles is a head's complete compose selection: the profile of the
// proxy the stack runs for the kind, tailscale's for tailnet and caddy's
// for domain; none for none and for proxy, whose proxy is the person's
// own.
func Profiles(browser string) []string {
	if browser == BrowserTailnet || browser == BrowserDomain {
		return []string{browser}
	}
	return []string{}
}

// BrowserProfiles are the profiles every kind's head selects to reach
// the server, as Profiles derives them.
func BrowserProfiles() []string {
	var out []string
	for _, browser := range Browsers {
		out = union(out, Profiles(browser))
	}
	return out
}

// Canonical is the head's RFC 8785 canonical JSON, as Prima.JCS writes it:
// keys in order, absent keys omitted, strings escaped only where JSON
// requires it.
func (h Head) Canonical() []byte {
	var b strings.Builder
	b.WriteByte('{')
	first := true
	field := func(key, value string) {
		if !first {
			b.WriteByte(',')
		}
		first = false
		writeString(&b, key)
		b.WriteByte(':')
		b.WriteString(value)
	}
	str := func(key, value string) {
		if value != "" {
			var v strings.Builder
			writeString(&v, value)
			field(key, v.String())
		}
	}
	// The keys in byte order, which for these ASCII names is RFC 8785's
	// UTF-16 order.
	str("acme_email", h.ACMEEmail)
	str("browser", h.Browser)
	str("host", h.Host)
	str("node_id", h.NodeID)
	field("port", strconv.Itoa(h.Port))
	var p strings.Builder
	p.WriteByte('[')
	for i, profile := range h.Profiles {
		if i > 0 {
			p.WriteByte(',')
		}
		writeString(&p, profile)
	}
	p.WriteByte(']')
	field("profiles", p.String())
	str("public_url", h.PublicURL)
	str("publish", h.Publish)
	b.WriteByte('}')
	return []byte(b.String())
}

// Digest is the head's digest in Prima.JCS.hash/1's form: sha256: and the
// lowercase hex of its canonical bytes.
func (h Head) Digest() string {
	sum := sha256.Sum256(h.Canonical())
	return "sha256:" + hex.EncodeToString(sum[:])
}

// writeString writes s as an RFC 8785 string: `"` and `\` escaped, the
// control characters as their short escapes or \u00xx, everything else as
// its UTF-8 bytes.
func writeString(b *strings.Builder, s string) {
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\b':
			b.WriteString(`\b`)
		case '\t':
			b.WriteString(`\t`)
		case '\n':
			b.WriteString(`\n`)
		case '\f':
			b.WriteString(`\f`)
		case '\r':
			b.WriteString(`\r`)
		default:
			if c < 0x20 {
				b.WriteString(`\u00`)
				b.WriteString(hex.EncodeToString([]byte{c}))
			} else {
				b.WriteByte(c)
			}
		}
	}
	b.WriteByte('"')
}

var (
	dnsLabel = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)
	nodeID   = regexp.MustCompile(`^[A-Za-z0-9._-]{1,128}$`)
	digits   = regexp.MustCompile(`^[0-9]{1,5}$`)
	allDigit = regexp.MustCompile(`^[0-9]+$`)
)

// TailnetName reports whether name is a tailnet machine name,
// <machine>.<tailnet>.ts.net, in lowercase.
func TailnetName(name string) bool {
	labels := strings.Split(name, ".")
	return len(labels) == 4 && labels[2] == "ts" && labels[3] == "net" &&
		dnsLabel.MatchString(labels[0]) && dnsLabel.MatchString(labels[1])
}

// NodeID reports whether id is a node id this server stores: 1 to 128 bytes
// of [A-Za-z0-9._-], compared byte for byte. Tailscale's stable node id
// has no format of its own, so the grammar is CYFR's.
func NodeID(id string) bool { return nodeID.MatchString(id) }

// PublicDomain reports whether host is a public domain name: at most 253
// bytes of two or more lowercase DNS labels, the last not all digits, and
// neither localhost, a .localhost name nor a ts.net name.
func PublicDomain(host string) bool {
	labels := strings.Split(host, ".")
	if len(host) > 253 || len(labels) < 2 {
		return false
	}
	for _, label := range labels {
		if !dnsLabel.MatchString(label) {
			return false
		}
	}
	last := labels[len(labels)-1]
	return !allDigit.MatchString(last) && last != "localhost" && !strings.HasSuffix("."+host, ".ts.net")
}

// origin is the server's address: http://localhost:<port> with no browser
// address, the browser address otherwise.
func (h Head) origin() string {
	if h.Browser == BrowserNone {
		return "http://localhost:" + strconv.Itoa(h.Port)
	}
	return h.PublicURL
}
