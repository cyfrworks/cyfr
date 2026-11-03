// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"
)

// issued is what a stored certificate says of who issued it and until
// when.
type issued struct {
	Issuer    string `json:"issuer"`
	Audience  string `json:"audience"`
	NotBefore int64  `json:"not_before"`
	ExpiresAt int64  `json:"expires_at"`
}

func readIssued(cert json.RawMessage) issued {
	var i issued
	_ = json.Unmarshal(cert, &i)
	return i
}

// elsewhere is whether the certificate was issued by another home than
// the one it is for: a person whose identity is at their own home. This
// home does not renew it; that home does (RenewAtIssuer).
func (i issued) elsewhere() bool {
	return i.Issuer != "" && strings.TrimRight(i.Issuer, "/") != strings.TrimRight(i.Audience, "/")
}

// due is whether the certificate is past half its life at now.
func (i issued) due(now time.Time) bool {
	return i.ExpiresAt > i.NotBefore && now.UnixMilli() >= i.NotBefore+(i.ExpiresAt-i.NotBefore)/2
}

// ErrCertificationEnded is a certification the issuing home ended or no
// longer holds (its 401, 403, 404 or 409): the device is certified there
// again, never renewed.
var ErrCertificationEnded = errors.New("the CYFR that certified this device ended its certification")

// RenewAtIssuer renews a certificate another home issued, at that home
// (POST <issuer>/certify/v1/renew), with no credential but the device
// key: the stored certificate locates its certification, the issuer
// answers a renew challenge, which is signed only when it names that
// issuer, this device's key and its client; the replacement is kept only
// when it certifies the same person, client, athanor and key for the same
// home, from the same issuer.
func RenewAtIssuer(ctx context.Context, client *http.Client, b Binding, cert json.RawMessage, key Signer) (json.RawMessage, error) {
	i := readIssued(cert)
	if !i.elsewhere() {
		return nil, errors.New("this home issued the certificate; it renews over the device channel")
	}
	issuer := strings.TrimRight(i.Issuer, "/")
	var ch struct {
		Challenge json.RawMessage `json:"challenge"`
	}
	if err := post(ctx, client, issuer, "/certify/v1/renew", nil, map[string]any{"certificate": cert}, &ch); err != nil {
		return nil, issuerFailure(err)
	}
	at := b
	at.Home = issuer
	c, err := Challenge(ch.Challenge, "renew", at, nil)
	if err != nil {
		return nil, err
	}
	proof, err := Prove(c, key)
	if err != nil {
		return nil, err
	}
	var got struct {
		Certificate json.RawMessage `json:"certificate"`
	}
	if err := post(ctx, client, issuer, "/certify/v1/renew", nil, map[string]any{"certificate": cert, "proof": proof}, &got); err != nil {
		return nil, issuerFailure(err)
	}
	if err := certifies(got.Certificate, b.Home, b.Athanor, b.ClientID, b.DeviceKey); err != nil {
		return nil, err
	}
	if readIssued(got.Certificate).Issuer != i.Issuer || !samePerson(cert, got.Certificate) {
		return nil, ErrRefused
	}
	return got.Certificate, nil
}

// samePerson is whether two certificates certify one person: the same
// subject kind and the same person in it, an identity's identifier or a
// local person's id.
func samePerson(a, b json.RawMessage) bool {
	var x, y struct {
		Subject struct {
			Kind       string `json:"kind"`
			Identifier string `json:"identifier"`
			UserID     string `json:"user_id"`
		} `json:"subject"`
	}
	if json.Unmarshal(a, &x) != nil || json.Unmarshal(b, &y) != nil {
		return false
	}
	return x.Subject.Kind != "" && x.Subject == y.Subject
}

func issuerFailure(err error) error {
	var home *HomeError
	if errors.As(err, &home) {
		switch home.Status {
		case http.StatusUnauthorized, http.StatusForbidden, http.StatusNotFound, http.StatusConflict:
			return ErrCertificationEnded
		}
	}
	return err
}
