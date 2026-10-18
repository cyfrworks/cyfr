// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"errors"
	"reflect"
	"testing"
)

func TestDeriveVectors(t *testing.T) {
	var refused int
	for _, v := range readVectors(t).Derive {
		target := Target{Mode: v.Target["mode"], Domain: v.Target["domain"], ACMEEmail: v.Target["acme_email"]}
		d, err := Derive(target, v.Current, v.Join)
		if v.Refusal != nil {
			refused++
			var r *Refusal
			if !errors.As(err, &r) {
				t.Errorf("%s: %v, want refusal %s", v.Name, err, v.Refusal.Code)
				continue
			}
			if r.Code != v.Refusal.Code || !reflect.DeepEqual(r.Payload, v.Refusal.Payload) {
				t.Errorf("%s: refusal %s %v, want %s %v", v.Name, r.Code, r.Payload, v.Refusal.Code, v.Refusal.Payload)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: %v", v.Name, err)
			continue
		}
		if !reflect.DeepEqual(d.Head, *v.Head) {
			t.Errorf("%s: head\n got %+v\nwant %+v", v.Name, d.Head, *v.Head)
		}
		if string(d.Head.Canonical()) != v.Canonical || d.Head.Digest() != v.Digest {
			t.Errorf("%s: canonical or digest differs from Elixir's", v.Name)
		}
		if !reflect.DeepEqual(d.Assignments, v.Assignments) {
			t.Errorf("%s: assignments %v, want %v", v.Name, d.Assignments, v.Assignments)
		}
		if !reflect.DeepEqual(d.Removals, v.Removals) {
			t.Errorf("%s: removals %v, want %v", v.Name, d.Removals, v.Removals)
		}
		// A head written to .env reads back as itself at boot.
		b, err := ResolveBoot(BootInput{File: d.Assignments, Process: d.Assignments, Release: true})
		if err != nil {
			t.Errorf("%s: its .env does not boot: %v", v.Name, err)
		} else if b.Head.Digest() != v.Digest {
			t.Errorf("%s: its .env boots as %s", v.Name, b.Head.Digest())
		}
	}
	if refused == 0 {
		t.Error("no refused derive vector")
	}
}

// Leaving a mode removes every key only that mode holds.
func TestSwitchRemovesTheOldModesKeys(t *testing.T) {
	d, err := Derive(Target{Mode: ModeLocal}, Current{Port: 4000}, nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"CADDY_ACME_EMAIL", "CYFR_PUBLIC_URL", "CYFR_TAILNET_NODE_ID", "CYFR_LOCUS_BUILDS_URL"} {
		if _, ok := d.Assignments[key]; ok {
			t.Errorf("local assigns %s", key)
		}
		found := false
		for _, r := range d.Removals {
			found = found || r == key
		}
		if !found {
			t.Errorf("local does not remove %s", key)
		}
	}
}

func TestBootVectors(t *testing.T) {
	var refused, accepted int
	for _, v := range readVectors(t).Boot {
		b, err := ResolveBoot(BootInput{File: v.Input.File, Process: v.Input.Process, Release: v.Input.Release})
		if v.Refusal != nil {
			refused++
			var r *Refusal
			if !errors.As(err, &r) {
				t.Errorf("%s: %v, want refusal %s", v.Name, err, v.Refusal.Code)
				continue
			}
			if r.Code != v.Refusal.Code || !reflect.DeepEqual(r.Payload, v.Refusal.Payload) {
				t.Errorf("%s: refusal %s %v, want %s %v", v.Name, r.Code, r.Payload, v.Refusal.Code, v.Refusal.Payload)
			}
			if got := r.Sentence(); got != v.Refusal.Sentence {
				t.Errorf("%s: sentence\n got %s\nwant %s", v.Name, got, v.Refusal.Sentence)
			}
			continue
		}
		accepted++
		if err != nil {
			t.Errorf("%s: %v", v.Name, err)
			continue
		}
		if got := bootJSON(b); !reflect.DeepEqual(got, v.Reach) {
			t.Errorf("%s: boot\n got %v\nwant %v", v.Name, got, v.Reach)
		}
	}
	if refused == 0 || accepted == 0 {
		t.Errorf("%d refused and %d accepted boot vectors; both are needed", refused, accepted)
	}
}

// bootJSON is a boot in the vector file's shape, as encoding/json decodes it.
func bootJSON(b Boot) map[string]any {
	listener := func(l *Listener) any {
		if l == nil {
			return "none"
		}
		return []any{l.Address, float64(l.Port)}
	}
	var trust any = "none"
	switch b.Trust.Kind {
	case "cidrs":
		cidrs := []any{}
		for _, c := range b.Trust.CIDRs {
			cidrs = append(cidrs, c)
		}
		trust = map[string]any{"cidrs": cidrs}
	case "hops":
		trust = map[string]any{"hops": float64(b.Trust.Hops)}
	}
	head := map[string]any{"mode": b.Head.Mode, "host": b.Head.Host, "port": float64(b.Head.Port)}
	for k, v := range map[string]string{"node_id": b.Head.NodeID, "public_url": b.Head.PublicURL, "acme_email": b.Head.ACMEEmail, "builds_url": b.Head.BuildsURL} {
		if v != "" {
			head[k] = v
		}
	}
	profiles, origins := []any{}, []any{}
	for _, p := range b.Head.Profiles {
		profiles = append(profiles, p)
	}
	for _, o := range b.CheckOrigins {
		origins = append(origins, o)
	}
	head["profiles"] = profiles
	loopback := b.Loopback
	return map[string]any{
		"mode":          b.Head.Mode,
		"head":          head,
		"canonical":     string(b.Head.Canonical()),
		"digest":        b.Head.Digest(),
		"origin":        b.Origin,
		"listeners":     map[string]any{"loopback": listener(&loopback), "proxy": listener(b.Proxy)},
		"trust":         trust,
		"hsts":          b.HSTS,
		"check_origins": origins,
		"assertion":     b.Assertion,
	}
}
