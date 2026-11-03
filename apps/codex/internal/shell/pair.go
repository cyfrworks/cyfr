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

// ErrCertifyElsewhere is an invitation of a person whose identity is at
// another home, which must certify this device first.
var ErrCertifyElsewhere = errors.New("your identity is kept by another CYFR, which certifies this command line there first; pair it from a browser instead")

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
func Pair(ctx context.Context, call PairCall, b Binding, d Holder, secret string, key Signer) (Paired, error) {
	args := map[string]any{"invitation_secret": secret, "device_key": b64(b.DeviceKey),
		"key_digest": KeyDigest(b.DeviceKey), "holder_kind": d.Kind, "display_name": d.DisplayName}
	got, err := pairOnce(ctx, call, b, args, key)
	if errors.Is(err, ErrUnavailable) {
		got, err = pairOnce(ctx, call, b, args, key)
	}
	return got, err
}

func pairOnce(ctx context.Context, call PairCall, b Binding, args map[string]any, key Signer) (Paired, error) {
	delete(args, "proof")
	asked, err := call(ctx, args)
	if err != nil {
		return Paired{}, err
	}
	if _, ok := asked["certify"]; ok {
		return Paired{}, ErrCertifyElsewhere
	}
	raw, _ := json.Marshal(asked["challenge"])
	c, err := Challenge(raw, "pair", b, nil)
	if err != nil {
		return Paired{}, err
	}
	proof, err := Prove(c, key)
	if err != nil {
		return Paired{}, err
	}
	args["proof"] = proof
	answer, err := call(ctx, args)
	if err != nil {
		return Paired{}, err
	}
	cert, _ := json.Marshal(answer["certificate"])
	got := Paired{ClientID: c["client_id"].(string), Athanor: c["athanor"].(string), Certificate: cert}
	if id, _ := answer["client_id"].(string); id != got.ClientID {
		return Paired{}, fmt.Errorf("%w: the client CYFR answered is not the one its challenge named", ErrRefused)
	}
	if err := certifies(cert, b.Home, got.Athanor, got.ClientID, b.DeviceKey); err != nil {
		return Paired{}, err
	}
	return got, nil
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
