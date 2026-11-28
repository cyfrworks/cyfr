// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package link owns a server's tunnel key as cyfr keeps it: the key pair
// `cyfr init` mints, and the private name and address its public half
// gives the server. tests/fixtures/link.json binds it to
// Cyfr.RuntimeConfig (private_name/1, resolve_link/3), which derives the
// same name from the same key.
package link

import (
	"crypto/ecdh"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/hex"
	"regexp"
	"strconv"
	"strings"
)

// The .env names of the tunnel key: its private half and pre-shared key,
// read by the link service alone, and its public half, which names the
// server's private address.
const (
	KeyVar    = "CYFR_LINK_KEY"
	PublicVar = "CYFR_LINK_PUBLIC"
)

// Public is a tunnel public key, the X25519 public half.
type Public [32]byte

var (
	publicText  = regexp.MustCompile(`^[0-9a-f]{64}$`)
	privateHost = regexp.MustCompile(`^h-[a-z2-7]{16}\.localhost$`)
	base32Lower = base32.NewEncoding("abcdefghijklmnopqrstuvwxyz234567").WithPadding(base32.NoPadding)
)

// ParsePublic reads CYFR_LINK_PUBLIC's text: exactly 64 lowercase
// hexadecimal digits, the form `cyfr init` writes and the boot reads.
func ParsePublic(text string) (Public, bool) {
	var p Public
	if !publicText.MatchString(text) {
		return p, false
	}
	_, err := hex.Decode(p[:], []byte(text))
	return p, err == nil
}

// String is p as CYFR_LINK_PUBLIC holds it.
func (p Public) String() string { return hex.EncodeToString(p[:]) }

// Name is the server's private name: `h-` and the first 16 characters of
// the lowercase, unpadded base32 (RFC 4648) of the SHA-256 of the key's
// 32 bytes, 80 bits in 18 characters.
func (p Public) Name() string {
	sum := sha256.Sum256(p[:])
	return "h-" + base32Lower.EncodeToString(sum[:])[:16]
}

// Address is the server's private address on port:
// http://<private name>.localhost:<port>, the address its own machine
// reaches it at whatever browser address it has. It is the origin as a
// browser serialises it, so on port 80, http's default, it has no port.
func (p Public) Address(port int) string {
	if port == 80 {
		return "http://" + p.Name() + ".localhost"
	}
	return "http://" + p.Name() + ".localhost:" + strconv.Itoa(port)
}

// PrivateHost reports whether host is a private name under localhost, as
// Address spells it: the one host at which a server's own machine takes
// that server's plain-http account service. The name says nothing of
// which server it is: a caller compares it with the address it derived
// from the server's own key.
func PrivateHost(host string) bool { return privateHost.MatchString(host) }

// Mint is a new tunnel key: CYFR_LINK_KEY's text, the private key and the
// pre-shared key in the text forms the link service reads
// (`privkey:<hex>,psk:<hex>`), and the public half. The private key is 32
// random bytes clamped as an X25519 node key is; the pre-shared key is 32
// random bytes, never all zero.
func Mint() (string, Public, error) {
	var private, psk [32]byte
	if _, err := rand.Read(private[:]); err != nil {
		return "", Public{}, err
	}
	private[0] &= 248
	private[31] = (private[31] & 127) | 64
	for psk == ([32]byte{}) {
		if _, err := rand.Read(psk[:]); err != nil {
			return "", Public{}, err
		}
	}
	k, err := ecdh.X25519().NewPrivateKey(private[:])
	if err != nil {
		return "", Public{}, err
	}
	var public Public
	copy(public[:], k.PublicKey().Bytes())
	return strings.Join([]string{"privkey:" + hex.EncodeToString(private[:]), "psk:" + hex.EncodeToString(psk[:])}, ","), public, nil
}
