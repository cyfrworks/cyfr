// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package network is Prima.Network, Prima.Destination's methods and
// Prima.AttachedRequest's writing in Go, as a worker service uses them: a
// URL read as Elixir's URI.parse/1 reads it, the egress domain match,
// the header rules a request is held to, the Host header a pinned request
// carries, and the args of an attached request it posts for its runner.
// Prima's modules are the one definition; tests/fixtures/host_api.json
// and runner_relay.json hold this package to them.
package network

import (
	"encoding/base64"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Methods are the HTTP methods a destination admits and a relay frame
// carries (Prima.Destination.methods/0), a fresh list each call.
func Methods() []string { return []string{"DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"} }

// URI is a URL's parts as URI.parse/1 reads them: Scheme lowercased, a
// part absent nil (a Path absent is empty), Host without its brackets,
// Port the port in decimal without leading zeros: the digits after the
// host's colon, or the scheme's default port (URI.default_port/1) where
// there are none.
type URI struct {
	Scheme   string
	Userinfo *string
	Host     *string
	Port     *string
	Path     string
	Query    *string
	Fragment *string
}

func alpha(c byte) bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' }
func digit(c byte) bool { return c >= '0' && c <= '9' }

// defaultPort is URI.default_port/1: the port a scheme's URL names when
// it names none.
var defaultPort = map[string]string{
	"ftp": "21", "sftp": "22", "tftp": "69", "http": "80", "https": "443", "ldap": "389", "ws": "80", "wss": "443",
}

// ParseURI reads text as URI.parse/1 does, by RFC 3986's appendix B,
// ^(([a-z][a-z0-9+\-.]*):)?(//([^/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?
// without case, the fragment's . stopping at a line feed; and an
// authority as (^(.*)@)?(\[[a-zA-Z0-9:.]*\]|[^:]*)(:(\d*))?, its
// userinfo's . likewise, an empty userinfo none, a host its brackets
// trimmed, an empty host none but in an empty authority, whose host is
// empty, and an empty port the scheme's default.
func ParseURI(text string) URI {
	var u URI
	rest := text
	if len(text) > 0 && alpha(text[0]) {
		i := 1
		for i < len(text) && (alpha(text[i]) || digit(text[i]) || strings.IndexByte("+-.", text[i]) >= 0) {
			i++
		}
		if i < len(text) && text[i] == ':' {
			u.Scheme = strings.ToLower(text[:i])
			rest = text[i+1:]
		}
	}
	if strings.HasPrefix(rest, "//") {
		after := rest[2:]
		end := strings.IndexAny(after, "/?#")
		if end < 0 {
			end = len(after)
		}
		u.Userinfo, u.Host, u.Port = splitAuthority(after[:end])
		rest = after[end:]
	}
	if port, known := defaultPort[u.Scheme]; known && u.Port == nil {
		u.Port = &port
	}
	end := strings.IndexAny(rest, "?#")
	if end < 0 {
		end = len(rest)
	}
	u.Path, rest = rest[:end], rest[end:]
	if strings.HasPrefix(rest, "?") {
		q := rest[1:]
		if i := strings.IndexByte(q, '#'); i >= 0 {
			q, rest = q[:i], q[i:]
		} else {
			rest = ""
		}
		u.Query = &q
	}
	if strings.HasPrefix(rest, "#") {
		f := rest[1:]
		if i := strings.IndexByte(f, '\n'); i >= 0 {
			f = f[:i]
		}
		u.Fragment = &f
	}
	return u
}

func splitAuthority(authority string) (userinfo, host, port *string) {
	if authority == "" {
		empty := ""
		return nil, &empty, nil
	}
	rest := authority
	line := authority
	if i := strings.IndexByte(line, '\n'); i >= 0 {
		line = line[:i]
	}
	if at := strings.LastIndexByte(line, '@'); at >= 0 {
		if at > 0 {
			info := authority[:at]
			userinfo = &info
		}
		rest = authority[at+1:]
	}
	n := hostLength(rest)
	if h := rest[:n]; h != "" {
		h = strings.TrimRight(strings.TrimLeft(h, "["), "]")
		host = &h
	}
	if after := rest[n:]; strings.HasPrefix(after, ":") {
		i := 1
		for i < len(after) && digit(after[i]) {
			i++
		}
		if digits := strings.TrimLeft(after[1:i], "0"); i > 1 {
			if digits == "" {
				digits = "0"
			}
			port = &digits
		}
	}
	return userinfo, host, port
}

// hostLength is the length of the host at the head of rest: a bracketed
// address of letters, digits, : and ., or everything to the first colon.
func hostLength(rest string) int {
	if strings.HasPrefix(rest, "[") {
		i := 1
		for i < len(rest) && (alpha(rest[i]) || digit(rest[i]) || rest[i] == ':' || rest[i] == '.') {
			i++
		}
		if i < len(rest) && rest[i] == ']' {
			return i + 1
		}
	}
	if i := strings.IndexByte(rest, ':'); i >= 0 {
		return i
	}
	return len(rest)
}

// ParseURL reads a URL a guest's request names as Prima.Network.parse_url/1
// does: URI.parse/1's parts, an http or https scheme, a host that is not
// empty, and no user information.
func ParseURL(text string) (URI, bool) {
	u := ParseURI(text)
	if (u.Scheme != "http" && u.Scheme != "https") || u.Host == nil || *u.Host == "" || u.Userinfo != nil {
		return URI{}, false
	}
	return u, true
}

// Downcase is s lowercased as Elixir's String.downcase/1 does in its
// default mode: each character's simple lowercase, but İ (U+0130), which
// Unicode's SpecialCasing lowercases to i and a combining dot above where
// Go's unicode.ToLower gives a plain i; and a byte that is no UTF-8 kept
// as it is, as Elixir keeps it, never read as U+FFFD.
func Downcase(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		switch {
		case r == utf8.RuneError && size == 1:
			b.WriteByte(s[i])
		case r == 'İ':
			b.WriteString("i\u0307")
		default:
			b.WriteRune(unicode.ToLower(r))
		}
		i += size
	}
	return b.String()
}

func dropTrailingDot(s string) string { return strings.TrimSuffix(s, ".") }

// DomainAllowed is whether host matches one of the egress domain patterns
// (Prima.Network.domain_allowed?/2): "*" matches any host; "*.b" every
// name below b and neither b nor a name sharing part of a label; any other
// pattern exactly. Host and pattern compare case-folded, each with one
// trailing dot dropped; an empty host, or no pattern, matches nothing.
func DomainAllowed(host string, patterns []string) bool {
	host = Downcase(dropTrailingDot(host))
	if host == "" {
		return false
	}
	for _, p := range patterns {
		switch {
		case p == "*":
			return true
		case strings.HasPrefix(p, "*."):
			if base := Downcase(dropTrailingDot(p[2:])); base != "" && strings.HasSuffix(host, "."+base) {
				return true
			}
		case Downcase(dropTrailingDot(p)) == host:
			return true
		}
	}
	return false
}

// The rosters of Prima.Network, lowercase and in order.
var (
	framingHeaders = []string{"host", "content-length", "transfer-encoding", "connection", "keep-alive",
		"te", "trailer", "upgrade", "proxy-connection", "expect"}
	overrideHeaders = []string{"x-http-method-override", "x-http-method", "x-method-override",
		"x-original-url", "x-rewrite-url", "x-original-host", "x-host", "x-forwarded-host",
		"x-forwarded-proto", "x-forwarded-port", "x-forwarded-prefix", "x-forwarded-server",
		"forwarded", "via", "x-real-ip", "true-client-ip"}
	overridePrefixes  = []string{"x-forwarded-"}
	credentialHeaders = []string{"authorization", "cookie", "proxy-authorization", "x-api-key",
		"x-auth-token", "x-access-token", "x-csrf-token"}
	credentialSuffixes = []string{"-token", "-key", "-secret"}
)

// FramingHeaders are the headers that route or frame a request, a fresh
// list each call (Prima.Network.framing_headers/0).
func FramingHeaders() []string { return append([]string(nil), framingHeaders...) }

// OverrideHeaders are the headers that override a request's method or
// target or claim its origin, a fresh list each call
// (Prima.Network.override_headers/0).
func OverrideHeaders() []string { return append([]string(nil), overrideHeaders...) }

// OverridePrefixes are the prefixes any name starting with which is an
// override header too, a fresh list each call.
func OverridePrefixes() []string { return append([]string(nil), overridePrefixes...) }

// CredentialHeaders are the headers that carry a credential, a fresh list
// each call (Prima.Network.credential_headers/0).
func CredentialHeaders() []string { return append([]string(nil), credentialHeaders...) }

func in(name string, roster []string) bool {
	for _, r := range roster {
		if r == name {
			return true
		}
	}
	return false
}

// FramingOrOverrideHeader is whether a header name, in any case, is one
// only the client making a request sets: a framing or override header, or
// a name starting with an override prefix.
func FramingOrOverrideHeader(name string) bool {
	name = Downcase(name)
	if in(name, framingHeaders) || in(name, overrideHeaders) {
		return true
	}
	for _, p := range overridePrefixes {
		if strings.HasPrefix(name, p) {
			return true
		}
	}
	return false
}

// CredentialHeader is whether a header name, in any case, carries a
// credential: one of CredentialHeaders, or a name ending in -token, -key
// or -secret.
func CredentialHeader(name string) bool {
	name = Downcase(name)
	if in(name, credentialHeaders) {
		return true
	}
	for _, s := range credentialSuffixes {
		if strings.HasSuffix(name, s) {
			return true
		}
	}
	return false
}

var defaultPorts = map[string]string{"http": "80", "https": "443"}

// HostHeader is the Host header a request to host on port carries
// (Prima.Network.host_header/1): the host, a bracketed host's one opening
// bracket and every closing one dropped, and any host holding a colon in
// brackets; then :port unless port, decimal digits without leading zeros,
// is the scheme's default or absent ("").
func HostHeader(scheme, host, port string) string {
	if strings.HasPrefix(host, "[") {
		host = strings.TrimRight(host[1:], "]")
	}
	if strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	if port == "" || port == defaultPorts[Downcase(scheme)] {
		return host
	}
	return host + ":" + port
}

// AttachedRequest is a guest's request that names a connection, as the
// worker service posts it to CYFR in attached_fetch
// (Prima.AttachedRequest).
type AttachedRequest struct {
	CallID, Connection, Method, URL string
	Headers                         [][2]string
	Body                            []byte
	Purpose                         string
}

// Args are the request as its attached_fetch args spell it
// (Prima.AttachedRequest.to_args/1): a body, when there is one, in
// standard base64 beside body_encoding base64.
func (r AttachedRequest) Args() map[string]any {
	headers := make([]any, len(r.Headers))
	for i, h := range r.Headers {
		headers[i] = []any{h[0], h[1]}
	}
	args := map[string]any{
		"call_id": r.CallID, "connection": r.Connection, "method": r.Method, "url": r.URL,
		"headers": headers, "purpose": r.Purpose,
	}
	if len(r.Body) > 0 {
		args["body"] = base64.StdEncoding.EncodeToString(r.Body)
		args["body_encoding"] = "base64"
	}
	return args
}
