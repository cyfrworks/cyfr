// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package main

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// recorder is an upstream that keeps the last request's Host and headers.
type recorder struct {
	host    string
	headers http.Header
}

func (rec *recorder) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	rec.host, rec.headers = r.Host, r.Header.Clone()
	io.WriteString(w, "upstream")
}

// forged is every header a client sends that Serve replaces or drops.
var forged = map[string]string{
	"X-Forwarded-For":            "203.0.113.9",
	"X-Forwarded-Proto":          "http",
	"X-Forwarded-Host":           "evil.example",
	"Forwarded":                  "for=198.51.100.1;proto=http",
	"Tailscale-User-Login":       "admin@evil.example",
	"Tailscale-User-Name":        "Forged",
	"Tailscale-User-Profile-Pic": "https://evil.example/p.png",
	"Tailscale-Funnel-Request":   "?1",
	"Tailscale-Headers-Info":     "forged",
	"Tailscale-App-Capabilities": `{"forged":[]}`,
	"Tailscale-User-Other":       "passes",
}

// through sends one request with every forged header, as Host
// cyfr.proof.ts.net, over TLS to Serve's reverse proxy in front of rec,
// with whois naming the peer.
func through(t *testing.T, whois func(netip.Addr) *person) *recorder {
	t.Helper()
	rec := &recorder{}
	upstream := httptest.NewServer(rec)
	defer upstream.Close()
	target, err := url.Parse(upstream.URL)
	if err != nil {
		t.Fatal(err)
	}
	front := httptest.NewTLSServer(reverseProxy(target, whois))
	defer front.Close()
	req, err := http.NewRequest(http.MethodGet, front.URL+"/probe?q=1", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Host = "cyfr.proof.ts.net"
	for name, value := range forged {
		req.Header.Set(name, value)
	}
	res, err := front.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if body, _ := io.ReadAll(res.Body); res.StatusCode != 200 || string(body) != "upstream" {
		t.Fatalf("through Serve: %d %q, want the upstream's 200", res.StatusCode, body)
	}
	return rec
}

func want(t *testing.T, h http.Header, name string, values ...string) {
	t.Helper()
	got := h.Values(name)
	if strings.Join(got, "\x00") != strings.Join(values, "\x00") {
		t.Errorf("%s reached the upstream as %q, want %q", name, got, values)
	}
}

func TestServeForwardsAsThePinnedImage(t *testing.T) {
	user := &person{Login: "person@proof.example", Name: "Proof Person", ProfilePic: "https://proof.example/p.png"}
	rec := through(t, func(netip.Addr) *person { return user })

	if rec.host != "cyfr.proof.ts.net" {
		t.Errorf("Host reached the upstream as %q, want the client's cyfr.proof.ts.net", rec.host)
	}
	want(t, rec.headers, "X-Forwarded-For", "127.0.0.1")
	want(t, rec.headers, "X-Forwarded-Proto", "https")
	want(t, rec.headers, "X-Forwarded-Host", "cyfr.proof.ts.net")
	want(t, rec.headers, "Forwarded")
	want(t, rec.headers, "Tailscale-User-Login", "person@proof.example")
	want(t, rec.headers, "Tailscale-User-Name", "Proof Person")
	want(t, rec.headers, "Tailscale-User-Profile-Pic", "https://proof.example/p.png")
	want(t, rec.headers, "Tailscale-Headers-Info", "https://tailscale.com/s/serve-headers")
	want(t, rec.headers, "Tailscale-Funnel-Request")
	want(t, rec.headers, "Tailscale-App-Capabilities")
	// serve.go deletes three Tailscale-User-* names, not the prefix.
	want(t, rec.headers, "Tailscale-User-Other", "passes")
}

func TestServeSetsNoIdentityForATaggedPeer(t *testing.T) {
	rec := through(t, func(netip.Addr) *person { return nil })
	for _, name := range []string{"Tailscale-User-Login", "Tailscale-User-Name", "Tailscale-User-Profile-Pic", "Tailscale-Headers-Info", "Tailscale-Funnel-Request"} {
		want(t, rec.headers, name)
	}
}

func TestIdentityHeaderValuesAreEncodedAsServeEncodesThem(t *testing.T) {
	if got := encTailscaleHeaderValue("Zoë"); got != "=?utf-8?q?Zo=C3=AB?=" {
		t.Errorf("a non-ASCII name is %q", got)
	}
	if got := encTailscaleHeaderValue("ascii"); got != "ascii" {
		t.Errorf("an ASCII name is %q", got)
	}
	if got := encTailscaleHeaderValue("\xff"); got != "" {
		t.Errorf("invalid UTF-8 is %q, want empty", got)
	}
}

func TestStatusIsTheRunningNodesOwn(t *testing.T) {
	n := fresh("cyfr")
	n.login("", "nAbC123CNTRL", "100.64.0.7")
	s := statusOf(n)
	if s.BackendState != "Running" || s.Self.ID != "nAbC123CNTRL" || s.Self.DNSName != "cyfr.proof.ts.net." || s.AuthURL != "" {
		t.Errorf("a Running node's status is %+v %+v", s, s.Self)
	}
	if strings.Join(s.Self.PeerAPIURL, ",") != "http://100.64.0.7:5252" {
		t.Errorf("a Running node's PeerAPI URLs are %q, want its address's", s.Self.PeerAPIURL)
	}
	if strings.Join(s.CertDomains, ",") != "cyfr.proof.ts.net" {
		t.Errorf("with HTTPS on the certificate domains are %q, want the node's name without the dot", s.CertDomains)
	}
	n.HTTPS = false
	if s := statusOf(n); s.CertDomains != nil {
		t.Errorf("with HTTPS off the certificate domains are %q, want none", s.CertDomains)
	}
	waiting := statusOf(fresh("cyfr"))
	if waiting.BackendState != "NeedsLogin" || !strings.HasPrefix(waiting.AuthURL, "https://login.proof.ts.net/a/") || waiting.Self.ID != "" || waiting.CertDomains != nil || waiting.Self.PeerAPIURL != nil {
		t.Errorf("a machine waiting for its login reports %+v %+v", waiting, waiting.Self)
	}
	data, err := json.Marshal(s)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{`"BackendState":`, `"Self":`, `"DNSName":`, `"ID":`, `"CertDomains":`, `"AuthURL":`} {
		if !strings.Contains(string(data), field) {
			t.Errorf("the status JSON has no %s field: %s", field, data)
		}
	}
}

// serving is a Running node's state directory, with HTTPS as https and
// the serve configuration held, and a serve file path in it.
func serving(t *testing.T, https bool, held string) (dir, serveFile string) {
	t.Helper()
	dir = t.TempDir()
	n := fresh("cyfr")
	n.login("", "", "")
	n.HTTPS = https
	if held != "" {
		n.Serve = json.RawMessage(held)
	}
	if err := writeSynced(statePath(dir), mustJSON(n), 0o600); err != nil {
		t.Fatal(err)
	}
	return dir, filepath.Join(dir, "serve.json")
}

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

// config is CYFR's serve configuration on port, proxying to target.
func config(port int, target string) string {
	return fmt.Sprintf(`{"TCP":{"%d":{"HTTPS":true}},"Web":{"${TS_CERT_DOMAIN}:%d":{"Handlers":{"/":{"Proxy":%q}}}}}`, port, port, target)
}

func listening(port int) bool {
	conn, err := net.DialTimeout("tcp", "127.0.0.1:"+strconv.Itoa(port), 500*time.Millisecond)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

func write(t *testing.T, path, text string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func watched(t *testing.T, s *server, serveFile string) {
	t.Helper()
	if err := s.watch(serveFile); err != nil {
		t.Fatal(err)
	}
}

// get asks Serve on port for /health as server name name, trusting the
// stand-in's authority alone.
func get(dir string, port int, name string) (int, error) {
	pool := x509.NewCertPool()
	caPEM, err := authorityPEM(dir)
	if err != nil {
		return 0, err
	}
	pool.AppendCertsFromPEM(caPEM)
	client := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{
		TLSClientConfig: &tls.Config{RootCAs: pool, ServerName: name},
	}}
	res, err := client.Get("https://127.0.0.1:" + strconv.Itoa(port) + "/health")
	if err != nil {
		return 0, err
	}
	res.Body.Close()
	return res.StatusCode, nil
}

func quiet(string, ...any) {}

func TestServeFollowsTheFileAsContainerbootDoes(t *testing.T) {
	upstream := httptest.NewServer(&recorder{})
	defer upstream.Close()
	port := freePort(t)
	dir, serveFile := serving(t, true, "")
	s, err := startServe(dir, quiet)
	if err != nil {
		t.Fatal(err)
	}
	defer s.close()

	watched(t, s, serveFile)
	if listening(port) {
		t.Fatal("with no serve file, Serve listens")
	}
	write(t, serveFile, "{}")
	watched(t, s, serveFile)
	if listening(port) {
		t.Fatal("under {}, Serve listens")
	}

	write(t, serveFile, config(port, upstream.URL))
	watched(t, s, serveFile)
	if status, err := get(dir, port, "cyfr.proof.ts.net"); err != nil || status != 200 {
		t.Fatalf("under the configuration, the node's name answers %d %v, want the upstream's 200", status, err)
	}
	if _, err := get(dir, port, "other.proof.ts.net"); err == nil {
		t.Error("a server name with no web handler got a certificate")
	}

	// An empty file is skipped, so Serve stays as it was.
	write(t, serveFile, "")
	watched(t, s, serveFile)
	if !listening(port) {
		t.Error("an empty serve file closed Serve; containerboot skips one")
	}

	write(t, serveFile, "{}")
	watched(t, s, serveFile)
	if listening(port) {
		t.Fatal("after {}, Serve still listens")
	}
	if n, _, _ := load(dir); strings.TrimSpace(string(n.Serve)) != "{}" {
		t.Errorf("after {}, tailscaled holds %s", n.Serve)
	}
}

func TestServeOpensNoHTTPSWithoutACertificateDomain(t *testing.T) {
	upstream := httptest.NewServer(&recorder{})
	defer upstream.Close()
	port := freePort(t)
	dir, serveFile := serving(t, false, "")
	s, err := startServe(dir, quiet)
	if err != nil {
		t.Fatal(err)
	}
	defer s.close()

	write(t, serveFile, config(port, upstream.URL))
	watched(t, s, serveFile)
	if listening(port) {
		t.Fatal("with HTTPS off for the tailnet, the HTTPS configuration was applied")
	}

	if _, err := update(dir, func(n *node, _ bool) (bool, error) { n.HTTPS = true; return true, nil }); err != nil {
		t.Fatal(err)
	}
	watched(t, s, serveFile)
	if status, err := get(dir, port, "cyfr.proof.ts.net"); err != nil || status != 200 {
		t.Fatalf("once HTTPS is on, the node's name answers %d %v, want 200", status, err)
	}
}

func TestBootUnsetsTheConfigurationAPreviousRunLeft(t *testing.T) {
	upstream := httptest.NewServer(&recorder{})
	defer upstream.Close()
	port := freePort(t)
	held := strings.ReplaceAll(config(port, upstream.URL), "${TS_CERT_DOMAIN}", "cyfr.proof.ts.net")
	dir, serveFile := serving(t, true, held)
	s, err := startServe(dir, quiet)
	if err != nil {
		t.Fatal(err)
	}
	defer s.close()
	watched(t, s, serveFile)
	if listening(port) {
		t.Fatal("with no serve file, the configuration the state held still serves")
	}
}

func TestAFieldTheStandInDoesNotEmulateFailsTheRead(t *testing.T) {
	if _, err := parseServeConfig([]byte(`{"AllowFunnel":{"cyfr.proof.ts.net:443":true}}`)); err == nil {
		t.Error("a Funnel configuration was read as one the stand-in emulates")
	}
	if _, err := parseServeConfig([]byte(`{"TCP":{"443":{"TCPForward":"cyfr:80"}}}`)); err == nil {
		t.Error("a TCP forward was read as one the stand-in emulates")
	}
}

func TestEveryMutationIsNamed(t *testing.T) {
	seen := map[string]bool{}
	for _, m := range mutations {
		if m == "" || seen[m] {
			t.Errorf("the mutation %q is empty or listed twice", m)
		}
		seen[m] = true
	}
	if mutation != "" && !seen[mutation] {
		t.Errorf("this build's mutation %q is not listed", mutation)
	}
}
