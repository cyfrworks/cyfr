// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

// Words are what a person reads for a head, each shown as before → after
// when a change is previewed. None names a compose term.
type Words struct {
	Who, Address, CertificateEmail, Ports string
}

// Describe is the words a head reads as.
func Describe(h Head) Words {
	w := Words{Address: h.origin(), CertificateEmail: "none", Ports: "none"}
	switch h.Mode {
	case ModeLocal:
		w.Who = "only this computer"
	case ModeTailnet:
		w.Who = "your devices on Tailscale, and people you share this machine with"
	case ModePublic:
		w.Who = "anyone on the internet, who still has to sign in"
		w.Ports = "80 and 443"
	}
	if h.ACMEEmail != "" {
		w.CertificateEmail = h.ACMEEmail
	}
	return w
}

// Sentences are the four lines the words are printed as, in the order
// shown.
func (w Words) Sentences() []string {
	return []string{
		"Who can reach this home: " + w.Who,
		"Address: " + w.Address,
		"Certificate email: " + w.CertificateEmail,
		"Ports opened on this machine: " + w.Ports,
	}
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
	"CYFR_LOCUS_BUILDS_URL":       "an http or https URL with a host, an optional port and no path, query or credentials",
}

// Sentence is a boot refusal's sentence, word for word the release's
// (Prima.Refusal), which cyfr up prints for an incoherent .env. A code
// that is not a boot refusal reads as its code.
func (r *Refusal) Sentence() string {
	p := r.Payload
	tailnet := func(what string) string {
		return "CYFR_REACH is `tailnet`, but " + what + ". Run `cyfr reach tailnet`, which reads both from Tailscale."
	}
	hostIs := func(fallback string) string {
		if host, ok := p["host"]; ok {
			return "CYFR_HOST `" + host + "` is not"
		}
		return fallback
	}
	switch r.Code {
	case "reach_source_conflict":
		there := "blank"
		if p["process_value"] != "" {
			there = "`" + p["process_value"] + "`"
		}
		return "`" + p["key"] + "` is `" + p["file_value"] + "` in .env and " + there + " in this process's environment; a home has one reach. Remove one of them."
	case "reach_assertion_from_file":
		return "CYFR_LOCAL_INGRESS_ASSERTED is the compose file's assertion and cannot come from .env. Remove it from .env."
	case "reach_missing":
		return "CYFR_REACH is not set in .env, so this home does not know how it is reached. Nothing started. Run `cyfr init` for a new home, or `cyfr reach local|tailnet|public` for this one."
	case "reach_unknown_mode":
		return "CYFR_REACH is `" + p["value"] + "`; it must be `local`, `tailnet` or `public`. Run `cyfr reach <mode>` to set it with the address it implies."
	case "reach_local_mismatch":
		return "CYFR_REACH is `local`, which serves this computer alone at its localhost address, but " + p["key"] + " is `" + p["value"] + "`. Run `cyfr reach local` to write the matching settings, or `cyfr reach tailnet|public` to reach it from other devices."
	case "reach_tailnet_host_invalid":
		return tailnet(hostIs("CYFR_HOST is not set to") + " a tailnet machine name (<machine>.<tailnet>.ts.net)")
	case "reach_tailnet_node_invalid":
		if value, ok := p["value"]; ok {
			return tailnet("CYFR_TAILNET_NODE_ID `" + value + "` is malformed")
		}
		return tailnet("CYFR_TAILNET_NODE_ID is missing")
	case "reach_public_host_invalid":
		return "CYFR_REACH is `public`, but " + hostIs("CYFR_HOST is not set to") + " a public domain name (not localhost, an IP address or a ts.net name). Run `cyfr reach public --domain <your domain>`."
	case "reach_public_url_mismatch":
		now := "it is not set"
		if value, ok := p["value"]; ok {
			now = "it is `" + value + "`"
		}
		return "CYFR_PUBLIC_URL must be exactly " + p["expected"] + " when CYFR_REACH is `" + p["mode"] + "`; " + now + ". Run `cyfr reach " + p["mode"] + "` to rewrite both."
	case "reach_key_outside_mode":
		return "`" + p["key"] + "` is set, but only a `" + p["needs"] + "` home uses it (CYFR_REACH is `" + p["mode"] + "`). Remove it, or run `cyfr reach " + p["needs"] + "`."
	case "reach_bind_not_loopback":
		return "CYFR_BIND_ADDRESS `" + p["address"] + "` is not a loopback address, so other machines could reach this home's loopback listener. Bind 127.0.0.1 or ::1; a home reached from other devices uses CYFR_REACH=tailnet or public."
	case "reach_setting_invalid":
		if _, ok := p["bind"]; ok {
			return "`CYFR_PROXY_PORT` is `" + p["value"] + "` on `" + p["address"] + "`, and the loopback listener takes CYFR_PORT `" + p["port"] + "` on `" + p["bind"] + "`: the proxy listener's port must differ from the loopback listener's on the same address. Nothing started. Set CYFR_PROXY_PORT to another port."
		}
		if _, ok := p["value"]; !ok {
			return "`" + p["key"] + "` is not valid UTF-8 text. Nothing started. Correct it, or remove it."
		}
		return "`" + p["key"] + "` is `" + p["value"] + "`, which is not " + settingForms[p["key"]] + ". Nothing started. Correct it, or remove it to take the default."
	}
	return r.Code
}
