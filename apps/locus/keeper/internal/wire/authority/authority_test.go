// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package authority

import (
	"encoding/hex"
	"encoding/json"
	"reflect"
	"testing"
	"unicode/utf8"

	"github.com/cyfr/locus/keeper/internal/wire/limits"
	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
	"github.com/cyfr/locus/keeper/internal/wire/wiretest"
)

// wireSections are the sections of tests/fixtures/authority_wire.json this test reads.
type wireSections struct {
	Version json.RawMessage `json:"version"`
	Read    json.RawMessage `json:"read"`
	Refused json.RawMessage `json:"refused"`
	Egress  json.RawMessage `json:"egress"`
}

func wireVectors(t *testing.T) wireSections {
	t.Helper()
	var s wireSections
	wiretest.Load(t, "authority_wire.json", &s)
	return s
}

// hostSections are the sections of tests/fixtures/host_api.json this test reads.
type hostSections struct {
	EdgeChecks    json.RawMessage `json:"edge_checks"`
	RequestSizes  json.RawMessage `json:"request_sizes"`
	MethodBytes   json.RawMessage `json:"method_bytes"`
	UpcaseSpecial json.RawMessage `json:"upcase_special"`
}

func hostVectors(t *testing.T) hostSections {
	t.Helper()
	var s hostSections
	wiretest.Load(t, "host_api.json", &s)
	return s
}

type wireLimits struct {
	Timeout            string `json:"timeout"`
	BatchTimeout       string `json:"batch_timeout"`
	MaxMemoryBytes     uint64 `json:"max_memory_bytes"`
	MaxRequestSize     uint64 `json:"max_request_size"`
	MaxResponseSize    uint64 `json:"max_response_size"`
	MaxConcurrentTasks uint64 `json:"max_concurrent_tasks"`
	RateLimit          struct {
		Requests uint64 `json:"requests"`
		Window   string `json:"window"`
	} `json:"rate_limit"`
}

func read(t *testing.T, raw json.RawMessage) (Authority, error) {
	t.Helper()
	decoded, err := wirejson.Read(raw)
	if err != nil {
		t.Fatal(err)
	}
	return Read(decoded)
}

func wire(t *testing.T) wireSections {
	t.Helper()
	top := wireVectors(t)
	var version int
	if err := json.Unmarshal(top.Version, &version); err != nil || version != 1 {
		t.Fatalf("the vector file's version: %d, %v", version, err)
	}
	return top
}

// Every authority reads to the limits its cursor stands on, a bound
// cursor's other members read past; every one Prima refuses in a part the
// service reads is refused; and one refused in a part the service carries
// unread, marked so and no other way, is read.
func TestEveryAuthorityReadsAsPrimaReadsItsParts(t *testing.T) {
	top := wire(t)
	for _, raw := range wiretest.Cases(t, top.Read, 12) {
		var c struct {
			Why            string          `json:"why"`
			Authority      json.RawMessage `json:"authority"`
			Limits         wireLimits      `json:"limits"`
			AttachedFields []string        `json:"attached_fields"`
		}
		wiretest.Decode(t, raw, &c, []string{"why", "authority", "limits", "attached_fields"})
		a, err := read(t, c.Authority)
		l := c.Limits
		want := limits.Limits{Timeout: l.Timeout, BatchTimeout: l.BatchTimeout, MaxMemoryBytes: l.MaxMemoryBytes,
			MaxRequestSize: l.MaxRequestSize, MaxResponseSize: l.MaxResponseSize, MaxConcurrentTasks: l.MaxConcurrentTasks,
			RateLimit: limits.RateLimit{Requests: l.RateLimit.Requests, Window: l.RateLimit.Window}}
		if err != nil || a.Limits != want {
			t.Errorf("%s: %+v, %v", c.Why, a.Limits, err)
		}
	}
	unread := 0
	for _, raw := range wiretest.Cases(t, top.Refused, 20) {
		var c struct {
			Why       string          `json:"why"`
			Authority json.RawMessage `json:"authority"`
			Unread    *bool           `json:"unread_by_service"`
		}
		wiretest.Decode(t, raw, &c, []string{"why", "authority"})
		_, err := read(t, c.Authority)
		switch {
		case c.Unread != nil && !*c.Unread:
			t.Errorf("%s: a marker that says nothing", c.Why)
		case c.Unread != nil:
			unread++
			if err != nil {
				t.Errorf("%s: refused, though the service carries that part unread", c.Why)
			}
		case err == nil:
			t.Errorf("%s: read; Prima refuses it", c.Why)
		}
	}
	if unread == 0 {
		t.Error("no refused case is marked as carried unread")
	}
}

func TestEveryEgressReadsAsWritten(t *testing.T) {
	for _, raw := range wiretest.Cases(t, wire(t).Egress, 10) {
		var c struct {
			Why       string              `json:"why"`
			Authority json.RawMessage     `json:"authority"`
			Egress    map[string][]string `json:"egress"`
		}
		wiretest.Decode(t, raw, &c, []string{"why", "authority", "egress"}, "egress")
		a, err := read(t, c.Authority)
		if c.Egress == nil {
			if err == nil {
				t.Errorf("%s: read; Prima refuses it", c.Why)
			}
			continue
		}
		got := map[string][]string{"domains": a.Egress.Domains, "methods": a.Egress.Methods,
			"schemes": a.Egress.Schemes, "private_ips": a.Egress.PrivateIPs}
		for k, list := range got {
			if list == nil {
				got[k] = []string{}
			}
		}
		if err != nil || !reflect.DeepEqual(got, c.Egress) {
			t.Errorf("%s: %v, %v; want %v", c.Why, got, err, c.Egress)
		}
	}
}

// The relay's own checks of a runner's request against its edge and
// limits, as the Elixir service's Locus.Runtime.EdgeGuard makes them: an
// edge with no lists, or empty ones, allows nothing.
func TestTheRelaysChecksAreTheElixirServices(t *testing.T) {
	top := hostVectors(t)
	for _, raw := range wiretest.Cases(t, top.EdgeChecks, 13) {
		var c struct {
			Why           string          `json:"why"`
			Egress        json.RawMessage `json:"egress"`
			Method        string          `json:"method"`
			Scheme        string          `json:"scheme"`
			Host          string          `json:"host"`
			MethodAllowed bool            `json:"method_allowed"`
			SchemeAllowed bool            `json:"scheme_allowed"`
			DomainAllowed bool            `json:"domain_allowed"`
		}
		wiretest.Decode(t, raw, &c, []string{"why", "egress", "method", "scheme", "host", "method_allowed", "scheme_allowed", "domain_allowed"})
		egress, err := wirejson.Read(c.Egress)
		if err != nil {
			t.Fatal(err)
		}
		e, err := readEgress(map[string]any{"egress": egress})
		if err != nil {
			t.Fatalf("%s: %v", c.Why, err)
		}
		if e.AllowsMethod(c.Method) != c.MethodAllowed || e.AllowsScheme(c.Scheme) != c.SchemeAllowed ||
			e.AllowsDomain(c.Host) != c.DomainAllowed {
			t.Errorf("%s: method %v, scheme %v, domain %v", c.Why, e.AllowsMethod(c.Method), e.AllowsScheme(c.Scheme), e.AllowsDomain(c.Host))
		}
	}
	for _, raw := range wiretest.Cases(t, top.RequestSizes, 5) {
		var c struct {
			Why            string      `json:"why"`
			URL            string      `json:"url"`
			Headers        [][2]string `json:"headers"`
			Body           []byte      `json:"body_b64"`
			MaxRequestSize uint64      `json:"max_request_size"`
			Within         bool        `json:"within"`
		}
		wiretest.Decode(t, raw, &c, []string{"why", "url", "headers", "body_b64", "max_request_size", "within"})
		if within := RequestBytes(c.URL, c.Headers, c.Body) <= c.MaxRequestSize; within != c.Within {
			t.Errorf("%s: within %v", c.Why, within)
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

// A method and the edge's are compared upcased as Elixir upcases them, on
// every byte: an invalid byte kept, a special character as Elixir spells
// it (the review's 15 pairs among them).
func TestEveryMethodOfBytesIsAllowedAsTheElixirServiceAllowsIt(t *testing.T) {
	top := hostVectors(t)
	marked := 0
	for _, raw := range wiretest.Cases(t, top.MethodBytes, 15) {
		var c struct {
			Method  string `json:"method_hex"`
			Edge    string `json:"allowed_hex"`
			Allowed bool   `json:"allowed"`
			// Go is Go's own answer where it fails closed on bytes that
			// are no UTF-8 and Elixir matches them.
			Go *struct {
				Allowed bool `json:"allowed"`
			} `json:"go"`
		}
		wiretest.Decode(t, raw, &c, []string{"method_hex", "allowed_hex", "allowed"})
		method, edge := unhex(t, c.Method), unhex(t, c.Edge)
		want := c.Allowed
		if c.Go != nil {
			marked++
			if !c.Allowed || c.Go.Allowed || (utf8.ValidString(method) && utf8.ValidString(edge)) {
				t.Fatalf("%s against %s: a go marker is Go's refusal of bytes that are no UTF-8, which Elixir matches", c.Method, c.Edge)
			}
			want = false
		}
		e := Egress{Methods: []string{edge}}
		if got := e.AllowsMethod(method); got != want {
			t.Errorf("%s against %s: %v", c.Method, c.Edge, got)
		}
	}
	if marked == 0 {
		t.Error("no method is marked as Go's refusal")
	}
	special := map[rune]string{}
	for _, raw := range wiretest.Cases(t, top.UpcaseSpecial, 100) {
		var c struct {
			Char   string `json:"char_hex"`
			Upcase string `json:"upcase_hex"`
		}
		wiretest.Decode(t, raw, &c, []string{"char_hex", "upcase_hex"})
		r, _ := utf8.DecodeRuneInString(unhex(t, c.Char))
		special[r] = unhex(t, c.Upcase)
		if got := upcase(unhex(t, c.Char)); got != special[r] {
			t.Errorf("%s upcases to %x; Elixir's %s", c.Char, got, c.Upcase)
		}
	}
	if !reflect.DeepEqual(special, specialUpper) {
		t.Errorf("the package's special upcasing, %d characters, is not the vector's %d", len(specialUpper), len(special))
	}
}

// The zero Egress, and one of empty lists, allows nothing.
func TestAnEmptyEgressAllowsNothing(t *testing.T) {
	for _, e := range []Egress{{}, {Domains: []string{}, Methods: []string{}, Schemes: []string{}, PrivateIPs: []string{}}} {
		if e.AllowsDomain("a.test") || e.AllowsMethod("GET") || e.AllowsScheme("https") || e.AllowsMethod("") || e.AllowsScheme("") {
			t.Errorf("%+v allows", e)
		}
	}
	if a, err := Read(map[string]any{"cursor": "unbound"}); err != nil || a.Egress.AllowsDomain("a.test") || a.Limits != limits.Zero() {
		t.Errorf("an authority of no resources: %+v, %v", a, err)
	}
}
