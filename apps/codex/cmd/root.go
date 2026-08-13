package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/output"
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
Use cyfr to manage components, secrets, policies, and executions from
the terminal or scripts.`,
	PersistentPostRun: func(cmd *cobra.Command, args []string) {
		// MCP spec: clients SHOULD send DELETE to terminate sessions on exit.
		if activeClient != nil {
			_ = activeClient.Close()
		}
	},
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

	rootCmd.Version = Version
	rootCmd.SetUsageFunc(customUsage)
}

// Execute runs the root command.
func Execute() error {
	return rootCmd.Execute()
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

// handleToolError checks for well-known error sentinels and prints a helpful
// message, otherwise falls back to a contextual or generic error.
// Pass an optional context string (e.g. "Register failed") for the fallback.
func handleToolError(err error, context ...string) {
	if errors.Is(err, mcp.ErrAuthRequired) {
		output.Error("Not logged in. Run 'cyfr login' to authenticate.")
		return
	}
	if msg, ok := explainConsentError(err); ok {
		output.Error(msg)
		return
	}
	if len(context) > 0 && context[0] != "" {
		output.Errorf("%s: %v", context[0], err)
	} else {
		output.Errorf("Failed: %v", err)
	}
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
