// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"errors"
	"maps"
	"reflect"
	"slices"
	"testing"
	"unicode/utf8"
)

func TestDeriveVectors(t *testing.T) {
	var refused int
	for _, v := range readVectors(t).Derive {
		target := Target{Browser: v.Target["browser"], Domain: v.Target["domain"], ACMEEmail: v.Target["acme_email"], Publish: v.Target["publish"]}
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
		// A head written to .env reads back as itself at boot, with the
		// trust the vector's .env states when it states one.
		env := maps.Clone(d.Assignments)
		if v.Current.Trusted {
			env["CYFR_TRUSTED_PROXY_HOPS"] = "1"
		}
		b, err := ResolveBoot(BootInput{File: env, Process: env, Release: true})
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

// Leaving a kind removes every key only that kind holds.
func TestSwitchRemovesTheOldKindsKeys(t *testing.T) {
	d, err := Derive(Target{Browser: BrowserNone}, Current{Port: 4000, Publish: DefaultPublish, Trusted: true}, nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"CADDY_ACME_EMAIL", "CYFR_PROXY_PUBLISH", "CYFR_PUBLIC_URL", "CYFR_TAILNET_NODE_ID"} {
		if _, ok := d.Assignments[key]; ok {
			t.Errorf("none assigns %s", key)
		}
		if !slices.Contains(d.Removals, key) {
			t.Errorf("none does not remove %s", key)
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
	head := map[string]any{"browser": b.Head.Browser, "host": b.Head.Host, "port": float64(b.Head.Port)}
	for k, v := range map[string]string{"node_id": b.Head.NodeID, "public_url": b.Head.PublicURL, "acme_email": b.Head.ACMEEmail, "publish": b.Head.Publish} {
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
		"browser":       b.Head.Browser,
		"exposure":      b.Exposure,
		"head":          head,
		"canonical":     string(b.Head.Canonical()),
		"digest":        b.Head.Digest(),
		"origin":        b.Origin,
		"listeners":     map[string]any{"loopback": listener(&loopback), "proxy": listener(b.Proxy), "published": listener(b.Published)},
		"trust":         trust,
		"hsts":          b.HSTS,
		"check_origins": origins,
		"assertion":     b.Assertion,
	}
}

// A value that is not UTF-8 is refused by its name, never carried into a
// head's canonical bytes or a sentence.
func TestInvalidUTF8Refuses(t *testing.T) {
	domain := map[string]string{"CYFR_BROWSER": "domain", "CYFR_HOST": "cyfr.example.com", "CYFR_PUBLIC_URL": "https://cyfr.example.com"}
	for _, key := range []string{"CADDY_ACME_EMAIL", "CYFR_HOST", "CYFR_BROWSER", "CYFR_PORT", "CYFR_PROXY_PUBLISH"} {
		env := map[string]string{}
		for k, v := range domain {
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
		{"CYFR_TAILNET_NODE_ID", Target{Browser: BrowserTailnet}, Current{Port: 4000}, &Join{Name: tn, NodeID: "n" + bad}},
		{"CYFR_HOST", Target{Browser: BrowserTailnet}, Current{Port: 4000}, &Join{Name: "cyfr" + bad + ".tail1a2b3c.ts.net", NodeID: "n1"}},
		{"CYFR_HOST", Target{Browser: BrowserDomain, Domain: "cyfr.example.com" + bad}, Current{Port: 4000}, nil},
		{"CADDY_ACME_EMAIL", Target{Browser: BrowserDomain, Domain: "cyfr.example.com", ACMEEmail: "ops" + bad + "@example.com"}, Current{Port: 4000}, nil},
		{"CYFR_BROWSER", Target{Browser: "none" + bad}, Current{Port: 4000}, nil},
		{"CYFR_PROXY_PUBLISH", Target{Browser: BrowserProxy, Domain: "cyfr.example.com", Publish: "127.0.0.1:" + bad}, Current{Port: 4000, Trusted: true}, nil},
		// Encoding comes first: the domain is outside its kind too, and
		// that is not answered.
		{"CADDY_ACME_EMAIL", Target{Browser: BrowserNone, Domain: "cyfr.example.com", ACMEEmail: bad}, Current{Port: 4000}, nil},
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

// An option that only some kinds take, given for another kind, is refused
// as that option, never as an invalid value.
func TestOptionOutsideItsKind(t *testing.T) {
	for _, c := range []struct {
		target Target
		join   *Join
		option string
	}{
		{Target{Browser: BrowserNone, Domain: "cyfr.example.com"}, nil, "--domain"},
		{Target{Browser: BrowserTailnet, ACMEEmail: "ops@example.com"}, &Join{Name: "cyfr.tail1a2b3c.ts.net", NodeID: "n1"}, "--acme-email"},
		{Target{Browser: BrowserNone, ACMEEmail: "ops@example.com"}, nil, "--acme-email"},
		{Target{Browser: BrowserTailnet, Domain: "cyfr.example.com"}, &Join{Name: "cyfr.tail1a2b3c.ts.net", NodeID: "n1"}, "--domain"},
		{Target{Browser: BrowserProxy, Domain: "cyfr.example.com", ACMEEmail: "ops@example.com"}, nil, "--acme-email"},
		{Target{Browser: BrowserNone, Publish: DefaultPublish}, nil, "--publish"},
		{Target{Browser: BrowserTailnet, Publish: DefaultPublish}, &Join{Name: "cyfr.tail1a2b3c.ts.net", NodeID: "n1"}, "--publish"},
		{Target{Browser: BrowserDomain, Domain: "cyfr.example.com", Publish: DefaultPublish}, nil, "--publish"},
	} {
		_, err := Derive(c.target, Current{Port: 4000, Trusted: true}, c.join)
		var r *Refusal
		want := map[string]string{"option": c.option, "browser": c.target.Browser}
		if !errors.As(err, &r) || r.Code != "access_option_outside_browser" || !reflect.DeepEqual(r.Payload, want) {
			t.Errorf("%+v: %v", c.target, err)
		}
	}
}

// A domain asked for without one, through Caddy or the person's own
// proxy, reads as the boot's absent host, word for word, never as an empty
// value that is not a domain.
func TestDomainWithoutADomainReadsAsAnAbsentHost(t *testing.T) {
	for _, browser := range []string{BrowserDomain, BrowserProxy} {
		_, err := Derive(Target{Browser: browser}, Current{Port: 4000, Trusted: true}, nil)
		var r *Refusal
		if !errors.As(err, &r) || !reflect.DeepEqual(r.Payload, map[string]string{"browser": browser}) {
			t.Fatalf("Derive %s without a domain: %v", browser, err)
		}
		want := "CYFR_BROWSER is `" + browser + "`, but CYFR_HOST is not set to a public domain name (not localhost, an IP address or a ts.net name). Run `cyfr access browser " + browser + " --domain <your domain>`."
		if got := r.Sentence(); got != want {
			t.Errorf("sentence\n got %s\nwant %s", got, want)
		}
	}
}

// proxy publishes the proxy listener at the default address, at the one
// asked for, or at the one .env already has, and writes it to .env with
// no key of Caddy's or Tailscale's.
func TestDeriveProxyPublication(t *testing.T) {
	trusted := Current{Port: 4000, Trusted: true}
	kept := Current{Port: 4000, Publish: "127.0.0.2:5000", Trusted: true}
	for _, c := range []struct {
		name    string
		publish string
		cur     Current
		want    string
	}{
		{"the default", "", trusted, DefaultPublish},
		{"--publish", "127.0.0.2:8443", trusted, "127.0.0.2:8443"},
		{"--publish, trimmed", " 127.0.0.1:8443 ", trusted, "127.0.0.1:8443"},
		{"the publication .env has", "", kept, "127.0.0.2:5000"},
		{"--publish over the publication .env has", "127.0.0.1:4002", kept, "127.0.0.1:4002"},
	} {
		d, err := Derive(Target{Browser: BrowserProxy, Domain: "cyfr.example.com", Publish: c.publish}, c.cur, nil)
		if err != nil {
			t.Errorf("%s: %v", c.name, err)
			continue
		}
		want := Head{Browser: BrowserProxy, Host: "cyfr.example.com", PublicURL: "https://cyfr.example.com", Port: 4000, Publish: c.want, Profiles: []string{}}
		if !reflect.DeepEqual(d.Head, want) {
			t.Errorf("%s: head\n got %+v\nwant %+v", c.name, d.Head, want)
		}
		assigned := map[string]string{"CYFR_BROWSER": "proxy", "CYFR_HOST": "cyfr.example.com", "CYFR_PORT": "4000", "CYFR_PROXY_PUBLISH": c.want, "CYFR_PUBLIC_URL": "https://cyfr.example.com"}
		if !reflect.DeepEqual(d.Assignments, assigned) || !reflect.DeepEqual(d.Removals, []string{"CADDY_ACME_EMAIL", "CYFR_TAILNET_NODE_ID"}) {
			t.Errorf("%s: assigns %v and removes %v", c.name, d.Assignments, d.Removals)
		}
	}
}

// proxy refuses a .env that states no trust in the person's proxy, and
// a publication that is not a loopback address and a port of its own,
// before anything is written.
func TestDeriveProxyRefusals(t *testing.T) {
	for _, c := range []struct {
		name    string
		publish string
		cur     Current
		code    string
		payload map[string]string
	}{
		{"no stated trust", "", Current{Port: 4000}, "access_proxy_trust_missing", map[string]string{}},
		{"no stated trust, a publication of its own", "127.0.0.2:8443", Current{Port: 4000}, "access_proxy_trust_missing", map[string]string{}},
		{"an IPv6 publication", "[::1]:4001", Current{Port: 4000, Trusted: true}, "access_setting_invalid", map[string]string{"key": "CYFR_PROXY_PUBLISH", "value": "[::1]:4001"}},
		{"a publication off the loopback", "192.0.2.1:4001", Current{Port: 4000, Trusted: true}, "access_setting_invalid", map[string]string{"key": "CYFR_PROXY_PUBLISH", "value": "192.0.2.1:4001"}},
		{"a publication without a port", "127.0.0.1", Current{Port: 4000, Trusted: true}, "access_setting_invalid", map[string]string{"key": "CYFR_PROXY_PUBLISH", "value": "127.0.0.1"}},
		{"a host name for a publication", "localhost:4001", Current{Port: 4000, Trusted: true}, "access_setting_invalid", map[string]string{"key": "CYFR_PROXY_PUBLISH", "value": "localhost:4001"}},
		{"published at the loopback listener's own", "127.0.0.1:4000", Current{Port: 4000, Trusted: true}, "access_setting_invalid", map[string]string{"key": "CYFR_PROXY_PUBLISH", "value": "127.0.0.1:4000", "port": "4000"}},
	} {
		_, err := Derive(Target{Browser: BrowserProxy, Domain: "cyfr.example.com", Publish: c.publish}, c.cur, nil)
		var r *Refusal
		if !errors.As(err, &r) || r.Code != c.code || !reflect.DeepEqual(r.Payload, c.payload) {
			t.Errorf("%s: %v", c.name, err)
			continue
		}
		if r.Class != classes[c.code] {
			t.Errorf("%s: class %s", c.name, r.Class)
		}
	}
	_, err := Derive(Target{Browser: BrowserProxy, Domain: "cyfr.example.com"}, Current{Port: 4000}, nil)
	var r *Refusal
	if !errors.As(err, &r) || r.Class != "setup_required" {
		t.Fatalf("no stated trust: %v", err)
	}
	want := "CYFR_BROWSER is `proxy`, and .env states no trust in your proxy's forwarded headers: neither CYFR_TRUSTED_PROXY_HOPS nor CYFR_TRUSTED_PROXY_CIDRS is set. Nothing was started or changed. Set CYFR_TRUSTED_PROXY_HOPS in .env to the number of proxies in front of CYFR (1 for your proxy alone), or list them in CYFR_TRUSTED_PROXY_CIDRS, then run the command again."
	if got := r.Sentence(); got != want {
		t.Errorf("sentence\n got %s\nwant %s", got, want)
	}
}

// proxyEnv is .env as `cyfr access browser proxy` writes it, with more.
func proxyEnv(more map[string]string) map[string]string {
	env := map[string]string{"CYFR_BROWSER": "proxy", "CYFR_HOST": "cyfr.example.com", "CYFR_PUBLIC_URL": "https://cyfr.example.com", "CYFR_PORT": "4000"}
	maps.Copy(env, more)
	return env
}

// proxy boots with the trust .env states, by hops or by CIDRs, its proxy
// listener published where CYFR_PROXY_PUBLISH says, an IPv4 loopback
// address (the default when it is unset), public, and with HSTS left to the endpoint as tailnet does.
func TestResolveBootProxy(t *testing.T) {
	for _, c := range []struct {
		name      string
		env       map[string]string
		trust     Trust
		published Listener
	}{
		{"hops", proxyEnv(map[string]string{"CYFR_PROXY_PUBLISH": DefaultPublish, "CYFR_TRUSTED_PROXY_HOPS": "1"}), Trust{Kind: "hops", Hops: 1}, Listener{"127.0.0.1", 4001}},
		{"no hops", proxyEnv(map[string]string{"CYFR_PROXY_PUBLISH": DefaultPublish, "CYFR_TRUSTED_PROXY_HOPS": "0"}), Trust{Kind: "hops", Hops: 0}, Listener{"127.0.0.1", 4001}},
		{"CIDRs", proxyEnv(map[string]string{"CYFR_PROXY_PUBLISH": "127.0.0.2:4001", "CYFR_TRUSTED_PROXY_CIDRS": "10.0.0.1, 192.0.2.0/24"}), Trust{Kind: "cidrs", CIDRs: []string{"10.0.0.1", "192.0.2.0/24"}}, Listener{"127.0.0.2", 4001}},
		{"the publication unset", proxyEnv(map[string]string{"CYFR_TRUSTED_PROXY_HOPS": "2"}), Trust{Kind: "hops", Hops: 2}, Listener{"127.0.0.1", 4001}},
		{"another loopback address on the loopback listener's port", proxyEnv(map[string]string{"CYFR_PROXY_PUBLISH": "127.0.0.2:4000", "CYFR_TRUSTED_PROXY_HOPS": "1"}), Trust{Kind: "hops", Hops: 1}, Listener{"127.0.0.2", 4000}},
	} {
		b, err := ResolveBoot(BootInput{File: c.env, Process: c.env, Release: true})
		if err != nil {
			t.Errorf("%s: %v", c.name, err)
			continue
		}
		publish := c.env["CYFR_PROXY_PUBLISH"]
		if publish == "" {
			publish = DefaultPublish
		}
		head := Head{Browser: BrowserProxy, Host: "cyfr.example.com", PublicURL: "https://cyfr.example.com", Port: 4000, Publish: publish, Profiles: []string{}}
		if !reflect.DeepEqual(b.Head, head) {
			t.Errorf("%s: head %+v", c.name, b.Head)
		}
		if b.Exposure != "public" || b.Origin != "https://cyfr.example.com" || b.HSTS != "endpoint_on_proxy" {
			t.Errorf("%s: exposure %s, origin %s, HSTS %s", c.name, b.Exposure, b.Origin, b.HSTS)
		}
		if b.Published == nil || *b.Published != c.published {
			t.Errorf("%s: published at %v, want %v", c.name, b.Published, c.published)
		}
		if b.Proxy == nil || *b.Proxy != (Listener{"127.0.0.1", 4001}) || b.Loopback != (Listener{"127.0.0.1", 4000}) {
			t.Errorf("%s: proxy listener %v, loopback %v", c.name, b.Proxy, b.Loopback)
		}
		if !reflect.DeepEqual(b.Trust, c.trust) {
			t.Errorf("%s: trust %+v, want %+v", c.name, b.Trust, c.trust)
		}
		if len(b.CheckOrigins) == 0 || b.CheckOrigins[0] != "https://cyfr.example.com" {
			t.Errorf("%s: check origins %v", c.name, b.CheckOrigins)
		}
	}
}

// proxy refuses to boot without a stated trust, and with a publication
// that is malformed, off the loopback or at the loopback listener's own;
// another kind refuses CYFR_PROXY_PUBLISH as a key outside it, and takes
// the default trust when none is stated.
func TestResolveBootProxyRefusals(t *testing.T) {
	hops := map[string]string{"CYFR_TRUSTED_PROXY_HOPS": "1"}
	with := func(more ...map[string]string) map[string]string {
		env := proxyEnv(nil)
		for _, m := range more {
			maps.Copy(env, m)
		}
		return env
	}
	publish := func(v string) map[string]string { return map[string]string{"CYFR_PROXY_PUBLISH": v} }
	for _, c := range []struct {
		name    string
		env     map[string]string
		code    string
		payload map[string]string
	}{
		{"no stated trust", with(publish(DefaultPublish)), "access_proxy_trust_missing", map[string]string{}},
		{"no stated trust, the stack's blank CIDRs", with(publish(DefaultPublish), map[string]string{"CYFR_TRUSTED_PROXY_CIDRS": ""}), "access_proxy_trust_missing", map[string]string{}},
		{"a malformed publication", with(hops, publish("127.0.0.1:")), "access_setting_invalid", map[string]string{"key": "CYFR_PROXY_PUBLISH", "value": "127.0.0.1:"}},
		{"a host name for a publication", with(hops, publish("localhost:4001")), "access_setting_invalid", map[string]string{"key": "CYFR_PROXY_PUBLISH", "value": "localhost:4001"}},
		{"an IPv6 publication", with(hops, publish("[::1]:4001")), "access_setting_invalid", map[string]string{"key": "CYFR_PROXY_PUBLISH", "value": "[::1]:4001"}},
		{"an IPv4-mapped IPv6 publication", with(hops, publish("[::ffff:127.0.0.1]:4001")), "access_setting_invalid", map[string]string{"key": "CYFR_PROXY_PUBLISH", "value": "[::ffff:127.0.0.1]:4001"}},
		{"an IPv6 publication without brackets", with(hops, publish("::1:4001")), "access_setting_invalid", map[string]string{"key": "CYFR_PROXY_PUBLISH", "value": "::1:4001"}},
		{"an IPv4 address in brackets", with(hops, publish("[127.0.0.1]:4001")), "access_setting_invalid", map[string]string{"key": "CYFR_PROXY_PUBLISH", "value": "[127.0.0.1]:4001"}},
		{"port 0", with(hops, publish("127.0.0.1:0")), "access_setting_invalid", map[string]string{"key": "CYFR_PROXY_PUBLISH", "value": "127.0.0.1:0"}},
		{"off the loopback", with(hops, publish("0.0.0.0:4001")), "access_setting_invalid", map[string]string{"key": "CYFR_PROXY_PUBLISH", "value": "0.0.0.0:4001"}},
		{"off the IPv6 loopback", with(hops, publish("[::]:4001")), "access_setting_invalid", map[string]string{"key": "CYFR_PROXY_PUBLISH", "value": "[::]:4001"}},
		{"at the loopback listener's own", with(hops, publish("127.0.0.1:4000")), "access_setting_invalid", map[string]string{"key": "CYFR_PROXY_PUBLISH", "value": "127.0.0.1:4000", "port": "4000"}},
		{"at the loopback listener's own, another port", with(hops, publish("127.0.0.1:4100"), map[string]string{"CYFR_PORT": "4100"}), "access_setting_invalid", map[string]string{"key": "CYFR_PROXY_PUBLISH", "value": "127.0.0.1:4100", "port": "4100"}},
		{"the publication before the trust", with(publish("192.0.2.1:4001")), "access_setting_invalid", map[string]string{"key": "CYFR_PROXY_PUBLISH", "value": "192.0.2.1:4001"}},
		{"none with a publication", map[string]string{"CYFR_BROWSER": "none", "CYFR_PROXY_PUBLISH": DefaultPublish}, "access_key_outside_browser", map[string]string{"key": "CYFR_PROXY_PUBLISH", "browser": "none", "needs": "proxy"}},
		{"domain with a publication", map[string]string{"CYFR_BROWSER": "domain", "CYFR_HOST": "cyfr.example.com", "CYFR_PUBLIC_URL": "https://cyfr.example.com", "CYFR_PROXY_PUBLISH": DefaultPublish}, "access_key_outside_browser", map[string]string{"key": "CYFR_PROXY_PUBLISH", "browser": "domain", "needs": "proxy"}},
		{"tailnet with a publication", map[string]string{"CYFR_BROWSER": "tailnet", "CYFR_HOST": "cyfr.tail1a2b3c.ts.net", "CYFR_PUBLIC_URL": "https://cyfr.tail1a2b3c.ts.net", "CYFR_TAILNET_NODE_ID": "n1", "CYFR_PROXY_PUBLISH": DefaultPublish}, "access_key_outside_browser", map[string]string{"key": "CYFR_PROXY_PUBLISH", "browser": "tailnet", "needs": "proxy"}},
		{"proxy with an email", with(hops, map[string]string{"CADDY_ACME_EMAIL": "ops@example.com"}), "access_key_outside_browser", map[string]string{"key": "CADDY_ACME_EMAIL", "browser": "proxy", "needs": "domain"}},
		{"proxy with a ts.net name", map[string]string{"CYFR_BROWSER": "proxy", "CYFR_HOST": "cyfr.tail1a2b3c.ts.net", "CYFR_PUBLIC_URL": "https://cyfr.tail1a2b3c.ts.net", "CYFR_TRUSTED_PROXY_HOPS": "1"}, "access_domain_host_invalid", map[string]string{"browser": "proxy", "host": "cyfr.tail1a2b3c.ts.net"}},
	} {
		_, err := ResolveBoot(BootInput{File: c.env, Process: c.env, Release: true})
		var r *Refusal
		if !errors.As(err, &r) || r.Code != c.code || !reflect.DeepEqual(r.Payload, c.payload) {
			t.Errorf("%s: %v, want %s %v", c.name, err, c.code, c.payload)
		}
	}
}

// Every kind but proxy takes the default trust when .env states none,
// publishes no proxy listener, and is public with a domain alone.
func TestResolveBootExposureAndDefaultTrust(t *testing.T) {
	for _, c := range []struct {
		env      map[string]string
		exposure string
	}{
		{map[string]string{"CYFR_BROWSER": "none"}, "private"},
		{map[string]string{"CYFR_BROWSER": "tailnet", "CYFR_HOST": "cyfr.tail1a2b3c.ts.net", "CYFR_PUBLIC_URL": "https://cyfr.tail1a2b3c.ts.net", "CYFR_TAILNET_NODE_ID": "n1"}, "private"},
		{map[string]string{"CYFR_BROWSER": "domain", "CYFR_HOST": "cyfr.example.com", "CYFR_PUBLIC_URL": "https://cyfr.example.com"}, "public"},
	} {
		b, err := ResolveBoot(BootInput{File: c.env, Process: c.env, Release: true})
		if err != nil {
			t.Errorf("%s: %v", c.env["CYFR_BROWSER"], err)
			continue
		}
		if b.Exposure != c.exposure || b.Published != nil || b.Head.Publish != "" {
			t.Errorf("%s: exposure %s, published %v, publish %q", c.env["CYFR_BROWSER"], b.Exposure, b.Published, b.Head.Publish)
		}
		want := Trust{Kind: "hops", Hops: 1}
		if c.env["CYFR_BROWSER"] == BrowserNone {
			want = Trust{Kind: "none"}
		}
		if !reflect.DeepEqual(b.Trust, want) {
			t.Errorf("%s: trust %+v, want %+v", c.env["CYFR_BROWSER"], b.Trust, want)
		}
	}
}
