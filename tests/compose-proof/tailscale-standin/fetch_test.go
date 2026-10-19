// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package main

import (
	"bufio"
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fetched is fetchMain's answer to args: its exit and the JSON it printed.
func fetched(t *testing.T, args ...string) (int, map[string]any) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	code := fetchMain(args, &stdout, &stderr)
	var answer map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(stdout.Bytes()), &answer); err != nil {
		t.Fatalf("fetch %v printed no JSON (exit %d): %q %q", args, code, stdout.String(), stderr.String())
	}
	return code, answer
}

// wantError holds a failed fetch to the error class it names.
func wantError(t *testing.T, class string, args ...string) {
	t.Helper()
	code, answer := fetched(t, args...)
	if code != 1 || answer["error"] != class {
		t.Fatalf("fetch %v: exit %d, %v; want error %q", args, code, answer, class)
	}
}

// closedAddr is a loopback address nothing listens on.
func closedAddr(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	l.Close()
	return addr
}

func TestFetchNamesATargetsRefusalRefused(t *testing.T) {
	wantError(t, "refused", "--connect", closedAddr(t), "http://node.proof.ts.net/")
}

func TestFetchNamesAnUntrustedCertificateTLS(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer server.Close()
	// An authority of its own, which did not sign the server's certificate.
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "another authority"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageCertSign}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	ca := filepath.Join(t.TempDir(), "ca.pem")
	if err := os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	wantError(t, "tls", "--ca", ca, "--connect", strings.TrimPrefix(server.URL, "https://"), "https://example.com/")
}

func TestFetchNamesAServerThatAnswersNoHandshakeTLS(t *testing.T) {
	// A listener that answers the handshake with no TLS record.
	plain := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer plain.Close()
	wantError(t, "tls", "--connect", strings.TrimPrefix(plain.URL, "http://"), "https://example.com/")
}

// A server name Serve has no web handler for: its TLS server answers the
// handshake with an alert, as the stand-in's does.
func TestFetchNamesAHandshakeTheServerRefusedTLS(t *testing.T) {
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	server.TLS = &tls.Config{GetCertificate: func(*tls.ClientHelloInfo) (*tls.Certificate, error) {
		return nil, errors.New("no certificate for that name")
	}}
	server.StartTLS()
	defer server.Close()
	wantError(t, "tls", "--connect", strings.TrimPrefix(server.URL, "https://"), "https://example.com/")
}

func TestFetchNamesAnUnresolvedNameDNS(t *testing.T) {
	wantError(t, "dns", "http://no-such-host.invalid/")
}

// proxyServer is an HTTP proxy that answers each CONNECT with answer:
// a nil answer tunnels to the request's target as tailscaled's does.
func proxyServer(t *testing.T, answer func(target string) *http.Response) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			conn, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				req, err := http.ReadRequest(bufio.NewReader(conn))
				if err != nil || req.Method != http.MethodConnect {
					return
				}
				if res := answer(req.Host); res != nil {
					res.Write(conn)
					return
				}
				back, err := net.Dial("tcp", req.Host)
				if err != nil {
					return
				}
				defer back.Close()
				io.WriteString(conn, "HTTP/1.1 200 OK\r\n\r\n")
				go io.Copy(back, conn)
				io.Copy(conn, back)
			}()
		}
	}()
	return "http://" + l.Addr().String()
}

// connectError is tailscaled's answer to a CONNECT whose dial failed
// (cmd/tailscaled/proxy.go): 500, the error in Tailscale-Connect-Error
// and as the body.
func connectError(reason string) *http.Response {
	return &http.Response{
		StatusCode: http.StatusInternalServerError, ProtoMajor: 1, ProtoMinor: 1,
		Header: http.Header{"Tailscale-Connect-Error": {reason}, "Content-Type": {"text/plain; charset=utf-8"}},
		Body:   io.NopCloser(strings.NewReader(reason + "\n")), ContentLength: int64(len(reason) + 1),
	}
}

func TestFetchThroughAProxyTunnelsAndNamesWhatFailed(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "%s %s", r.Host, r.URL.Path)
	}))
	defer backend.Close()
	target := strings.TrimPrefix(backend.URL, "http://")

	tunnels := proxyServer(t, func(string) *http.Response { return nil })
	code, answer := fetched(t, "--proxy", tunnels, "http://"+target+"/through")
	if code != 0 || answer["status"] != float64(200) || answer["body"] != target+" /through" {
		t.Fatalf("through a tunnel: exit %d, %v", code, answer)
	}

	for reason, class := range map[string]string{
		// The node's netstack refused the port (gVisor's wording).
		"connect tcp 100.64.0.7:443: connection was refused": "refused",
		// The kernel's.
		"dial tcp 100.64.0.7:443: connect: connection refused":                   "refused",
		"dial tcp: lookup node.proof.ts.net on 100.100.100.100:53: no such host": "dns",
		"dial tcp 100.64.0.7:443: i/o timeout":                                   "proxy",
		"dial tcp 100.64.0.7:443: no route to host":                              "proxy",
	} {
		proxy := proxyServer(t, func(string) *http.Response { return connectError(reason) })
		wantError(t, class, "--proxy", proxy, "https://node.proof.ts.net/")
	}

	// A proxy that refuses the tunnel itself, or whose 500 names no dial,
	// failed: it is no answer of the target's.
	forbidden := proxyServer(t, func(string) *http.Response {
		return &http.Response{StatusCode: http.StatusForbidden, ProtoMajor: 1, ProtoMinor: 1, Header: http.Header{}, Body: http.NoBody}
	})
	wantError(t, "proxy", "--proxy", forbidden, "https://node.proof.ts.net/")
	bare := proxyServer(t, func(string) *http.Response {
		return &http.Response{StatusCode: http.StatusInternalServerError, ProtoMajor: 1, ProtoMinor: 1, Header: http.Header{},
			Body: io.NopCloser(strings.NewReader("connection refused")), ContentLength: 18}
	})
	wantError(t, "proxy", "--proxy", bare, "https://node.proof.ts.net/")
	wantError(t, "proxy", "--proxy", "http://"+closedAddr(t), "https://node.proof.ts.net/")
}
