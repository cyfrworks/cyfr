// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"context"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"
)

// status reads .env, the project's containers, the journal and the
// newest receipt, and asks the mode's proxy how it is: no lock is taken
// and nothing is written.
func (e *Engine) status(ctx context.Context) (Status, error) {
	var s Status
	st, err := e.readState()
	var ref *Refusal
	switch {
	case errors.As(err, &ref):
		s.HeadErr = ref
	case err != nil:
		return s, err
	default:
		s.Head, s.HeadErr = st.head, st.headErr
		if st.headErr == nil {
			s.Words = Describe(st.head)
		}
	}
	if j, err := e.readJournal(); err == nil && j != nil {
		r := j.receipt()
		s.Unfinished = &r
	}
	s.Last, _ = e.latestReceipt()
	cs, err := e.observe(ctx)
	if err != nil {
		s.Health = append(s.Health, "Docker did not answer: "+err.Error())
		return s, nil
	}
	s.Containers = cs
	if js, err := e.observeJoins(ctx); err == nil {
		for _, c := range js {
			s.Containers = append(s.Containers, Container{Service: "tailnet join " + c.JoinID, Name: c.Name, State: c.State})
		}
	}
	if s.HeadErr == nil {
		s.Health = e.health(ctx, s.Head, cs)
	}
	return s, nil
}

// health is the mode's proxy as status shows it. The certificate's expiry
// is read where the proxy keeps it, and said not to be read when it
// cannot be.
func (e *Engine) health(ctx context.Context, h Head, cs []Container) []string {
	switch h.Mode {
	case ModeTailnet:
		name, ok := containerOf(cs, serveService)
		if !ok || !running(stateOf(cs, name)) {
			return []string{"Tailscale: not running"}
		}
		ts, err := e.readStatus(ctx, []string{"exec", name, "tailscale", "status", "--json"})
		if err != nil {
			return []string{"Tailscale: running, but its status could not be read (" + err.Error() + ")"}
		}
		lines := []string{}
		if ts.BackendState != "Running" {
			lines = append(lines, "Tailscale: not connected ("+ts.BackendState+")")
		} else if ts.name() == h.Host && ts.id() == h.NodeID {
			lines = append(lines, "Tailscale: connected as "+ts.name()+" (node ID "+ts.id()+"), the machine .env names")
		} else {
			lines = append(lines, "Tailscale: connected as "+ts.name()+" (node ID "+ts.id()+"), but .env names "+h.Host+" (node ID "+h.NodeID+")")
		}
		if ts.https() {
			lines = append(lines, "HTTPS certificates: on")
		} else {
			lines = append(lines, "HTTPS certificates: off")
		}
		if e.serveIsOpen() {
			lines = append(lines, "Serve: open")
		} else {
			lines = append(lines, "Serve: off")
		}
		return append(lines, e.certificate(ctx, name, "cat /var/lib/tailscale/certs/"+h.Host+".crt"))
	case ModePublic:
		proxies, err := e.servicesOf(ctx, h, nil)
		if err != nil {
			return []string{"The proxy: its service could not be read (" + err.Error() + ")"}
		}
		var lines []string
		for _, service := range proxies {
			name, ok := containerOf(cs, service)
			if !ok {
				lines = append(lines, service+": not running")
				continue
			}
			lines = append(lines, service+": "+stateOf(cs, name))
			if running(stateOf(cs, name)) {
				lines = append(lines, e.certificate(ctx, name, "cat /data/caddy/certificates/*/"+h.Host+"/"+h.Host+".crt"))
			}
		}
		return lines
	}
	return nil
}

func stateOf(cs []Container, name string) string {
	for _, c := range cs {
		if c.Name == name {
			return c.State
		}
	}
	return ""
}

// certificate reads the certificate a shell command prints in container
// and says when it expires.
func (e *Engine) certificate(ctx context.Context, container, command string) string {
	res, err := e.docker.Run(ctx, Call{Args: []string{"exec", container, "sh", "-c", command}, Deadline: probeDeadline})
	if err != nil {
		return "Certificate: none issued yet, or not readable"
	}
	block, _ := pem.Decode(res.Stdout)
	if block == nil {
		return "Certificate: not readable"
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return "Certificate: not readable"
	}
	return "Certificate: expires " + cert.NotAfter.UTC().Format(time.RFC3339)
}

// receiptOf answers request id from the journal or its receipt, without
// the lock.
func (e *Engine) receiptOf(id string) (Receipt, bool, error) {
	if !requestID.MatchString(id) {
		return Receipt{}, false, fmt.Errorf("access: the request id %q is not 32 lowercase hexadecimal characters", id)
	}
	j, err := e.readJournal()
	if err != nil {
		return Receipt{}, false, err
	}
	if j != nil {
		if j.RequestID == id {
			return j.receipt(), true, nil
		}
		if j.Op == "cancel" && j.Join != nil && j.Join.RequestID == id {
			return Receipt{RequestID: id, RequestDigest: j.Join.RequestDigest, Op: "join", State: "accepted", Phase: "cancelling", At: j.At}, true, nil
		}
	}
	return e.readReceipt(id)
}

func readDirNames(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".json") && !strings.HasPrefix(entry.Name(), ".") {
			names = append(names, entry.Name())
		}
	}
	return names, nil
}

// resent is Resent: request id's record, and whether c is the content it
// was first sent with, a switch's by its content digest, a join's by its
// request digest.
func (e *Engine) resent(id string, c RequestContent) (Receipt, bool, error) {
	r, ok, err := e.receiptOf(id)
	if err != nil || !ok {
		return Receipt{}, false, err
	}
	same := false
	switch r.Op {
	case "switch":
		same = r.ContentDigest != "" && r.ContentDigest == contentDigest(c)
	case "join":
		same = r.RequestDigest == joinDigest(joinHostname(c.Hostname), c.NewNode, c.AuthKeyFingerprint)
	}
	if same {
		return r, true, nil
	}
	return Receipt{RequestID: id, Op: r.Op, State: "rejected", Code: "access_request_reused", At: e.now()}, true, nil
}
