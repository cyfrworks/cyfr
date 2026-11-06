// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package holder keeps a device's Ed25519 signing key behind a secret only
// the person at the device knows: a six-digit PIN that the device's TPM
// checks (the chip holder), or a generated six-word passphrase stretched with
// Argon2id (the software holder). The home server sees the public key and
// never the PIN, the passphrase or anything that verifies either.
//
// A record holds the protected seed and nothing that opens it. Open asks the
// chip, or runs Argon2id, on every call; no opened key or authorization
// outlives the Key it returns. The package keeps no copy of a PIN or
// passphrase; callers erase their own buffers.
package holder

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
)

// Kind names which holder protects a record's seed.
type Kind string

const (
	// KindChip is a seed sealed in the device's TPM under a six-digit PIN.
	KindChip Kind = "chip"
	// KindSoftware is a seed encrypted under a six-word passphrase.
	KindSoftware Kind = "software"
)

// recordVersion is the only record format this package reads and writes. The
// chip holder's parent and sealed-object templates and the software holder's
// associated-data encoding are part of it.
const recordVersion = 1

var (
	// ErrWrongSecret means the PIN or passphrase does not open the record.
	// A software record edited on disk reports it too: AES-GCM cannot tell
	// an edit from a wrong passphrase.
	ErrWrongSecret = errors.New("wrong PIN or passphrase")
	// ErrLockedOut means the chip refuses every PIN, the right one included,
	// until its lockout interval restores a try.
	ErrLockedOut = errors.New("the chip is locked after too many wrong PINs")
	// ErrNoChip means the device has no TPM the chip holder can use. A
	// *ChipRefusedError matches it too, so one check offers the software
	// holder.
	ErrNoChip = errors.New("this device has no usable TPM chip")
	// ErrSecretShape means the secret is not a six-digit PIN or not a
	// six-word passphrase, whichever the holder needs.
	ErrSecretShape = errors.New("the PIN or passphrase has the wrong shape")
)

// ChipRefusedError means a TPM is present but the chip holder cannot rely on
// it: it could not be provisioned, or its settings do not protect a
// six-digit PIN. errors.Is(err, ErrNoChip) holds for it.
type ChipRefusedError struct {
	Reason string
}

func (e *ChipRefusedError) Error() string {
	return "the chip cannot hold the key: " + e.Reason
}

// Is makes a refused chip match ErrNoChip.
func (e *ChipRefusedError) Is(target error) bool { return target == ErrNoChip }

// Record is a device's key holder as it is stored on disk: the protected
// seed, its public key and what enrollment fills in later. A chip record
// sets Chip alone; a software record sets Software alone.
type Record struct {
	Version   int    `json:"version"`
	Kind      Kind   `json:"kind"`
	Home      string `json:"home"`
	RequestID string `json:"request_id"`
	Admission string `json:"admission"`
	// PublicKey is the raw 32-byte Ed25519 public key; on disk it is an
	// unpadded base64url string.
	PublicKey   []byte          `json:"public_key"`
	Chip        *ChipBlob       `json:"chip,omitempty"`
	Software    *SoftwareBlob   `json:"software,omitempty"`
	ClientID    string          `json:"client_id,omitempty"`
	Athanor     string          `json:"athanor,omitempty"`
	Certificate json.RawMessage `json:"certificate,omitempty"`
}

// ChipBlob is a seed sealed by the TPM: the sealed object's TPM2B_PUBLIC and
// TPM2B_PRIVATE as TPM2_Create returned them. The private part is wrapped by
// a parent key only the same chip, with the same owner seed, re-creates, so
// the blob opens on no other chip and not after the chip is cleared.
type ChipBlob struct {
	Public  []byte `json:"public"`
	Private []byte `json:"private"`
	// Parent is the name of the storage key the seed was sealed under, as
	// computed here from its public area: an unseal salts its session only
	// to a parent of this name, so a device that impersonates the chip on
	// the bus cannot learn the salt and test PINs offline.
	Parent []byte `json:"parent"`
}

// MarshalJSON writes the public key as unpadded base64url.
func (r Record) MarshalJSON() ([]byte, error) {
	type plain Record
	return json.Marshal(struct {
		plain
		PublicKey string `json:"public_key"`
	}{plain(r), base64.RawURLEncoding.EncodeToString(r.PublicKey)})
}

// UnmarshalJSON reads the public key from unpadded base64url.
func (r *Record) UnmarshalJSON(data []byte) error {
	type plain Record
	var v struct {
		plain
		PublicKey string `json:"public_key"`
	}
	if err := json.Unmarshal(data, &v); err != nil {
		return err
	}
	pub, err := base64.RawURLEncoding.Strict().DecodeString(v.PublicKey)
	if err != nil {
		return fmt.Errorf("public_key is not unpadded base64url: %w", err)
	}
	*r = Record(v.plain)
	r.PublicKey = pub
	return nil
}

// check refuses a record this package cannot open as it stands.
func (r *Record) check() error {
	if r.Version != recordVersion {
		return fmt.Errorf("the key record is version %d; this CYFR reads version %d", r.Version, recordVersion)
	}
	switch r.Kind {
	case KindChip:
		if r.Chip == nil || r.Software != nil || len(r.Chip.Parent) == 0 {
			return errors.New("a chip key record must carry the chip's blob and no other")
		}
	case KindSoftware:
		if r.Software == nil || r.Chip != nil {
			return errors.New("a software key record must carry its encrypted blob and no other")
		}
	default:
		return fmt.Errorf("the key record's kind %q is neither %q nor %q", r.Kind, KindChip, KindSoftware)
	}
	if len(r.PublicKey) != ed25519.PublicKeySize {
		return fmt.Errorf("the key record's public key is %d bytes, not %d", len(r.PublicKey), ed25519.PublicKeySize)
	}
	return nil
}

// Load reads the record at path. A missing file reports an error matching
// os.ErrNotExist.
func Load(path string) (*Record, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var r Record
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("read the key record %s: %w", path, err)
	}
	if err := r.check(); err != nil {
		return nil, fmt.Errorf("read the key record %s: %w", path, err)
	}
	return &r, nil
}

// Save replaces the record at path in one step: it writes a private (0600)
// temporary file in the same directory, flushes it, renames it over path and
// flushes the directory, so a crash leaves either the old record or the new
// one.
func (r *Record) Save(path string) error {
	if err := r.check(); err != nil {
		return err
	}
	data, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Dir(path)
	// CreateTemp makes the file 0600.
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".*")
	if err != nil {
		return fmt.Errorf("save the key record %s: %w", path, err)
	}
	defer os.Remove(tmp.Name())
	_, err = tmp.Write(data)
	if err = errors.Join(err, tmp.Sync(), tmp.Close()); err != nil {
		return fmt.Errorf("save the key record %s: %w", path, err)
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return fmt.Errorf("save the key record %s: %w", path, err)
	}
	return syncDir(dir)
}

// syncDir makes a rename in dir durable. Windows cannot flush a directory
// handle, so there the rename is as durable as the filesystem makes it.
func syncDir(dir string) error {
	if runtime.GOOS == "windows" {
		return nil
	}
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	return errors.Join(d.Sync(), d.Close())
}

// chip is the TPM seam. tpm_linux.go installs it when the package loads; in
// a build without that file it stays nil, and NewChip and a chip record's
// Open report ErrNoChip.
var chip *chipOps

type chipOps struct {
	present func() bool
	// seal seals seed under pin and returns the blob; it keeps neither.
	seal func(seed, pin []byte) (*ChipBlob, error)
	// unseal returns the seed sealed in blob; the caller erases it.
	unseal func(blob *ChipBlob, pin []byte) ([]byte, error)
}

// ChipPresent reports whether the device has a TPM device node the chip
// holder could use.
func ChipPresent() bool { return chip != nil && chip.present() }

// NewChip creates a fresh key and seals its seed in the TPM under pin. A
// device without a usable chip reports ErrNoChip or a *ChipRefusedError.
func NewChip(home, requestID, admission string, pin []byte) (*Record, error) {
	if err := CheckPIN(pin); err != nil {
		return nil, err
	}
	if chip == nil {
		return nil, fmt.Errorf("%w: this build has no TPM support", ErrNoChip)
	}
	seed, pub, err := newSeed()
	if err != nil {
		return nil, err
	}
	defer clear(seed)
	blob, err := chip.seal(seed, pin)
	if err != nil {
		return nil, err
	}
	return &Record{Version: recordVersion, Kind: KindChip, Home: home, RequestID: requestID,
		Admission: admission, PublicKey: pub, Chip: blob}, nil
}

// NewSoftware creates a fresh key and encrypts its seed under passphrase,
// which must pass CheckPassphrase.
func NewSoftware(home, requestID, admission string, passphrase []byte) (*Record, error) {
	if err := CheckPassphrase(passphrase); err != nil {
		return nil, err
	}
	seed, pub, err := newSeed()
	if err != nil {
		return nil, err
	}
	defer clear(seed)
	r := &Record{Version: recordVersion, Kind: KindSoftware, Home: home, RequestID: requestID,
		Admission: admission, PublicKey: pub}
	if r.Software, err = sealSoftware(seed, passphrase, r.aad()); err != nil {
		return nil, err
	}
	return r, nil
}

// newSeed draws a new random seed, so a replacement device never reuses an
// old one, and derives its public key. The caller erases the seed.
func newSeed() (seed, pub []byte, err error) {
	seed = make([]byte, ed25519.SeedSize)
	if _, err := rand.Read(seed); err != nil {
		return nil, nil, err
	}
	priv := ed25519.NewKeyFromSeed(seed)
	pub = bytes.Clone(priv[ed25519.SeedSize:])
	clear(priv)
	return seed, pub, nil
}

// Open unseals or decrypts the seed with secret, a PIN for a chip record and
// a passphrase for a software record, and returns the key once its public
// key matches the record's. Every call goes back to the chip or to Argon2id.
func (r *Record) Open(secret []byte) (*Key, error) {
	if err := r.check(); err != nil {
		return nil, err
	}
	var seed []byte
	var err error
	if r.Kind == KindChip {
		if err := CheckPIN(secret); err != nil {
			return nil, err
		}
		if chip == nil {
			return nil, fmt.Errorf("%w: this build has no TPM support", ErrNoChip)
		}
		seed, err = chip.unseal(r.Chip, secret)
	} else {
		if err := CheckPassphrase(secret); err != nil {
			return nil, err
		}
		seed, err = openSoftware(r.Software, secret, r.aad())
	}
	if err != nil {
		return nil, err
	}
	defer clear(seed)
	return r.keyFrom(seed)
}

// keyFrom is the key of an opened seed, once its public key is the
// record's. The caller erases seed.
func (r *Record) keyFrom(seed []byte) (*Key, error) {
	if len(seed) != ed25519.SeedSize {
		return nil, fmt.Errorf("the opened seed is %d bytes, not %d", len(seed), ed25519.SeedSize)
	}
	priv := ed25519.NewKeyFromSeed(seed)
	if !bytes.Equal(priv[ed25519.SeedSize:], r.PublicKey) {
		clear(priv)
		return nil, errors.New("the opened key does not match the key record's public key")
	}
	return &Key{priv: priv}, nil
}

// Key is an opened holder's private key, held in memory until Erase. It must
// not be used after Erase.
type Key struct {
	priv ed25519.PrivateKey
}

// Public returns a copy of the key's public half.
func (k *Key) Public() ed25519.PublicKey { return k.priv.Public().(ed25519.PublicKey) }

// Sign signs msg with Ed25519.
func (k *Key) Sign(msg []byte) []byte { return ed25519.Sign(k.priv, msg) }

// Erase zeroes the private key, whose first half is the seed. It is best
// effort: Go cannot guarantee the bytes are gone from physical memory, since
// the garbage collector may have copied them and crypto/ed25519 derives an
// expanded key on every Sign that this package cannot reach.
func (k *Key) Erase() {
	clear(k.priv)
	k.priv = nil
}

// CheckPIN accepts exactly six ASCII digits.
func CheckPIN(pin []byte) error {
	if len(pin) != 6 {
		return fmt.Errorf("%w: a PIN is six digits", ErrSecretShape)
	}
	for _, c := range pin {
		if c < '0' || c > '9' {
			return fmt.Errorf("%w: a PIN is six digits", ErrSecretShape)
		}
	}
	return nil
}
