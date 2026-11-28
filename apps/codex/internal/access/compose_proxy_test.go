// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// proxyOverlay is the one compose file that publishes the proxy listener:
// at the head's publication alone, its target the listener's own port,
// the listener moved to the loopback listener's address and its trust
// left to .env; a stack with no address to move it to is refused.
func TestProxyOverlay(t *testing.T) {
	for _, c := range []struct {
		name, publish, bind string
		hostIP, published   string
	}{
		{"the default", "127.0.0.1:4001", "172.16.230.2", "127.0.0.1", "4001"},
		{"another loopback address and port", "127.0.0.2:8443", "172.16.230.2", "127.0.0.2", "8443"},
	} {
		h := Head{Browser: BrowserProxy, Host: "cyfr.example.com", PublicURL: "https://cyfr.example.com", Port: 4000, Publish: c.publish, Profiles: []string{}}
		data, err := proxyOverlay(h, c.bind)
		if err != nil {
			t.Errorf("%s: %v", c.name, err)
			continue
		}
		var got map[string]any
		if err := yaml.Unmarshal(data, &got); err != nil {
			t.Errorf("%s: the overlay is not YAML: %v\n%s", c.name, err, data)
			continue
		}
		env := map[string]any{"CYFR_TRUSTED_PROXY_CIDRS": "${CYFR_TRUSTED_PROXY_CIDRS:-}", "CYFR_PROXY_BIND_ADDRESS": c.bind}
		want := map[string]any{"services": map[string]any{"cyfr": map[string]any{
			"ports": []any{map[string]any{
				"host_ip": c.hostIP, "published": c.published, "target": "${CYFR_PROXY_PORT:-4001}", "protocol": "tcp",
			}},
			"environment": env,
		}}}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s: the overlay is\n%s", c.name, data)
		}
	}
	// A publication the boot would refuse is refused here too.
	for _, publish := range []string{"", "192.0.2.1:4002", "127.0.0.1:4000", "localhost:4002", "[::1]:4002"} {
		h := Head{Browser: BrowserProxy, Port: 4000, Publish: publish}
		if _, err := proxyOverlay(h, "172.16.230.2"); refusalCode(err) != "access_setting_invalid" {
			t.Errorf("the overlay of publication %q answered %v", publish, err)
		}
	}
}

// A switch to proxy with .env's trust stated runs no proxy of the
// stack's, flattens the files plainly and then with the overlay read from
// standard input, and starts cyfr on a configuration whose proxy listener
// binds the loopback listener's address; .env holds the publication.
// Without a stated trust the preview is refused and nothing changes.
func TestSwitchToProxy(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	target := Target{Browser: BrowserProxy, Domain: "cyfr.example.com"}
	if _, err := h.e.Preview(bg, target, ""); refusalCode(err) != "access_proxy_trust_missing" {
		t.Fatalf("a proxy preview with no stated trust answered %v", err)
	}
	writeFile(t, filepath.Join(h.dir, ".env"), []byte(h.env()+"CYFR_TRUSTED_PROXY_HOPS=1\n"))
	r := h.request(id(1), target, "")
	var materialized []byte
	h.fake.hook = func(_ context.Context, c *fakeCall) *fakeAnswer {
		if c.Args[0] == "compose" && slices.Contains(c.Args, "up") && materialized == nil {
			materialized, _ = os.ReadFile(filepath.Join(h.dir, resolvedName(r.NewDigest)))
		}
		return nil
	}
	rc, err := h.e.Switch(bg, r)
	if err != nil || rc.Outcome != "ok" {
		t.Fatalf("switch answered %+v, %v", rc, err)
	}
	h.assertConverged(baseStack...)
	head := h.head()
	if head.Browser != BrowserProxy || head.Publish != DefaultPublish || len(head.Profiles) != 0 || head.Digest() != r.NewDigest {
		t.Errorf(".env holds %+v", head)
	}
	if !strings.Contains(h.env(), "\nCYFR_PROXY_PUBLISH=127.0.0.1:4001\n") || !strings.Contains(h.env(), "\nCYFR_TRUSTED_PROXY_HOPS=1\n") {
		t.Errorf(".env is\n%s", h.env())
	}

	calls := h.fake.calls()
	var overlaid int
	for i, c := range calls {
		if c.Args[0] != "compose" || !slices.Contains(c.Args, "-") {
			if c.Stdin != "" && c.Args[0] == "compose" {
				t.Errorf("a compose call without the overlay read standard input: %s", c)
			}
			continue
		}
		overlaid++
		if !slices.Contains(c.Args, "config") || slices.Contains(c.Args, "--profile") {
			t.Errorf("the overlay is read by %s", c)
		}
		if !strings.Contains(c.Stdin, "host_ip: 127.0.0.1") || !strings.Contains(c.Stdin, "CYFR_PROXY_BIND_ADDRESS: 172.16.230.2") {
			t.Errorf("the overlay read is\n%s", c.Stdin)
		}
		if i == 0 || calls[i-1].Args[0] != "compose" || slices.Contains(calls[i-1].Args, "-") || !slices.Contains(calls[i-1].Args, "config") {
			t.Errorf("the overlaid read %s does not follow a plain one", c)
		}
	}
	if overlaid == 0 {
		t.Error("no compose call read the overlay")
	}
	var cfg fakeConfig
	if err := yaml.Unmarshal(materialized, &cfg); err != nil || cfg.Services[cyfrService] == nil {
		t.Fatalf("the materialized configuration is %v:\n%s", err, materialized)
	}
	env := cfg.Services[cyfrService].Environment
	if env["CYFR_PROXY_BIND_ADDRESS"] != env["CYFR_BIND_ADDRESS"] || env["CYFR_BIND_ADDRESS"] == "" || env["CYFR_TRUSTED_PROXY_CIDRS"] != "" {
		t.Errorf("cyfr starts with bind %q, proxy bind %q and CIDRs %q", env["CYFR_BIND_ADDRESS"], env["CYFR_PROXY_BIND_ADDRESS"], env["CYFR_TRUSTED_PROXY_CIDRS"])
	}
	if _, ok := cfg.Services["caddy"]; ok {
		t.Error("the proxy configuration runs caddy")
	}
}

// cyfr's final published ports are held to the kind's, from the flattened
// configuration alone, whatever file put a binding there: the proxy
// listener is published with proxy alone, once, at CYFR_PROXY_PUBLISH, and
// with proxy nothing else is published but the loopback listener.
func TestCheckPublishedHoldsTheFinalPublications(t *testing.T) {
	loopback := "- {target: 4000, host_ip: 127.0.0.1, published: \"4000\", protocol: tcp}\n"
	picked := "- {target: 4000, host_ip: 127.0.0.1, protocol: tcp}\n"
	publication := "- {target: 4001, host_ip: 127.0.0.1, published: \"4001\", protocol: tcp}\n"
	boot := func(browser string) Boot {
		b := Boot{Loopback: Listener{"172.16.230.2", 4000}}
		if browser != BrowserNone {
			b.Proxy = &Listener{"172.16.234.2", 4001}
		}
		if browser == BrowserProxy {
			b.Published = &Listener{"127.0.0.1", 4001}
		}
		return b
	}
	for _, c := range []struct {
		name, browser, ports string
		refused              bool
	}{
		{"none, the loopback listener alone", BrowserNone, loopback, false},
		{"tailnet, the loopback listener alone", BrowserTailnet, loopback, false},
		{"domain, the loopback listener alone", BrowserDomain, loopback, false},
		{"proxy, the loopback listener and the publication", BrowserProxy, loopback + publication, false},
		{"proxy, the loopback listener at a port Docker picks", BrowserProxy, picked + publication, false},
		{"proxy, a second binding of the proxy listener", BrowserProxy, loopback + publication + "- {target: 4001, host_ip: 127.0.0.1, published: \"4002\", protocol: tcp}\n", true},
		{"proxy, the proxy listener on every address", BrowserProxy, loopback + "- {target: 4001, host_ip: 0.0.0.0, published: \"4001\", protocol: tcp}\n", true},
		{"proxy, the proxy listener off its publication", BrowserProxy, loopback + "- {target: 4001, host_ip: 127.0.0.2, published: \"4001\", protocol: tcp}\n", true},
		{"proxy, the proxy listener unpublished", BrowserProxy, loopback, true},
		{"proxy, another port published", BrowserProxy, loopback + publication + "- {target: 4300, host_ip: 127.0.0.1, published: \"4300\", protocol: tcp}\n", true},
		{"proxy, the loopback listener on every address too", BrowserProxy, loopback + publication + "- {target: 4000, host_ip: 0.0.0.0, published: \"4000\", protocol: tcp}\n", true},
		{"none, the proxy port published", BrowserNone, loopback + publication, true},
		{"tailnet, the proxy port published", BrowserTailnet, loopback + publication, true},
		{"domain, the proxy port published", BrowserDomain, loopback + publication, true},
		{"domain, the proxy port on every address", BrowserDomain, loopback + "- {target: 4001, host_ip: 0.0.0.0, published: \"8001\", protocol: tcp}\n", true},
	} {
		var cfg config
		if err := yaml.Unmarshal([]byte("services:\n  cyfr:\n    ports:\n"+indent(c.ports, "      ")), &cfg); err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		err := checkPublished(cfg, boot(c.browser), 4001)
		if (err != nil) != c.refused {
			t.Errorf("%s: checkPublished answered %v", c.name, err)
		}
		if err != nil && !strings.Contains(err.Error(), "Nothing started") {
			t.Errorf("%s: the refusal does not say nothing started: %v", c.name, err)
		}
	}
}

func indent(text, by string) string {
	lines := strings.Split(strings.TrimSuffix(text, "\n"), "\n")
	for i := range lines {
		lines[i] = by + lines[i]
	}
	return strings.Join(lines, "\n") + "\n"
}
