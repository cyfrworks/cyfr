// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package main

import (
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
	"strings"
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
// HTTP proxy --proxy names when given (CONNECT for https). It prints
// {status, headers, body} as JSON and exits 0 on any answer, a protocol
// switch's (101) without reading past its headers, or prints why there
// was none and exits 1.
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
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	transport := &http.Transport{
		TLSClientConfig: tlsConfig,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			if *connect != "" {
				addr = *connect
			}
			return dialer.DialContext(ctx, network, addr)
		},
	}
	if *proxy != "" {
		proxyURL, err := url.Parse(*proxy)
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 64
		}
		transport.Proxy = http.ProxyURL(proxyURL)
	}
	client := &http.Client{
		Timeout:       15 * time.Second,
		Transport:     transport,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	res, err := client.Do(req)
	if err != nil {
		var opErr *net.OpError
		if errors.As(err, &opErr) && opErr.Op == "dial" {
			fmt.Fprintf(stdout, "{\"error\":\"refused\",\"detail\":%q}\n", err.Error())
		} else {
			fmt.Fprintf(stdout, "{\"error\":\"failed\",\"detail\":%q}\n", err.Error())
		}
		return 1
	}
	defer res.Body.Close()
	var answered []byte
	if res.StatusCode != http.StatusSwitchingProtocols {
		if answered, err = io.ReadAll(io.LimitReader(res.Body, 1<<20)); err != nil {
			fmt.Fprintf(stdout, "{\"error\":\"failed\",\"detail\":%q}\n", err.Error())
			return 1
		}
	}
	out, _ := json.Marshal(map[string]any{"status": res.StatusCode, "headers": res.Header, "body": string(answered)})
	fmt.Fprintln(stdout, string(out))
	return 0
}
