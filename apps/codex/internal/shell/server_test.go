// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// The listener is literal loopback: an address, never a name.
func TestListen_IsLiteralLoopback(t *testing.T) {
	host, _, err := net.SplitHostPort(Listen)
	if ip := net.ParseIP(host); err != nil || ip == nil || !ip.IsLoopback() || ip.To4() == nil {
		t.Fatalf("Listen %q", Listen)
	}
}

// Every request names the listener exactly; every POST comes from the
// shell's own pages, or for Lock and Confirm alone from Prism; GETs only
// open the page; nothing answers a preflight or grants CORS; and every
// answer carries the pages' headers.
func TestServer_AdmitsOnlyTheShellsOwnRequests(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	prism := home.address()
	cases := []struct {
		name, method, host, path, origin string
		want                             int
	}{
		{"the page", "GET", Listen, "/", "", 200},
		{"another host name", "GET", "localhost:7340", "/", "", 421},
		{"a rebinding name", "GET", "evil.example:7340", "/", "", 421},
		{"no Origin", "POST", Listen, "/unlock", "", 403},
		{"an opaque Origin", "POST", Listen, "/unlock", "null", 403},
		{"an opaque Origin for Lock", "POST", Listen, "/lock", "null", 403},
		{"another Origin", "POST", Listen, "/unlock", "https://evil.example", 403},
		{"Prism's Origin for an unlock", "POST", Listen, "/unlock", prism, 403},
		{"Prism's Origin for a setup", "POST", Listen, "/setup", prism, 403},
		{"Prism's Origin for a decision", "POST", Listen, "/confirm/decide", prism, 403},
		{"Prism's Origin for Lock", "POST", Listen, "/lock", prism, 303},
		{"Confirm on this device, a navigation", "GET", Listen, "/confirm?ref=cnr_x", "", 200},
		{"Confirm by POST", "POST", Listen, "/confirm", prism, 404},
		{"a lock by GET", "GET", Listen, "/lock", "", 404},
		{"a preflight", "OPTIONS", Listen, "/lock", prism, 404},
		{"an unknown path", "POST", Listen, "/sign", Origin, 404},
	}
	for _, c := range cases {
		req := httptest.NewRequest(c.method, "http://"+c.host+c.path, strings.NewReader(url.Values{"x": {"y"}}.Encode()))
		req.Host = c.host
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		if c.origin != "" {
			req.Header.Set("Origin", c.origin)
		}
		w := httptest.NewRecorder()
		b.srv.ServeHTTP(w, req)
		if w.Code != c.want {
			t.Errorf("%s: %d, want %d", c.name, w.Code, c.want)
		}
		h := w.Header()
		csp := h.Get("Content-Security-Policy")
		if h.Get("Cache-Control") != "no-store" || h.Get("Referrer-Policy") != "same-origin" || h.Get("X-Frame-Options") != "DENY" ||
			!strings.Contains(csp, "frame-ancestors 'none'") || !strings.Contains(csp, "default-src 'none'") ||
			!strings.Contains(csp, "form-action 'self' "+prism+";") || strings.Contains(csp, "unsafe") {
			t.Errorf("%s: headers %v", c.name, h)
		}
		for k := range h {
			if strings.HasPrefix(k, "Access-Control-") {
				t.Errorf("%s: answers %s", c.name, k)
			}
		}
	}
}

// A POST whose body is not a form, or names a field twice, is refused
// before it reaches the shell.
func TestServer_RefusesWhatIsNotAForm(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	for name, req := range map[string]*http.Request{
		"JSON":      httptest.NewRequest("POST", "http://"+Listen+"/unlock", strings.NewReader(`{"secret":"1"}`)),
		"twice":     httptest.NewRequest("POST", "http://"+Listen+"/unlock", strings.NewReader("secret=1&secret=2")),
		"bad quote": httptest.NewRequest("POST", "http://"+Listen+"/unlock", strings.NewReader("secret=%zz")),
	} {
		req.Header.Set("Origin", Origin)
		if name != "JSON" {
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		} else {
			req.Header.Set("Content-Type", "application/json")
		}
		w := httptest.NewRecorder()
		b.srv.ServeHTTP(w, req)
		if w.Code < 400 {
			t.Errorf("%s: %d", name, w.Code)
		}
	}
}

// The pages run only the two scripts their policy hashes.
func TestPages_RunOnlyTheHashedScripts(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	b.setUp("alice")
	page := b.do(http.MethodGet, "/", "", nil)
	if !strings.Contains(page.Body.String(), "<script>"+printScript+"</script>") {
		t.Fatal("the recovery page's script is not the hashed one")
	}
	if n := strings.Count(page.Body.String(), "<script"); n != 1 {
		t.Fatalf("%d scripts", n)
	}
	if !strings.Contains(page.Body.String(), "<style>"+style+"</style>") {
		t.Fatal("the style is not the hashed one")
	}
}

// The shell's origin and Prism's two entries into it are the fixture's
// exchange.shell: Lock a POST with no form, Confirm a navigation naming
// its ref.
func TestServer_EntriesAreTheFixtures(t *testing.T) {
	var v struct {
		Exchange struct {
			Shell struct {
				Origin string `json:"origin"`
				Lock   struct {
					Method, Path string
					Form         []string
				} `json:"lock"`
				Confirm struct {
					Method, Path, Target string
					Query                []string
				} `json:"confirm"`
			} `json:"shell"`
		} `json:"exchange"`
	}
	fixture(t, "device_unlock.json", &v)
	sh := v.Exchange.Shell
	if sh.Origin != Origin || sh.Lock.Method != "POST" || sh.Lock.Path != "/lock" || len(sh.Lock.Form) != 0 ||
		sh.Confirm.Method != "GET" || sh.Confirm.Path != "/confirm" || len(sh.Confirm.Query) != 1 || sh.Confirm.Query[0] != "ref" {
		t.Fatalf("the fixture's shell %+v, the shell's origin %s", sh, Origin)
	}
	if _, ok := actions[sh.Lock.Path]; !ok || !actions[sh.Lock.Path].prism {
		t.Fatal("Prism cannot post the fixture's Lock")
	}
}
