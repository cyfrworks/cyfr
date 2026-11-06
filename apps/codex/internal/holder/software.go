// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package holder

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	_ "embed"
	"encoding/binary"
	"errors"
	"fmt"
	"strings"

	"golang.org/x/crypto/argon2"
)

// The software holder's Argon2id parameters (version 1.3). They are fixed:
// Open refuses a record that names others, so editing the file cannot make a
// guess cheaper.
const (
	argonTime    = 3
	argonMemory  = 64 * 1024 // KiB
	argonThreads = 4
	argonKeyLen  = 32 // an AES-256 key
	saltSize     = 16
	nonceSize    = 12
)

// passphraseWords is the number of list words in a passphrase: 66 bits.
const passphraseWords = 6

// wordList is the BIP-0039 English word list: 2048 lowercase words, sorted,
// SHA-256 2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda.
// It comes from https://github.com/bitcoin/bips (bip-0039/english.txt),
// BSD-2-Clause.
//
//go:embed bip39_english.txt
var wordList string

var words = strings.Fields(wordList)

var wordSet = func() map[string]bool {
	set := make(map[string]bool, len(words))
	for _, w := range words {
		set[w] = true
	}
	return set
}()

// SoftwareBlob is a seed encrypted with AES-256-GCM under a key Argon2id
// derives from the passphrase and Salt. The Argon2id parameters are stored
// so a record names what opened it, and Open refuses any but the fixed ones.
type SoftwareBlob struct {
	Salt       []byte `json:"salt"`
	Nonce      []byte `json:"nonce"`
	Ciphertext []byte `json:"ciphertext"`
	Time       uint32 `json:"time"`
	MemoryKiB  uint32 `json:"memory_kib"`
	Threads    uint8  `json:"threads"`
	KeyLen     uint32 `json:"key_len"`
}

// aad is the associated data AES-GCM authenticates with the seed: the record
// version as a 4-byte big-endian integer, then the 32-byte public key. A
// record given another public key or relabelled with another version no
// longer opens.
func (r *Record) aad() []byte {
	b := binary.BigEndian.AppendUint32(nil, uint32(r.Version))
	return append(b, r.PublicKey...)
}

// sealSoftware encrypts seed under passphrase with fresh salt and nonce.
func sealSoftware(seed, passphrase, aad []byte) (*SoftwareBlob, error) {
	b := &SoftwareBlob{Salt: make([]byte, saltSize), Nonce: make([]byte, nonceSize),
		Time: argonTime, MemoryKiB: argonMemory, Threads: argonThreads, KeyLen: argonKeyLen}
	if _, err := rand.Read(b.Salt); err != nil {
		return nil, err
	}
	if _, err := rand.Read(b.Nonce); err != nil {
		return nil, err
	}
	aead, err := passphraseAEAD(passphrase, b.Salt)
	if err != nil {
		return nil, err
	}
	b.Ciphertext = aead.Seal(nil, b.Nonce, seed, aad)
	return b, nil
}

// openSoftware decrypts b's seed with passphrase. The caller erases it.
func openSoftware(b *SoftwareBlob, passphrase, aad []byte) ([]byte, error) {
	if b.Time != argonTime || b.MemoryKiB != argonMemory || b.Threads != argonThreads || b.KeyLen != argonKeyLen {
		return nil, fmt.Errorf("the key record's Argon2id parameters (time %d, memory %d KiB, threads %d, key %d bytes) are not CYFR's",
			b.Time, b.MemoryKiB, b.Threads, b.KeyLen)
	}
	if len(b.Salt) != saltSize || len(b.Nonce) != nonceSize {
		return nil, errors.New("the key record's salt or nonce has the wrong length")
	}
	aead, err := passphraseAEAD(passphrase, b.Salt)
	if err != nil {
		return nil, err
	}
	seed, err := aead.Open(nil, b.Nonce, b.Ciphertext, aad)
	if err != nil {
		return nil, ErrWrongSecret
	}
	return seed, nil
}

// passphraseAEAD derives the AES-256-GCM key from passphrase and salt. The
// derived key is erased here; the AES key schedule the cipher expands from it
// lives inside crypto/aes, beyond this package's reach.
func passphraseAEAD(passphrase, salt []byte) (cipher.AEAD, error) {
	key := argon2.IDKey(passphrase, salt, argonTime, argonMemory, argonThreads, argonKeyLen)
	defer clear(key)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// GeneratePassphrase draws six words uniformly from the 2048-word list, 11
// bits each, from crypto/rand.
func GeneratePassphrase() (string, error) {
	var b [2 * passphraseWords]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	w := make([]string, passphraseWords)
	for i := range w {
		w[i] = words[binary.BigEndian.Uint16(b[2*i:])&2047]
	}
	return strings.Join(w, " "), nil
}

// CheckPassphrase accepts exactly six list words, lowercase, separated by
// single spaces. Digits are never list words, so a PIN is refused.
func CheckPassphrase(p []byte) error {
	fields := bytes.Split(p, []byte(" "))
	if len(fields) != passphraseWords {
		return fmt.Errorf("%w: a passphrase is six words separated by single spaces", ErrSecretShape)
	}
	for i, f := range fields {
		if !wordSet[string(f)] {
			return fmt.Errorf("%w: word %d of the passphrase is not in the word list", ErrSecretShape, i+1)
		}
	}
	return nil
}
