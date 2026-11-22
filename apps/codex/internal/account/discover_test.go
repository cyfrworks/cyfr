// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package account

import (
	"context"
	"errors"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
)

type loginDirectory struct {
	Path      string `json:"path"`
	Attribute string `json:"attribute"`
	Pages     []struct {
		Name      string `json:"name"`
		HTML      string `json:"html"`
		Directory string `json:"directory"`
		Origin    string `json:"origin"`
		Refused   string `json:"refused"`
	} `json:"pages"`
}

func TestDirectoryVectors(t *testing.T) {
	var v loginDirectory
	fixture(t, "login_directory.json", &v)
	if v.Attribute != directoryAttribute || v.Path != "/login" {
		t.Fatalf("the vector names %s on %s; the reader reads %s on /login", v.Attribute, v.Path, directoryAttribute)
	}
	refusals := map[string]error{
		"missing": errDirectoryMissing, "duplicate": errDirectoryDuplicate, "invalid": errDirectoryInvalid,
	}
	for _, p := range v.Pages {
		t.Run(p.Name, func(t *testing.T) {
			got, err := readDirectory([]byte(p.HTML))
			if p.Refused != "" {
				want, ok := refusals[p.Refused]
				if !ok {
					t.Fatalf("unknown refusal %q", p.Refused)
				}
				if !errors.Is(err, want) {
					t.Fatalf("got %+v, %v; want refused %s", got, err, p.Refused)
				}
				return
			}
			want := Discovered{Directory: p.Directory, Origin: p.Origin}
			if err != nil || got != want {
				t.Fatalf("got %+v, %v; want %+v", got, err, want)
			}
		})
	}
}

const page = `<div data-account-directory="https://accounts.example.com/cyfr"></div>`

func TestDiscoverReadsTheSignInPageWithoutCredentials(t *testing.T) {
	var cookie atomic.Value
	cookie.Store("")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cookie.Store(r.Header.Get("Cookie") + r.Header.Get("Authorization"))
		if r.URL.Path != "/login" || r.Method != http.MethodGet {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(page))
	}))
	defer srv.Close()
	jar, _ := cookiejar.New(nil)
	u, _ := url.Parse(srv.URL)
	jar.SetCookies(u, []*http.Cookie{{Name: "_cyfr_key", Value: "session"}})

	got, err := Discover(context.Background(), &http.Client{Jar: jar}, srv.URL)
	want := Discovered{Directory: "https://accounts.example.com/cyfr", Origin: "https://accounts.example.com"}
	if err != nil || got != want {
		t.Fatalf("got %+v, %v; want %+v", got, err, want)
	}
	if c := cookie.Load().(string); c != "" {
		t.Fatalf("the read carried a credential: %q", c)
	}
}

func TestDiscoverRefuses(t *testing.T) {
	var followed atomic.Bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/elsewhere":
			followed.Store(true)
			_, _ = w.Write([]byte(page))
		case r.Host == "redirect":
			http.Redirect(w, r, "/elsewhere", http.StatusFound)
		case r.Host == "error":
			http.Error(w, page, http.StatusServiceUnavailable)
		case r.Host == "large":
			_, _ = w.Write([]byte(page + strings.Repeat(" ", maxLoginPage)))
		case r.Host == "none":
			_, _ = w.Write([]byte(`<div></div>`))
		}
	}))
	defer srv.Close()
	for _, host := range []string{"redirect", "error", "large", "none"} {
		t.Run(host, func(t *testing.T) {
			client := &http.Client{Transport: hostRewriter{host: host}}
			got, err := Discover(context.Background(), client, srv.URL)
			if err == nil {
				t.Fatalf("got %+v; want a refusal", got)
			}
		})
	}
	if followed.Load() {
		t.Fatal("a redirect was followed")
	}
	if _, err := Discover(context.Background(), nil, srv.URL+"/login"); err == nil {
		t.Fatal("an address with a path was read")
	}
}

// hostRewriter sends each request with host as its Host, so one server
// answers each case by name.
type hostRewriter struct{ host string }

func (h hostRewriter) RoundTrip(r *http.Request) (*http.Response, error) {
	r = r.Clone(r.Context())
	r.Host = h.host
	return http.DefaultTransport.RoundTrip(r)
}

// The app takes a CYFR's account service by one rule, which its main
// process holds too (desktop/test/policy.test.mjs).
func TestAccountServiceVectors(t *testing.T) {
	var v struct {
		Services []struct {
			Name     string `json:"name"`
			Home     string `json:"home"`
			Account  string `json:"account"`
			Accepted bool   `json:"accepted"`
		} `json:"account_services"`
	}
	fixture(t, "desktop-process.json", &v)
	if len(v.Services) == 0 {
		t.Fatal("the fixture names no account service")
	}
	for _, s := range v.Services {
		t.Run(s.Name, func(t *testing.T) {
			got, ok := ServiceOf(s.Home, s.Account)
			if ok != s.Accepted || ok && (got.Directory != s.Account || got.Origin != s.Account) {
				t.Fatalf("got %+v, %v; want accepted %v", got, ok, s.Accepted)
			}
		})
	}
	if got, ok := ServiceOf("http://localhost:4000", "http://localhost:4000/accounts"); !ok || got.Origin != "http://localhost:4000" {
		t.Fatalf("a local CYFR's own directory under a path: %+v, %v", got, ok)
	}
}

// An address has the one grammar every side reads: whether it names a
// CYFR, whether it is a directory URL, and the one spelling of one a
// setting or a person wrote another way.
func TestAddressVectors(t *testing.T) {
	var v struct {
		Addresses []struct {
			Name      string `json:"name"`
			Value     string `json:"value"`
			Home      bool   `json:"home"`
			Directory bool   `json:"directory"`
			Spelled   string `json:"spelled"`
		} `json:"addresses"`
	}
	fixture(t, "addresses.json", &v)
	if len(v.Addresses) == 0 {
		t.Fatal("the fixture holds no address")
	}
	for _, a := range v.Addresses {
		t.Run(a.Name, func(t *testing.T) {
			if got := IsHome(a.Value); got != a.Home {
				t.Errorf("%q names a CYFR: %v", a.Value, got)
			}
			if got := IsDirectoryURL(a.Value); got != a.Directory {
				t.Errorf("%q is a directory URL: %v", a.Value, got)
			}
			if got, ok := CanonicalHome(a.Value); ok != (a.Spelled != "") || ok && got != a.Spelled {
				t.Errorf("%q is spelled %q, %v; want %q", a.Value, got, ok, a.Spelled)
			}
		})
	}
	// No case mapping beyond ASCII makes a host (the Kelvin sign to k).
	if got, ok := CanonicalHome("http://\u212ayfr.example.com"); ok {
		t.Errorf("a Unicode host was spelled %q", got)
	}
}
