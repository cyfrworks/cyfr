package cmd

import (
	"errors"

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
	Short: "CYFR CLI — sandboxed WASM runtime for AI agents",
	Long: `cyfr is the command-line interface for CYFR — a sandboxed runtime
where AI agents execute tools via MCP. Use cyfr to manage components,
secrets, policies, and executions from the terminal or scripts.`,
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
				"local": {URL: "http://localhost:4000"},
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

	// Wire up auto-recovery: when a session is recovered after expiry,
	// persist the new session ID to config.
	client.OnSessionRecovered = func(sessionID string) {
		saveSessionID(client)
	}

	// Use cached session ID
	ctx := cfg.Current()
	if ctx != nil && ctx.SessionID != "" {
		client.SessionID = ctx.SessionID
	}

	// No cached session — initialize with the server.
	// Without a cached token this returns an unauthenticated session;
	// the user must run `cyfr login` to authenticate.
	if client.SessionID == "" {
		if err := client.Initialize(); err == nil {
			saveSessionID(client)
		}
	}

	return client
}

// handleToolError checks for well-known error sentinels and prints a helpful
// message, otherwise falls back to a contextual or generic error.
// Pass an optional context string (e.g. "Register failed") for the fallback.
func handleToolError(err error, context ...string) {
	if errors.Is(err, mcp.ErrSessionExpired) {
		output.Error("Session expired. Run 'cyfr login' to re-authenticate.")
		return
	}
	if errors.Is(err, mcp.ErrSessionRequired) {
		output.Error("Not logged in. Run 'cyfr login' to authenticate.")
		return
	}
	if errors.Is(err, mcp.ErrAuthRequired) {
		output.Error("Not logged in. Run 'cyfr login' to authenticate.")
		return
	}
	if len(context) > 0 && context[0] != "" {
		output.Errorf("%s: %v", context[0], err)
	} else {
		output.Errorf("Failed: %v", err)
	}
}

// saveSessionID persists the session ID from the client to config.
func saveSessionID(client *mcp.Client) {
	if client.SessionID == "" {
		return
	}
	cfg, err := config.Load()
	if err != nil {
		return
	}
	_ = cfg.SetSessionID(client.SessionID)
}
