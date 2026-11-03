// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package holder

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/cloudflare/circl/oprf"
)

// A software record may keep its seed under a six-digit PIN instead of a
// passphrase when the home is another machine: the home holds a key of its
// own for this device (the evaluator) and counts every evaluation. Each
// open blinds the PIN with RFC 9497's OPRF (mode 0, ristretto255-SHA512,
// circl's implementation), the home evaluates the one blinded element under
// that key and charges the attempt, and the unblinded result derives the
// AES-256-GCM key the seed is sealed under. The home sees a random-looking
// element, never the PIN or anything that verifies it; the record alone
// cannot be guessed offline, as every guess needs the home's key.

// pinSuite is the OPRF suite of every PIN record.
var pinSuite = oprf.SuiteRistretto255

// ElementSize is the length of one serialized ristretto255 element, blinded
// or evaluated.
const ElementSize = 32

// pinInfo is HKDF's info for the wrap key of a PIN record.
const pinInfo = "cyfr-device-pin/v1 wrap"

var (
	// ErrNeedsHome means the record's seed is under a PIN its home
	// evaluates: it opens through OpenPIN, never offline.
	ErrNeedsHome = errors.New("this key opens only with its home's answer")
	// ErrBadElement means the home answered something that is not one
	// valid, non-identity ristretto255 element.
	ErrBadElement = errors.New("the home's answer is not a valid evaluated element")
)

// PINBlob is a seed sealed under a key derived from the OPRF output of the
// PIN under the home's evaluator for this device. Evaluator is the
// enrollment-bound identifier by which a locked device asks its home for
// the evaluation; the AES-GCM associated data binds it, so the record
// opens under no other evaluator's name.
type PINBlob struct {
	Evaluator  string `json:"evaluator"`
	Salt       []byte `json:"salt"`
	Nonce      []byte `json:"nonce"`
	Ciphertext []byte `json:"ciphertext"`
}

// Evaluate sends one blinded element to the home, which charges the
// attempt and answers the evaluated element. Nothing else of the PIN
// leaves the holder.
type Evaluate func(blinded []byte) (evaluated []byte, err error)

// HardenPIN reseals k's seed, the key r holds, under pin as the home's
// evaluator names evaluator evaluates it: one evaluation, charged at the
// home like any unlock. It answers a new record and changes neither r
// nor the file: the caller saves it once the home holds the evaluator.
func (r *Record) HardenPIN(k *Key, evaluator string, pin []byte, eval Evaluate) (*Record, error) {
	if err := r.check(); err != nil {
		return nil, err
	}
	if r.Kind != KindSoftware {
		return nil, errors.New("only a software key is kept under a PIN its home evaluates; a chip keeps its own")
	}
	if err := CheckPIN(pin); err != nil {
		return nil, err
	}
	if evaluator == "" {
		return nil, errors.New("the home named no evaluator for this device")
	}
	if !bytes.Equal(k.Public(), r.PublicKey) {
		return nil, errors.New("the key is not this record's")
	}
	out := *r
	out.Software = nil
	out.PIN = &PINBlob{Evaluator: evaluator, Salt: make([]byte, saltSize), Nonce: make([]byte, nonceSize)}
	if _, err := rand.Read(out.PIN.Salt); err != nil {
		return nil, err
	}
	if _, err := rand.Read(out.PIN.Nonce); err != nil {
		return nil, err
	}
	aead, err := pinAEAD(pin, out.PIN.Salt, eval)
	if err != nil {
		return nil, err
	}
	out.PIN.Ciphertext = aead.Seal(nil, out.PIN.Nonce, k.priv[:ed25519.SeedSize], out.pinAAD())
	return &out, nil
}

// OpenPIN opens a PIN record's seed: pin, blinded, is evaluated once by
// the home (eval) and the unblinded result opens the seed. A wrong PIN is
// ErrWrongSecret, after the home charged it; the holder never retries.
func (r *Record) OpenPIN(pin []byte, eval Evaluate) (*Key, error) {
	if err := r.check(); err != nil {
		return nil, err
	}
	if r.PIN == nil {
		return nil, errors.New("this key is not kept under a PIN its home evaluates")
	}
	if err := CheckPIN(pin); err != nil {
		return nil, err
	}
	if len(r.PIN.Salt) != saltSize || len(r.PIN.Nonce) != nonceSize {
		return nil, errors.New("the key record's salt or nonce has the wrong length")
	}
	aead, err := pinAEAD(pin, r.PIN.Salt, eval)
	if err != nil {
		return nil, err
	}
	seed, err := aead.Open(nil, r.PIN.Nonce, r.PIN.Ciphertext, r.pinAAD())
	if err != nil {
		return nil, ErrWrongSecret
	}
	defer clear(seed)
	return r.keyFrom(seed)
}

// Hardened is whether the record's seed is under a PIN its home evaluates.
func (r *Record) Hardened() bool { return r.PIN != nil }

// pinAAD is the software holder's associated data followed by the
// evaluator's length as a 4-byte big-endian integer and its bytes.
func (r *Record) pinAAD() []byte {
	b := binary.BigEndian.AppendUint32(r.aad(), uint32(len(r.PIN.Evaluator)))
	return append(b, r.PIN.Evaluator...)
}

// pinAEAD runs one OPRF round for pin through eval and derives the wrap
// key from its output with HKDF-SHA256 under salt. The output and the
// derived key are erased here.
func pinAEAD(pin, salt []byte, eval Evaluate) (cipher.AEAD, error) {
	output, err := PINOutput(pin, eval)
	if err != nil {
		return nil, err
	}
	defer clear(output)
	key, err := hkdf.Key(sha256.New, output, salt, pinInfo, 32)
	if err != nil {
		return nil, err
	}
	defer clear(key)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// PINOutput is RFC 9497's OPRF output for input pin under the home's key:
// a fresh random blind, one blinded element sent through eval, the one
// evaluated element it answers unblinded and finalized.
func PINOutput(pin []byte, eval Evaluate) ([]byte, error) {
	return oprfRound(oprf.NewClient(pinSuite), pin, eval, nil)
}

// oprfRound is one OPRF round with blind, or a random one when blind is
// nil (the vector tests give RFC 9497's).
func oprfRound(c oprf.Client, input []byte, eval Evaluate, blind []byte) ([]byte, error) {
	var fin *oprf.FinalizeData
	var req *oprf.EvaluationRequest
	var err error
	if blind == nil {
		fin, req, err = c.Blind([][]byte{input})
	} else {
		s := pinSuite.Group().NewScalar()
		if err := s.UnmarshalBinary(blind); err != nil {
			return nil, err
		}
		fin, req, err = c.DeterministicBlind([][]byte{input}, []oprf.Blind{s})
	}
	if err != nil {
		return nil, err
	}
	blinded, err := req.Elements[0].MarshalBinaryCompress()
	if err != nil {
		return nil, err
	}
	answer, err := eval(blinded)
	if err != nil {
		return nil, err
	}
	if len(answer) != ElementSize {
		return nil, ErrBadElement
	}
	e := pinSuite.Group().NewElement()
	if err := e.UnmarshalBinary(answer); err != nil || e.IsIdentity() {
		return nil, ErrBadElement
	}
	out, err := c.Finalize(fin, &oprf.Evaluation{Elements: []oprf.Evaluated{e}})
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrBadElement, err)
	}
	return out[0], nil
}
