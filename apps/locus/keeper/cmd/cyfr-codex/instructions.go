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

// A resume's developer instructions do not reach the thread's history
// (0.169.0), so instructions that changed since the thread was last handed
// some are injected before the resumed thread's first post. An injected
// copy stays in the history for every later request, so unchanged ones
// never are: the driver keeps the SHA-256 of what it last handed, one file
// for each thread, `<codex>/cyfr-instructions/<thread>`, written once
// Codex took them and removed with the thread (forget.go). Every start
// still carries the instructions, which a compaction reads, so their
// presence on the wire says nothing of a change. A record that is missing
// or does not read costs one repeated injection.

const replacingWords = "Your current instructions, in place of any given earlier in this thread:\n"

// instructionsFile is where the thread's record is, in the folder.
func instructionsFile(home, thread string) string {
	return filepath.Join(codexHome(home), "cyfr-instructions", thread)
}

func digest(system string) string {
	sum := sha256.Sum256([]byte(system))
	return hex.EncodeToString(sum[:])
}

// wasHanded says whether the thread was last handed `system`.
func wasHanded(home, thread, system string) bool {
	last, err := os.ReadFile(instructionsFile(home, thread))
	return err == nil && string(last) == digest(system)
}

// recordHanded keeps that the thread was handed `system`. One that cannot
// be written is as a lost one.
func recordHanded(home, thread, system string) {
	file := instructionsFile(home, thread)
	if os.MkdirAll(filepath.Dir(file), 0o700) == nil {
		_ = os.WriteFile(file, []byte(digest(system)), 0o600)
	}
}

// injectInstructions is one developer message in the thread's history
// that says it replaces the instructions before it.
func injectInstructions(id, thread, system string) []byte {
	return request(id, "thread/inject_items", map[string]any{"threadId": thread, "items": []any{map[string]any{
		"type":    "message",
		"role":    "developer",
		"content": []any{map[string]any{"type": "input_text", "text": replacingWords + system}},
	}}})
}

// instructionsRecord is the thread's record if the folder holds one, or
// why that could not be read.
func instructionsRecord(home, thread string) (string, error) {
	file := instructionsFile(home, thread)
	if _, err := os.Lstat(file); err != nil {
		if brainwire.Absent(err) {
			return "", nil
		}
		return "", err
	}
	return file, nil
}
