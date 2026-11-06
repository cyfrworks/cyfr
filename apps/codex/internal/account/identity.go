// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package account

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"slices"
	"strings"
)

// The identity log's protocol and bounds (Prima.Identity).
const (
	Protocol      = "cyfr-identity/v2"
	maxEntryBytes = 16384
	maxRecovery   = 8
	maxKeys       = 64
)

// Key is a public key the log lists: an Ed25519 device key, or a
// passkey's P-256 point with its credential id.
type Key struct {
	Kid          string
	Alg          string
	Kind         string
	Pub          []byte
	CredentialID []byte
}

// Kid is a public key's kid: sha256:<hex> over its bytes.
func Kid(pub []byte) string {
	sum := sha256.Sum256(pub)
	return "sha256:" + hex.EncodeToString(sum[:])
}

// ShortCode is the code a person compares for a key: the first 16 hex
// digits of its kid, as the account pages show it.
func ShortCode(kid string) string {
	h := strings.TrimPrefix(kid, "sha256:")
	return h[:min(16, len(h))]
}

// RecoverySigner is the signer a recovery key signs as: recovery:<kid>.
func RecoverySigner(pub []byte) string { return "recovery:" + Kid(pub) }

// DeviceKey is the log's key for an Ed25519 device key.
func DeviceKey(pub []byte) Key {
	return Key{Kid: Kid(pub), Alg: "ed25519", Kind: "device", Pub: bytes.Clone(pub)}
}

// Map is a key's JSON map.
func (k Key) Map() map[string]any {
	m := map[string]any{"kid": k.Kid, "alg": k.Alg, "kind": k.Kind, "pub": B64(k.Pub)}
	if k.CredentialID != nil {
		m["credential_id"] = B64(k.CredentialID)
	}
	return m
}

// readKey reads a key from its JSON map: exactly a device's or a
// passkey's fields, its kid its pub's.
func readKey(v any) (Key, bool) {
	m, ok := v.(map[string]any)
	if !ok {
		return Key{}, false
	}
	var k Key
	switch {
	case m["alg"] == "ed25519" && m["kind"] == "device":
		pub, ok := UnB64(m["pub"], 32, 32)
		if !ok || fields(m, []string{"kid", "alg", "kind", "pub"}, nil) != nil {
			return Key{}, false
		}
		k = Key{Alg: "ed25519", Kind: "device", Pub: pub}
	case m["alg"] == "es256" && m["kind"] == "passkey":
		pub, ok := UnB64(m["pub"], 65, 65)
		cid, cok := UnB64(m["credential_id"], 1, 1023)
		if !ok || !cok || pub[0] != 4 || fields(m, []string{"kid", "alg", "kind", "pub", "credential_id"}, nil) != nil {
			return Key{}, false
		}
		k = Key{Alg: "es256", Kind: "passkey", Pub: pub, CredentialID: cid}
	default:
		return Key{}, false
	}
	if m["kid"] != Kid(k.Pub) {
		return Key{}, false
	}
	k.Kid = Kid(k.Pub)
	return k, true
}

// State is what a verified log answers: its identifier and directory, its
// head and position, the keys listed now in the order they were added,
// and the recovery set.
type State struct {
	Identifier string
	Directory  string
	Head       string
	Seq        int64
	Keys       []Key
	Recovery   [][]byte
}

// Key is the listed key kid names.
func (s State) Key(kid string) (Key, bool) {
	i := slices.IndexFunc(s.Keys, func(k Key) bool { return k.Kid == kid })
	if i < 0 {
		return Key{}, false
	}
	return s.Keys[i], true
}

func (s State) recoveryKey(signer string) ([]byte, bool) {
	i := slices.IndexFunc(s.Recovery, func(pub []byte) bool { return RecoverySigner(pub) == signer })
	if i < 0 {
		return nil, false
	}
	return s.Recovery[i], true
}

// Genesis is an unsigned genesis: the account at directory, its recovery
// set, signed by the recovery key signer names.
func Genesis(directory string, recovery [][]byte, at int64, signer string) map[string]any {
	return map[string]any{"protocol": Protocol, "kind": "genesis", "seq": 0, "at": at, "signer": signer,
		"directory": directory, "recovery": b64s(recovery)}
}

// Next is an unsigned entry of kind after the state's head: add_key takes
// {"key": Key.Map()}, remove_key {"kid": kid}.
func Next(s State, kind string, f map[string]any, at int64, signer string) map[string]any {
	e := map[string]any{"protocol": Protocol, "kind": kind, "prev": s.Head, "seq": s.Seq + 1, "at": at, "signer": signer}
	for k, v := range f {
		e[k] = v
	}
	return e
}

func b64s(keys [][]byte) []any {
	out := make([]any, len(keys))
	for i, k := range keys {
		out[i] = B64(k)
	}
	return out
}

// SigningBytes is what an entry's or a request's signer signs: the JCS
// bytes of its map without sig.
func SigningBytes(m map[string]any) ([]byte, error) { return JCS(clone(m, "sig")) }

// Sign is m with sig, Ed25519 under key over SigningBytes(m).
func Sign(m map[string]any, key ed25519.PrivateKey) (map[string]any, error) {
	return SignedBy(m, func(msg []byte) []byte { return ed25519.Sign(key, msg) })
}

// SignedBy is m with sig, sign's Ed25519 signature over SigningBytes(m):
// for a key a holder keeps, which signs without handing its seed out.
func SignedBy(m map[string]any, sign func([]byte) []byte) (map[string]any, error) {
	msg, err := SigningBytes(m)
	if err != nil {
		return nil, err
	}
	out := clone(m, "sig")
	out["sig"] = B64(sign(msg))
	return out, nil
}

// Hash is an entry's hash: sha256:<hex> over its JCS bytes.
func Hash(entry map[string]any) (string, error) {
	raw, err := JCS(normal(entry))
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(raw)
	return "sha256:" + hex.EncodeToString(sum[:]), nil
}

// Identifier is the account a genesis makes: per_ and the hex of SHA-256
// over its JCS bytes.
func Identifier(genesis map[string]any) (string, error) {
	h, err := Hash(genesis)
	return "per_" + strings.TrimPrefix(h, "sha256:"), err
}

// normal is an entry made by this side read back as one received, its
// numbers json.Number, so its JCS bytes are the same either way.
func normal(m map[string]any) map[string]any {
	raw, err := json.Marshal(m)
	if err != nil {
		return m
	}
	v, err := Decode(raw)
	if out, ok := v.(map[string]any); err == nil && ok {
		return out
	}
	return m
}

// UserID is the 32 bytes an identifier spells, a passkey's user.id.
func UserID(identifier string) ([]byte, bool) {
	if !IsIdentifier(identifier) {
		return nil, false
	}
	raw, err := hex.DecodeString(identifier[4:])
	return raw, err == nil
}

// IdentifierForUserID is the identifier a passkey's user handle names.
func IdentifierForUserID(raw []byte) (string, bool) {
	if len(raw) != 32 {
		return "", false
	}
	return "per_" + hex.EncodeToString(raw), true
}

var (
	kindFields = map[string][]string{
		"genesis":      {"directory", "recovery"},
		"add_key":      {"prev", "key"},
		"remove_key":   {"prev", "kid"},
		"recover":      {"prev", "keys", "recovery"},
		"add_recovery": {"prev", "recovery"},
	}
	signerShape = func(v any) bool {
		s, ok := v.(string)
		return ok && IsDigest(strings.TrimPrefix(s, "recovery:"))
	}
)

// entry is a signed entry as read: its map and the fields its kind holds.
type entry struct {
	m        map[string]any
	kind     string
	prev     string
	seq      int64
	signer   string
	key      Key
	kid      string
	keys     []Key
	recovery [][]byte
}

// readEntry reads a signed entry from its JSON value, in Prima's order:
// JCS, size, protocol, kind, exact fields, then each field's shape.
func readEntry(v any) (*entry, *Refusal) {
	m, ok := v.(map[string]any)
	if !ok {
		return nil, invalid("entry")
	}
	m = normal(m)
	raw, err := JCS(m)
	if err != nil {
		return nil, invalid(err.(*JCSError).Field)
	}
	if len(raw) > maxEntryBytes {
		return nil, refused("too_large")
	}
	switch p, ok := m["protocol"]; {
	case !ok:
		return nil, &Refusal{Reason: "missing_field", Field: "protocol"}
	case p != Protocol:
		return nil, refused("wrong_protocol")
	}
	kind, ok := m["kind"].(string)
	own, known := kindFields[kind]
	switch {
	case m["kind"] == nil:
		return nil, &Refusal{Reason: "missing_field", Field: "kind"}
	case !ok || !known:
		k, _ := json.Marshal(m["kind"])
		if ok {
			return nil, &Refusal{Reason: "unknown_kind", Kind: kind}
		}
		return nil, &Refusal{Reason: "unknown_kind", Kind: string(k)}
	}
	required := append([]string{"protocol", "kind", "seq", "at", "signer"}, own...)
	if r := fields(m, append(required, "sig"), nil); r != nil {
		return nil, r
	}
	e := &entry{m: m, kind: kind}
	if kind == "genesis" {
		if n, ok := m["seq"].(json.Number); !ok || n.String() != "0" {
			return nil, invalid("seq")
		}
	} else if e.seq, ok = ms(m["seq"]); !ok {
		return nil, invalid("seq")
	}
	if _, ok := ms(m["at"]); !ok {
		return nil, invalid("at")
	}
	if !signerShape(m["signer"]) {
		return nil, invalid("signer")
	}
	e.signer = m["signer"].(string)
	if kind != "genesis" {
		if !IsDigest(m["prev"]) {
			return nil, invalid("prev")
		}
		e.prev = m["prev"].(string)
	}
	var r *Refusal
	switch kind {
	case "genesis":
		if !IsDirectoryURL(m["directory"]) {
			return nil, invalid("directory")
		}
		e.recovery, r = recoverySet(m)
	case "add_key":
		if e.key, ok = readKey(m["key"]); !ok {
			r = invalid("key")
		}
	case "remove_key":
		if !IsDigest(m["kid"]) {
			r = invalid("kid")
		} else {
			e.kid = m["kid"].(string)
		}
	case "recover":
		if e.keys, ok = keyList(m["keys"]); !ok {
			r = invalid("keys")
		} else {
			e.recovery, r = recoverySet(m)
		}
	case "add_recovery":
		e.recovery, r = recoverySet(m)
	}
	if r != nil {
		return nil, r
	}
	switch sig := m["sig"].(type) {
	case string:
		if _, ok := UnB64(sig, 64, 64); !ok {
			return nil, invalid("sig")
		}
	default:
		if _, ok := readAssertion(sig); !ok {
			return nil, invalid("sig")
		}
	}
	return e, nil
}

func recoverySet(m map[string]any) ([][]byte, *Refusal) {
	list, ok := m["recovery"].([]any)
	if !ok || len(list) == 0 || len(list) > maxRecovery {
		return nil, invalid("recovery")
	}
	out := make([][]byte, 0, len(list))
	for _, v := range list {
		pub, ok := UnB64(v, 32, 32)
		if !ok || slices.ContainsFunc(out, func(p []byte) bool { return bytes.Equal(p, pub) }) {
			return nil, invalid("recovery")
		}
		out = append(out, pub)
	}
	return out, nil
}

func keyList(v any) ([]Key, bool) {
	list, ok := v.([]any)
	if !ok || len(list) > maxKeys {
		return nil, false
	}
	out := make([]Key, 0, len(list))
	for _, e := range list {
		k, ok := readKey(e)
		if !ok {
			return nil, false
		}
		out = append(out, k)
	}
	return out, true
}

// Walk verifies a log from its genesis and answers its state, or the
// index of the first entry refused and why (Prima.Identity.verify_chain).
// Each entry is a decoded JSON map (Decode), so its JCS bytes are the ones
// its signer signed.
func Walk(entries []any) (State, error) {
	if len(entries) == 0 {
		return State{}, &Refusal{Reason: "empty"}
	}
	s, r := begin(entries[0])
	if r != nil {
		return State{}, r
	}
	for i, e := range entries[1:] {
		if s, r = extend(s, e); r != nil {
			r.Index = i + 1
			return State{}, r
		}
	}
	return s, nil
}

func begin(v any) (State, *Refusal) {
	e, r := readEntry(v)
	if r != nil {
		return State{}, r
	}
	if e.kind != "genesis" {
		return State{}, refused("not_genesis")
	}
	i := slices.IndexFunc(e.recovery, func(pub []byte) bool { return RecoverySigner(pub) == e.signer })
	if i < 0 || !ed25519Signed(e.m, e.recovery[i]) {
		return State{}, refused("wrong_signer")
	}
	head, _ := Hash(e.m)
	return State{Identifier: "per_" + strings.TrimPrefix(head, "sha256:"), Directory: e.m["directory"].(string),
		Head: head, Recovery: e.recovery}, nil
}

func extend(s State, v any) (State, *Refusal) {
	e, r := readEntry(v)
	if r != nil {
		return s, r
	}
	if e.kind == "genesis" {
		return s, refused("unexpected_genesis")
	}
	if e.prev != s.Head || e.seq != s.Seq+1 {
		return s, refused("broken_link")
	}
	if !authorized(e, s) || !signed(e, s) {
		return s, refused("wrong_signer")
	}
	switch e.kind {
	case "add_key":
		if _, listed := s.Key(e.key.Kid); listed {
			return s, refused("duplicate_key")
		}
		s.Keys = append(slices.Clone(s.Keys), e.key)
	case "remove_key":
		if _, listed := s.Key(e.kid); !listed {
			return s, invalid("kid")
		}
		s.Keys = slices.DeleteFunc(slices.Clone(s.Keys), func(k Key) bool { return k.Kid == e.kid })
	case "recover":
		kids := map[string]bool{}
		for _, k := range e.keys {
			kids[k.Kid] = true
		}
		if len(kids) != len(e.keys) {
			return s, refused("duplicate_key")
		}
		s.Keys, s.Recovery = e.keys, e.recovery
	case "add_recovery":
		for _, pub := range s.Recovery {
			if !slices.ContainsFunc(e.recovery, func(p []byte) bool { return bytes.Equal(p, pub) }) {
				return s, invalid("recovery")
			}
		}
		if len(e.recovery) <= len(s.Recovery) {
			return s, invalid("recovery")
		}
		s.Recovery = e.recovery
	}
	s.Head, _ = Hash(e.m)
	s.Seq = e.seq
	return s, nil
}

// authorized is whether the entry's kind takes its signer: a code alone
// recovers or adds a code, and a key never removes itself.
func authorized(e *entry, s State) bool {
	if strings.HasPrefix(e.signer, "recovery:") {
		_, ok := s.recoveryKey(e.signer)
		return ok
	}
	switch e.kind {
	case "add_key":
	case "remove_key":
		if e.signer == e.kid {
			return false
		}
	default:
		return false
	}
	_, ok := s.Key(e.signer)
	return ok
}

func signed(e *entry, s State) bool {
	if pub, ok := s.recoveryKey(e.signer); ok {
		return ed25519Signed(e.m, pub)
	}
	k, _ := s.Key(e.signer)
	if k.Alg == "ed25519" {
		return ed25519Signed(e.m, k.Pub)
	}
	a, ok := readAssertion(e.m["sig"])
	if !ok {
		return false
	}
	msg, err := SigningBytes(e.m)
	if err != nil {
		return false
	}
	origin, host, _ := DirectoryOrigin(s.Directory)
	challenge := sha256.Sum256(msg)
	return VerifyAssertion(a, k.Pub, challenge[:], origin, host) == nil
}

func ed25519Signed(m map[string]any, pub []byte) bool {
	sig, ok := UnB64(m["sig"], 64, 64)
	if !ok {
		return false
	}
	msg, err := SigningBytes(m)
	return err == nil && ed25519.Verify(pub, msg, sig)
}

// Assertion is a passkey's signature as WebAuthn returned it.
type Assertion struct{ AuthenticatorData, ClientData, Signature []byte }

func readAssertion(v any) (Assertion, bool) {
	m, ok := v.(map[string]any)
	if !ok || fields(m, []string{"authenticator_data", "client_data", "signature"}, nil) != nil {
		return Assertion{}, false
	}
	a, aok := UnB64(m["authenticator_data"], 1, 16384)
	c, cok := UnB64(m["client_data"], 1, 16384)
	sg, sok := UnB64(m["signature"], 1, 16384)
	return Assertion{a, c, sg}, aok && cok && sok
}

// VerifyAssertion checks an assertion by the passkey whose point is pub
// over challenge at the directory whose origin and host are origin and
// rpID, refusing in Prima.Identity.WebAuthn's order.
func VerifyAssertion(a Assertion, pub, challenge []byte, origin, rpID string) error {
	cv, err := Decode(a.ClientData)
	client, ok := cv.(map[string]any)
	if err != nil || !ok {
		return refused("malformed")
	}
	switch {
	case client["type"] != "webauthn.get":
		return refused("wrong_type")
	case client["challenge"] != B64(challenge):
		return refused("wrong_challenge")
	case client["origin"] != origin:
		return refused("wrong_origin")
	case client["crossOrigin"] == true:
		return refused("cross_origin")
	case len(a.AuthenticatorData) < 37:
		return refused("malformed")
	}
	rp := sha256.Sum256([]byte(rpID))
	flags := a.AuthenticatorData[32]
	switch {
	case !bytes.Equal(a.AuthenticatorData[:32], rp[:]):
		return refused("wrong_rp")
	case flags&0x01 == 0:
		return refused("user_not_present")
	case flags&0x04 == 0:
		return refused("user_not_verified")
	}
	key, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), pub)
	if err != nil {
		return refused("bad_signature")
	}
	digest := sha256.Sum256(append(bytes.Clone(a.AuthenticatorData), sha256Of(a.ClientData)...))
	if !ecdsa.VerifyASN1(key, digest[:], a.Signature) {
		return refused("bad_signature")
	}
	return nil
}

func sha256Of(b []byte) []byte { s := sha256.Sum256(b); return s[:] }
