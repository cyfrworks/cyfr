package cmd

import (
	"fmt"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(contextCmd)
	contextCmd.AddCommand(contextListCmd)
	contextCmd.AddCommand(contextSetCmd)
	contextCmd.AddCommand(contextAddCmd)
}

var contextCmd = &cobra.Command{
	Use:     "context",
	Short:   "Manage server connections (local only)",
	GroupID: "advanced",
	Long:    "Add, list, and switch between CYFR server connections. Use contexts to manage multiple instances (e.g. local, staging, production) from a single CLI installation.",
}

var contextListCmd = &cobra.Command{
	Use:     "list",
	Short:   "Show all contexts",
	Long:    "Show all configured server contexts. The active context is marked with an asterisk (*).",
	Example: "  cyfr context list",
	Run: func(cmd *cobra.Command, args []string) {
		cfg, err := config.Load()
		if err != nil {
			output.Errorf("Failed to load config: %v", err)
		}

		if flagJSON {
			output.JSON(cfg)
			return
		}

		for name, ctx := range cfg.Contexts {
			marker := "  "
			if name == cfg.CurrentContext {
				marker = "* "
			}
			fmt.Printf("%s%-15s %s\n", marker, name, ctx.URL)
		}
	},
}

var contextSetCmd = &cobra.Command{
	Use:     "set <name>",
	Short:   "Switch active context",
	Long:    "Set the named context as the active server connection for all subsequent commands.",
	Example: "  cyfr context set production",
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		name := args[0]

		cfg, err := config.Load()
		if err != nil {
			output.Errorf("Failed to load config: %v", err)
		}

		if _, ok := cfg.Contexts[name]; !ok {
			output.Errorf("Context '%s' not found. Use 'cyfr context add' first.", name)
		}

		cfg.CurrentContext = name
		if err := cfg.Save(); err != nil {
			output.Errorf("Failed to save config: %v", err)
		}

		fmt.Printf("Switched to context '%s' (%s)\n", name, cfg.Contexts[name].URL)
	},
}

var contextAddCmd = &cobra.Command{
	Use:   "add <name> <url>",
	Short: "Add a new server connection",
	Long:  "Register a new CYFR server connection by name and URL.",
	Example: `  cyfr context add local http://localhost:4000
  cyfr context add cloud https://cyfr.example.com
  cyfr context add enterprise https://cyfr.corp.internal:4000`,
	Args: cobra.ExactArgs(2),
	Run: func(cmd *cobra.Command, args []string) {
		name := args[0]
		url := args[1]

		cfg, err := config.Load()
		if err != nil {
			output.Errorf("Failed to load config: %v", err)
		}

		cfg.Contexts[name] = &config.Context{URL: url}
		if err := cfg.Save(); err != nil {
			output.Errorf("Failed to save config: %v", err)
		}

		fmt.Printf("Added context '%s' (%s)\n", name, url)
	},
}
