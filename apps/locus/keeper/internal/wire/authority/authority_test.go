// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package authority

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/cyfr/locus/keeper/internal/wire/limits"
	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
)

type vectors struct {
	Version int `json:"version"`
	Read    []struct {
		Why       string          `json:"why"`
		Authority json.RawMessage `json:"authority"`
		Limits    struct {
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
		} `json:"limits"`
	} `json:"read"`
	Refused []struct {
		Why       string          `json:"why"`
		Authority json.RawMessage `json:"authority"`
		Unread    bool            `json:"unread_by_service"`
	} `json:"refused"`
	Egress []struct {
		Why       string              `json:"why"`
		Authority json.RawMessage     `json:"authority"`
		Egress    map[string][]string `json:"egress"`
	} `json:"egress"`
}

func load(t *testing.T) vectors {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "tests", "fixtures", "authority_wire.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v vectors
	if err := json.Unmarshal(data, &v); err != nil || v.Version != 1 {
		t.Fatalf("the vector file: %v", err)
	}
	return v
}

func read(t *testing.T, raw json.RawMessage) (Authority, error) {
	t.Helper()
	decoded, err := wirejson.Read(raw)
	if err != nil {
		t.Fatal(err)
	}
	return Read(decoded)
}

// Every authority reads to the limits its cursor stands on, and every one
// Prima refuses in a part the service reads is refused; one refused in a
// part the service carries unread is read.
func TestEveryAuthorityReadsAsPrimaReadsItsParts(t *testing.T) {
	v := load(t)
	if len(v.Read) < 10 || len(v.Refused) < 20 {
		t.Fatalf("%d read, %d refused", len(v.Read), len(v.Refused))
	}
	for _, c := range v.Read {
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
	for _, c := range v.Refused {
		_, err := read(t, c.Authority)
		switch {
		case c.Unread:
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
	v := load(t)
	if len(v.Egress) < 10 {
		t.Fatalf("%d egress cases", len(v.Egress))
	}
	for _, c := range v.Egress {
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
// limits, as the Elixir service's Locus.Runtime.EdgeGuard makes them.
func TestTheRelaysChecksAreTheElixirServices(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "tests", "fixtures", "host_api.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		EdgeChecks []struct {
			Why           string          `json:"why"`
			Egress        json.RawMessage `json:"egress"`
			Method        string          `json:"method"`
			Scheme        string          `json:"scheme"`
			Host          string          `json:"host"`
			MethodAllowed bool            `json:"method_allowed"`
			SchemeAllowed bool            `json:"scheme_allowed"`
			DomainAllowed bool            `json:"domain_allowed"`
		} `json:"edge_checks"`
		RequestSizes []struct {
			Why            string      `json:"why"`
			URL            string      `json:"url"`
			Headers        [][2]string `json:"headers"`
			Body           []byte      `json:"body_b64"`
			MaxRequestSize uint64      `json:"max_request_size"`
			Within         bool        `json:"within"`
		} `json:"request_sizes"`
	}
	if err := json.Unmarshal(data, &v); err != nil || len(v.EdgeChecks) < 10 || len(v.RequestSizes) < 5 {
		t.Fatalf("the vector file: %v", err)
	}
	for _, c := range v.EdgeChecks {
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
	for _, c := range v.RequestSizes {
		if within := RequestBytes(c.URL, c.Headers, c.Body) <= c.MaxRequestSize; within != c.Within {
			t.Errorf("%s: within %v", c.Why, within)
		}
	}
}
