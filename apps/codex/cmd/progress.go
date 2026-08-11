package cmd

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"

	"github.com/cyfr/codex/internal/mcp"
)

// randomHex generates n random bytes as a hex string.
func randomHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// progressPrinter returns a handler that prints progress phases to stderr.
//
// Progress arrives on the response stream of the call that produced it, so
// there is nothing to open, nothing to close, and no id to match against: every
// notification the handler sees belongs to this request. The idField/idValue
// filtering the previous implementation needed existed only because a single
// shared stream carried every caller's progress at once.
//
// stderr rather than stdout: the command's actual result goes to stdout and is
// routinely piped into jq.
func progressPrinter() mcp.ProgressFunc {
	return func(params map[string]any) {
		phase, _ := params["phase"].(string)
		message, _ := params["message"].(string)

		if phase != "" && message != "" {
			fmt.Fprintf(os.Stderr, "[%s] %s\n", phase, message)
		}
	}
}
