// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package main

import (
	"bufio"
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"mime"
	"net"
	"net/http"
	"net/http/httputil"
	"net/netip"
	"net/url"
	"os"
	"os/signal"
	"path"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
)

// noHTTPS is what ${TS_CERT_DOMAIN} becomes for a node without a
// certificate domain (kubetypes.ValueNoHTTPS).
const noHTTPS = "no-https"

// pollInterval is how often containerboot reads the serve file and the
// state: containerboot's own timer-only mode reads every 5 s; a shorter
// period only shortens the proof's waits.
const pollInterval = 200 * time.Millisecond

// serveConfig is ipn.ServeConfig, the fields a configuration CYFR writes
// uses. Any other field fails the read (parseServeConfig): the stand-in
// emulates these alone.
type serveConfig struct {
	TCP map[uint16]*tcpPortHandler  `json:",omitempty"`
	Web map[string]*webServerConfig `json:",omitempty"`
}

// tcpPortHandler is ipn.TCPPortHandler; HTTPS and HTTP alone are emulated.
type tcpPortHandler struct {
	HTTPS bool `json:",omitempty"`
	HTTP  bool `json:",omitempty"`
}

// webServerConfig is ipn.WebServerConfig.
type webServerConfig struct {
	Handlers map[string]*httpHandler `json:",omitempty"`
}

// httpHandler is ipn.HTTPHandler; Proxy and Text alone are emulated.
type httpHandler struct {
	Proxy string `json:",omitempty"`
	Text  string `json:",omitempty"`
}

// parseServeConfig reads a serve file's bytes as readServeConfig does,
// after ${TS_CERT_DOMAIN} is replaced: JSON into the configuration, here
// refusing any field the stand-in does not emulate.
func parseServeConfig(data []byte) (*serveConfig, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var sc serveConfig
	if err := decoder.Decode(&sc); err != nil {
		return nil, fmt.Errorf("the serve configuration is not one the stand-in emulates (%v)", err)
	}
	return &sc, nil
}

func (sc *serveConfig) empty() bool { return sc == nil || (len(sc.TCP) == 0 && len(sc.Web) == 0) }

// hasHTTPSEndpoint and validHTTPS are containerboot's hasHTTPSEndpoint and
// isValidHTTPSConfig: an HTTPS endpoint without a certificate domain is
// not applied.
func (sc *serveConfig) hasHTTPSEndpoint() bool {
	if sc == nil {
		return false
	}
	for _, h := range sc.TCP {
		if h != nil && h.HTTPS {
			return true
		}
	}
	return false
}

func validHTTPS(certDomain string, sc *serveConfig) bool {
	return mutated("https-anyway") || !(certDomain == noHTTPS && sc.hasHTTPSEndpoint())
}

// containerbootMain is containerboot: tailscaled's state on its volume,
// a login (an auth key from TS_AUTHKEY, or a person's approval of the
// link it prints), then, with TS_SERVE_CONFIG, Serve as that file says,
// until SIGTERM (the join container's `timeout -s TERM`, or `docker
// stop`) or SIGINT.
func containerbootMain(stdout, stderr io.Writer) int {
	logf := func(format string, args ...any) {
		fmt.Fprintf(stderr, "containerboot (stand-in): "+format+"\n", args...)
	}
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)

	dir := stateDir()
	hostname := os.Getenv("TS_HOSTNAME")
	if hostname == "" {
		hostname, _ = os.Hostname()
	}
	authKey := os.Getenv("TS_AUTHKEY")
	authOnce := os.Getenv("TS_AUTH_ONCE") == "true"

	n, err := update(dir, func(n *node, exists bool) (bool, error) {
		if exists {
			return false, nil
		}
		*n = fresh(hostname)
		return true, nil
	})
	if err != nil {
		logf("%v", err)
		return 1
	}

	// TS_AUTH_ONCE logs in only a machine that is not logged in; without
	// it, a key logs the machine in again on every start.
	if n.BackendState != "Running" || (!authOnce && authKey != "") {
		if authKey != "" {
			sum := sha256.Sum256([]byte(authKey))
			n, err = update(dir, func(n *node, _ bool) (bool, error) {
				if n.BackendState == "Running" {
					n.login(n.Name, n.ID, n.IP)
				} else {
					n.login("", "", "")
				}
				n.AuthKeySHA256 = hex.EncodeToString(sum[:])
				return true, nil
			})
			if err != nil {
				logf("%v", err)
				return 1
			}
			logf("logged in with an auth key as %s", n.Name)
		} else {
			fmt.Fprintf(stdout, "\nTo authenticate, visit:\n\n\t%s\n\n", n.AuthURL)
			for n.BackendState != "Running" {
				select {
				case <-stop:
					return 0
				case <-time.After(pollInterval):
				}
				if n, _, err = load(dir); err != nil {
					logf("%v", err)
					return 1
				}
			}
		}
	}
	logf("Running as %s (%s)", n.Name, n.ID)

	servePath := os.Getenv("TS_SERVE_CONFIG")
	if servePath == "" {
		<-stop
		return 0
	}
	s, err := startServe(dir, logf)
	if err != nil {
		logf("%v", err)
		return 1
	}
	for {
		select {
		case <-stop:
			s.close()
			return 0
		case <-time.After(pollInterval):
		}
		if err := s.watch(servePath); err != nil {
			logf("serve proxy: %v", err)
			s.close()
			return 1
		}
	}
}

// startServe is Serve as containerboot leaves it on a Running node with
// TS_SERVE_CONFIG set, before it first reads the file: the configuration
// a previous run left is unset, and the one tailscaled then holds, `{}`,
// is the last one read.
func startServe(dir string, logf func(string, ...any)) (*server, error) {
	n, _, err := load(dir)
	if err != nil {
		return nil, err
	}
	if !mutated("stale-serve") {
		if n, err = update(dir, func(n *node, _ bool) (bool, error) {
			n.Serve = json.RawMessage("{}")
			return true, nil
		}); err != nil {
			return nil, err
		}
		logf("serve proxy: unsetting previous config")
	}
	s := &server{dir: dir, logf: logf, listeners: map[uint16]net.Listener{}, certs: map[string]*tls.Certificate{}, proxies: map[string]http.Handler{}}
	held := &serveConfig{}
	if len(n.Serve) > 0 {
		if held, err = parseServeConfig(n.Serve); err != nil {
			return nil, err
		}
	}
	if err := s.apply(held, false); err != nil {
		return nil, err
	}
	s.prev = held
	return s, nil
}

// server is Serve: the applied configuration, the listeners it opened,
// and the reverse proxy for each target.
type server struct {
	dir  string
	logf func(string, ...any)
	// prev is the configuration last read, applied or not, as
	// watchServeConfigChanges keeps it; certDomain the domain it was read
	// with.
	prev       *serveConfig
	certDomain string

	mu        sync.Mutex
	applied   *serveConfig
	listeners map[uint16]net.Listener
	certs     map[string]*tls.Certificate
	proxies   map[string]http.Handler
}

// watch reads the serve file once, as watchServeConfigChanges does on each
// event: skipped when missing or empty, applied when it differs from the
// last read and is valid for the certificate domain.
func (s *server) watch(servePath string) error {
	n, _, err := load(s.dir)
	if err != nil {
		return err
	}
	certDomain := noHTTPS
	if domains := n.certDomains(); len(domains) > 0 && domains[0] != "" {
		certDomain = domains[0]
	}
	s.certDomain = certDomain
	data, err := os.ReadFile(servePath)
	if errors.Is(err, os.ErrNotExist) || (err == nil && len(data) == 0) {
		return nil
	}
	if err != nil {
		return err
	}
	data = bytes.ReplaceAll(data, []byte("${TS_CERT_DOMAIN}"), []byte(certDomain))
	sc, err := parseServeConfig(data)
	if err != nil {
		return err
	}
	if mutated("empty-serves") && sc.empty() {
		return nil
	}
	if s.prev != nil && reflect.DeepEqual(sc, s.prev) {
		return nil
	}
	if validHTTPS(certDomain, sc) {
		if err := s.apply(sc, true); err != nil {
			return err
		}
	} else {
		s.logf("serve proxy: this node exposes an HTTPS endpoint but cannot issue TLS certificates (HTTPS is off for its tailnet); not applying")
	}
	s.prev = sc
	return nil
}

// apply makes sc tailscaled's serve configuration, recorded in the state
// when record is set, and opens and closes listeners to match it.
func (s *server) apply(sc *serveConfig, record bool) error {
	if record {
		s.logf("serve proxy: applying serve config")
		if _, err := update(s.dir, func(n *node, _ bool) (bool, error) {
			n.Serve = mustJSON(sc)
			return true, nil
		}); err != nil {
			return err
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.applied = sc
	s.proxies = map[string]http.Handler{}
	wanted := map[uint16]*tcpPortHandler{}
	for port, h := range sc.TCP {
		if h != nil && (h.HTTPS || h.HTTP) {
			wanted[port] = h
		}
	}
	for port, l := range s.listeners {
		if _, ok := wanted[port]; !ok {
			l.Close()
			delete(s.listeners, port)
		}
	}
	for port, h := range wanted {
		if _, ok := s.listeners[port]; ok {
			continue
		}
		l, err := net.Listen("tcp", ":"+strconv.Itoa(int(port)))
		if err != nil {
			return err
		}
		s.listeners[port] = l
		srv := &http.Server{Handler: s, ReadHeaderTimeout: 30 * time.Second}
		if h.HTTPS {
			srv.TLSConfig = &tls.Config{GetCertificate: s.certificate}
			go srv.ServeTLS(l, "", "")
		} else {
			go srv.Serve(l)
		}
		s.logf("serve proxy: serving port %d", port)
	}
	return nil
}

func (s *server) close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for port, l := range s.listeners {
		l.Close()
		delete(s.listeners, port)
	}
}

// web is the web configuration for the server name and port, as
// webServerConfig keys it.
func (s *server) web(name string, port uint16) (*webServerConfig, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.applied == nil {
		return nil, false
	}
	wsc, ok := s.applied.Web[net.JoinHostPort(name, strconv.Itoa(int(port)))]
	return wsc, ok && wsc != nil
}

func localPort(addr net.Addr) uint16 {
	if tcp, ok := addr.(*net.TCPAddr); ok {
		return uint16(tcp.Port)
	}
	return 0
}

// certificate is getTLSServeCertForPort: a certificate only for a server
// name with a web handler on the port the connection reached.
func (s *server) certificate(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
	if hello.ServerName == "" {
		return nil, errors.New("no SNI ServerName")
	}
	if _, ok := s.web(hello.ServerName, localPort(hello.Conn.LocalAddr())); !ok {
		return nil, errors.New("no webserver configured for name/port")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if cert, ok := s.certs[hello.ServerName]; ok {
		return cert, nil
	}
	cert, err := issue(s.dir, hello.ServerName)
	if err != nil {
		return nil, err
	}
	s.certs[hello.ServerName] = cert
	return cert, nil
}

// handler is getServeHandler: the handler mounted at the request's path,
// or at the nearest mount above it.
func (s *server) handler(r *http.Request) (*httpHandler, string, bool) {
	port := uint16(0)
	if addr, ok := r.Context().Value(http.LocalAddrContextKey).(net.Addr); ok {
		port = localPort(addr)
	}
	hostname := r.Host
	if r.TLS == nil {
		if host, _, err := net.SplitHostPort(hostname); err == nil {
			hostname = host
		}
		if !strings.HasSuffix(hostname, "."+magicDNSSuffix) {
			hostname += "." + magicDNSSuffix
		}
	} else {
		hostname = r.TLS.ServerName
	}
	wsc, ok := s.web(hostname, port)
	if !ok {
		return nil, "", false
	}
	if h, ok := wsc.Handlers[r.URL.Path]; ok && h != nil {
		return h, r.URL.Path, true
	}
	pth := path.Clean(r.URL.Path)
	if !strings.HasPrefix(pth, "/") {
		return nil, "", false
	}
	for {
		withSlash := pth + "/"
		if h, ok := wsc.Handlers[withSlash]; ok && h != nil {
			return h, withSlash, true
		}
		if h, ok := wsc.Handlers[pth]; ok && h != nil {
			return h, pth, true
		}
		if pth == "/" {
			return nil, "", false
		}
		pth = path.Dir(pth)
	}
}

// ServeHTTP is serveWebHandler.
func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h, mountPoint, ok := s.handler(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	if h.Text != "" {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		io.WriteString(w, h.Text)
		return
	}
	if h.Proxy == "" {
		http.Error(w, "empty handler", http.StatusInternalServerError)
		return
	}
	p, err := s.proxy(h.Proxy)
	if err != nil {
		http.Error(w, "unknown proxy destination", http.StatusInternalServerError)
		return
	}
	if r.URL.Path != "/" {
		p = http.StripPrefix(strings.TrimSuffix(mountPoint, "/"), p)
	}
	p.ServeHTTP(w, r)
}

func (s *server) proxy(target string) (http.Handler, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if p, ok := s.proxies[target]; ok {
		return p, nil
	}
	u, err := url.Parse(target)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return nil, fmt.Errorf("the proxy target %q is not an http(s) URL", target)
	}
	p := reverseProxy(u, s.peer)
	s.proxies[target] = p
	return p, nil
}

// peer is WhoIs for a source address: the state's person, or nil for a
// tagged node.
func (s *server) peer(netip.Addr) *person {
	n, _, err := load(s.dir)
	if err != nil {
		return nil
	}
	return n.User
}

// reverseProxy is reverseProxy.ServeHTTP's httputil.ReverseProxy for the
// target, its transport http.DefaultTransport's settings with no proxy
// from the environment.
func reverseProxy(target *url.URL, whois func(netip.Addr) *person) *httputil.ReverseProxy {
	return &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			oldOutPath := r.Out.URL.Path
			r.SetURL(target)
			if oldOutPath == "" && target.Path != "" {
				r.Out.URL.Path = target.Path
				r.Out.URL.RawPath = target.RawPath
			}
			if !mutated("host") {
				r.Out.Host = r.In.Host
			}
			addProxyForwardedHeaders(r)
			addTailscaleIdentityHeaders(r, whois)
			r.Out.Header.Del("Tailscale-App-Capabilities")
		},
		Transport: &http.Transport{
			ForceAttemptHTTP2:     true,
			MaxIdleConns:          100,
			IdleConnTimeout:       90 * time.Second,
			TLSHandshakeTimeout:   10 * time.Second,
			ExpectContinueTimeout: 1 * time.Second,
		},
	}
}

func sourceAddr(r *http.Request) (netip.Addr, bool) {
	addrPort, err := netip.ParseAddrPort(r.RemoteAddr)
	if err != nil {
		return netip.Addr{}, false
	}
	return addrPort.Addr().Unmap(), true
}

// addProxyForwardedHeaders is serve.go's: on headers httputil has already
// stripped of the client's forwarding ones.
func addProxyForwardedHeaders(r *httputil.ProxyRequest) {
	if v := r.In.Header.Get("X-Forwarded-Host"); mutated("forwarded-host") && v != "" {
		r.Out.Header.Set("X-Forwarded-Host", v)
	} else {
		r.Out.Header.Set("X-Forwarded-Host", r.In.Host)
	}
	if r.In.TLS != nil && !mutated("forwarded-proto") {
		r.Out.Header.Set("X-Forwarded-Proto", "https")
	}
	if src, ok := sourceAddr(r.In); ok {
		if mutated("forwarded-for") {
			r.Out.Header["X-Forwarded-For"] = append(r.In.Header.Values("X-Forwarded-For"), src.String())
		} else {
			r.Out.Header.Set("X-Forwarded-For", src.String())
		}
	}
}

// addTailscaleIdentityHeaders is serve.go's, the peer's identity from
// whois.
func addTailscaleIdentityHeaders(r *httputil.ProxyRequest, whois func(netip.Addr) *person) {
	if !mutated("identity-kept") {
		r.Out.Header.Del("Tailscale-User-Login")
		r.Out.Header.Del("Tailscale-User-Name")
		r.Out.Header.Del("Tailscale-User-Profile-Pic")
		r.Out.Header.Del("Tailscale-Funnel-Request")
		r.Out.Header.Del("Tailscale-Headers-Info")
	}
	src, ok := sourceAddr(r.In)
	if !ok || mutated("identity-unset") {
		return
	}
	user := whois(src)
	if user == nil {
		return
	}
	r.Out.Header.Set("Tailscale-User-Login", encTailscaleHeaderValue(user.Login))
	r.Out.Header.Set("Tailscale-User-Name", encTailscaleHeaderValue(user.Name))
	r.Out.Header.Set("Tailscale-User-Profile-Pic", user.ProfilePic)
	r.Out.Header.Set("Tailscale-Headers-Info", "https://tailscale.com/s/serve-headers")
}

// encTailscaleHeaderValue is serve.go's: empty for invalid UTF-8, RFC
// 2047 Q-encoded when not ASCII.
func encTailscaleHeaderValue(v string) string {
	if !utf8.ValidString(v) {
		return ""
	}
	return mime.QEncoding.Encode("utf-8", v)
}

// authority is the stand-in's certificate authority, made once per state
// volume (standin-ca.pem and standin-ca.key in the state directory), which
// the proof's clients trust in place of the publicly trusted one a real
// tailnet's certificates chain to.
func authority(dir string) (*x509.Certificate, *ecdsa.PrivateKey, error) {
	var cert *x509.Certificate
	var key *ecdsa.PrivateKey
	_, err := update(dir, func(*node, bool) (bool, error) {
		certPEM, certErr := os.ReadFile(filepath.Join(dir, "standin-ca.pem"))
		keyPEM, keyErr := os.ReadFile(filepath.Join(dir, "standin-ca.key"))
		if certErr == nil && keyErr == nil {
			certBlock, _ := pem.Decode(certPEM)
			keyBlock, _ := pem.Decode(keyPEM)
			if certBlock == nil || keyBlock == nil {
				return false, errors.New("the stand-in's authority files do not read")
			}
			var err error
			if cert, err = x509.ParseCertificate(certBlock.Bytes); err != nil {
				return false, err
			}
			if key, err = x509.ParseECPrivateKey(keyBlock.Bytes); err != nil {
				return false, err
			}
			return false, nil
		}
		var err error
		if key, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader); err != nil {
			return false, err
		}
		template := &x509.Certificate{
			SerialNumber:          serial(),
			Subject:               pkix.Name{CommonName: "CYFR Compose proof Tailscale stand-in"},
			NotBefore:             time.Now().Add(-time.Hour),
			NotAfter:              time.Now().Add(7 * 24 * time.Hour),
			IsCA:                  true,
			BasicConstraintsValid: true,
			MaxPathLenZero:        true,
			KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		}
		der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
		if err != nil {
			return false, err
		}
		if cert, err = x509.ParseCertificate(der); err != nil {
			return false, err
		}
		keyDER, err := x509.MarshalECPrivateKey(key)
		if err != nil {
			return false, err
		}
		if err := writeSynced(filepath.Join(dir, "standin-ca.key"), pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}), 0o600); err != nil {
			return false, err
		}
		return false, writeSynced(filepath.Join(dir, "standin-ca.pem"), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644)
	})
	return cert, key, err
}

func authorityPEM(dir string) ([]byte, error) {
	cert, _, err := authority(dir)
	if err != nil {
		return nil, err
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Raw}), nil
}

func serial() *big.Int {
	n, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if err != nil {
		panic(err)
	}
	return n
}

// issue is the certificate Serve presents for name, signed by the
// stand-in's authority.
func issue(dir, name string) (*tls.Certificate, error) {
	ca, caKey, err := authority(dir)
	if err != nil {
		return nil, err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	der, err := x509.CreateCertificate(rand.Reader, &x509.Certificate{
		SerialNumber: serial(),
		Subject:      pkix.Name{CommonName: name},
		DNSNames:     []string{name},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(7 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}, ca, &key.PublicKey, caKey)
	if err != nil {
		return nil, err
	}
	return &tls.Certificate{Certificate: [][]byte{der, ca.Raw}, PrivateKey: key}, nil
}

// echoMain is an upstream that answers each request with what reached it:
// its method, Host, path and query, every header with every value, and
// the peer, as JSON, and writes the same as one line on stderr.
// /status/<code> answers that status with the same body, and a WebSocket
// upgrade is switched and echoed byte for byte, its Host in X-Echo-Host.
func echoMain(listen string, stderr io.Writer) int {
	var logged sync.Mutex
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen, _ := json.Marshal(map[string]any{
			"method":  r.Method,
			"host":    r.Host,
			"path":    r.URL.Path,
			"query":   r.URL.RawQuery,
			"headers": r.Header,
			"remote":  r.RemoteAddr,
		})
		logged.Lock()
		fmt.Fprintln(stderr, string(seen))
		logged.Unlock()
		if strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
			conn, rw, err := http.NewResponseController(w).Hijack()
			if err != nil {
				return
			}
			defer conn.Close()
			fmt.Fprintf(rw, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nX-Echo-Host: %s\r\n\r\n", r.Host)
			rw.Flush()
			io.Copy(conn, bufio.NewReader(rw))
			return
		}
		code := http.StatusOK
		if rest, ok := strings.CutPrefix(r.URL.Path, "/status/"); ok {
			if n, err := strconv.Atoi(rest); err == nil && n >= 200 && n <= 599 {
				code = n
			}
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(code)
		w.Write(append(seen, '\n'))
	})
	if err := (&http.Server{Addr: listen, Handler: handler, ReadHeaderTimeout: 30 * time.Second}).ListenAndServe(); err != nil {
		fmt.Fprintf(stderr, "standin echo: %v\n", err)
		return 1
	}
	return 0
}
