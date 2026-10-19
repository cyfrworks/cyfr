// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"
)

// Serve's configuration, which containerboot applies whenever the file
// changes: closed serves nothing, whatever the state volume last held;
// open forwards the machine's HTTPS name to cyfr's proxy listener.
const serveClosed = `{}`

func serveOpen(proxyPort int) string {
	return `{"TCP":{"443":{"HTTPS":true}},"Web":{"${TS_CERT_DOMAIN}:443":{"Handlers":{"/":{"Proxy":"http://cyfr:` + strconv.Itoa(proxyPort) + `"}}}}}`
}

// The Serve directory and file are readable by the tailscale container,
// which mounts the directory read-only; they hold no secret.
const (
	serveDirMode  = 0o755
	serveFileMode = 0o644
)

func (e *Engine) servePath() string { return e.path(serveDir, serveFile) }

// closeServe writes Serve's empty configuration, before every stop and
// every start.
func (e *Engine) closeServe() error {
	if err := e.ensureState(); err != nil {
		return err
	}
	if equalBytes(e.servePath(), []byte(serveClosed)) {
		return syncDir(e.path(serveDir))
	}
	return e.writeDurable(e.servePath(), []byte(serveClosed), serveFileMode)
}

func (e *Engine) openServe(proxyPort int) error {
	return e.writeDurable(e.servePath(), []byte(serveOpen(proxyPort)), serveFileMode)
}

// serveIsOpen reports whether Serve's configuration forwards anything.
func (e *Engine) serveIsOpen() bool {
	data, err := os.ReadFile(e.servePath())
	return err == nil && len(bytes.TrimSpace(data)) > 0 && !bytes.Equal(bytes.TrimSpace(data), []byte(serveClosed))
}

// tsStatus is what the engine reads of `tailscale status --json`.
type tsStatus struct {
	BackendState string `json:"BackendState"`
	AuthURL      string `json:"AuthURL"`
	Self         *struct {
		DNSName string `json:"DNSName"`
		ID      string `json:"ID"`
	} `json:"Self"`
	CertDomains []string `json:"CertDomains"`
}

// name is the machine's DNS name, its trailing dot dropped.
func (s tsStatus) name() string {
	if s.Self == nil {
		return ""
	}
	return strings.TrimSuffix(s.Self.DNSName, ".")
}

func (s tsStatus) id() string {
	if s.Self == nil {
		return ""
	}
	return s.Self.ID
}

func (s tsStatus) https() bool { return s.name() != "" && slices.Contains(s.CertDomains, s.name()) }

// agrees reports whether two reads say the same of the machine.
func (s tsStatus) agrees(o tsStatus) bool {
	return s.BackendState == o.BackendState && s.name() == o.name() && s.id() == o.id() && slices.Equal(s.CertDomains, o.CertDomains)
}

// readStatus runs a status command and reads its answer.
func (e *Engine) readStatus(ctx context.Context, args []string) (tsStatus, error) {
	res, err := e.docker.Run(ctx, Call{Args: args, Deadline: probeDeadline})
	if err != nil {
		return tsStatus{}, errors.New(e.callFailed("tailscale status", err, res.Stderr))
	}
	var s tsStatus
	if err := json.Unmarshal(res.Stdout, &s); err != nil {
		return tsStatus{}, fmt.Errorf("tailscale status answered what is not its JSON: %w", err)
	}
	return s, nil
}

// agreedStatus reads status until two reads a second apart agree on a
// settled state, Running or NeedsLogin, within limit.
func (e *Engine) agreedStatus(ctx context.Context, args []string, limit time.Duration) (tsStatus, error) {
	end := e.now().Add(limit)
	var lastErr error
	for {
		a, err := e.readStatus(ctx, args)
		if err == nil {
			if err := e.sleep(ctx, time.Second); err != nil {
				return tsStatus{}, err
			}
			var b tsStatus
			if b, err = e.readStatus(ctx, args); err == nil && a.agrees(b) && (b.BackendState == "Running" || b.BackendState == "NeedsLogin") {
				return b, nil
			}
		}
		lastErr = err
		if !e.now().Before(end) {
			if lastErr == nil {
				lastErr = fmt.Errorf("tailscale did not settle (it reports %s)", a.BackendState)
			}
			return tsStatus{}, fmt.Errorf("the tailscale service did not report this machine within %s: %w", limit, lastErr)
		}
		if err := e.sleep(ctx, time.Second); err != nil {
			return tsStatus{}, err
		}
	}
}

// statusOnce is two reads a second apart, when both answer and agree: a
// look at a machine that may not be up, where nothing waits for it.
func (e *Engine) statusOnce(ctx context.Context, args []string) (tsStatus, bool) {
	a, err := e.readStatus(ctx, args)
	if err != nil || e.sleep(ctx, time.Second) != nil {
		return tsStatus{}, false
	}
	b, err := e.readStatus(ctx, args)
	return b, err == nil && a.agrees(b)
}

// identity is how a machine reads in a refusal: its name, and its id
// when the name alone does not tell two apart.
func identity(name, id string, withID bool) string {
	if withID {
		return name + " (node " + id + ")"
	}
	return name
}

// validateNode compares the running tailscale service's machine, read
// twice in agreement, with h byte for byte: tailnet_node_mismatch when
// it is another, tailnet_not_joined when it has joined no tailnet,
// tailnet_https_off when it is h's machine but cannot have a
// certificate. Only a match with HTTPS on lets Serve open.
func (e *Engine) validateNode(ctx context.Context, h Head) (*Refusal, error) {
	s, err := e.agreedStatus(ctx, e.composeArgs(h, "exec", "-T", serveService, "tailscale", "status", "--json"), HealthDeadline)
	if err != nil {
		return nil, err
	}
	if s.BackendState != "Running" {
		return Refuse("tailnet_not_joined", nil), nil
	}
	if s.name() == h.Host && s.id() == h.NodeID {
		if !s.https() {
			return Refuse("tailnet_https_off", map[string]string{"name": s.name()}), nil
		}
		return nil, nil
	}
	withID := s.name() == h.Host
	return Refuse("tailnet_node_mismatch", map[string]string{"node": identity(s.name(), s.id(), withID), "env": identity(h.Host, h.NodeID, withID)}), nil
}
