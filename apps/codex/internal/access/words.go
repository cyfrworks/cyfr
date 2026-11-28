// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

// Words are what a person reads for a head, each shown as before → after
// when a change is previewed. None names a compose term. Private is the
// address the server's own machine reaches it at, which every server has;
// Browser is its browser address, "" with none, and said only when it has
// one, as Forward is said with proxy alone.
type Words struct {
	Who, Private, Browser, CertificateEmail, Ports, Forward string
}

// Describe is the words a head reads as, on a server whose private
// address is private.
func Describe(h Head, private string) Words {
	w := Words{Private: private, Browser: h.PublicURL, CertificateEmail: "none", Ports: "none"}
	switch h.Browser {
	case BrowserNone:
		w.Who = "only this computer"
	case BrowserTailnet:
		w.Who = "your devices on Tailscale, and people you share this machine with"
	case BrowserDomain:
		w.Who = "anyone on the internet, who still has to sign in"
		w.Ports = "80 and 443"
	case BrowserProxy:
		w.Who = "whoever your own proxy lets through, who still has to sign in"
		w.Forward = "http://" + h.Publish
	}
	if h.ACMEEmail != "" {
		w.CertificateEmail = h.ACMEEmail
	}
	return w
}

// Shared is the address the server gives out: its browser address when it
// has one, otherwise its private address.
func (w Words) Shared() string {
	if w.Browser != "" {
		return w.Browser
	}
	return w.Private
}

// Sentences are the lines the words are printed as, in the order shown:
// who reaches CYFR, its address on this computer, its browser address when
// it has one, the certificate email, the ports, and with proxy where the
// person's proxy sends CYFR's requests.
func (w Words) Sentences() []string {
	lines := []string{"Who can reach CYFR: " + w.Who, "Address on this computer: " + w.Private}
	if w.Browser != "" {
		lines = append(lines, "Browser address: "+w.Browser)
	}
	lines = append(lines, "Certificate email: "+w.CertificateEmail, "Ports opened on this machine: "+w.Ports)
	if w.Forward != "" {
		lines = append(lines, "Your proxy sends CYFR's requests to: "+w.Forward)
	}
	return lines
}

// settingForms is the form each setting a boot reads strictly must take.
var settingForms = map[string]string{
	"CYFR_PORT":                   "a port from 1 to 65535",
	"CYFR_PROXY_PORT":             "a port from 1 to 65535",
	"CYFR_BIND_ADDRESS":           "an IPv4 or IPv6 address",
	"CYFR_PROXY_BIND_ADDRESS":     "an IPv4 or IPv6 address",
	"CYFR_LOCAL_INGRESS_ASSERTED": "true, the one value the compose file asserts",
	"CYFR_TRUSTED_PROXY_HOPS":     "a whole number of proxy hops from 0 to 16",
	"CYFR_TRUSTED_PROXY_CIDRS":    "a comma-separated list of IP addresses and CIDRs",
	"CYFR_PROXY_PUBLISH":          "an IPv4 loopback address and a port, as 127.0.0.1:4001",
}

// Sentence is a boot refusal's sentence, word for word the release's
// (Prima.Refusal), which cyfr up prints for an incoherent .env. A code
// that is not a boot refusal reads as its code.
func (r *Refusal) Sentence() string {
	p := r.Payload
	tailnet := func(what string) string {
		return "CYFR_BROWSER is `tailnet`, but " + what + ". Run `cyfr access browser tailnet`, which reads both from Tailscale."
	}
	hostIs := func(fallback string) string {
		if host, ok := p["host"]; ok {
			return "CYFR_HOST `" + host + "` is not"
		}
		return fallback
	}
	switch r.Code {
	case "access_source_conflict":
		there := "blank"
		if p["process_value"] != "" {
			there = "`" + p["process_value"] + "`"
		}
		return "`" + p["key"] + "` is `" + p["file_value"] + "` in .env and " + there + " in this process's environment; CYFR is reached one way. Remove one of them."
	case "access_assertion_from_file":
		return "CYFR_LOCAL_INGRESS_ASSERTED is the compose file's assertion and cannot come from .env. Remove it from .env."
	case "access_missing":
		return "CYFR_BROWSER is not set in .env, so CYFR does not know what browser address it has. Nothing started. Run `cyfr init` for a new CYFR, or `cyfr access browser none|tailnet|domain|proxy` for this one."
	case "access_proxy_trust_missing":
		return "CYFR_BROWSER is `proxy`, and .env states no trust in your proxy's forwarded headers: neither CYFR_TRUSTED_PROXY_HOPS nor CYFR_TRUSTED_PROXY_CIDRS is set. Nothing was started or changed. Set CYFR_TRUSTED_PROXY_HOPS in .env to the number of proxies in front of CYFR (1 for your proxy alone), or list them in CYFR_TRUSTED_PROXY_CIDRS, then run the command again."
	case "access_unknown_browser":
		return "CYFR_BROWSER is `" + p["value"] + "`; it must be `none`, `tailnet`, `domain` or `proxy`. Run `cyfr access browser <kind>` to set it with the address it implies."
	case "access_none_mismatch":
		return "CYFR_BROWSER is `none`, which serves this computer alone at its private address, but " + p["key"] + " is `" + p["value"] + "`. Run `cyfr access browser none` to write the matching settings, or `cyfr access browser tailnet|domain|proxy` to reach it from other devices."
	case "access_tailnet_host_invalid":
		return tailnet(hostIs("CYFR_HOST is not set to") + " a tailnet machine name (<machine>.<tailnet>.ts.net)")
	case "access_tailnet_node_invalid":
		if value, ok := p["value"]; ok {
			return tailnet("CYFR_TAILNET_NODE_ID `" + value + "` is malformed")
		}
		return tailnet("CYFR_TAILNET_NODE_ID is missing")
	case "access_domain_host_invalid":
		return "CYFR_BROWSER is `" + p["browser"] + "`, but " + hostIs("CYFR_HOST is not set to") + " a public domain name (not localhost, an IP address or a ts.net name). Run `cyfr access browser " + p["browser"] + " --domain <your domain>`."
	case "access_public_url_mismatch":
		now := "it is not set"
		if value, ok := p["value"]; ok {
			now = "it is `" + value + "`"
		}
		return "CYFR_PUBLIC_URL must be exactly " + p["expected"] + " when CYFR_BROWSER is `" + p["browser"] + "`; " + now + ". Run `cyfr access browser " + p["browser"] + "` to rewrite both."
	case "access_key_outside_browser":
		return "`" + p["key"] + "` is set, but only `" + p["needs"] + "` uses it (CYFR_BROWSER is `" + p["browser"] + "`). Remove it, or run `cyfr access browser " + p["needs"] + "`."
	case "access_bind_not_loopback":
		return "CYFR_BIND_ADDRESS `" + p["address"] + "` is not a loopback address, so other machines could reach CYFR's loopback listener. Bind 127.0.0.1 or ::1; to reach CYFR from other devices, give it a browser address with `cyfr access browser`."
	case "access_setting_invalid":
		if _, ok := p["bind"]; ok {
			return "`CYFR_PROXY_PORT` is `" + p["value"] + "` on `" + p["address"] + "`, and the loopback listener takes CYFR_PORT `" + p["port"] + "` on `" + p["bind"] + "`: the proxy listener's port must differ from the loopback listener's on the same address. Nothing started. Set CYFR_PROXY_PORT to another port."
		}
		if _, ok := p["port"]; ok {
			return "`CYFR_PROXY_PUBLISH` is `" + p["value"] + "`, where the loopback listener is published already (127.0.0.1 on CYFR_PORT `" + p["port"] + "`). Nothing started. Publish the proxy listener at another port."
		}
		if _, ok := p["value"]; !ok {
			return "`" + p["key"] + "` is not valid UTF-8 text. Nothing started. Correct it, or remove it."
		}
		return "`" + p["key"] + "` is `" + p["value"] + "`, which is not " + settingForms[p["key"]] + ". Nothing started. Correct it, or remove it to take the default."
	}
	return r.Code
}
