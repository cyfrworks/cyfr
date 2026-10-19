// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"syscall"
	"time"
)

// headerFlags is a repeated --header "Name: value".
type headerFlags []string

func (h *headerFlags) String() string     { return strings.Join(*h, ", ") }
func (h *headerFlags) Set(v string) error { *h = append(*h, v); return nil }

// fetchMain is `standin fetch`, the proofs' client of Serve: one request to
// URL, its TLS server name the URL's host, connecting to --connect when
// given (as curl's --resolve), trusting only --ca, with --host as the Host
// header, each --header sent as given and --body as the body, through the
// HTTP proxy --proxy names when given, which every request reaches by a
// CONNECT tunnel of fetch's own. It prints {status, headers, body} as JSON
// and exits 0 on any answer, a protocol switch's (101) without reading past
// its headers, or prints {error, detail} and exits 1, the error saying what
// failed (probeError):
//
//	refused  the target itself refused the connection: a direct dial's
//	         ECONNREFUSED, or, through the proxy, its CONNECT answered 500
//	         with a Tailscale-Connect-Error naming a refused connection,
//	         as tailscaled's outbound HTTP proxy (cmd/tailscaled/proxy.go)
//	         reports the dial it made for the tunnel
//	dns      the target's name did not resolve, here or at the proxy
//	tls      the TLS handshake with the target failed or its certificate
//	         was not trusted
//	proxy    the proxy could not be reached, or refused or failed the
//	         tunnel for any other reason
//	timeout  no answer within the deadline
//	failed   anything else
//
// so a probe that failed is never read as the target's refusal.
func fetchMain(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("fetch", flag.ContinueOnError)
	flags.SetOutput(stderr)
	ca := flags.String("ca", "", "the PEM authority to trust, alone")
	connect := flags.String("connect", "", "host:port to connect to in place of the URL's")
	host := flags.String("host", "", "the Host header")
	method := flags.String("method", http.MethodGet, "the request method")
	body := flags.String("body", "", "the request body")
	proxy := flags.String("proxy", "", "an HTTP proxy to send the request through")
	var headers headerFlags
	flags.Var(&headers, "header", `a header to send, "Name: value"; repeatable`)
	if err := flags.Parse(args); err != nil || flags.NArg() != 1 {
		fmt.Fprintln(stderr, "usage: standin fetch [--ca FILE] [--connect HOST:PORT | --proxy URL] [--host H] [--method M] [--header 'N: V']... [--body B] URL")
		return 64
	}
	var payload io.Reader
	if *body != "" {
		payload = strings.NewReader(*body)
	}
	req, err := http.NewRequest(*method, flags.Arg(0), payload)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 64
	}
	for _, h := range headers {
		name, value, ok := strings.Cut(h, ":")
		if !ok {
			fmt.Fprintf(stderr, "a header is Name: value, not %q\n", h)
			return 64
		}
		req.Header.Add(strings.TrimSpace(name), strings.TrimSpace(value))
	}
	if *host != "" {
		req.Host = *host
	}
	tlsConfig := &tls.Config{ServerName: req.URL.Hostname()}
	if *ca != "" {
		pemBytes, err := os.ReadFile(*ca)
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 64
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pemBytes) {
			fmt.Fprintf(stderr, "%s holds no certificate\n", *ca)
			return 64
		}
		tlsConfig.RootCAs = pool
	}
	var proxyAddr string
	if *proxy != "" {
		proxyURL, err := url.Parse(*proxy)
		if err != nil || proxyURL.Scheme != "http" || proxyURL.Host == "" {
			fmt.Fprintf(stderr, "--proxy is an http:// proxy URL, not %q\n", *proxy)
			return 64
		}
		proxyAddr = proxyURL.Host
	}
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	transport := &http.Transport{
		TLSClientConfig: tlsConfig,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			if *connect != "" {
				addr = *connect
			}
			if proxyAddr != "" {
				return tunnel(ctx, dialer, proxyAddr, addr)
			}
			return dialer.DialContext(ctx, network, addr)
		},
	}
	client := &http.Client{
		Timeout:       15 * time.Second,
		Transport:     transport,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	res, err := client.Do(req)
	if err != nil {
		writeProbeError(stdout, classify(err))
		return 1
	}
	defer res.Body.Close()
	var answered []byte
	if res.StatusCode != http.StatusSwitchingProtocols {
		if answered, err = io.ReadAll(io.LimitReader(res.Body, 1<<20)); err != nil {
			writeProbeError(stdout, classify(err))
			return 1
		}
	}
	out, _ := json.Marshal(map[string]any{"status": res.StatusCode, "headers": res.Header, "body": string(answered)})
	fmt.Fprintln(stdout, string(out))
	return 0
}

// probeError is why a probe got no answer, by what failed (fetchMain).
type probeError struct {
	class  string
	detail string
}

func (e *probeError) Error() string { return e.class + ": " + e.detail }

func writeProbeError(stdout io.Writer, e *probeError) {
	out, _ := json.Marshal(map[string]string{"error": e.class, "detail": e.detail})
	fmt.Fprintln(stdout, string(out))
}

// connectRefusal is how a dial the proxy made for a tunnel reads when the
// target refused it: the kernel's ECONNREFUSED, or gVisor's
// ErrConnectionRefused, which tailscaled's userspace netstack reports.
var connectRefusal = regexp.MustCompile(`connection (was )?refused`)

// tunnel is a CONNECT through the HTTP proxy at proxyAddr to addr, the
// proxy's refusal read whole: a 200 gives the tunnel, and anything else a
// probeError saying whether the target refused the proxy's dial, its name
// did not resolve there, or the proxy failed.
func tunnel(ctx context.Context, dialer *net.Dialer, proxyAddr, addr string) (net.Conn, error) {
	conn, err := dialer.DialContext(ctx, "tcp", proxyAddr)
	if err != nil {
		return nil, &probeError{"proxy", "the proxy " + proxyAddr + " could not be reached: " + err.Error()}
	}
	if deadline, ok := ctx.Deadline(); ok {
		conn.SetDeadline(deadline)
	}
	connectReq := &http.Request{Method: http.MethodConnect, URL: &url.URL{Opaque: addr}, Host: addr, Header: http.Header{}}
	if err := connectReq.Write(conn); err != nil {
		conn.Close()
		return nil, &probeError{"proxy", "the CONNECT to " + proxyAddr + " could not be sent: " + err.Error()}
	}
	reader := bufio.NewReader(conn)
	res, err := http.ReadResponse(reader, connectReq)
	if err != nil {
		conn.Close()
		return nil, &probeError{"proxy", "the proxy " + proxyAddr + " gave no answer to CONNECT " + addr + ": " + err.Error()}
	}
	if res.StatusCode != http.StatusOK {
		answer, _ := io.ReadAll(io.LimitReader(res.Body, 4096))
		conn.Close()
		reason := res.Header.Get("Tailscale-Connect-Error")
		detail := fmt.Sprintf("the proxy answered CONNECT %s %d: %s", addr, res.StatusCode, strings.TrimSpace(string(answer)))
		switch {
		case res.StatusCode == http.StatusInternalServerError && reason != "" && connectRefusal.MatchString(reason):
			return nil, &probeError{"refused", detail}
		case res.StatusCode == http.StatusInternalServerError && reason != "" && strings.Contains(reason, "no such host"):
			return nil, &probeError{"dns", detail}
		default:
			return nil, &probeError{"proxy", detail}
		}
	}
	conn.SetDeadline(time.Time{})
	if reader.Buffered() > 0 {
		conn.Close()
		return nil, &probeError{"proxy", "the proxy sent bytes after its CONNECT answer"}
	}
	return conn, nil
}

// classify is the probeError a request's failure is.
func classify(err error) *probeError {
	var pe *probeError
	if errors.As(err, &pe) {
		return pe
	}
	detail := err.Error()
	var dnsErr *net.DNSError
	var unknownAuthority x509.UnknownAuthorityError
	var hostname x509.HostnameError
	var invalid x509.CertificateInvalidError
	var verification *tls.CertificateVerificationError
	var record tls.RecordHeaderError
	var alert tls.AlertError
	var op *net.OpError
	var netErr net.Error
	switch {
	case errors.As(err, &dnsErr):
		return &probeError{"dns", detail}
	case errors.As(err, &unknownAuthority), errors.As(err, &hostname), errors.As(err, &invalid),
		errors.As(err, &verification), errors.As(err, &record), errors.As(err, &alert),
		// An alert the server sent during the handshake.
		errors.As(err, &op) && op.Op == "remote error",
		// net/http's own word for a target that answered no TLS.
		strings.Contains(detail, "server gave HTTP response to HTTPS client"):
		return &probeError{"tls", detail}
	case errors.Is(err, syscall.ECONNREFUSED):
		return &probeError{"refused", detail}
	case errors.As(err, &netErr) && netErr.Timeout():
		return &probeError{"timeout", detail}
	default:
		return &probeError{"failed", detail}
	}
}
