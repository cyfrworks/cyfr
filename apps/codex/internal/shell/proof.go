// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode/utf16"
)

// ProofProtocol is the protocol every device challenge and proof names
// (tests/fixtures/device_cert.json and device_unlock.json).
const ProofProtocol = "cyfr-device-proof/v1"

// The fields every purpose binds (B in the plan's C1), the freshness pair
// (F), and each purpose's own fields. A challenge naming any other field,
// or lacking one, is refused before anything is signed.
var (
	bindingFields = []string{"protocol", "purpose", "home", "athanor", "client_id", "device_key"}
	freshFields   = []string{"nonce", "expires_at"}
	purposeFields = map[string][]string{
		"connect": nil,
		"renew":   nil,
		"pair":    nil,
		"enroll":  {"admission", "request_id"},
		"unlock":  {"session_id"},
		"confirm": {"ref", "digest"},
		"lock":    {"session_id"},
	}
)

// fieldsOf is the exact field list of a purpose's challenge: lock alone
// carries no freshness, since it can only end the one session it names.
func fieldsOf(purpose string) ([]string, bool) {
	own, ok := purposeFields[purpose]
	if !ok {
		return nil, false
	}
	fields := slices.Clone(bindingFields)
	if purpose != "lock" {
		fields = append(fields, freshFields...)
	}
	return append(fields, own...), true
}

// Binding is what this device knows of itself and expects every challenge
// it signs to name: the home it talks to, its own key, and, once enrolled,
// its athanor and client. Enrollment's challenge names the athanor and
// client the home reserved, so an empty Athanor or ClientID accepts any
// well-formed id for that purpose only.
type Binding struct {
	Home      string
	Athanor   string
	ClientID  string
	DeviceKey []byte
}

// Expect is a purpose's own expectations: the values the shell itself
// asked for, never ones a page supplied.
type Expect map[string]string

// ErrRefusedChallenge is a challenge this device will not sign.
var ErrRefusedChallenge = errors.New("the home's challenge does not match what this device asked for")

// Challenge decodes a challenge the home sent and checks it field by field
// against purpose, the binding and expect before it can be signed: the
// exact field list, the protocol, unpadded base64url values of the right
// lengths, and every bound value equal to what this device expects.
func Challenge(raw json.RawMessage, purpose string, b Binding, expect Expect) (map[string]any, error) {
	fields, ok := fieldsOf(purpose)
	if !ok {
		return nil, fmt.Errorf("%w: purpose %q", ErrRefusedChallenge, purpose)
	}
	var m map[string]any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&m); err != nil || dec.More() {
		return nil, fmt.Errorf("%w: not one JSON object", ErrRefusedChallenge)
	}
	if len(m) != len(fields) {
		return nil, fmt.Errorf("%w: its fields are not %s's", ErrRefusedChallenge, purpose)
	}
	for _, f := range fields {
		v, ok := m[f]
		if !ok {
			return nil, fmt.Errorf("%w: no %s", ErrRefusedChallenge, f)
		}
		if f == "expires_at" {
			n, ok := v.(json.Number)
			if !ok {
				return nil, fmt.Errorf("%w: expires_at", ErrRefusedChallenge)
			}
			if _, err := strconv.ParseInt(n.String(), 10, 64); err != nil {
				return nil, fmt.Errorf("%w: expires_at", ErrRefusedChallenge)
			}
			continue
		}
		s, ok := v.(string)
		if !ok {
			return nil, fmt.Errorf("%w: %s", ErrRefusedChallenge, f)
		}
		if err := checkField(f, s, purpose, b, expect); err != nil {
			return nil, err
		}
	}
	return m, nil
}

func checkField(f, s, purpose string, b Binding, expect Expect) error {
	bad := fmt.Errorf("%w: %s", ErrRefusedChallenge, f)
	switch f {
	case "protocol":
		if s != ProofProtocol {
			return bad
		}
	case "purpose":
		if s != purpose {
			return bad
		}
	case "home":
		if s != b.Home {
			return bad
		}
	case "athanor":
		if (b.Athanor != "" && s != b.Athanor) || !strings.HasPrefix(s, "ath_") {
			return bad
		}
	case "client_id":
		if (b.ClientID != "" && s != b.ClientID) || !strings.HasPrefix(s, "pcl_") {
			return bad
		}
	case "device_key":
		if s != b64(b.DeviceKey) || len(b.DeviceKey) != 32 {
			return bad
		}
	case "nonce":
		if raw, err := unb64(s); err != nil || len(raw) != 32 {
			return bad
		}
	default:
		if want, ok := expect[f]; ok {
			if s != want {
				return bad
			}
			return nil
		}
		// What the home alone chooses: the session an unlock reserves and
		// the digest of the record a confirmation names, each only
		// well-formed here. Everything else a purpose binds is what this
		// device asked for.
		switch {
		case f == "session_id" && idShape.MatchString(s):
		case f == "digest" && digestShape.MatchString(s):
		default:
			return bad
		}
	}
	return nil
}

var (
	idShape     = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)
	digestShape = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
)

// Signer is the unlocked key: Sign signs the canonical bytes it is given.
type Signer interface {
	Sign(msg []byte) []byte
}

// Prove signs a checked challenge: the canonical (JCS) bytes of the
// challenge without sig, as an unpadded base64url sig added to the same
// fields.
func Prove(challenge map[string]any, key Signer) (map[string]any, error) {
	if _, ok := challenge["sig"]; ok {
		return nil, fmt.Errorf("%w: it already carries a sig", ErrRefusedChallenge)
	}
	msg, err := Canonical(challenge)
	if err != nil {
		return nil, err
	}
	proof := make(map[string]any, len(challenge)+1)
	for k, v := range challenge {
		proof[k] = v
	}
	proof["sig"] = b64(key.Sign(msg))
	return proof, nil
}

// LockProof is the pre-signed retirement of exactly session: built by this
// device from what it knows, with no freshness, since it can only end the
// one session it names.
func LockProof(b Binding, session string, key Signer) (map[string]any, error) {
	if !strings.HasPrefix(b.Athanor, "ath_") || !strings.HasPrefix(b.ClientID, "pcl_") || session == "" {
		return nil, fmt.Errorf("%w: a lock needs this device's athanor, client and session", ErrRefusedChallenge)
	}
	return Prove(map[string]any{
		"protocol": ProofProtocol, "purpose": "lock", "home": b.Home, "athanor": b.Athanor,
		"client_id": b.ClientID, "device_key": b64(b.DeviceKey), "session_id": session,
	}, key)
}

// Digest is sha256:<hex> over a value's canonical bytes, as
// Prima.Confirmation.digest computes over a confirmation record.
func Digest(v any) (string, error) {
	raw, err := Canonical(v)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(raw)
	return "sha256:" + hex.EncodeToString(sum[:]), nil
}

// Canonical is the RFC 8785 (JCS) encoding of a decoded JSON value whose
// numbers are integers (json.Number, int, int64 or an integral float64):
// keys sorted by UTF-16 code units, strings escaped as ECMAScript's
// JSON.stringify escapes them, no whitespace. A fractional number is
// refused: no wire value this device signs carries one.
func Canonical(v any) ([]byte, error) {
	var buf bytes.Buffer
	if err := canonical(&buf, v); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func canonical(buf *bytes.Buffer, v any) error {
	switch x := v.(type) {
	case nil:
		buf.WriteString("null")
	case bool:
		buf.WriteString(strconv.FormatBool(x))
	case string:
		canonicalString(buf, x)
	case json.Number:
		n, err := strconv.ParseInt(x.String(), 10, 64)
		if err != nil {
			return fmt.Errorf("canonical JSON: %s is not an integer", x)
		}
		buf.WriteString(strconv.FormatInt(n, 10))
	case int:
		buf.WriteString(strconv.Itoa(x))
	case int64:
		buf.WriteString(strconv.FormatInt(x, 10))
	case float64:
		if x != math.Trunc(x) || math.Abs(x) > 1<<53 {
			return fmt.Errorf("canonical JSON: %v is not an integer", x)
		}
		buf.WriteString(strconv.FormatInt(int64(x), 10))
	case []any:
		buf.WriteByte('[')
		for i, e := range x {
			if i > 0 {
				buf.WriteByte(',')
			}
			if err := canonical(buf, e); err != nil {
				return err
			}
		}
		buf.WriteByte(']')
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		slices.SortFunc(keys, func(a, b string) int {
			return slices.Compare(utf16.Encode([]rune(a)), utf16.Encode([]rune(b)))
		})
		buf.WriteByte('{')
		for i, k := range keys {
			if i > 0 {
				buf.WriteByte(',')
			}
			canonicalString(buf, k)
			buf.WriteByte(':')
			if err := canonical(buf, x[k]); err != nil {
				return err
			}
		}
		buf.WriteByte('}')
	default:
		return fmt.Errorf("canonical JSON: unsupported %T", v)
	}
	return nil
}

func canonicalString(buf *bytes.Buffer, s string) {
	buf.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			buf.WriteString(`\"`)
		case '\\':
			buf.WriteString(`\\`)
		case '\b':
			buf.WriteString(`\b`)
		case '\f':
			buf.WriteString(`\f`)
		case '\n':
			buf.WriteString(`\n`)
		case '\r':
			buf.WriteString(`\r`)
		case '\t':
			buf.WriteString(`\t`)
		default:
			if r < 0x20 {
				fmt.Fprintf(buf, `\u%04x`, r)
			} else {
				buf.WriteRune(r)
			}
		}
	}
	buf.WriteByte('"')
}

func b64(raw []byte) string { return base64.RawURLEncoding.EncodeToString(raw) }

func unb64(s string) ([]byte, error) {
	raw, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil || b64(raw) != s {
		return nil, errors.New("not unpadded base64url")
	}
	return raw, nil
}
