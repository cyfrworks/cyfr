// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"strings"
)

// The recovery code's spelling (tests/fixtures/recovery_code.json, beside
// Prima.RecoveryCode): CYFR- and 112 Crockford base32 symbols spelling the
// 32-byte digest an identifier names, the 32-byte recovery secret and a
// 6-byte check, the first 6 bytes of SHA-256 over the protocol string, a
// zero byte, the digest and the secret.
const (
	recoveryProtocol = "cyfr-recovery-code/v1"
	recoveryAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
	recoverySymbols  = (32 + 32 + 6) * 8 / 5
	kitProtocol      = "cyfr/restore-kit/v1"
)

// The ways a recovery code is refused, as the fixture names them.
var (
	ErrNotACode = errors.New("not_a_code")
	ErrTypo     = errors.New("typo")
)

// DecodeRecoveryCode reads text as a person copied it: separators
// dropped, ASCII letters uppercased, O read as 0 and I and L as 1. It
// answers the identifier (per_ and the digest's hex) and the 32-byte
// secret, the Ed25519 seed of the person's recovery key.
func DecodeRecoveryCode(text string) (string, []byte, error) {
	stripped := strings.Map(func(r rune) rune {
		switch r {
		case ' ', '\t', '\n', '\r', '-':
			return -1
		}
		return r
	}, text)
	for _, r := range stripped {
		if r > 0x7f {
			return "", nil, ErrNotACode
		}
	}
	upper := strings.ToUpper(stripped)
	body, ok := strings.CutPrefix(upper, "CYFR")
	if !ok {
		return "", nil, ErrNotACode
	}
	body = strings.NewReplacer("O", "0", "I", "1", "L", "1").Replace(body)
	if len(body) != recoverySymbols {
		return "", nil, ErrNotACode
	}
	raw := make([]byte, 0, recoverySymbols*5/8)
	var held, bits uint
	for _, c := range body {
		v := strings.IndexRune(recoveryAlphabet, c)
		if v < 0 {
			return "", nil, ErrNotACode
		}
		held = held<<5 | uint(v)
		bits += 5
		if bits >= 8 {
			bits -= 8
			raw = append(raw, byte(held>>bits))
			held &= 1<<bits - 1
		}
	}
	digest, secret, check := raw[:32], raw[32:64], raw[64:]
	sum := sha256.Sum256(append(append(append([]byte(recoveryProtocol), 0), digest...), secret...))
	if string(sum[:6]) != string(check) {
		return "", nil, ErrTypo
	}
	return "per_" + hex.EncodeToString(digest), append([]byte(nil), secret...), nil
}

// KitProof is the proof cyfr/restore-kit/v1 a recovery key gives a home
// restored from a backup: the home's challenge, the identifier and the
// restore's id, signed over their canonical bytes with the protocol.
func KitProof(challenge, identifier, restoreID string, seed []byte) (map[string]any, error) {
	if len(seed) != ed25519.SeedSize {
		return nil, ErrNotACode
	}
	proof := map[string]any{"challenge": challenge, "identifier": identifier, "protocol": kitProtocol, "restore_id": restoreID}
	msg, err := Canonical(proof)
	if err != nil {
		return nil, err
	}
	priv := ed25519.NewKeyFromSeed(seed)
	proof["sig"] = b64(ed25519.Sign(priv, msg))
	clear(priv)
	return proof, nil
}

// reenable brings this screen's paired client back after a declared backup
// restore suspended it: the home's kit challenge for the code's identity,
// the proof its recovery key signs, then pairing.reenable for this
// screen's own client under the restore credential that proof answers.
// The code's secret never leaves this process.
func reenable(ctx context.Context, client *http.Client, address, code, clientID string) error {
	identifier, seed, err := DecodeRecoveryCode(code)
	if err != nil {
		return err
	}
	defer clear(seed)
	var ch struct {
		Challenge string `json:"challenge"`
		RestoreID string `json:"restore_id"`
	}
	if err := post(ctx, client, address, "/restore/kit/challenge", nil, map[string]any{"identifier": identifier}, &ch); err != nil {
		return err
	}
	proof, err := KitProof(ch.Challenge, identifier, ch.RestoreID, seed)
	if err != nil {
		return err
	}
	var granted struct {
		Credential string `json:"credential"`
	}
	if err := post(ctx, client, address, "/restore/kit", nil, map[string]any{"proof": proof}, &granted); err != nil {
		return err
	}
	bearer := http.Header{"Authorization": {"Bearer " + granted.Credential}}
	return post(ctx, client, address, "/restore/kit/reenable", bearer,
		map[string]any{"operation": "pairing.reenable", "client_id": clientID}, nil)
}
