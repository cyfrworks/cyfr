// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"os"

	"github.com/cyfr/locus/keeper/internal/homepath"
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

// driverFolder is the way down to the driver's own folder in the home.
const driverFolder = ".cache/cyfr-acp"

func instructionsPath(home, session string) homepath.Path {
	return homepath.Path{Root: home, Rel: driverFolder + "/instructions/" + session}
}

// instructionsFile is the record's path, for words.
func instructionsFile(home, session string) string { return instructionsPath(home, session).String() }

func digest(system string) string {
	sum := sha256.Sum256([]byte(system))
	return hex.EncodeToString(sum[:])
}

// wasHanded says whether the session was last handed `system`.
func wasHanded(home, session, system string) bool {
	last, err := homepath.ReadFile(instructionsPath(home, session))
	return err == nil && string(last) == digest(system)
}

// clearHanded withdraws the session's record, removed or else emptied in
// place, and says whether none stands.
func clearHanded(home, session string) bool {
	record := instructionsPath(home, session)
	if err := homepath.Remove(record); err == nil || homepath.Absent(err) {
		return true
	}
	f, err := homepath.OpenFile(record, os.O_WRONLY|os.O_TRUNC, 0, false)
	if err != nil {
		return homepath.Absent(err)
	}
	return f.Close() == nil
}

// recordHanded keeps that the session was handed `system`, after the last
// record was cleared. One that cannot be written is as a lost one.
func recordHanded(home, session, system string) {
	_ = homepath.WriteFile(instructionsPath(home, session), []byte(digest(system)))
}
