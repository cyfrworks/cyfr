// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
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
