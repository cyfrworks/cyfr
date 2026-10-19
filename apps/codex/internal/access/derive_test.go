// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"errors"
	"reflect"
	"testing"
	"unicode/utf8"
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
			if r.Code != v.Refusal.Code || r.Class != v.Refusal.Class || !reflect.DeepEqual(r.Payload, v.Refusal.Payload) {
				t.Errorf("%s: refusal %s %s %v, want %s %s %v", v.Name, r.Code, r.Class, r.Payload, v.Refusal.Code, v.Refusal.Class, v.Refusal.Payload)
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
			if r.Code != v.Refusal.Code || r.Class != v.Refusal.Class || !reflect.DeepEqual(r.Payload, v.Refusal.Payload) {
				t.Errorf("%s: refusal %s %s %v, want %s %s %v", v.Name, r.Code, r.Class, r.Payload, v.Refusal.Code, v.Refusal.Class, v.Refusal.Payload)
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
		if got := bootJSON(b); !reflect.DeepEqual(got, v.Access) {
			t.Errorf("%s: boot\n got %v\nwant %v", v.Name, got, v.Access)
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

// A malformed builds URL is refused before a head is made from it, at boot
// and when a head is derived.
func TestMalformedBuildsURLRefuses(t *testing.T) {
	for _, raw := range []string{"http://locus-builds:bad", "http://locus-builds:4100/path", "http://locus-builds:4100?token=x", "http://user@locus-builds:4100", "ftp://locus-builds:4100", "not-a-url"} {
		want := map[string]string{"key": "CYFR_LOCUS_BUILDS_URL", "value": raw}
		_, err := ResolveBoot(BootInput{Process: map[string]string{"CYFR_ACCESS": "local", "CYFR_LOCUS_BUILDS_URL": raw}, Release: true})
		var r *Refusal
		if !errors.As(err, &r) || r.Code != "access_setting_invalid" || !reflect.DeepEqual(r.Payload, want) {
			t.Errorf("ResolveBoot with builds URL %q: %v", raw, err)
		}
		_, err = Derive(Target{Mode: ModeLocal}, Current{Port: 4000, BuildsURL: raw}, nil)
		if !errors.As(err, &r) || r.Code != "access_setting_invalid" || !reflect.DeepEqual(r.Payload, want) {
			t.Errorf("Derive with builds URL %q: %v", raw, err)
		}
	}
}

// A value that is not UTF-8 is refused by its name, never carried into a
// head's canonical bytes or a sentence.
func TestInvalidUTF8Refuses(t *testing.T) {
	public := map[string]string{"CYFR_ACCESS": "public", "CYFR_HOST": "cyfr.example.com", "CYFR_PUBLIC_URL": "https://cyfr.example.com"}
	for _, key := range []string{"CADDY_ACME_EMAIL", "CYFR_LOCUS_BUILDS_URL", "CYFR_HOST", "CYFR_ACCESS", "CYFR_PORT"} {
		env := map[string]string{}
		for k, v := range public {
			env[k] = v
		}
		env[key] = "a" + string([]byte{255})
		_, err := ResolveBoot(BootInput{Process: env, Release: true})
		var r *Refusal
		if !errors.As(err, &r) || r.Code != "access_setting_invalid" || !reflect.DeepEqual(r.Payload, map[string]string{"key": key}) {
			t.Errorf("ResolveBoot with non-UTF-8 %s: %v", key, err)
		}
	}
}

// Every input Derive reads that is not UTF-8 is refused by the name it
// would be written under, before any other rule reads it: the payload is
// that name alone, and the sentence is UTF-8.
func TestDeriveRefusesInputThatIsNotUTF8(t *testing.T) {
	bad := string([]byte{255})
	tn := "cyfr.tail1a2b3c.ts.net"
	for _, c := range []struct {
		key     string
		target  Target
		current Current
		join    *Join
	}{
		{"CYFR_LOCUS_BUILDS_URL", Target{Mode: ModeLocal}, Current{Port: 4000, BuildsURL: "http://locus-builds:4100/" + bad}, nil},
		{"CYFR_TAILNET_NODE_ID", Target{Mode: ModeTailnet}, Current{Port: 4000}, &Join{Name: tn, NodeID: "n" + bad}},
		{"CYFR_HOST", Target{Mode: ModeTailnet}, Current{Port: 4000}, &Join{Name: "cyfr" + bad + ".tail1a2b3c.ts.net", NodeID: "n1"}},
		{"CYFR_HOST", Target{Mode: ModePublic, Domain: "cyfr.example.com" + bad}, Current{Port: 4000}, nil},
		{"CADDY_ACME_EMAIL", Target{Mode: ModePublic, Domain: "cyfr.example.com", ACMEEmail: "ops" + bad + "@example.com"}, Current{Port: 4000}, nil},
		{"CYFR_ACCESS", Target{Mode: "local" + bad}, Current{Port: 4000}, nil},
		// Encoding comes first: the domain is outside its mode too, and
		// the builds URL is malformed too, and neither is answered.
		{"CADDY_ACME_EMAIL", Target{Mode: ModeLocal, Domain: "cyfr.example.com", ACMEEmail: bad}, Current{Port: 4000, BuildsURL: "bad"}, nil},
	} {
		_, err := Derive(c.target, c.current, c.join)
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("%s: %v, want a refusal", c.key, err)
			continue
		}
		if r.Code != "access_setting_invalid" || r.Class != "invalid_argument" || !reflect.DeepEqual(r.Payload, map[string]string{"key": c.key}) {
			t.Errorf("%s: refusal %s %s %#v", c.key, r.Code, r.Class, r.Payload)
		}
		want := "`" + c.key + "` is not valid UTF-8 text. Nothing started. Correct it, or remove it."
		if s := r.Sentence(); s != want || !utf8.ValidString(s) {
			t.Errorf("%s: sentence %q", c.key, s)
		}
	}
}

// An option that only a public home takes, given for another mode, is
// refused as that option, never as an invalid value.
func TestOptionOutsideItsMode(t *testing.T) {
	for _, c := range []struct {
		target Target
		join   *Join
		option string
	}{
		{Target{Mode: ModeLocal, Domain: "cyfr.example.com"}, nil, "--domain"},
		{Target{Mode: ModeTailnet, ACMEEmail: "ops@example.com"}, &Join{Name: "cyfr.tail1a2b3c.ts.net", NodeID: "n1"}, "--acme-email"},
		{Target{Mode: ModeLocal, ACMEEmail: "ops@example.com"}, nil, "--acme-email"},
	} {
		_, err := Derive(c.target, Current{Port: 4000}, c.join)
		var r *Refusal
		want := map[string]string{"option": c.option, "mode": c.target.Mode}
		if !errors.As(err, &r) || r.Code != "access_option_outside_mode" || !reflect.DeepEqual(r.Payload, want) {
			t.Errorf("%+v: %v", c.target, err)
		}
	}
}

// A public home asked for without a domain reads as the boot's absent
// host, word for word, never as an empty value that is not a domain.
func TestPublicWithoutADomainReadsAsAnAbsentHost(t *testing.T) {
	_, err := Derive(Target{Mode: ModePublic}, Current{Port: 4000}, nil)
	var r *Refusal
	if !errors.As(err, &r) {
		t.Fatalf("Derive without a domain: %v", err)
	}
	want := "CYFR_ACCESS is `public`, but CYFR_HOST is not set to a public domain name (not localhost, an IP address or a ts.net name). Run `cyfr access public --domain <your domain>`."
	if got := r.Sentence(); got != want {
		t.Errorf("sentence\n got %s\nwant %s", got, want)
	}
}
