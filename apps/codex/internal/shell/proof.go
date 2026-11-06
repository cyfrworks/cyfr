// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/cyfr/codex/internal/account"
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
		"unlock":  {"session_id"},
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
// it signs to name: the CYFR it talks to, its own key, and the athanor and
// client that CYFR admitted it as.
type Binding struct {
	Home      string
	Athanor   string
	ClientID  string
	DeviceKey []byte
}

// ErrRefusedChallenge is a challenge this device will not sign.
var ErrRefusedChallenge = errors.New("the home's challenge does not match what this device asked for")

// Challenge decodes a challenge the home sent and checks it field by field
// against purpose and the binding before it can be signed: the exact field
// list, the protocol, unpadded base64url values of the right lengths, and
// every bound value equal to what this device expects.
func Challenge(raw json.RawMessage, purpose string, b Binding) (map[string]any, error) {
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
				return nil, fmt.Errorf("%w: %s", ErrRefusedChallenge, f)
			}
			if i, err := strconv.ParseInt(n.String(), 10, 64); err != nil || i < 0 {
				return nil, fmt.Errorf("%w: %s", ErrRefusedChallenge, f)
			}
			continue
		}
		s, ok := v.(string)
		if !ok {
			return nil, fmt.Errorf("%w: %s", ErrRefusedChallenge, f)
		}
		if err := checkField(f, s, purpose, b); err != nil {
			return nil, err
		}
	}
	return m, nil
}

func checkField(f, s, purpose string, b Binding) error {
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
		if s != b.Athanor || !strings.HasPrefix(s, "ath_") {
			return bad
		}
	case "client_id":
		if s != b.ClientID || !strings.HasPrefix(s, "pcl_") {
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
	case "session_id":
		// The session an unlock reserves is the home's alone to choose,
		// so it is only well-formed here.
		if !idShape.MatchString(s) {
			return bad
		}
	default:
		return bad
	}
	return nil
}

var idShape = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

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
	msg, err := account.JCS(challenge)
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

func b64(raw []byte) string { return base64.RawURLEncoding.EncodeToString(raw) }

func unb64(s string) ([]byte, error) {
	raw, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil || b64(raw) != s {
		return nil, errors.New("not unpadded base64url")
	}
	return raw, nil
}
