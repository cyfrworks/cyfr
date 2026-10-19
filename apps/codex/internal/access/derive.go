// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"net"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Target is the access mode a person asks for.
type Target struct {
	Mode, Domain, ACMEEmail string
}

// Current is what the head keeps from .env whatever the mode: the loopback
// listener's port and the builds service's URL, empty when builds are off.
type Current struct {
	Port      int
	BuildsURL string
}

// Join is a tailnet join's record: the machine's name and its stable node
// id, frozen when it joined.
type Join struct {
	Name, NodeID string
}

// Derivation is a target's head and the .env change that writes it: the
// access settings assigned, and the access settings removed because the
// head holds no value for them.
type Derivation struct {
	Head        Head
	Assignments map[string]string
	Removals    []string
}

// envKeys are the .env names of the head's keys, the access settings a switch
// writes. Every other line of .env is kept byte for byte.
var envKeys = []struct {
	name  string
	value func(Head) string
}{
	{"CADDY_ACME_EMAIL", func(h Head) string { return h.ACMEEmail }},
	{"CYFR_HOST", func(h Head) string { return h.Host }},
	{"CYFR_LOCUS_BUILDS_URL", func(h Head) string { return h.BuildsURL }},
	{"CYFR_PORT", func(h Head) string { return strconv.Itoa(h.Port) }},
	{"CYFR_PUBLIC_URL", func(h Head) string { return h.PublicURL }},
	{"CYFR_ACCESS", func(h Head) string { return h.Mode }},
	{"CYFR_TAILNET_NODE_ID", func(h Head) string { return h.NodeID }},
}

var emailLocal = regexp.MustCompile(`^[A-Za-z0-9._+-]{1,64}$`)

const (
	domainRule      = "a domain is two or more labels of letters, digits and hyphens, and not localhost, an IP address or a ts.net name"
	tailnetNameRule = "a tailnet machine name is <machine>.<tailnet>.ts.net"
	emailRule       = "an email address is a name of letters, digits, dots, plus signs, hyphens and underscores, then @ and a domain"
)

// Derive is the head a target makes from the current settings and, for
// tailnet, the join record, with the .env change that writes it. A domain
// is read without case; every other input is taken as given. An input that
// is not UTF-8 is refused first, by the name it would be written under.
func Derive(t Target, cur Current, join *Join) (Derivation, error) {
	if key := unreadableInput(t, cur, join); key != "" {
		return Derivation{}, refuse("access_setting_invalid", map[string]string{"key": key})
	}
	domain := strings.ToLower(strings.TrimSpace(t.Domain))
	email := strings.TrimSpace(t.ACMEEmail)
	buildsURL := strings.TrimSpace(cur.BuildsURL)
	if t.Mode != ModeLocal && t.Mode != ModeTailnet && t.Mode != ModePublic {
		return Derivation{}, refuse("access_unknown_mode", map[string]string{"value": t.Mode})
	}
	if cur.Port < 1 || cur.Port > 65535 {
		return Derivation{}, refuse("access_setting_invalid", map[string]string{"key": "CYFR_PORT", "value": strconv.Itoa(cur.Port)})
	}
	if buildsURL != "" && !BuildsURL(buildsURL) {
		return Derivation{}, settingInvalid("CYFR_LOCUS_BUILDS_URL", buildsURL)
	}
	if t.Mode != ModePublic && domain != "" {
		return Derivation{}, refuse("access_option_outside_mode", map[string]string{"option": "--domain", "mode": t.Mode})
	}
	if t.Mode != ModePublic && email != "" {
		return Derivation{}, refuse("access_option_outside_mode", map[string]string{"option": "--acme-email", "mode": t.Mode})
	}
	h := Head{Mode: t.Mode, Port: cur.Port, BuildsURL: buildsURL}
	switch t.Mode {
	case ModeLocal:
		h.Host = "localhost"
	case ModeTailnet:
		if join == nil {
			return Derivation{}, refuse("tailnet_not_joined", nil)
		}
		if !TailnetName(join.Name) {
			return Derivation{}, invalid(join.Name, "tailnet_name", tailnetNameRule)
		}
		if !NodeID(join.NodeID) {
			return Derivation{}, refuse("tailnet_node_id_unsupported", map[string]string{"value": join.NodeID})
		}
		h.Host, h.NodeID, h.PublicURL = join.Name, join.NodeID, "https://"+join.Name
	case ModePublic:
		if domain == "" {
			return Derivation{}, refuse("access_public_host_invalid", nil)
		}
		if !PublicDomain(domain) {
			return Derivation{}, invalid(t.Domain, "domain", domainRule)
		}
		if email != "" && !validEmail(email) {
			return Derivation{}, invalid(email, "email", emailRule)
		}
		h.Host, h.PublicURL, h.ACMEEmail = domain, "https://"+domain, email
	}
	h.Profiles = Profiles(h.Mode, h.BuildsURL)

	d := Derivation{Head: h, Assignments: map[string]string{}, Removals: []string{}}
	for _, k := range envKeys {
		if v := k.value(h); v != "" {
			d.Assignments[k.name] = v
		} else {
			d.Removals = append(d.Removals, k.name)
		}
	}
	return d, nil
}

func invalid(input, kind, rule string) *Refusal {
	return refuse("access_invalid", map[string]string{"input": input, "kind": kind, "rule": rule})
}

// unreadableInput is the first name, in byte order, whose input is not
// UTF-8, or "". Every refusal after it carries only UTF-8 text.
func unreadableInput(t Target, cur Current, join *Join) string {
	var name, nodeID string
	if join != nil {
		name, nodeID = join.Name, join.NodeID
	}
	for _, input := range []struct{ key, value string }{
		{"CADDY_ACME_EMAIL", t.ACMEEmail},
		{"CYFR_HOST", t.Domain},
		{"CYFR_HOST", name},
		{"CYFR_LOCUS_BUILDS_URL", cur.BuildsURL},
		{"CYFR_ACCESS", t.Mode},
		{"CYFR_TAILNET_NODE_ID", nodeID},
	} {
		if !utf8.ValidString(input.value) {
			return input.key
		}
	}
	return ""
}

func validEmail(email string) bool {
	at := strings.LastIndexByte(email, '@')
	return at > 0 && emailLocal.MatchString(email[:at]) && PublicDomain(strings.ToLower(email[at+1:]))
}

// BootInput is what a boot read: the names and values .env assigns, nil
// when no .env was read itself; the environment merged over it; and
// whether this is a release, where an unset mode is refused, or a dev or
// test run, where it is local.
type BootInput struct {
	File    map[string]string
	Process map[string]string
	Release bool
}

// Listener is an address and a port a listener binds.
type Listener struct {
	Address string
	Port    int
}

// Trust is whose forwarded headers the proxy listener trusts: none, the
// listed addresses and CIDRs, or a count of hops.
type Trust struct {
	Kind  string // "none", "cidrs" or "hops"
	CIDRs []string
	Hops  int
}

// Boot is a coherent deployment's access mode, as the release resolves it.
type Boot struct {
	Head         Head
	Origin       string
	Loopback     Listener
	Proxy        *Listener // nil in local, which has no proxy listener
	Trust        Trust
	HSTS         string // "none", "endpoint_on_proxy" or "caddy"
	CheckOrigins []string
	Assertion    string // "absent" or "process"
}

// accessKeys are every name the boot reads but the compose file's
// assertion, in byte order: the order a source conflict is looked for.
var accessKeys = []string{
	"CADDY_ACME_EMAIL", "CYFR_BIND_ADDRESS", "CYFR_HOST", "CYFR_LOCUS_BUILDS_URL",
	"CYFR_PORT", "CYFR_PROXY_BIND_ADDRESS", "CYFR_PROXY_PORT", "CYFR_PUBLIC_URL", "CYFR_ACCESS",
	"CYFR_TAILNET_NODE_ID", "CYFR_TRUSTED_PROXY_CIDRS", "CYFR_TRUSTED_PROXY_HOPS",
}

const assertionKey = "CYFR_LOCAL_INGRESS_ASSERTED"

// readKeys are every name the boot reads, in byte order.
var readKeys = func() []string {
	keys := append([]string{assertionKey}, accessKeys...)
	slices.Sort(keys)
	return keys
}()

// ResolveBoot answers what Cyfr.RuntimeConfig.resolve_access/1 answers for
// the same input, a refusal by the same code and payload: the first in
// the order that function documents.
func ResolveBoot(in BootInput) (Boot, error) {
	get := func(key string) string { return strings.TrimSpace(in.Process[key]) }

	// A value no rule can read is refused before any rule reads it, by
	// its name alone.
	for _, key := range readKeys {
		if !utf8.ValidString(in.File[key]) || !utf8.ValidString(in.Process[key]) {
			return Boot{}, refuse("access_setting_invalid", map[string]string{"key": key})
		}
	}
	for _, key := range accessKeys {
		if file := strings.TrimSpace(in.File[key]); file != "" && file != get(key) {
			return Boot{}, refuse("access_source_conflict", map[string]string{"key": key, "file_value": file, "process_value": get(key)})
		}
	}
	if _, ok := in.File[assertionKey]; ok {
		return Boot{}, refuse("access_assertion_from_file", nil)
	}

	mode := get("CYFR_ACCESS")
	switch {
	case mode == "" && in.Release:
		return Boot{}, refuse("access_missing", nil)
	case mode == "":
		mode = ModeLocal
	case mode != ModeLocal && mode != ModeTailnet && mode != ModePublic:
		return Boot{}, refuse("access_unknown_mode", map[string]string{"value": mode})
	}

	h, err := bootHead(mode, get)
	if err != nil {
		return Boot{}, err
	}

	bind, err := address(get, "CYFR_BIND_ADDRESS")
	if err != nil {
		return Boot{}, err
	}
	assertion := "absent"
	switch v := get(assertionKey); v {
	case "":
	case "true":
		assertion = "process"
	default:
		return Boot{}, settingInvalid(assertionKey, v)
	}
	proxyBind, err := address(get, "CYFR_PROXY_BIND_ADDRESS")
	if err != nil {
		return Boot{}, err
	}
	proxyPort, err := port(get, "CYFR_PROXY_PORT", 4001)
	if err != nil {
		return Boot{}, err
	}
	trust, err := proxyTrust(get)
	if err != nil {
		return Boot{}, err
	}
	if mode != ModeLocal && proxyPort == h.Port && overlapping(bind, proxyBind) {
		return Boot{}, refuse("access_setting_invalid", map[string]string{
			"key": "CYFR_PROXY_PORT", "value": strconv.Itoa(proxyPort), "address": proxyBind,
			"bind": bind, "port": strconv.Itoa(h.Port),
		})
	}
	if assertion == "absent" && !loopback(bind) {
		return Boot{}, refuse("access_bind_not_loopback", map[string]string{"address": bind})
	}

	b := Boot{
		Head:      h,
		Origin:    h.origin(),
		Loopback:  Listener{bind, h.Port},
		Trust:     Trust{Kind: "none"},
		HSTS:      map[string]string{ModeLocal: "none", ModeTailnet: "endpoint_on_proxy", ModePublic: "caddy"}[mode],
		Assertion: assertion,
	}
	if mode != ModeLocal {
		b.Proxy = &Listener{proxyBind, proxyPort}
		b.Trust = trust
		b.CheckOrigins = append(b.CheckOrigins, "https://"+h.Host)
	}
	for _, host := range []string{"localhost", "127.0.0.1", "[::1]"} {
		for _, scheme := range []string{"http", "https"} {
			b.CheckOrigins = append(b.CheckOrigins, scheme+"://"+host+":"+strconv.Itoa(h.Port))
		}
	}
	return b, nil
}

// bootHead is the head the mode's settings make, once each is the one the
// mode allows, checked in order: the host, the node id, the URL, the keys
// outside the mode, the port.
func bootHead(mode string, get func(string) string) (Head, error) {
	host, nodeID, publicURL := get("CYFR_HOST"), get("CYFR_TAILNET_NODE_ID"), get("CYFR_PUBLIC_URL")
	email, buildsURL := get("CADDY_ACME_EMAIL"), get("CYFR_LOCUS_BUILDS_URL")

	switch mode {
	case ModeLocal:
		if host != "" && host != "localhost" {
			return Head{}, refuse("access_local_mismatch", map[string]string{"key": "CYFR_HOST", "value": host})
		}
	case ModeTailnet:
		if !TailnetName(host) {
			return Head{}, refuse("access_tailnet_host_invalid", omitEmpty(map[string]string{"host": host}))
		}
		if !NodeID(nodeID) {
			return Head{}, refuse("access_tailnet_node_invalid", omitEmpty(map[string]string{"value": nodeID}))
		}
	case ModePublic:
		if !PublicDomain(host) {
			return Head{}, refuse("access_public_host_invalid", omitEmpty(map[string]string{"host": host}))
		}
	}
	switch {
	case mode == ModeLocal && publicURL != "":
		return Head{}, refuse("access_local_mismatch", map[string]string{"key": "CYFR_PUBLIC_URL", "value": publicURL})
	case mode != ModeLocal && publicURL != "https://"+host:
		return Head{}, refuse("access_public_url_mismatch", omitEmpty(map[string]string{"mode": mode, "expected": "https://" + host, "value": publicURL}))
	case mode != ModePublic && email != "":
		return Head{}, refuse("access_key_outside_mode", map[string]string{"key": "CADDY_ACME_EMAIL", "mode": mode, "needs": ModePublic})
	case mode != ModeTailnet && nodeID != "":
		return Head{}, refuse("access_key_outside_mode", map[string]string{"key": "CYFR_TAILNET_NODE_ID", "mode": mode, "needs": ModeTailnet})
	}
	p, err := port(get, "CYFR_PORT", 4000)
	if err != nil {
		return Head{}, err
	}
	if buildsURL != "" && !BuildsURL(buildsURL) {
		return Head{}, settingInvalid("CYFR_LOCUS_BUILDS_URL", buildsURL)
	}
	if host == "" {
		host = "localhost"
	}
	return Head{
		Mode: mode, Host: host, NodeID: nodeID, PublicURL: publicURL, Port: p,
		ACMEEmail: email, BuildsURL: buildsURL, Profiles: Profiles(mode, buildsURL),
	}, nil
}

func omitEmpty(m map[string]string) map[string]string {
	for k, v := range m {
		if v == "" {
			delete(m, k)
		}
	}
	return m
}

func settingInvalid(key, value string) *Refusal {
	return refuse("access_setting_invalid", map[string]string{"key": key, "value": value})
}

func port(get func(string) string, key string, def int) (int, error) {
	text := get(key)
	if text == "" {
		return def, nil
	}
	if n, err := strconv.Atoi(text); err == nil && digits.MatchString(text) && n >= 1 && n <= 65535 {
		return n, nil
	}
	return 0, settingInvalid(key, text)
}

func address(get func(string) string, key string) (string, error) {
	text := get(key)
	if text == "" {
		text = "127.0.0.1"
	}
	if ipLiteral(text) == nil {
		return "", settingInvalid(key, text)
	}
	return text, nil
}

func proxyTrust(get func(string) string) (Trust, error) {
	if text := get("CYFR_TRUSTED_PROXY_CIDRS"); text != "" {
		var entries []string
		for _, e := range strings.Split(text, ",") {
			if e = strings.TrimSpace(e); e != "" {
				entries = append(entries, e)
			}
		}
		if len(entries) == 0 || slices.ContainsFunc(entries, func(e string) bool { return !cidr(e) }) {
			return Trust{}, settingInvalid("CYFR_TRUSTED_PROXY_CIDRS", text)
		}
		return Trust{Kind: "cidrs", CIDRs: entries}, nil
	}
	text := get("CYFR_TRUSTED_PROXY_HOPS")
	if text == "" {
		return Trust{Kind: "hops", Hops: 1}, nil
	}
	if n, err := strconv.Atoi(text); err == nil && digits.MatchString(text) && n <= 16 {
		return Trust{Kind: "hops", Hops: n}, nil
	}
	return Trust{}, settingInvalid("CYFR_TRUSTED_PROXY_HOPS", text)
}

var prefixDigits = regexp.MustCompile(`^[0-9]{1,3}$`)

func cidr(entry string) bool {
	addr, prefix, ranged := strings.Cut(entry, "/")
	if ipLiteral(addr) == nil || strings.Contains(prefix, "/") {
		return false
	}
	if !ranged {
		return true
	}
	limit := 32
	if strings.Contains(addr, ":") {
		limit = 128
	}
	n, err := strconv.Atoi(prefix)
	return err == nil && prefixDigits.MatchString(prefix) && n <= limit
}

// ipLiteral parses an IP literal strictly: dotted quads in full, no zone.
func ipLiteral(text string) net.IP {
	if strings.Contains(text, "%") {
		return nil
	}
	return net.ParseIP(text)
}

// overlapping reports whether two listeners' addresses take a port the
// other takes too: the same address (an IPv4-mapped IPv6 address is the
// IPv4 address it maps), or an unspecified one that takes it as well
// (0.0.0.0 every IPv4 address, :: every address).
func overlapping(a, b string) bool {
	ia, ib := ipLiteral(a), ipLiteral(b)
	v4 := func(ip net.IP) bool { return ip.To4() != nil }
	switch {
	case ia.Equal(ib):
		return true
	case !v4(ia) && ia.IsUnspecified(), !v4(ib) && ib.IsUnspecified():
		return true
	case v4(ia) && v4(ib):
		return ia.IsUnspecified() || ib.IsUnspecified()
	}
	return false
}

// loopback reports whether text is an IPv4 loopback address or ::1, the
// addresses only this machine reaches.
func loopback(text string) bool {
	ip := ipLiteral(text)
	if ip == nil {
		return false
	}
	if strings.Contains(text, ":") {
		return ip.Equal(net.IPv6loopback)
	}
	return ip.To4()[0] == 127
}
