// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package network

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
)

func fixture(t *testing.T, name string, v any) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "tests", "fixtures", name))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, v); err != nil {
		t.Fatal(err)
	}
}

type hostVectors struct {
	DomainCases []struct {
		Why      string   `json:"why"`
		Host     string   `json:"host"`
		Patterns []string `json:"patterns"`
		Allowed  bool     `json:"allowed"`
	} `json:"domain_cases"`
	HeaderRules []struct {
		Name              string `json:"name"`
		FramingOrOverride bool   `json:"framing_or_override"`
		Credential        bool   `json:"credential"`
	} `json:"header_rules"`
	FramingHeaders    []string `json:"framing_headers"`
	OverrideHeaders   []string `json:"override_headers"`
	OverridePrefixes  []string `json:"override_prefixes"`
	CredentialHeaders []string `json:"credential_headers"`
	HostHeaders       []struct {
		Scheme string `json:"scheme"`
		Host   string `json:"host"`
		Port   *int   `json:"port"`
		Header string `json:"header"`
	} `json:"host_headers"`
	AttachedRequests []struct {
		Why     string `json:"why"`
		Request struct {
			CallID     string      `json:"call_id"`
			Connection string      `json:"connection"`
			Method     string      `json:"method"`
			URL        string      `json:"url"`
			Headers    [][2]string `json:"headers"`
			Body       string      `json:"body_b64"`
			Purpose    string      `json:"purpose"`
		} `json:"request"`
		Args string `json:"args"`
	} `json:"attached_requests"`
}

func TestEveryDomainMatchesAsPrimaMatchesIt(t *testing.T) {
	var v hostVectors
	fixture(t, "host_api.json", &v)
	if len(v.DomainCases) < 20 {
		t.Fatalf("%d cases", len(v.DomainCases))
	}
	for _, c := range v.DomainCases {
		if got := DomainAllowed(c.Host, c.Patterns); got != c.Allowed {
			t.Errorf("%s: %q against %q: %v", c.Why, c.Host, c.Patterns, got)
		}
	}
}

func TestEveryHeaderIsRuledAsPrimaRulesIt(t *testing.T) {
	var v hostVectors
	fixture(t, "host_api.json", &v)
	if !reflect.DeepEqual(v.FramingHeaders, FramingHeaders) || !reflect.DeepEqual(v.OverrideHeaders, OverrideHeaders) ||
		!reflect.DeepEqual(v.OverridePrefixes, OverridePrefixes) || !reflect.DeepEqual(v.CredentialHeaders, CredentialHeaders) {
		t.Fatal("the rosters differ from the vector's")
	}
	if len(v.HeaderRules) < 25 {
		t.Fatalf("%d rules", len(v.HeaderRules))
	}
	for _, c := range v.HeaderRules {
		if FramingOrOverrideHeader(c.Name) != c.FramingOrOverride || CredentialHeader(c.Name) != c.Credential {
			t.Errorf("%q: framing or override %v, credential %v", c.Name, FramingOrOverrideHeader(c.Name), CredentialHeader(c.Name))
		}
	}
}

func TestEveryHostHeaderIsWrittenAsPrimaWritesIt(t *testing.T) {
	var v hostVectors
	fixture(t, "host_api.json", &v)
	if len(v.HostHeaders) < 10 {
		t.Fatalf("%d host headers", len(v.HostHeaders))
	}
	for _, c := range v.HostHeaders {
		port := ""
		if c.Port != nil {
			port = itoa(*c.Port)
		}
		if got := HostHeader(c.Scheme, c.Host, port); got != c.Header {
			t.Errorf("%s %s %v: %q, want %q", c.Scheme, c.Host, c.Port, got, c.Header)
		}
	}
}

func itoa(n int) string {
	b, _ := wirejson.Write(n)
	return string(b)
}

func TestEveryAttachedRequestIsWrittenAsPrimaWritesIt(t *testing.T) {
	var v hostVectors
	fixture(t, "host_api.json", &v)
	if len(v.AttachedRequests) < 3 {
		t.Fatalf("%d requests", len(v.AttachedRequests))
	}
	for _, c := range v.AttachedRequests {
		r := c.Request
		body, _ := base64.StdEncoding.DecodeString(r.Body)
		req := AttachedRequest{CallID: r.CallID, Connection: r.Connection, Method: r.Method, URL: r.URL,
			Headers: r.Headers, Body: body, Purpose: r.Purpose}
		if got, err := wirejson.Write(req.Args()); err != nil || string(got) != c.Args {
			t.Errorf("%s: %s, %v; want %s", c.Why, got, err, c.Args)
		}
	}
}

// A relay frame's methods are Prima.Destination's, as runner_relay.json
// holds them.
func TestTheMethodsAreTheRelaysAndADestinations(t *testing.T) {
	var v struct {
		Methods []string `json:"methods"`
	}
	fixture(t, "runner_relay.json", &v)
	if !reflect.DeepEqual(v.Methods, Methods) {
		t.Fatalf("the vector's methods %v, the package's %v", v.Methods, Methods)
	}
}
