package cmd

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
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

// streamProgress opens an SSE stream and prints progress notifications
// matching the given idField/idValue to stderr. Returns a cleanup function.
func streamProgress(client *mcp.Client, idField, idValue string) func() {
	stream, err := client.OpenStream("")
	if err != nil {
		// Non-fatal: progress just won't be shown
		return func() {}
	}

	done := make(chan struct{})

	go func() {
		defer close(done)
		for event := range stream.Events {
			var msg struct {
				Method string          `json:"method"`
				Params json.RawMessage `json:"params"`
			}
			if err := json.Unmarshal(event.Data, &msg); err != nil {
				continue
			}
			if msg.Method != "notifications/progress" {
				continue
			}

			var params map[string]any
			if err := json.Unmarshal(msg.Params, &params); err != nil {
				continue
			}

			if id, ok := params[idField].(string); !ok || id != idValue {
				continue
			}

			phase, _ := params["phase"].(string)
			message, _ := params["message"].(string)
			if phase != "" && message != "" {
				fmt.Fprintf(os.Stderr, "[%s] %s\n", phase, message)
			}
		}
	}()

	return func() {
		stream.Close()
		<-done
	}
}
