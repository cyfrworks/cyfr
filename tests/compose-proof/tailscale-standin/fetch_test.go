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
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
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

	// Each tunnel to the node's address, as --connect asks for it.
	for reason, class := range map[string]string{
		// The node's netstack refused the port (gVisor's wording).
		"connect tcp 100.64.0.7:443: connection was refused": "refused",
		// The kernel's.
		"dial tcp 100.64.0.7:443: connect: connection refused": "refused",
		"dial tcp 100.64.0.7:443: i/o timeout":                 "proxy",
		"dial tcp 100.64.0.7:443: no route to host":            "proxy",
	} {
		proxy := proxyServer(t, func(string) *http.Response { return connectError(reason) })
		wantError(t, class, "--proxy", proxy, "--connect", "100.64.0.7:443", "https://node.proof.ts.net/")
	}
	unresolved := proxyServer(t, func(string) *http.Response {
		return connectError("dial tcp: lookup node.proof.ts.net on 100.100.100.100:53: no such host")
	})
	wantError(t, "dns", "--proxy", unresolved, "https://node.proof.ts.net/")
	// Two reasons, the refusal one of them, are not the proxy's one dial.
	twice := proxyServer(t, func(string) *http.Response {
		res := connectError("connect tcp 100.64.0.7:443: connection was refused")
		res.Header.Add("Tailscale-Connect-Error", "dial tcp 100.64.0.7:443: i/o timeout")
		return res
	})
	wantError(t, "proxy", "--proxy", twice, "--connect", "100.64.0.7:443", "https://node.proof.ts.net/")

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

// serveClosed is the real-tailnet run's serve_closed (tests/tailnet-real/
// run.sh) on fetch's two answers: nil where it reads Serve as closed.
func serveClosed(t *testing.T, control, target map[string]any) error {
	t.Helper()
	controlJSON, _ := json.Marshal(control)
	targetJSON, _ := json.Marshal(target)
	runSh, err := filepath.Abs(filepath.Join("..", "..", "tailnet-real", "run.sh"))
	if err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command("bash", "-c", `source "$1" && serve_closed "$2" "$3"`, "bash", runSh, string(controlJSON), string(targetJSON)).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, out)
	}
	return nil
}

// The proxy's resolver failed with a refusal of its own DNS server: the
// target's name did not resolve, which is no refusal of the target's, and
// the real-tailnet run reads no closed Serve from it beside an answering
// control through the same proxy.
func TestFetchNamesAResolverRefusalAtTheProxyDNS(t *testing.T) {
	control := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusForbidden) }))
	defer control.Close()
	controlAddr := strings.TrimPrefix(control.URL, "http://")
	reason := (&net.DNSError{Err: "read udp 172.18.0.2:45376->127.0.0.11:53: read: connection refused",
		Name: "node.proof.ts.net", Server: "127.0.0.11:53"}).Error()
	proxy := proxyServer(t, func(target string) *http.Response {
		switch target {
		case controlAddr:
			return nil
		case "100.64.0.7:443":
			return connectError("connect tcp 100.64.0.7:443: connection was refused")
		}
		return connectError(reason)
	})
	controlCode, controlAnswer := fetched(t, "--proxy", proxy, control.URL)
	if controlCode != 0 || controlAnswer["status"] != float64(http.StatusForbidden) {
		t.Fatalf("the numeric-IP control through the proxy: exit %d, %v; want its 403", controlCode, controlAnswer)
	}
	code, answer := fetched(t, "--proxy", proxy, "https://node.proof.ts.net/")
	if code != 1 || answer["error"] != "dns" {
		t.Errorf("the proxy's resolver failed, but fetch exited %d, %v; want error dns", code, answer)
	}
	if err := serveClosed(t, controlAnswer, answer); err == nil {
		t.Errorf("serve_closed read a closed Serve from a DNS failure beside the same proxy's answering control: %v", answer)
	}
	// The target's own refusal, through the same proxy, is a closed Serve.
	code, answer = fetched(t, "--proxy", proxy, "--connect", "100.64.0.7:443", "https://node.proof.ts.net/")
	if code != 1 || answer["error"] != "refused" {
		t.Fatalf("the target refused the tunnel, but fetch exited %d, %v; want error refused", code, answer)
	}
	if err := serveClosed(t, controlAnswer, answer); err != nil {
		t.Errorf("serve_closed did not read the target's refusal beside an answering control as closed: %v", err)
	}
}

// A refusal is the target's only where it names the very address the
// tunnel was asked for: another address's, another port's, or one named
// for a target the proxy had to resolve is no refusal of the target's.
func TestFetchNamesARefusalOfAnotherAddressNotRefused(t *testing.T) {
	for _, c := range []struct{ target, reason string }{
		{"100.64.0.7:443", "connect tcp 100.64.0.8:443: connection was refused"},
		{"100.64.0.7:443", "connect tcp 100.64.0.7:444: connection was refused"},
		{"100.64.0.7:443", "dial tcp 100.64.0.70:443: connect: connection refused"},
		{"100.64.0.7:443", "connect tcp 100.64.0.7:443: connection was refused by the resolver"},
		{"100.64.0.7:443", "lookup x: connect tcp 100.64.0.7:443: connection was refused"},
		{"node.proof.ts.net:443", "connect tcp 100.64.0.7:443: connection was refused"},
	} {
		proxy := proxyServer(t, func(string) *http.Response { return connectError(c.reason) })
		code, answer := fetched(t, "--proxy", proxy, "--connect", c.target, "https://node.proof.ts.net/")
		if code != 1 || answer["error"] == "refused" || answer["error"] == nil {
			t.Errorf("CONNECT %s answered %q: exit %d, %v; want an error other than refused", c.target, c.reason, code, answer)
		}
	}
	// A direct dial's refusal is the target's at the address dialed.
	wantError(t, "refused", "--connect", closedAddr(t), "https://node.proof.ts.net/")
}

// A direct dial's refusal is the target's only where the dial's own
// connect was refused at the port asked for, and at the address asked
// for where that is an address; a refusal reported any other way is no
// refusal of the target's.
func TestFetchReadsADialsRefusalOnlyAtTheAddressDialed(t *testing.T) {
	refusal := func(op string, syscallName string, port int) error {
		return &net.OpError{Op: op, Net: "tcp", Addr: &net.TCPAddr{IP: net.ParseIP("172.18.0.3"), Port: port},
			Err: os.NewSyscallError(syscallName, syscall.ECONNREFUSED)}
	}
	for _, c := range []struct {
		err  error
		addr string
		want bool
	}{
		{refusal("dial", "connect", 443), "172.18.0.3:443", true},
		{refusal("dial", "connect", 443), "tailscale:443", true},
		{refusal("dial", "connect", 443), "172.18.0.4:443", false},
		{refusal("dial", "connect", 443), "tailscale:4443", false},
		{refusal("dial", "connect", 443), "[::ffff:172.18.0.3]:443", true},
		{refusal("read", "connect", 443), "172.18.0.3:443", false},
		{refusal("dial", "read", 443), "172.18.0.3:443", false},
		{&net.OpError{Op: "dial", Net: "tcp", Err: &net.DNSError{Err: "read: connection refused", Name: "tailscale"}}, "tailscale:443", false},
	} {
		if got := dialRefused(c.err, c.addr); got != c.want {
			t.Errorf("dialRefused(%v, %q) = %v, want %v", c.err, c.addr, got, c.want)
		}
	}
	if pe := classify(refusal("read", "read", 443)); pe.class != "failed" {
		t.Errorf("a refusal outside the dial classified %q, want failed", pe.class)
	}
}
