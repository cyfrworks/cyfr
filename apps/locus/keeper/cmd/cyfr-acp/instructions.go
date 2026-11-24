// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"

	"github.com/cyfr/locus/keeper/internal/brainwire"
)

// A program with no place for one process's instructions (profile's
// appends) is handed them as the leading text block of a prompt: a new
// session's first, and a resumed session's next once they changed since it
// was last handed some. A copy in a prompt stays in the session's history
// for every later request, so unchanged ones are never handed again: the
// driver keeps the SHA-256 of what it last handed, one file for each
// session, `<home>/.cache/cyfr-acp/instructions/<session>`, cleared before
// others are handed, written once the prompt carrying them was written, and
// removed with the session (forget.go). So a record stands only for what
// was last handed: one that could not be written is missing, and the next
// start hands the instructions again. Where it cannot even be cleared
// nothing is handed, and the post is refused, since a stale record would
// hide the change.

const replacingWords = "Your current instructions, in place of any given earlier in this session:\n"

// driverFolder is the driver's own folder in the home.
func driverFolder(home string) string { return filepath.Join(home, ".cache", "cyfr-acp") }

func instructionsFile(home, session string) string {
	return filepath.Join(driverFolder(home), "instructions", session)
}

func digest(system string) string {
	sum := sha256.Sum256([]byte(system))
	return hex.EncodeToString(sum[:])
}

// wasHanded says whether the session was last handed `system`.
func wasHanded(home, session, system string) bool {
	last, err := os.ReadFile(instructionsFile(home, session))
	return err == nil && string(last) == digest(system)
}

// clearHanded withdraws the session's record, removed or else emptied in
// place, and says whether none stands.
func clearHanded(home, session string) bool {
	file := instructionsFile(home, session)
	if err := os.Remove(file); err == nil || brainwire.Absent(err) {
		return true
	}
	err := os.Truncate(file, 0)
	return err == nil || brainwire.Absent(err)
}

// recordHanded keeps that the session was handed `system`, after the last
// record was cleared. One that cannot be written is as a lost one.
func recordHanded(home, session, system string) {
	file := instructionsFile(home, session)
	if os.MkdirAll(filepath.Dir(file), 0o700) == nil {
		_ = os.WriteFile(file, []byte(digest(system)), 0o600)
	}
}
