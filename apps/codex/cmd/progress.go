// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"

	"github.com/cyfr/codex/internal/mcp"
)

// randomHex generates n random bytes as a hex string. The id only labels a
// progress stream, so a failed read degrades to a fixed label rather than an
// error path every caller would have to thread.
func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "cli-unknown"
	}
	return hex.EncodeToString(b)
}

// progressPrinter prints progress phases for this request to stderr.
// The command result uses stdout.
func progressPrinter() mcp.ProgressFunc {
	return func(params map[string]any) {
		phase, _ := params["phase"].(string)
		message, _ := params["message"].(string)

		if phase != "" && message != "" {
			fmt.Fprintf(os.Stderr, "[%s] %s\n", phase, message)
		}
	}
}
