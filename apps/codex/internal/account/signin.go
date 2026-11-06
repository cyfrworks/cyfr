// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package account

import (
	"crypto/sha256"
	"errors"
)

// SignInProtocol is the protocol a CYFR's request carries (Prima.SignIn).
const SignInProtocol = "cyfr-sign-in/v1"

// Request is a request a CYFR minted for one sign-in, confirmation or
// registry signature, as read from its JSON map.
type Request struct {
	Map             map[string]any
	Purpose         string
	Audience        string
	Challenge       []byte
	ExpiresAt       int64
	Return          string
	Subject         string
	RegistryRequest map[string]any
}

var purposeFields = map[string][]string{"sign_in": nil, "confirm": {"subject"}, "registry": {"registry_request"}}

// ReadRequest reads a request from its JSON value in Prima.SignIn's
// order: protocol, purpose, exact fields, audience (a home), challenge
// (32 bytes), expiry, return (a URL on the audience), subject, and the
// registry request to sign.
func ReadRequest(v any) (Request, error) {
	m, ok := v.(map[string]any)
	if !ok {
		return Request{}, invalid("request")
	}
	m = normal(m)
	switch p, ok := m["protocol"]; {
	case !ok:
		return Request{}, &Refusal{Reason: "missing_field", Field: "protocol"}
	case p != SignInProtocol:
		return Request{}, refused("wrong_protocol")
	}
	purpose, _ := m["purpose"].(string)
	own, known := purposeFields[purpose]
	switch {
	case m["purpose"] == nil:
		return Request{}, &Refusal{Reason: "missing_field", Field: "purpose"}
	case !known:
		return Request{}, invalid("purpose")
	}
	if r := fields(m, append([]string{"protocol", "purpose", "audience", "challenge", "expires_at", "return"}, own...), nil); r != nil {
		return Request{}, r
	}
	r := Request{Map: m, Purpose: purpose}
	if !IsHome(m["audience"]) {
		return Request{}, invalid("audience")
	}
	r.Audience = m["audience"].(string)
	if r.Challenge, ok = UnB64(m["challenge"], 32, 32); !ok {
		return Request{}, invalid("challenge")
	}
	if r.ExpiresAt, ok = ms(m["expires_at"]); !ok {
		return Request{}, invalid("expires_at")
	}
	if o, _, ok := DirectoryOrigin(m["return"]); !ok || o != r.Audience {
		return Request{}, invalid("return")
	}
	r.Return = m["return"].(string)
	if s, has := m["subject"]; has {
		if !IsDigest(s) {
			return Request{}, invalid("subject")
		}
		r.Subject = s.(string)
	}
	if rr, has := m["registry_request"]; has {
		read, err := ReadToSign(rr)
		if err != nil {
			return Request{}, invalid("registry_request")
		}
		r.RegistryRequest = read
	}
	if _, err := JCS(m); err != nil {
		return Request{}, invalid(err.(*JCSError).Field)
	}
	return r, nil
}

// Digest is what a device signs for a sign_in or confirm request: the
// SHA-256 of its JCS bytes. A registry request is signed whole instead
// (SignRegistryRequest).
func (r Request) Digest() ([]byte, error) {
	if r.Purpose == "registry" {
		return nil, errors.New("a registry request is signed whole, not by its digest")
	}
	raw, err := JCS(r.Map)
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(raw)
	return sum[:], nil
}

// Answer is a device's answer to a sign_in or confirm request:
// {challenge, kid, sig}, sig the Ed25519 signature over its digest by the
// key whose kid it names.
func (r Request) Answer(kid string, sign func([]byte) []byte) (map[string]any, error) {
	digest, err := r.Digest()
	if err != nil {
		return nil, err
	}
	return map[string]any{"challenge": B64(r.Challenge), "kid": kid, "sig": B64(sign(digest))}, nil
}
