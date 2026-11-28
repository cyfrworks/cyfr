// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package network

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"reflect"
	"testing"
	"unicode/utf8"

	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
	"github.com/cyfr/locus/keeper/internal/wire/wiretest"
)

// hostSections are the sections of tests/fixtures/host_api.json this test reads.
type hostSections struct {
	DomainCases       json.RawMessage `json:"domain_cases"`
	DomainBytes       json.RawMessage `json:"domain_bytes"`
	Urls              json.RawMessage `json:"urls"`
	FramingHeaders    json.RawMessage `json:"framing_headers"`
	OverrideHeaders   json.RawMessage `json:"override_headers"`
	OverridePrefixes  json.RawMessage `json:"override_prefixes"`
	CredentialHeaders json.RawMessage `json:"credential_headers"`
	HeaderRules       json.RawMessage `json:"header_rules"`
	HostHeaders       json.RawMessage `json:"host_headers"`
	AttachedRequests  json.RawMessage `json:"attached_requests"`
}

func hostVectors(t *testing.T) hostSections {
	t.Helper()
	var s hostSections
	wiretest.Load(t, "host_api.json", &s)
	return s
}

// relaySections are the sections of tests/fixtures/runner_relay.json this test reads.
type relaySections struct {
	Methods json.RawMessage `json:"methods"`
}

func relayVectors(t *testing.T) relaySections {
	t.Helper()
	var s relaySections
	wiretest.Load(t, "runner_relay.json", &s)
	return s
}

func host(t *testing.T) hostSections { return hostVectors(t) }

func TestEveryDomainMatchesAsPrimaMatchesIt(t *testing.T) {
	for _, raw := range wiretest.Cases(t, host(t).DomainCases, 20) {
		var c struct {
			Why      string   `json:"why"`
			Host     string   `json:"host"`
			Patterns []string `json:"patterns"`
			Allowed  bool     `json:"allowed"`
		}
		wiretest.Decode(t, raw, &c, []string{"why", "host", "patterns", "allowed"})
		if got := DomainAllowed(c.Host, c.Patterns); got != c.Allowed {
			t.Errorf("%s: %q against %q: %v", c.Why, c.Host, c.Patterns, got)
		}
	}
}

func unhex(t *testing.T, s string) string {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// A host and its patterns are compared byte for byte where they are no
// UTF-8, as Elixir compares them: an invalid byte is kept, never read as
// U+FFFD (the review's 96 cases among them).
func TestEveryHostOfBytesMatchesAsPrimaMatchesIt(t *testing.T) {
	marked := 0
	defer func() {
		if marked == 0 {
			t.Error("no host is marked as Go's refusal")
		}
	}()
	for _, raw := range wiretest.Cases(t, host(t).DomainBytes, 100) {
		var c struct {
			Host     string   `json:"host_hex"`
			Patterns []string `json:"patterns_hex"`
			Allowed  bool     `json:"allowed"`
			// Go is Go's own answer where it fails closed on bytes that
			// are no UTF-8 and Elixir matches them.
			Go *struct {
				Allowed bool `json:"allowed"`
			} `json:"go"`
		}
		wiretest.Decode(t, raw, &c, []string{"host_hex", "patterns_hex", "allowed"})
		host, patterns := unhex(t, c.Host), make([]string, len(c.Patterns))
		valid := utf8.ValidString(host)
		for i, p := range c.Patterns {
			patterns[i] = unhex(t, p)
			valid = valid && utf8.ValidString(patterns[i])
		}
		want := c.Allowed
		if c.Go != nil {
			marked++
			if !c.Allowed || c.Go.Allowed || valid {
				t.Fatalf("%s against %v: a go marker is Go's refusal of bytes that are no UTF-8, which Elixir matches", c.Host, c.Patterns)
			}
			want = false
		}
		if got := DomainAllowed(host, patterns); got != want {
			t.Errorf("%s against %v: %v", c.Host, c.Patterns, got)
		}
	}
}

// Every URL reads as Prima.Network.parse_url/1 reads it, every part of
// it, the scheme's default port where it names none, or is refused.
func TestEveryURLReadsWholeAsPrimaReadsIt(t *testing.T) {
	for _, raw := range wiretest.Cases(t, host(t).Urls, 30) {
		var c struct {
			Text string `json:"text"`
			URL  *struct {
				Scheme   string      `json:"scheme"`
				Userinfo *string     `json:"userinfo"`
				Host     string      `json:"host"`
				Port     json.Number `json:"port"`
				Path     *string     `json:"path"`
				Query    *string     `json:"query"`
				Fragment *string     `json:"fragment"`
			} `json:"url"`
		}
		wiretest.Decode(t, raw, &c, []string{"text", "url"}, "url")
		got, ok := ParseURL(c.Text)
		if c.URL == nil {
			if ok {
				t.Errorf("%q reads as %+v; Prima refuses it", c.Text, got)
			}
			continue
		}
		if !ok {
			t.Errorf("%q refused", c.Text)
			continue
		}
		path := ""
		if c.URL.Path != nil {
			path = *c.URL.Path
		}
		if got.Scheme != c.URL.Scheme || !same(got.Userinfo, c.URL.Userinfo) || got.Host == nil || *got.Host != c.URL.Host ||
			got.Port == nil || *got.Port != string(c.URL.Port) || got.Path != path || !same(got.Query, c.URL.Query) ||
			!same(got.Fragment, c.URL.Fragment) {
			t.Errorf("%q reads as %s; Prima's %s", c.Text, show(got), raw)
		}
	}
}

func same(a, b *string) bool { return (a == nil) == (b == nil) && (a == nil || *a == *b) }

func show(u URI) string {
	b, _ := json.Marshal(u)
	return string(b)
}

func TestEveryHeaderIsRuledAsPrimaRulesIt(t *testing.T) {
	top := host(t)
	for name, r := range map[string]struct {
		raw    json.RawMessage
		roster []string
	}{
		"framing_headers": {top.FramingHeaders, FramingHeaders()}, "override_headers": {top.OverrideHeaders, OverrideHeaders()},
		"override_prefixes": {top.OverridePrefixes, OverridePrefixes()}, "credential_headers": {top.CredentialHeaders, CredentialHeaders()},
	} {
		var want []string
		roster := r.roster
		if err := json.Unmarshal(r.raw, &want); err != nil || len(want) == 0 || !reflect.DeepEqual(want, roster) {
			t.Errorf("%s: the vector's %v, the package's %v (%v)", name, want, roster, err)
		}
	}
	FramingHeaders()[0] = "changed"
	if FramingHeaders()[0] != "host" {
		t.Error("a caller changed the roster")
	}
	for _, raw := range wiretest.Cases(t, top.HeaderRules, 25) {
		var c struct {
			Name              string `json:"name"`
			FramingOrOverride bool   `json:"framing_or_override"`
			Credential        bool   `json:"credential"`
		}
		wiretest.Decode(t, raw, &c, []string{"name", "framing_or_override", "credential"})
		if FramingOrOverrideHeader(c.Name) != c.FramingOrOverride || CredentialHeader(c.Name) != c.Credential {
			t.Errorf("%q: framing or override %v, credential %v", c.Name, FramingOrOverrideHeader(c.Name), CredentialHeader(c.Name))
		}
	}
}

func TestEveryHostHeaderIsWrittenAsPrimaWritesIt(t *testing.T) {
	for _, raw := range wiretest.Cases(t, host(t).HostHeaders, 10) {
		var c struct {
			Scheme string       `json:"scheme"`
			Host   string       `json:"host"`
			Port   *json.Number `json:"port"`
			Header string       `json:"header"`
		}
		wiretest.Decode(t, raw, &c, []string{"scheme", "host", "port", "header"}, "port")
		port := ""
		if c.Port != nil {
			port = string(*c.Port)
		}
		if got := HostHeader(c.Scheme, c.Host, port); got != c.Header {
			t.Errorf("%s %s %v: %q, want %q", c.Scheme, c.Host, port, got, c.Header)
		}
	}
}

func TestEveryAttachedRequestIsWrittenAsPrimaWritesIt(t *testing.T) {
	for _, raw := range wiretest.Cases(t, host(t).AttachedRequests, 3) {
		var c struct {
			Why     string          `json:"why"`
			Request json.RawMessage `json:"request"`
			Args    string          `json:"args"`
		}
		wiretest.Decode(t, raw, &c, []string{"why", "request", "args"})
		var r struct {
			CallID     string      `json:"call_id"`
			Connection string      `json:"connection"`
			Method     string      `json:"method"`
			URL        string      `json:"url"`
			Headers    [][2]string `json:"headers"`
			Body       string      `json:"body_b64"`
			Purpose    string      `json:"purpose"`
		}
		wiretest.Decode(t, c.Request, &r, []string{"call_id", "connection", "method", "url", "headers", "body_b64", "purpose"})
		body, _ := base64.StdEncoding.DecodeString(r.Body)
		req := AttachedRequest{CallID: r.CallID, Connection: r.Connection, Method: r.Method, URL: r.URL,
			Headers: r.Headers, Body: body, Purpose: r.Purpose}
		if got, err := wirejson.Write(req.Args()); err != nil || string(got) != c.Args {
			t.Errorf("%s: %s, %v; want %s", c.Why, got, err, c.Args)
		}
	}
}

// A relay frame's methods are Prima.Destination's, as runner_relay.json
// holds them, and each call answers a list of its own.
func TestTheMethodsAreTheRelaysAndADestinations(t *testing.T) {
	var methods []string
	if err := json.Unmarshal(relayVectors(t).Methods, &methods); err != nil {
		t.Fatal(err)
	}
	if len(methods) == 0 || !reflect.DeepEqual(methods, Methods()) {
		t.Fatalf("the vector's methods %v, the package's %v", methods, Methods())
	}
	Methods()[0] = "changed"
	if Methods()[0] != methods[0] {
		t.Error("a caller changed the methods")
	}
}

// ParseURI reads an empty authority, and a scheme's default port, as
// URI.parse/1 does (Elixir 1.20.4's answers, written here): an empty
// authority's host is empty, an authority of userinfo alone has none, and
// a known scheme's port is its default where the text names none.
func TestParseURIReadsAnEmptyAuthorityAndADefaultPortAsURIParseDoes(t *testing.T) {
	text := func(s string) *string { return &s }
	for _, c := range []struct {
		in         string
		host, port *string
		path       string
	}{
		{"http://", text(""), text("80"), ""},
		{"//", text(""), nil, ""},
		{"http:///p", text(""), text("80"), "/p"},
		{"https://u@", nil, text("443"), ""},
		{"http:foo", nil, text("80"), "foo"},
		{"foo://x", text("x"), nil, ""},
		{"ws://x", text("x"), text("80"), ""},
		{"https://x:12ab", text("x"), text("12"), ""},
	} {
		u := ParseURI(c.in)
		if !same(u.Host, c.host) || !same(u.Port, c.port) || u.Path != c.path {
			t.Errorf("%q: %s", c.in, show(u))
		}
	}
}
