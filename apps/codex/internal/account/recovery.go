// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package account

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
)

// The recovery code (Prima.RecoveryCode): CYFR- and 112 Crockford base32
// symbols in 14 groups of 8, spelling the 32 digest bytes an identifier
// names, the 32-byte recovery secret and a 6-byte check, the first 6
// bytes of SHA-256 over the protocol string, a zero byte, the digest and
// the secret. The secret is the Ed25519 seed of the account's recovery
// key.
const (
	recoveryProtocol = "cyfr-recovery-code/v1"
	crockford        = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
	recoverySymbols  = (32 + 32 + 6) * 8 / 5
)

// The ways a recovery code is refused, as recovery_code.json names them.
var (
	ErrNotACode = errors.New("not_a_code")
	ErrTypo     = errors.New("typo")
)

// NewRecoverySecret draws a recovery secret: 32 random bytes.
func NewRecoverySecret() []byte {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}

// RecoveryKey is the recovery key a secret derives (RFC 8032).
func RecoveryKey(secret []byte) ed25519.PrivateKey { return ed25519.NewKeyFromSeed(secret) }

func recoveryCheck(digest, secret []byte) []byte {
	h := sha256.New()
	h.Write([]byte(recoveryProtocol))
	h.Write([]byte{0})
	h.Write(digest)
	h.Write(secret)
	return h.Sum(nil)[:6]
}

// EncodeRecoveryCode is the canonical text of the code for identifier and
// secret.
func EncodeRecoveryCode(identifier string, secret []byte) (string, error) {
	digest, ok := UserID(identifier)
	if !ok || len(secret) != 32 {
		return "", errors.New("a recovery code needs an identifier and a 32-byte secret")
	}
	raw := append(append(append([]byte{}, digest...), secret...), recoveryCheck(digest, secret)...)
	var symbols strings.Builder
	var held, bits uint
	for _, b := range raw {
		held = held<<8 | uint(b)
		bits += 8
		for bits >= 5 {
			bits -= 5
			symbols.WriteByte(crockford[held>>bits&31])
		}
		held &= 1<<bits - 1
	}
	s := symbols.String()
	groups := []string{"CYFR"}
	for i := 0; i < len(s); i += 8 {
		groups = append(groups, s[i:i+8])
	}
	return strings.Join(groups, "-"), nil
}

// DecodeRecoveryCode reads text as a person copied it: spaces, tabs, line
// breaks and hyphens dropped, ASCII letters uppercased, O read as 0 and I
// and L as 1. It answers the identifier and the 32-byte secret.
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
	body, ok := strings.CutPrefix(strings.ToUpper(stripped), "CYFR")
	if !ok {
		return "", nil, ErrNotACode
	}
	body = strings.NewReplacer("O", "0", "I", "1", "L", "1").Replace(body)
	if len(body) != recoverySymbols {
		return "", nil, ErrNotACode
	}
	raw := make([]byte, 0, 70)
	var held, bits uint
	for _, c := range body {
		v := strings.IndexRune(crockford, c)
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
	if string(recoveryCheck(digest, secret)) != string(check) {
		return "", nil, ErrTypo
	}
	return "per_" + hex.EncodeToString(digest), append([]byte(nil), secret...), nil
}
