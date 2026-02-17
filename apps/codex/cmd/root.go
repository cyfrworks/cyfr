package cmd

import (
	"errors"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

var (
	flagJSON    bool
	flagURL     string
	flagContext string
)

var rootCmd = &cobra.Command{
	Use:   "cyfr",
	Short: "CYFR CLI — sandboxed WASM runtime for AI agents",
	Long: `cyfr is the command-line interface for CYFR — a sandboxed runtime
where AI agents execute tools via MCP. Use cyfr to manage components,
secrets, policies, and executions from the terminal or scripts.`,
}

func init() {
	rootCmd.PersistentFlags().BoolVar(&flagJSON, "json", false, "Output as JSON")
	rootCmd.PersistentFlags().StringVar(&flagURL, "url", "", "Override server URL")
	rootCmd.PersistentFlags().StringVar(&flagContext, "context", "", "Use specific context")

	rootCmd.AddGroup(
		&cobra.Group{ID: "start", Title: "Getting Started:"},
		&cobra.Group{ID: "exec", Title: "Execution:"},
		&cobra.Group{ID: "component", Title: "Components:"},
		&cobra.Group{ID: "security", Title: "Security:"},
		&cobra.Group{ID: "governance", Title: "Governance:"},
		&cobra.Group{ID: "storage", Title: "Storage:"},
		&cobra.Group{ID: "advanced", Title: "Advanced:"},
	)

	// Cobra already includes a "Use ... --help" footer in the default template
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

	// Use cached session ID
	ctx := cfg.Current()
	if ctx != nil && ctx.SessionID != "" {
		client.SessionID = ctx.SessionID
	}

	// No cached session — try to initialize with the server.
	// If a session was created via browser login, the server will
	// return it in the Mcp-Session-Id response header.
	if client.SessionID == "" {
		if err := client.Initialize(); err == nil {
			saveSessionID(client)
		}
	}

	return client
}

// handleToolError checks for session expiry and prints a helpful message,
// otherwise falls back to a generic error.
func handleToolError(err error) {
	if errors.Is(err, mcp.ErrSessionExpired) {
		output.Error("Session expired. Run 'cyfr login' to re-authenticate.")
	}
	if errors.Is(err, mcp.ErrSessionRequired) {
		output.Error("Not logged in. Run 'cyfr login' to authenticate.")
	}
	output.Errorf("Failed: %v", err)
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
