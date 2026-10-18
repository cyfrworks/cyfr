// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package reach owns how a home is reached: the reach head every derived
// setting comes from, its canonical form and digest, the words a person
// reads for it, and the coherence check of a deployment's settings that
// the release applies at boot (Cyfr.RuntimeConfig.resolve_reach/1).
// tests/fixtures/reach_modes.json binds this package and the release to
// one answer.
package reach

import (
	"crypto/sha256"
	"encoding/hex"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// The three ways a home is reached.
const (
	ModeLocal   = "local"
	ModeTailnet = "tailnet"
	ModePublic  = "public"
)

// buildsService is the compose service, and the host, of the Locus builds
// service, and the profile that starts it.
const buildsService = "locus-builds"

// Head is the complete selection every reach setting derives from. A
// string field that is empty is absent: it is omitted from the canonical
// form and from .env.
type Head struct {
	Mode      string   `json:"mode"`
	Host      string   `json:"host"`
	NodeID    string   `json:"node_id,omitempty"`
	PublicURL string   `json:"public_url,omitempty"`
	Port      int      `json:"port"`
	ACMEEmail string   `json:"acme_email,omitempty"`
	BuildsURL string   `json:"builds_url,omitempty"`
	Profiles  []string `json:"profiles"`
}

// Refusal is a reach refusal: the code of its Prima.Refusal row and the
// payload its sentence is rendered from. No payload carries a secret.
type Refusal struct {
	Code    string
	Payload map[string]string
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
	return "reach: " + strings.Join(parts, " ")
}

func refuse(code string, payload map[string]string) *Refusal {
	if payload == nil {
		payload = map[string]string{}
	}
	return &Refusal{Code: code, Payload: payload}
}

// Profiles is a head's complete compose selection, sorted: the mode's
// proxy profile, and locus-builds exactly when buildsURL's host is that
// compose service.
func Profiles(mode, buildsURL string) []string {
	profiles := []string{}
	if mode != ModeLocal {
		profiles = append(profiles, mode)
	}
	if buildsURL != "" {
		if u, err := url.Parse(buildsURL); err == nil && u.Hostname() == buildsService {
			profiles = append(profiles, buildsService)
		}
	}
	slices.Sort(profiles)
	return profiles
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
	str("builds_url", h.BuildsURL)
	str("host", h.Host)
	str("mode", h.Mode)
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

// NodeID reports whether id is a node id this home stores: 1 to 128 bytes
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

// origin is the home's address: http://localhost:<port> for a local home,
// its public URL otherwise.
func (h Head) origin() string {
	if h.Mode == ModeLocal {
		return "http://localhost:" + strconv.Itoa(h.Port)
	}
	return h.PublicURL
}
