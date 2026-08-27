// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/version"
	"github.com/spf13/cobra"
)

var (
	flagJSON          bool
	flagURL           string
	flagContext       string
	flagNoInteractive bool
	flagVersions      bool

	// activeClient tracks the MCP client for session cleanup on exit.
	activeClient *mcp.Client
)

var rootCmd = &cobra.Command{
	Use:   "cyfr",
	Short: "CYFR CLI — sandboxed component runtime for AI agents",
	Long: `cyfr is the command-line interface for CYFR — a sandboxed runtime
where AI agents execute WASM tools and serve tincture frontends via MCP.
Use cyfr to manage components, connections, consents, and executions
from the terminal or scripts.`,
	PersistentPostRun: func(cmd *cobra.Command, args []string) {
		// MCP spec: clients SHOULD send DELETE to terminate sessions on exit.
		if activeClient != nil {
			_ = activeClient.Close()
		}
	},
	// Commands report failures by returning an error (cobra prints it as
	// "Error: …" on stderr); a failure is not a usage mistake, so no help
	// text dump rides along.
	SilenceUsage: true,
}

func init() {
	rootCmd.PersistentFlags().BoolVar(&flagJSON, "json", false, "Output as JSON")
	rootCmd.PersistentFlags().StringVar(&flagURL, "url", "", "Override server URL")
	rootCmd.PersistentFlags().StringVar(&flagContext, "context", "", "Use specific context")
	rootCmd.PersistentFlags().BoolVar(&flagNoInteractive, "no-interactive", false, "Disable interactive prompts")

	rootCmd.AddGroup(
		&cobra.Group{ID: "server", Title: "Server:"},
		&cobra.Group{ID: "identity", Title: "Identity:"},
		&cobra.Group{ID: "component", Title: "Components:"},
		&cobra.Group{ID: "security", Title: "Security:"},
		&cobra.Group{ID: "admin", Title: "Administration:"},
	)

	rootCmd.Version = version.Version
	rootCmd.SetUsageFunc(customUsage)
}

// Execute runs the root command under the process context, so every request
// a command makes is cancellable by Ctrl-C / SIGTERM.
func Execute(ctx context.Context) error {
	return rootCmd.ExecuteContext(ctx)
}

// newClient creates an MCP client from config.
// If no cached session exists, it tries to initialize with the server
// to auto-adopt a session created via browser login (Prism).
func newClient() *mcp.Client {
	cfg, err := config.Load()
	if err != nil {
		cfg = &config.Config{
			CurrentContext: "local",
			Contexts: map[string]*config.Context{
				"local": {URL: "http://127.0.0.1:4000"},
			},
		}
	}

	// Override context if flag is set
	if flagContext != "" {
		cfg.CurrentContext = flagContext
	}

	url := cfg.CurrentURL()
	if flagURL != "" {
		url = flagURL
	}

	client := mcp.NewClient(url)
	activeClient = client

	// The stored credential authenticates every request; there is nothing to
	// establish up front. Without one, commands that need auth will say so.
	ctx := cfg.Current()
	if ctx != nil && ctx.SessionID != "" {
		client.SessionID = ctx.SessionID
	}

	return client
}

// handleToolError maps well-known error sentinels to a helpful message,
// otherwise falls back to a contextual or generic error. Commands return the
// result so cobra prints it and main exits non-zero.
// Pass an optional context string (e.g. "Register failed") for the fallback.
func handleToolError(err error, context ...string) error {
	if errors.Is(err, mcp.ErrAuthRequired) {
		return errors.New("Not logged in. Run 'cyfr login' to authenticate.")
	}
	if msg, ok := explainConsentError(err); ok {
		return errors.New(msg)
	}
	if len(context) > 0 && context[0] != "" {
		return fmt.Errorf("%s: %w", context[0], err)
	}
	return fmt.Errorf("Failed: %w", err)
}

// The four §4.3 payloads cross every boundary as "tag: {json}". Render
// them as something an operator can act on instead of raw JSON.
func explainConsentError(err error) (string, bool) {
	text := err.Error()

	for _, tag := range []string{
		"setup_required",
		"consent_required",
		"consent_conflict",
		"restart_required",
	} {
		prefix := tag + ": "
		idx := strings.Index(text, prefix)
		if idx < 0 {
			continue
		}

		var payload map[string]any
		if e := json.Unmarshal([]byte(text[idx+len(prefix):]), &payload); e != nil {
			continue
		}

		return formatConsentError(tag, payload), true
	}

	return "", false
}

func formatConsentError(tag string, payload map[string]any) string {
	switch tag {
	case "setup_required":
		ref, _ := payload["node_ref"].(string)
		need, _ := payload["need"].(string)
		if need != "" {
			return fmt.Sprintf("Setup required: %s needs a connection for %q.\n  Run: cyfr profile grant %s", ref, need, ref)
		}
		return fmt.Sprintf("Setup required: %s is not ready.\n  Run: cyfr profile grant %s", ref, ref)

	case "consent_required":
		rev, _ := payload["current_revision"].(float64)
		return fmt.Sprintf("This app's permissions changed since you approved them (consent rev %.0f).\n  Run: cyfr profile grant <ref> to review and approve.", rev)

	case "consent_conflict":
		cause, _ := payload["cause"].(string)
		actual, _ := payload["actual_revision"].(float64)
		return fmt.Sprintf("Consent changed while you were deciding (%s; current revision %.0f).\n  Re-run the grant to decide against what is true now.", cause, actual)

	case "restart_required":
		rev, _ := payload["new_revision"].(float64)
		return fmt.Sprintf("Approved (consent rev %.0f) — re-run the command to continue.\n  The run that was in flight was stopped rather than re-bound mid-execution.", rev)
	}

	return ""
}

// saveSessionID persists the session ID from the client to config.
func saveSessionID(client *mcp.Client) {
	if client.SessionID == "" {
		return
	}
	cfg, err := config.Load()
	if err != nil {
		output.Debugf("could not load config to persist session id: %v", err)
		return
	}
	if err := cfg.SetSessionID(client.SessionID); err != nil {
		output.Debugf("could not persist session id: %v", err)
	}
}
