// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package confirmation names a pending confirmation the way the home does.
//
// A sensitive change that waits for the person's fresh confirmation answers
// the confirmation_required signal with a secret id, to the asking request
// alone. The CLI holds that id in memory to repeat the change and never shows
// it. Everything the person reads names the record by its public ref, a
// one-way function of the id, so this is the one place the CLI derives it.
// Prima.Confirmation.ref/1 is its Elixir twin; tests/fixtures/confirmation.json
// carries the vector both sides reproduce.
package confirmation

import (
	"crypto/sha256"
	"encoding/base64"
)

// RefProtocol is the domain-separation string the ref's hash starts with.
const RefProtocol = "cyfr-confirmation-ref/v1"

// Ref is the public ref of the secret id a confirmation_required signal
// answered: "cnr_" and the unpadded base64url SHA-256 of RefProtocol followed
// by the id. Any holder of the id computes it, and no ref reveals its id.
func Ref(id string) string {
	sum := sha256.Sum256([]byte(RefProtocol + id))
	return "cnr_" + base64.RawURLEncoding.EncodeToString(sum[:])
}
