// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Command standin is the Compose proof's stand-in for the tailscale service
// (tests/compose-proof/run.sh): one program, installed as `tailscale`,
// `containerboot` and `standin` on the compose file's pinned Caddy image,
// which the proof's overlay names in place of the tailscale/tailscale
// image. It answers what CYFR's access engine asks of the pinned image —
// `tailscale status --json`, `containerboot` with TS_SERVE_CONFIG, and the
// join container's `timeout -s TERM <seconds> containerboot` with or
// without an auth key on standard input — from a state file in the state
// volume (TS_STATE_DIR/standin.json), so the machine's tailnet identity
// follows the volume as the real one does. The proof drives the state with
// `standin` (approve, tailnet, user, state, serving, ca).
//
// It is not Tailscale, talks to no control server, and certifies no
// Tailscale binary, the pinned one included. What it reproduces is the
// behaviour CYFR depends on, as tailscale/tailscale v1.104.1 (the tag
// docker-compose.yml pins) implements it:
//
//   - ipn/ipnlocal/serve.go, reverseProxy.ServeHTTP: an
//     httputil.ReverseProxy whose Rewrite keeps the client's Host
//     (r.Out.Host = r.In.Host); httputil strips Forwarded,
//     X-Forwarded-For, X-Forwarded-Host and X-Forwarded-Proto before any
//     Rewrite runs.
//   - addProxyForwardedHeaders: X-Forwarded-Host is the request's Host,
//     X-Forwarded-Proto is https on a TLS connection, and X-Forwarded-For
//     is the source address.
//   - addTailscaleIdentityHeaders: Tailscale-User-Login, Tailscale-User-Name,
//     Tailscale-User-Profile-Pic, Tailscale-Funnel-Request and
//     Tailscale-Headers-Info are deleted, then the three user headers and
//     Tailscale-Headers-Info are set for a peer that is a user's untagged
//     node, and none for a tagged one. Another Tailscale-User-* header a
//     client sends passes through, as it does there.
//     addAppCapabilitiesHeader deletes Tailscale-App-Capabilities, and sets
//     it only for a handler that accepts capabilities, which no
//     configuration CYFR writes has.
//   - getServeHandler and serveWebHandler: the web handler is the one the
//     TLS server name and the port name, the longest mounted path wins,
//     and no handler answers 404; getTLSServeCertForPort presents a
//     certificate only for a server name with a web handler on that port.
//   - cmd/containerboot: once the node is Running, a set TS_SERVE_CONFIG
//     first unsets whatever serve configuration tailscaled held (main.go);
//     then the file is read whenever it or the certificate domain changes
//     (serve.go, watchServeConfigChanges and readServeConfig): a missing or
//     empty file is skipped, ${TS_CERT_DOMAIN} becomes the node's first
//     certificate domain, or no-https when it has none
//     (kubetypes.ValueNoHTTPS), an HTTPS configuration is not applied
//     without a certificate domain (isValidHTTPSConfig), and `{}` applies
//     the empty configuration, which serves nothing.
//   - tailcfg/tailcfg.go: StableNodeID is a string whose one rule is
//     IsZero (u == ""); ipn/ipnstate/ipnstate.go: Status and PeerStatus,
//     whose ID is the StableNodeID and whose DNSName ends with a dot, and
//     CertDomains, FQDNs without one.
//   - ipn/ipnlocal/peerapi.go: a Running node answers HTTP on its PeerAPI
//     port whatever Serve holds, at the URL its status names
//     (PeerStatus.PeerAPIURL), which the proofs ask beside a refused
//     Serve port, so a refusal they read is the node's own.
//
// The proof's own check of these is proof.sh beside this file, which also
// breaks each of them on purpose (`mutation`, below) and fails;
// tests/tailnet-real/run.sh asserts them against the pinned image on a
// real tailnet.
package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// mutation names one behaviour proof.sh breaks on purpose, set at link
// time (-ldflags "-X main.mutation=<name>"). It is empty in the image the
// Compose proof runs; mutations lists every name.
var mutation string

// mutations are the behaviours proof.sh breaks, one build each.
var mutations = []string{
	"host",            // the upstream's host in place of the client's Host
	"forwarded-for",   // the client's X-Forwarded-For kept, the source appended
	"forwarded-proto", // no X-Forwarded-Proto
	"forwarded-host",  // the client's X-Forwarded-Host kept
	"identity-kept",   // the client's Tailscale-User-* headers kept
	"identity-unset",  // no identity headers of its own
	"empty-serves",    // `{}` skipped like an empty file, so Serve stays as it was
	"stale-serve",     // the serve configuration the state held kept at boot
	"cert-domains",    // a certificate domain reported with HTTPS off
	"https-anyway",    // an HTTPS configuration applied without a certificate domain
}

func mutated(name string) bool { return mutation == name }

// version is what `tailscale version` and the status report.
const version = "1.104.1-standin"

// magicDNSSuffix is the proof's tailnet's MagicDNS suffix.
const magicDNSSuffix = "proof.ts.net"

func main() {
	name := filepath.Base(os.Args[0])
	args := os.Args[1:]
	if name == "standin" && len(args) > 0 && (args[0] == "tailscale" || args[0] == "containerboot") {
		name, args = args[0], args[1:]
	}
	switch name {
	case "tailscale":
		os.Exit(tailscaleMain(args, os.Stdout, os.Stderr))
	case "containerboot":
		os.Exit(containerbootMain(os.Stdout, os.Stderr))
	default:
		os.Exit(standinMain(args, os.Stdout, os.Stderr))
	}
}

// node is the state file: the machine as its tailnet knows it, and the
// serve configuration tailscaled holds.
type node struct {
	// BackendState is NeedsLogin until the machine is approved or logs in
	// with an auth key, then Running.
	BackendState string `json:"backend_state"`
	AuthURL      string `json:"auth_url,omitempty"`
	HostName     string `json:"hostname"`
	// Name is the machine's MagicDNS name without its trailing dot, ID its
	// StableNodeID and IP its tailnet address, all set at login.
	Name string `json:"name,omitempty"`
	ID   string `json:"id,omitempty"`
	IP   string `json:"ip,omitempty"`
	// HTTPS is the tailnet's HTTPS certificates setting: while it is on, the
	// machine's certificate domain is its name.
	HTTPS bool `json:"https"`
	// User is the person every peer that reaches Serve is, or nil when every
	// peer is a tagged node, which gets no identity headers.
	User *person `json:"user,omitempty"`
	// AuthKeySHA256 is the SHA-256 of the auth key the machine last logged
	// in with; the key itself is written nowhere.
	AuthKeySHA256 string `json:"auth_key_sha256,omitempty"`
	// Serve is the serve configuration tailscaled holds.
	Serve json.RawMessage `json:"serve,omitempty"`
}

// person is a tailnet user as Serve's identity headers name one.
type person struct {
	Login      string `json:"login"`
	Name       string `json:"name"`
	ProfilePic string `json:"profile_pic,omitempty"`
}

// stateDir is where tailscaled keeps its state: TS_STATE_DIR, as the
// compose file and the join container set it.
func stateDir() string {
	if dir := os.Getenv("TS_STATE_DIR"); dir != "" {
		return dir
	}
	return "/var/lib/tailscale"
}

func statePath(dir string) string { return filepath.Join(dir, "standin.json") }

// load reads the state file; exists is false when there is none.
func load(dir string) (n node, exists bool, err error) {
	data, err := os.ReadFile(statePath(dir))
	if errors.Is(err, os.ErrNotExist) {
		return node{}, false, nil
	}
	if err != nil {
		return node{}, false, err
	}
	if err := json.Unmarshal(data, &n); err != nil {
		return node{}, false, fmt.Errorf("%s: %w", statePath(dir), err)
	}
	return n, true, nil
}

// update runs f on the state under the state directory's lock, and writes
// the state back, whole and synced, when f answers true. Every writer
// holds the lock, so a change the proof makes while containerboot runs is
// never lost; a reader without it sees the old file or the new one.
func update(dir string, f func(n *node, exists bool) (bool, error)) (node, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return node{}, err
	}
	lock, err := os.OpenFile(filepath.Join(dir, "standin.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return node{}, err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return node{}, err
	}
	n, exists, err := load(dir)
	if err != nil {
		return node{}, err
	}
	write, err := f(&n, exists)
	if err != nil || !write {
		return n, err
	}
	return n, writeSynced(statePath(dir), mustJSON(n), 0o600)
}

// writeSynced replaces path with data through a synced temporary file and
// syncs the directory.
func writeSynced(path string, data []byte, mode os.FileMode) error {
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	d, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

func mustJSON(v any) []byte {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		panic(err)
	}
	return append(data, '\n')
}

func randomHex(bytes int) string {
	b := make([]byte, bytes)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

// fresh is a machine tailscaled has just started for: it needs a login,
// and offers the link a person approves it at. The proof's tailnet has
// HTTPS certificates on, and every peer is one person's untagged node.
func fresh(hostname string) node {
	return node{
		BackendState: "NeedsLogin",
		AuthURL:      "https://login." + magicDNSSuffix + "/a/" + randomHex(6),
		HostName:     hostname,
		HTTPS:        true,
		User:         &person{Login: "person@proof.example", Name: "Proof Person"},
	}
}

// login makes the machine Running: name, id and ip are what the tailnet
// gives it, each the default when empty (the host name in the proof's
// tailnet, a fresh StableNodeID, a fresh address in 100.64.0.0/10).
func (n *node) login(name, id, ip string) {
	if name == "" {
		name = n.HostName + "." + magicDNSSuffix
	}
	if id == "" {
		id = "n" + randomHex(6) + "CNTRL"
	}
	if ip == "" {
		b := make([]byte, 2)
		if _, err := rand.Read(b); err != nil {
			panic(err)
		}
		ip = fmt.Sprintf("100.%d.%d.%d", 64+int(b[0])%64, b[1], 1+int(b[0]^b[1])%254)
	}
	n.BackendState, n.AuthURL, n.Name, n.ID, n.IP = "Running", "", name, id, ip
}

// certDomains are the names the control server issues the machine
// certificates for: its own name while the tailnet has HTTPS on.
func (n node) certDomains() []string {
	if n.BackendState != "Running" {
		return nil
	}
	if n.HTTPS || mutated("cert-domains") {
		return []string{n.Name}
	}
	return nil
}

// status is ipnstate.Status, the fields `tailscale status --json` writes
// that the stand-in has values for, in that type's order and spelling.
type status struct {
	Version        string
	TUN            bool
	BackendState   string
	HaveNodeKey    bool `json:",omitempty"`
	AuthURL        string
	TailscaleIPs   []string
	Self           *peerStatus
	Health         []string
	MagicDNSSuffix string
	CurrentTailnet *tailnetStatus
	CertDomains    []string
}

// peerStatus is ipnstate.PeerStatus, likewise.
type peerStatus struct {
	ID           string
	PublicKey    string
	HostName     string
	DNSName      string
	OS           string
	UserID       int64
	TailscaleIPs []string
	Online       bool
	PeerAPIURL   []string `json:",omitempty"`
}

// peerAPIPort is the port the stand-in's PeerAPI answers on, a Running
// node's (containerbootMain).
const peerAPIPort = 5252

// tailnetStatus is ipnstate.TailnetStatus, likewise.
type tailnetStatus struct {
	Name            string
	MagicDNSSuffix  string
	MagicDNSEnabled bool
}

func statusOf(n node) status {
	s := status{
		Version:      version,
		BackendState: n.BackendState,
		AuthURL:      n.AuthURL,
		Self:         &peerStatus{HostName: n.HostName, OS: "linux"},
	}
	if n.BackendState != "Running" {
		return s
	}
	suffix := n.Name
	if _, after, ok := strings.Cut(n.Name, "."); ok {
		suffix = after
	}
	key := sha256.Sum256([]byte(n.ID))
	s.HaveNodeKey = true
	s.TailscaleIPs = []string{n.IP}
	s.Self = &peerStatus{
		ID:           n.ID,
		PublicKey:    "nodekey:" + hex.EncodeToString(key[:]),
		HostName:     n.HostName,
		DNSName:      n.Name + ".",
		OS:           "linux",
		UserID:       1,
		TailscaleIPs: []string{n.IP},
		Online:       true,
		PeerAPIURL:   []string{fmt.Sprintf("http://%s:%d", n.IP, peerAPIPort)},
	}
	s.MagicDNSSuffix = suffix
	s.CurrentTailnet = &tailnetStatus{Name: "proof.example", MagicDNSSuffix: suffix, MagicDNSEnabled: true}
	s.CertDomains = n.certDomains()
	return s
}

// tailscaleMain is the `tailscale` command: `status` and `status --json`,
// read from the state file, and `version`.
func tailscaleMain(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "tailscale (the Compose proof's stand-in): no command; it answers status and version")
		return 64
	}
	switch args[0] {
	case "version":
		fmt.Fprintln(stdout, version)
		return 0
	case "status":
		flags := flag.NewFlagSet("status", flag.ContinueOnError)
		flags.SetOutput(stderr)
		asJSON := flags.Bool("json", false, "output in JSON format")
		if err := flags.Parse(args[1:]); err != nil {
			return 64
		}
		n, exists, err := load(stateDir())
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		if !exists {
			fmt.Fprintln(stderr, "failed to connect to local tailscaled; it doesn't appear to be running")
			return 1
		}
		if *asJSON {
			if _, err := stdout.Write(mustJSON(statusOf(n))); err != nil {
				return 1
			}
			return 0
		}
		if n.BackendState != "Running" {
			fmt.Fprintln(stdout, "Logged out.")
			if n.AuthURL != "" {
				fmt.Fprintf(stdout, "Log in at: %s\n", n.AuthURL)
			}
			return 1
		}
		login := "tagged-devices"
		if n.User != nil {
			login = n.User.Login
		}
		fmt.Fprintf(stdout, "%-15s %-20s %-24s linux   -\n", n.IP, n.HostName, login)
		return 0
	}
	fmt.Fprintf(stderr, "tailscale (the Compose proof's stand-in): %q is no command it answers\n", args[0])
	return 64
}

// standinMain is the proof's control of the state:
//
//	standin state                                the state file
//	standin approve [--name N] [--id I] [--ip A]  a person approves the waiting machine
//	standin tailnet --https on|off               the tailnet's HTTPS certificates
//	standin user --login L --name N | --tagged    who every peer is
//	standin serving                              the serve configuration tailscaled holds
//	standin ca                                   the authority Serve's certificates chain to
//	standin echo --listen ADDR                   an upstream that answers what reached it
//	standin fetch [--ca F] [--connect A] URL     a client of Serve (fetch.go)
//	standin mutations                            the behaviours proof.sh breaks
func standinMain(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: standin state | approve | tailnet | user | serving | ca | echo | fetch | mutations")
		return 64
	}
	dir := stateDir()
	flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
	flags.SetOutput(stderr)
	fail := func(err error) int {
		fmt.Fprintf(stderr, "standin %s: %v\n", args[0], err)
		return 1
	}
	switch args[0] {
	case "state":
		n, exists, err := load(dir)
		if err != nil {
			return fail(err)
		}
		if !exists {
			return fail(errors.New("no state: containerboot has not started on this volume"))
		}
		stdout.Write(mustJSON(n))
		return 0
	case "approve":
		name := flags.String("name", "", "the machine's MagicDNS name (default <hostname>."+magicDNSSuffix+")")
		id := flags.String("id", "", "its StableNodeID (default a fresh one)")
		ip := flags.String("ip", "", "its tailnet address (default a fresh one)")
		if err := flags.Parse(args[1:]); err != nil {
			return 64
		}
		n, err := update(dir, func(n *node, exists bool) (bool, error) {
			switch {
			case !exists:
				return false, errors.New("no machine waits: containerboot has not started on this volume")
			case n.BackendState == "Running":
				return false, fmt.Errorf("%s is already Running", n.Name)
			}
			n.login(*name, *id, *ip)
			return true, nil
		})
		if err != nil {
			return fail(err)
		}
		fmt.Fprintf(stdout, "approved %s (%s)\n", n.Name, n.ID)
		return 0
	case "tailnet":
		https := flags.String("https", "", "on or off")
		if err := flags.Parse(args[1:]); err != nil {
			return 64
		}
		if *https != "on" && *https != "off" {
			return fail(errors.New("--https is on or off"))
		}
		_, err := update(dir, func(n *node, exists bool) (bool, error) {
			if !exists {
				return false, errors.New("no state: containerboot has not started on this volume")
			}
			n.HTTPS = *https == "on"
			return true, nil
		})
		if err != nil {
			return fail(err)
		}
		return 0
	case "user":
		login := flags.String("login", "", "the person's login name")
		display := flags.String("name", "", "the person's display name")
		tagged := flags.Bool("tagged", false, "every peer is a tagged node")
		if err := flags.Parse(args[1:]); err != nil {
			return 64
		}
		if *tagged == (*login != "") {
			return fail(errors.New("give --login (and --name) or --tagged"))
		}
		_, err := update(dir, func(n *node, exists bool) (bool, error) {
			if !exists {
				return false, errors.New("no state: containerboot has not started on this volume")
			}
			n.User = nil
			if !*tagged {
				n.User = &person{Login: *login, Name: *display}
			}
			return true, nil
		})
		if err != nil {
			return fail(err)
		}
		return 0
	case "serving":
		n, _, err := load(dir)
		if err != nil {
			return fail(err)
		}
		var served bytes.Buffer
		if len(n.Serve) == 0 {
			served.WriteString("{}")
		} else if err := json.Compact(&served, n.Serve); err != nil {
			return fail(err)
		}
		fmt.Fprintln(stdout, served.String())
		return 0
	case "ca":
		pemBytes, err := authorityPEM(dir)
		if err != nil {
			return fail(err)
		}
		stdout.Write(pemBytes)
		return 0
	case "fetch":
		return fetchMain(args[1:], stdout, stderr)
	case "mutations":
		for _, m := range mutations {
			fmt.Fprintln(stdout, m)
		}
		return 0
	case "echo":
		listen := flags.String("listen", "", "the address to answer on")
		if err := flags.Parse(args[1:]); err != nil {
			return 64
		}
		if *listen == "" {
			return fail(errors.New("--listen is required"))
		}
		return echoMain(*listen, stderr)
	}
	return fail(errors.New("no such command"))
}
