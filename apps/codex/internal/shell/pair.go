// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
)

// PairCall is pairing.complete at the home, asked anonymously: the
// command line's own client to the home. It answers the operation's
// result, or the home's refusal as an error.
type PairCall func(ctx context.Context, args map[string]any) (map[string]any, error)

// KeyDigest is the digest of a device key, the code a new device shows:
// SHA-256 over its 32 raw bytes, unpadded base64url.
func KeyDigest(key []byte) string {
	sum := sha256.Sum256(key)
	return b64(sum[:])
}

// KeyCode spells a key digest as a person reads and types it: groups of
// four, separated by single spaces.
func KeyCode(digest string) string {
	var groups []string
	for len(digest) > 4 {
		groups = append(groups, digest[:4])
		digest = digest[4:]
	}
	return strings.Join(append(groups, digest), " ")
}

// ApproveURL is the address a new device shows as its QR code and its
// code: the home's page where a device the person already holds previews
// the addition of exactly this key and confirms it
// (tests/fixtures/device_unlock.json, exchange.pairing.approve_url).
func ApproveURL(home, digest string) string {
	return strings.TrimRight(home, "/") + "/devices/add#key=" + digest
}

// ErrNotAnInvitation is text that is neither the link a confirmed
// addition answers (<home>/pair#code=<secret>) nor its code.
var ErrNotAnInvitation = errors.New("that is not the link or the code CYFR showed once the addition was confirmed")

// ErrOtherHome is an invitation link of another home than the one this
// command line pairs with.
var ErrOtherHome = errors.New("that link is another CYFR's")

// InvitationSecret reads the invitation's secret from what the person
// pasted or typed: the whole link, whose home must be this one, or the
// code alone, 16 bytes as unpadded base64url
// (exchange.pairing.invitation_url).
func InvitationSecret(home, text string) (string, error) {
	text = strings.TrimSpace(text)
	code := text
	if strings.Contains(text, "#") {
		u, err := url.Parse(text)
		if err != nil {
			return "", ErrNotAnInvitation
		}
		h, err := url.Parse(home)
		if err != nil || !strings.EqualFold(u.Scheme, h.Scheme) || !strings.EqualFold(u.Host, h.Host) {
			return "", ErrOtherHome
		}
		frag, err := url.ParseQuery(u.Fragment)
		if err != nil || strings.TrimRight(u.Path, "/") != strings.TrimRight(h.Path, "/")+"/pair" {
			return "", ErrNotAnInvitation
		}
		code = frag.Get("code")
	}
	code = strings.Join(strings.Fields(code), "")
	if raw, err := unb64(code); err != nil || len(raw) != 16 {
		return "", ErrNotAnInvitation
	}
	return code, nil
}

// Certification is what a person's own home is asked to certify for this
// device when their identity is kept there and not at the home it pairs
// with: the home it pairs with (Audience), the athanor and the client id
// that home reserved, and this device's key. Issuer is the home that
// certified this device before, when one did: a re-certification after the
// person's keys changed.
type Certification struct {
	Audience  string
	Athanor   string
	ClientID  string
	DeviceKey []byte
	Issuer    string
}

// Certified is a certificate the person's own home issued for a
// Certification, and that home's address.
type Certified struct {
	Issuer      string
	Certificate json.RawMessage
}

// CertifyCall obtains, at the person's own home, the certificate a
// Certification asks for: there the device is unlocked afresh and the
// certification confirmed, never through a browser.
type CertifyCall func(ctx context.Context, c Certification) (Certified, error)

// ErrCertifiedOther is a certificate the person's own home answered that
// does not certify exactly this device here: it is not used.
var ErrCertifiedOther = errors.New("Your own CYFR's answer does not certify this device here, so it was not used.")

// ErrNoCertifier is a pairing whose home asks for another home's
// certificate where this device has no way to obtain one.
var ErrNoCertifier = errors.New("Your identity is kept by another CYFR, which certifies this device, and this device cannot ask it.")

// Paired is a completed pairing: the client the home recorded and its
// first certificate.
type Paired struct {
	ClientID    string
	Athanor     string
	Certificate json.RawMessage
}

// Pair completes the pairing the invitation secret opens, for key: the
// home's pair challenge for this key and its holder, checked and signed,
// then the proof, answered with the client and its certificate. A proof
// whose answer was lost is made again under a new challenge with the same
// secret and key, which the home answers with the client it committed;
// any other key it refuses.
//
// A person whose identity is kept at another home is answered, beside the
// challenge, what that home is to certify. certify obtains it there; the
// certificate is used only when it certifies exactly this device for this
// home (Elsewhere), and the pairing completes with it under a new
// challenge. The certificate is not kept before this home committed it: a
// completion whose answer is lost certifies again.
func Pair(ctx context.Context, call PairCall, certify CertifyCall, b Binding, d Holder, secret string, key Signer) (Paired, error) {
	args := map[string]any{"invitation_secret": secret, "device_key": b64(b.DeviceKey),
		"key_digest": KeyDigest(b.DeviceKey), "holder_kind": d.Kind, "display_name": d.DisplayName}
	got, asked, err := pairRetried(ctx, call, b, args, key)
	if err != nil || asked == nil {
		return got, err
	}
	if certify == nil {
		return Paired{}, ErrNoCertifier
	}
	certified, err := certify(ctx, *asked)
	if err != nil {
		return Paired{}, err
	}
	if err := Elsewhere(certified, *asked); err != nil {
		return Paired{}, err
	}
	args["certificate"] = certified.Certificate
	got, again, err := pairRetried(ctx, call, b, args, key)
	switch {
	case err != nil:
		return Paired{}, err
	case again != nil:
		return Paired{}, fmt.Errorf("%w: CYFR asked for a certificate again", ErrRefused)
	case got.ClientID != asked.ClientID || got.Athanor != asked.Athanor:
		return Paired{}, fmt.Errorf("%w: CYFR paired another client than the one it asked to certify", ErrRefused)
	}
	if err := Elsewhere(Certified{Issuer: certified.Issuer, Certificate: got.Certificate}, *asked); err != nil {
		return Paired{}, err
	}
	return got, nil
}

func pairRetried(ctx context.Context, call PairCall, b Binding, args map[string]any, key Signer) (Paired, *Certification, error) {
	got, asked, err := pairOnce(ctx, call, b, args, key)
	if errors.Is(err, ErrUnavailable) {
		got, asked, err = pairOnce(ctx, call, b, args, key)
	}
	return got, asked, err
}

// pairOnce asks the pair challenge and answers it. A home that answers,
// beside the challenge, what the person's own home is to certify, and was
// offered no certificate, is answered that request, and nothing is signed.
func pairOnce(ctx context.Context, call PairCall, b Binding, args map[string]any, key Signer) (Paired, *Certification, error) {
	delete(args, "proof")
	asked, err := call(ctx, args)
	if err != nil {
		return Paired{}, nil, err
	}
	if raw, ok := asked["certify"]; ok {
		if _, offered := args["certificate"]; offered {
			return Paired{}, nil, fmt.Errorf("%w: CYFR asked for a certificate again", ErrRefused)
		}
		c, err := certification(raw, b)
		return Paired{}, c, err
	}
	raw, _ := json.Marshal(asked["challenge"])
	c, err := Challenge(raw, "pair", b, nil)
	if err != nil {
		return Paired{}, nil, err
	}
	proof, err := Prove(c, key)
	if err != nil {
		return Paired{}, nil, err
	}
	args["proof"] = proof
	answer, err := call(ctx, args)
	if err != nil {
		return Paired{}, nil, err
	}
	cert, _ := json.Marshal(answer["certificate"])
	got := Paired{ClientID: c["client_id"].(string), Athanor: c["athanor"].(string), Certificate: cert}
	if id, _ := answer["client_id"].(string); id != got.ClientID {
		return Paired{}, nil, fmt.Errorf("%w: the client CYFR answered is not the one its challenge named", ErrRefused)
	}
	if err := certifies(cert, b.Home, got.Athanor, got.ClientID, b.DeviceKey); err != nil {
		return Paired{}, nil, err
	}
	return got, nil, nil
}

// certification reads what this home asks the person's own home to
// certify: exactly its audience, athanor and client id, the audience
// being this home.
func certification(raw any, b Binding) (*Certification, error) {
	m, ok := raw.(map[string]any)
	audience, _ := m["audience"].(string)
	athanor, _ := m["athanor"].(string)
	client, _ := m["client_id"].(string)
	if !ok || len(m) != 3 || !sameOrigin(audience, b.Home) || !strings.HasPrefix(athanor, "ath_") || !strings.HasPrefix(client, "pcl_") {
		return nil, fmt.Errorf("%w: CYFR asked to certify something other than this device here", ErrRefused)
	}
	return &Certification{Audience: b.Home, Athanor: athanor, ClientID: client, DeviceKey: b.DeviceKey}, nil
}

// Elsewhere checks that got certifies exactly what c asked: a v1
// certificate for c's client, athanor and key at c's audience, issued by
// the home got names, another than the audience, for an identity (its
// identifier and key epoch named). Anything else is not used.
func Elsewhere(got Certified, c Certification) error {
	if certifies(got.Certificate, c.Audience, c.Athanor, c.ClientID, c.DeviceKey) != nil {
		return ErrCertifiedOther
	}
	var s struct {
		Subject struct {
			Kind       string `json:"kind"`
			Identifier string `json:"identifier"`
			KeyEpoch   string `json:"key_epoch"`
		} `json:"subject"`
	}
	i := readIssued(got.Certificate)
	if json.Unmarshal(got.Certificate, &s) != nil || s.Subject.Kind != "identity" || s.Subject.Identifier == "" ||
		s.Subject.KeyEpoch == "" || got.Issuer == "" || !sameOrigin(i.Issuer, got.Issuer) || sameOrigin(i.Issuer, c.Audience) {
		return ErrCertifiedOther
	}
	return nil
}

// sameOrigin is whether two origins name one home, a trailing slash and
// the case of the scheme and host aside.
func sameOrigin(a, b string) bool {
	return a != "" && strings.EqualFold(strings.TrimRight(a, "/"), strings.TrimRight(b, "/"))
}

// certifies checks that cert is a certificate for exactly this device at
// this home: its client, athanor, key and audience. Anything else is not
// kept.
func certifies(cert json.RawMessage, home, athanor, clientID string, key []byte) error {
	var c struct {
		Protocol  string `json:"protocol"`
		Athanor   string `json:"athanor"`
		ClientID  string `json:"client_id"`
		DeviceKey string `json:"device_key"`
		Audience  string `json:"audience"`
		Issuer    string `json:"issuer"`
		ExpiresAt int64  `json:"expires_at"`
	}
	if json.Unmarshal(cert, &c) != nil || c.Protocol != "cyfr-device-cert/v1" || c.Athanor != athanor ||
		c.ClientID != clientID || c.DeviceKey != b64(key) || c.Audience != home || c.Issuer == "" || c.ExpiresAt == 0 {
		return fmt.Errorf("%w: the certificate is not for this device at this CYFR", ErrRefused)
	}
	return nil
}
