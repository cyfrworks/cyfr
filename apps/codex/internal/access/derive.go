// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"cmp"
	"net"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Target is the browser address a person asks for.
type Target struct {
	Browser, Domain, ACMEEmail, Publish string
}

// Current is what the head keeps from .env whatever the kind: the
// loopback listener's port, where the proxy listener is published when
// .env has proxy, and whether .env states whose forwarded headers the
// proxy listener trusts.
type Current struct {
	Port    int
	Publish string
	Trusted bool
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
	{"CYFR_PORT", func(h Head) string { return strconv.Itoa(h.Port) }},
	{"CYFR_BROWSER", func(h Head) string { return h.Browser }},
	{"CYFR_PROXY_PUBLISH", func(h Head) string { return h.Publish }},
	{"CYFR_PUBLIC_URL", func(h Head) string { return h.PublicURL }},
	{"CYFR_TAILNET_NODE_ID", func(h Head) string { return h.NodeID }},
}

var emailLocal = regexp.MustCompile(`^[A-Za-z0-9._+-]{1,64}$`)

const (
	domainRule      = "a domain is two or more labels of letters, digits and hyphens, and not localhost, an IP address or a ts.net name"
	tailnetNameRule = "a tailnet machine name is <machine>.<tailnet>.ts.net"
	emailRule       = "an email address is a name of letters, digits, dots, plus signs, hyphens and underscores, then @ and a domain"
)

// optionKinds are the kinds each option of a target is for.
var optionKinds = []struct {
	option string
	kinds  []string
	value  func(t Target) string
}{
	{"--domain", []string{BrowserDomain, BrowserProxy}, func(t Target) string { return strings.TrimSpace(t.Domain) }},
	{"--acme-email", []string{BrowserDomain}, func(t Target) string { return strings.TrimSpace(t.ACMEEmail) }},
	{"--publish", []string{BrowserProxy}, func(t Target) string { return strings.TrimSpace(t.Publish) }},
}

// Derive is the head a target makes from the current settings and, for
// tailnet, the join record, with the .env change that writes it. A domain
// is read without case; every other input is taken as given. An input that
// is not UTF-8 is refused first, by the name it would be written under.
func Derive(t Target, cur Current, join *Join) (Derivation, error) {
	if key := unreadableInput(t, join); key != "" {
		return Derivation{}, refuse("access_setting_invalid", map[string]string{"key": key})
	}
	domain := strings.ToLower(strings.TrimSpace(t.Domain))
	email := strings.TrimSpace(t.ACMEEmail)
	if !slices.Contains(Browsers, t.Browser) {
		return Derivation{}, refuse("access_unknown_browser", map[string]string{"value": t.Browser})
	}
	if cur.Port < 1 || cur.Port > 65535 {
		return Derivation{}, refuse("access_setting_invalid", map[string]string{"key": "CYFR_PORT", "value": strconv.Itoa(cur.Port)})
	}
	for _, o := range optionKinds {
		if o.value(t) != "" && !slices.Contains(o.kinds, t.Browser) {
			return Derivation{}, refuse("access_option_outside_browser", map[string]string{"option": o.option, "browser": t.Browser})
		}
	}
	h := Head{Browser: t.Browser, Port: cur.Port}
	switch t.Browser {
	case BrowserNone:
		h.Host = "localhost"
	case BrowserTailnet:
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
	case BrowserDomain, BrowserProxy:
		if domain == "" {
			return Derivation{}, refuse("access_domain_host_invalid", map[string]string{"browser": t.Browser})
		}
		if !PublicDomain(domain) {
			return Derivation{}, invalid(t.Domain, "domain", domainRule)
		}
		if email != "" && !validEmail(email) {
			return Derivation{}, invalid(email, "email", emailRule)
		}
		h.Host, h.PublicURL, h.ACMEEmail = domain, "https://"+domain, email
	}
	if t.Browser == BrowserProxy {
		h.Publish = strings.TrimSpace(t.Publish)
		if h.Publish == "" {
			h.Publish = cmp.Or(cur.Publish, DefaultPublish)
		}
		if _, err := publishOf(h.Publish, h.Port); err != nil {
			return Derivation{}, err
		}
		if !cur.Trusted {
			return Derivation{}, refuse("access_proxy_trust_missing", nil)
		}
	}
	h.Profiles = Profiles(h.Browser)

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
func unreadableInput(t Target, join *Join) string {
	var name, nodeID string
	if join != nil {
		name, nodeID = join.Name, join.NodeID
	}
	for _, input := range []struct{ key, value string }{
		{"CADDY_ACME_EMAIL", t.ACMEEmail},
		{"CYFR_HOST", t.Domain},
		{"CYFR_HOST", name},
		{"CYFR_BROWSER", t.Browser},
		{"CYFR_PROXY_PUBLISH", t.Publish},
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
// whether this is a release, where an unset kind is refused, or a dev or
// test run, where it is none.
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

// Boot is a coherent deployment's browser address, as the release
// resolves it.
type Boot struct {
	Head     Head
	Exposure string // "public" for domain and proxy, "private" otherwise
	Origin   string
	Loopback Listener
	Proxy    *Listener // nil with none, which has no proxy listener
	// Published is where the proxy listener is published on this
	// machine's loopback: with proxy alone, nil otherwise.
	Published    *Listener
	Trust        Trust
	HSTS         string // "none", "endpoint_on_proxy" or "caddy"
	CheckOrigins []string
	Assertion    string // "absent" or "process"
}

// accessKeys are every name the boot reads but the compose file's
// assertion, in byte order: the order a source conflict is looked for.
var accessKeys = []string{
	"CADDY_ACME_EMAIL", "CYFR_BIND_ADDRESS", "CYFR_BROWSER", "CYFR_HOST",
	"CYFR_PORT", "CYFR_PROXY_BIND_ADDRESS", "CYFR_PROXY_PORT", "CYFR_PROXY_PUBLISH", "CYFR_PUBLIC_URL",
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

	browser := get("CYFR_BROWSER")
	switch {
	case browser == "" && in.Release:
		return Boot{}, refuse("access_missing", nil)
	case browser == "":
		browser = BrowserNone
	case !slices.Contains(Browsers, browser):
		return Boot{}, refuse("access_unknown_browser", map[string]string{"value": browser})
	}

	h, err := bootHead(browser, get)
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
	var published *Listener
	if browser == BrowserProxy {
		if published, err = publishOf(h.Publish, h.Port); err != nil {
			return Boot{}, err
		}
		if trust.Kind == "" {
			return Boot{}, refuse("access_proxy_trust_missing", nil)
		}
	}
	if trust.Kind == "" {
		trust = Trust{Kind: "hops", Hops: defaultHops}
	}
	if browser != BrowserNone && proxyPort == h.Port && overlapping(bind, proxyBind) {
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
		Exposure:  exposure(browser),
		Origin:    h.origin(),
		Loopback:  Listener{bind, h.Port},
		Published: published,
		Trust:     Trust{Kind: "none"},
		HSTS:      map[string]string{BrowserNone: "none", BrowserTailnet: "endpoint_on_proxy", BrowserDomain: "caddy", BrowserProxy: "endpoint_on_proxy"}[browser],
		Assertion: assertion,
	}
	if browser != BrowserNone {
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

// bootHead is the head the kind's settings make, once each is the one
// the kind allows, checked in order: the host, the node id, the URL, the
// keys outside the kind, the port.
func bootHead(browser string, get func(string) string) (Head, error) {
	host, nodeID, publicURL := get("CYFR_HOST"), get("CYFR_TAILNET_NODE_ID"), get("CYFR_PUBLIC_URL")
	email, publish := get("CADDY_ACME_EMAIL"), get("CYFR_PROXY_PUBLISH")

	switch browser {
	case BrowserNone:
		if host != "" && host != "localhost" {
			return Head{}, refuse("access_none_mismatch", map[string]string{"key": "CYFR_HOST", "value": host})
		}
	case BrowserTailnet:
		if !TailnetName(host) {
			return Head{}, refuse("access_tailnet_host_invalid", omitEmpty(map[string]string{"host": host}))
		}
		if !NodeID(nodeID) {
			return Head{}, refuse("access_tailnet_node_invalid", omitEmpty(map[string]string{"value": nodeID}))
		}
	case BrowserDomain, BrowserProxy:
		if !PublicDomain(host) {
			return Head{}, refuse("access_domain_host_invalid", omitEmpty(map[string]string{"browser": browser, "host": host}))
		}
	}
	switch {
	case browser == BrowserNone && publicURL != "":
		return Head{}, refuse("access_none_mismatch", map[string]string{"key": "CYFR_PUBLIC_URL", "value": publicURL})
	case browser != BrowserNone && publicURL != "https://"+host:
		return Head{}, refuse("access_public_url_mismatch", omitEmpty(map[string]string{"browser": browser, "expected": "https://" + host, "value": publicURL}))
	case browser != BrowserDomain && email != "":
		return Head{}, refuse("access_key_outside_browser", map[string]string{"key": "CADDY_ACME_EMAIL", "browser": browser, "needs": BrowserDomain})
	case browser != BrowserTailnet && nodeID != "":
		return Head{}, refuse("access_key_outside_browser", map[string]string{"key": "CYFR_TAILNET_NODE_ID", "browser": browser, "needs": BrowserTailnet})
	case browser != BrowserProxy && publish != "":
		return Head{}, refuse("access_key_outside_browser", map[string]string{"key": "CYFR_PROXY_PUBLISH", "browser": browser, "needs": BrowserProxy})
	}
	p, err := port(get, "CYFR_PORT", 4000)
	if err != nil {
		return Head{}, err
	}
	if host == "" {
		host = "localhost"
	}
	if browser == BrowserProxy && publish == "" {
		publish = DefaultPublish
	}
	return Head{
		Browser: browser, Host: host, NodeID: nodeID, PublicURL: publicURL, Port: p,
		ACMEEmail: email, Publish: publish, Profiles: Profiles(browser),
	}, nil
}

// exposure is how far a kind reaches: public for a domain, whether
// through Caddy or the person's own proxy, private otherwise.
func exposure(browser string) string {
	if browser == BrowserDomain || browser == BrowserProxy {
		return "public"
	}
	return "private"
}

// publishOf reads where the proxy listener is published, text: an IPv4
// loopback address and a port, apart from the loopback listener's own
// publication at 127.0.0.1 on port. IPv4 alone: the listener binds the
// container's IPv4 address, which Docker's IPv6 publication of [::1] does
// not reach.
func publishOf(text string, port int) (*Listener, error) {
	addr, portText, ok := strings.Cut(text, ":")
	if !ok || strings.Contains(addr, ":") || strings.Contains(addr, "%") || strings.Contains(portText, ":") {
		return nil, settingInvalid("CYFR_PROXY_PUBLISH", text)
	}
	n, err := strconv.Atoi(portText)
	if ip := ipLiteral(addr); err != nil || !digits.MatchString(portText) || n < 1 || n > 65535 || ip == nil || ip.To4() == nil || ip.To4()[0] != 127 {
		return nil, settingInvalid("CYFR_PROXY_PUBLISH", text)
	}
	if n == port && ipLiteral(addr).Equal(net.IPv4(127, 0, 0, 1)) {
		return nil, refuse("access_setting_invalid", map[string]string{"key": "CYFR_PROXY_PUBLISH", "value": text, "port": strconv.Itoa(port)})
	}
	return &Listener{addr, n}, nil
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

// defaultHops is the proxy hops trusted when no trust is stated, by every
// kind but proxy.
const defaultHops = 1

// proxyTrust is the trust .env and the environment state, its Kind ""
// when they state none.
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
		// Unstated: proxy refuses it, every other kind takes the default.
		return Trust{}, nil
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
