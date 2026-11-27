// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package macenvelope is Prima.MacEnvelope in Go: the construction two
// parties sharing a 32-byte root secret use to sign messages and seal
// values to each other, which package workerauth and the pool wire
// (package locuspool) are built on. Prima's module is the one definition;
// the vector files under tests/fixtures hold this package to it.
//
//   - A key is HMAC-SHA256 of the root over a label, or over a label
//     followed by field values one per line (Derive, DeriveFields).
//   - A signature is the unpadded base64url HMAC-SHA256 of the canonical
//     string: "<prefix>/<kind>", each field's value in the envelope's
//     order, then the hex SHA-256 of the raw body, one per line.
//   - A header is "v1 kind=<kind> name=value … body=<hex> mac=<mac>"; Parse
//     reads it back, in any order of its pairs, refusing another version
//     token ("v2") as ErrUnknownVersion before anything else.
//   - A sealed value is base64url(iv ‖ tag ‖ ciphertext), unpadded, under
//     AES-256-GCM, its additional data a label followed by field values one
//     per line; Open opens it under the same label and values only.
//
// Every field value is 1 to 256 bytes of printable ASCII without spaces;
// an integer field takes 0 to 2^53 − 1, written in decimal without leading
// zeros.
//
// A Key prints as "Key(..)" under every verb and refuses to be marshalled,
// and no error of this package names a value, so neither a key nor what a
// peer sent reaches a log through it.
package macenvelope

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
)

const (
	// Version is the one header version this wire reads.
	Version = "v1"
	// Domain names the island and the version of its protocols.
	Domain = "cyfr-locus/v1"
	// AuthHeader is the HTTP header a signature travels in, lowercase.
	AuthHeader = "x-cyfr-auth"
	// MaxInteger is 2^53 − 1, the largest value an integer field takes.
	MaxInteger = 1<<53 - 1
	// MaxText is the most bytes a field value spans.
	MaxText = 256
)

// Services are the services signing under the island's domain, by their
// names within it.
var Services = []string{"builds", "backends", "runtime"}

// Label is the label a service's keys derive over: "<domain>/<service>".
func Label(service string) string { return Domain + "/" + service }

var (
	ErrUnknownVersion = errors.New("unknown_version")
	ErrMalformed      = errors.New("malformed")
	ErrUnsealable     = errors.New("unsealable")
)

// InvalidField is a message whose field Name holds no value its type
// takes. It names the field, never the value.
type InvalidField struct{ Name string }

func (e InvalidField) Error() string { return "invalid_field " + e.Name }

// Key is a 32-byte key. Its methods print it as "Key(..)" under every
// verb, its zero value and a copy alike. Its bytes are held as a pointer
// to a string, which fmt prints as an address wherever it reaches a Key by
// reflection, as it reaches an unexported field of a struct that holds
// one, and never as the bytes; a pointer to an array or a slice would be
// printed whole under a verb it does not take. A Key is never changed
// once made, so copies share its bytes.
type Key struct{ b *string }

const redacted = "Key(..)"

var errUnwritten = errors.New("a key is not written")

func (Key) String() string               { return redacted }
func (Key) GoString() string             { return redacted }
func (Key) Format(f fmt.State, _ rune)   { io.WriteString(f, redacted) }
func (Key) MarshalText() ([]byte, error) { return nil, errUnwritten }
func (Key) MarshalJSON() ([]byte, error) { return nil, errUnwritten }

// Equal is whether k and o are the same key, compared in constant time.
func (k Key) Equal(o Key) bool { return subtle.ConstantTimeCompare(k.bytes(), o.bytes()) == 1 }

// bytes are the key's bytes; the zero Key's are 32 zeroes.
func (k Key) bytes() []byte {
	if k.b == nil {
		return make([]byte, 32)
	}
	return []byte(*k.b)
}

func keyOf(b []byte) Key {
	s := string(b)
	return Key{b: &s}
}

func (k Key) mac(text []byte) []byte {
	m := hmac.New(sha256.New, k.bytes())
	m.Write(text)
	return m.Sum(nil)
}

func (k Key) aead() (cipher.AEAD, error) {
	c, err := aes.NewCipher(k.bytes())
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(c)
}

// DecodeRoot reads a root secret as it is configured: exactly 64
// hexadecimal digits, in either case.
func DecodeRoot(text string) (Key, bool) {
	if len(text) != 64 {
		return Key{}, false
	}
	b, err := hex.DecodeString(text)
	if err != nil {
		return Key{}, false
	}
	defer clear(b)
	return keyOf(b), true
}

// KeyFromBytes is the key of 32 bytes, as a sealed value carries one.
func KeyFromBytes(b []byte) (Key, bool) {
	if len(b) != 32 {
		return Key{}, false
	}
	return keyOf(b), true
}

// Derive is the key HMAC-SHA256 of key over label derives.
func Derive(key Key, label string) Key {
	sum := key.mac([]byte(label))
	defer clear(sum)
	return keyOf(sum)
}

// Type is a field's type.
type Type int

const (
	String Type = iota
	Integer
)

// Field is one field of an envelope; its header name is Name unless
// Header gives another.
type Field struct {
	Name   string
	Type   Type
	Header string
}

func (f Field) header() string {
	if f.Header != "" {
		return f.Header
	}
	return f.Name
}

// Envelope describes one message type.
type Envelope struct {
	Prefix string
	Kind   string
	Fields []Field
}

// Message is a message's fields by name: a string for a string field, a
// uint64 for an integer field.
type Message map[string]any

// Text is whether s is a value a string field takes: 1 to 256 bytes of
// printable ASCII without spaces.
func Text(s string) bool {
	if len(s) < 1 || len(s) > MaxText {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < 0x21 || s[i] > 0x7e {
			return false
		}
	}
	return true
}

// ValidValue is whether v is a value a field of t takes.
func ValidValue(t Type, v any) bool {
	_, ok := write(t, v)
	return ok
}

func write(t Type, v any) (string, bool) {
	switch t {
	case Integer:
		var n uint64
		switch v := v.(type) {
		case uint64:
			n = v
		case int:
			if v < 0 {
				return "", false
			}
			n = uint64(v)
		case int64:
			if v < 0 {
				return "", false
			}
			n = uint64(v)
		default:
			return "", false
		}
		if n > MaxInteger {
			return "", false
		}
		return strconv.FormatUint(n, 10), true
	case String:
		s, ok := v.(string)
		return s, ok && Text(s)
	}
	return "", false
}

func values(fields []Field, m Message) ([]string, error) {
	out := make([]string, len(fields))
	for i, f := range fields {
		v, ok := write(f.Type, m[f.Name])
		if !ok {
			return nil, InvalidField{f.Name}
		}
		out[i] = v
	}
	return out, nil
}

func lines(label string, fields []Field, m Message) (string, error) {
	vs, err := values(fields, m)
	if err != nil {
		return "", err
	}
	return strings.Join(append([]string{label}, vs...), "\n"), nil
}

// DeriveFields is the key derived from key over label and the message's
// fields, one per line.
func DeriveFields(key Key, label string, fields []Field, m Message) (Key, error) {
	text, err := lines(label, fields, m)
	if err != nil {
		return Key{}, err
	}
	return Derive(key, text), nil
}

// BodyHash is the hex SHA-256 of body, as a header names it.
func BodyHash(body []byte) string {
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}

func (e Envelope) canonical(vs []string, bodyHash string) string {
	return strings.Join(append(append([]string{e.Prefix + "/" + e.Kind}, vs...), bodyHash), "\n")
}

// Canonical is the string a signature of m and body covers.
func (e Envelope) Canonical(m Message, body []byte) (string, error) {
	vs, err := values(e.Fields, m)
	if err != nil {
		return "", err
	}
	return e.canonical(vs, BodyHash(body)), nil
}

// Header is the v1 header carrying the signature of m and body with key.
func (e Envelope) Header(key Key, m Message, body []byte) (string, error) {
	vs, err := values(e.Fields, m)
	if err != nil {
		return "", err
	}
	hash := BodyHash(body)
	var b strings.Builder
	b.WriteString(Version + " kind=" + e.Kind)
	for i, f := range e.Fields {
		b.WriteString(" " + f.header() + "=" + vs[i])
	}
	b.WriteString(" body=" + hash + " mac=" + EncodeURL(key.mac([]byte(e.canonical(vs, hash)))))
	return b.String(), nil
}

// versionToken is "v" and a decimal number without leading zeros.
func versionToken(t string) bool {
	if len(t) < 2 || t[0] != 'v' {
		return false
	}
	return decimal(t[1:])
}

func decimal(s string) bool {
	if s == "" || (len(s) > 1 && s[0] == '0') {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// Parsed is a header's fields, the body hash it names and its MAC.
type Parsed struct {
	Message  Message
	BodyHash string
	MAC      string
}

// Parse reads a header: "v1" then name=value tokens each separated by one
// space, kind naming the envelope's kind, every field once under its
// header name, body and mac, in any order and nothing else. A first token
// (the text before the first space) that is a version token other than
// v1 is ErrUnknownVersion; anything else that is no such header is
// ErrMalformed.
func (e Envelope) Parse(header string) (Parsed, error) {
	token, _, _ := strings.Cut(header, " ")
	switch {
	case token == Version:
	case versionToken(token):
		return Parsed{}, ErrUnknownVersion
	default:
		return Parsed{}, ErrMalformed
	}
	tokens := strings.Split(header, " ")[1:]
	pairs := make(map[string]string, len(tokens))
	for _, t := range tokens {
		name, value, found := strings.Cut(t, "=")
		if !found || name == "" {
			return Parsed{}, ErrMalformed
		}
		if _, dup := pairs[name]; dup {
			return Parsed{}, ErrMalformed
		}
		pairs[name] = value
	}
	if len(pairs) != len(e.Fields)+3 {
		return Parsed{}, ErrMalformed
	}
	for _, name := range append(e.names(), "kind", "body", "mac") {
		if _, ok := pairs[name]; !ok {
			return Parsed{}, ErrMalformed
		}
	}
	if pairs["kind"] != e.Kind || !Text(pairs["mac"]) {
		return Parsed{}, ErrMalformed
	}
	m := make(Message, len(e.Fields))
	for _, f := range e.Fields {
		v := pairs[f.header()]
		if !Text(v) {
			return Parsed{}, ErrMalformed
		}
		if f.Type == String {
			m[f.Name] = v
			continue
		}
		if !decimal(v) || len(v) > 16 {
			return Parsed{}, ErrMalformed
		}
		n, err := strconv.ParseUint(v, 10, 64)
		if err != nil || n > MaxInteger {
			return Parsed{}, ErrMalformed
		}
		m[f.Name] = n
	}
	if !lowerHex64(pairs["body"]) {
		return Parsed{}, ErrMalformed
	}
	return Parsed{Message: m, BodyHash: pairs["body"], MAC: pairs["mac"]}, nil
}

func (e Envelope) names() []string {
	out := make([]string, len(e.Fields))
	for i, f := range e.Fields {
		out[i] = f.header()
	}
	sort.Strings(out)
	return out
}

func lowerHex64(s string) bool {
	if len(s) != 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func equal(a, b string) bool { return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1 }

// VerifyHeader is whether mac is the signature, with key, of m and the
// body whose hash the header names, compared in constant time: the first
// half of verifying a message before its body is read.
func (e Envelope) VerifyHeader(key Key, m Message, bodyHash, mac string) bool {
	if !lowerHex64(bodyHash) {
		return false
	}
	vs, err := values(e.Fields, m)
	if err != nil {
		return false
	}
	return equal(EncodeURL(key.mac([]byte(e.canonical(vs, bodyHash)))), mac)
}

// VerifyBody is whether body is the one a verified header named by its
// hash, compared in constant time: the second half.
func VerifyBody(bodyHash string, body []byte) bool {
	return len(bodyHash) == 64 && equal(bodyHash, BodyHash(body))
}

// Verify is whether mac is the signature of m and body with key, and the
// header named body's hash: VerifyHeader and VerifyBody together.
func (e Envelope) Verify(key Key, p Parsed, body []byte) bool {
	return e.VerifyHeader(key, p.Message, p.BodyHash, p.MAC) && VerifyBody(p.BodyHash, body)
}

// Seal seals plaintext with key to label and the message's fields, under
// the 12 bytes of iv, which the caller draws fresh for every seal.
func Seal(key Key, label string, fields []Field, m Message, plaintext, iv []byte) (string, error) {
	if len(iv) != 12 {
		return "", errors.New("an iv is 12 bytes")
	}
	aad, err := lines(label, fields, m)
	if err != nil {
		return "", err
	}
	gcm, err := key.aead()
	if err != nil {
		return "", err
	}
	sealed := gcm.Seal(nil, iv, plaintext, []byte(aad))
	ct, tag := sealed[:len(plaintext)], sealed[len(plaintext):]
	out := make([]byte, 0, 12+16+len(ct))
	out = append(append(append(out, iv...), tag...), ct...)
	return EncodeURL(out), nil
}

// Open opens what Seal sealed with the same key, label and field values;
// anything else is ErrUnsealable, or the InvalidField of a message that
// names no valid value.
func Open(key Key, label string, fields []Field, m Message, sealed string) ([]byte, error) {
	aad, err := lines(label, fields, m)
	if err != nil {
		return nil, err
	}
	raw, ok := DecodeURL(sealed)
	if !ok || len(raw) < 28 {
		return nil, ErrUnsealable
	}
	gcm, err := key.aead()
	if err != nil {
		return nil, ErrUnsealable
	}
	iv, tag, ct := raw[:12], raw[12:28], raw[28:]
	plain, err := gcm.Open(nil, iv, append(append([]byte{}, ct...), tag...), []byte(aad))
	if err != nil {
		return nil, ErrUnsealable
	}
	if plain == nil {
		plain = []byte{}
	}
	return plain, nil
}

// EncodeURL is unpadded base64url.
func EncodeURL(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// DecodeURL reads base64url as Elixir's Base.url_decode64/2 with padding
// false does: without padding or with exactly the padding it would carry,
// bits past the last byte ignored, and nothing outside the alphabet, line
// breaks included (encoding/base64 would skip them).
func DecodeURL(text string) ([]byte, bool) {
	if strings.ContainsAny(text, "\r\n") {
		return nil, false
	}
	if b, err := base64.RawURLEncoding.DecodeString(text); err == nil {
		return b, true
	}
	if !strings.HasSuffix(text, "=") {
		return nil, false
	}
	b, err := base64.URLEncoding.DecodeString(text)
	return b, err == nil
}

// DecodeStd reads standard base64 as Elixir's Base.decode64/1 does: its
// padding required, bits past the last byte ignored, nothing outside the
// alphabet.
func DecodeStd(text string) ([]byte, bool) {
	if strings.ContainsAny(text, "\r\n") {
		return nil, false
	}
	b, err := base64.StdEncoding.DecodeString(text)
	return b, err == nil
}
