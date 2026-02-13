package cmd

import (
	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/ref"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(searchCmd)
	rootCmd.AddCommand(inspectCmd)
	rootCmd.AddCommand(pullCmd)
	rootCmd.AddCommand(resolveCmd)
	rootCmd.AddCommand(publishCmd)
}

var searchCmd = &cobra.Command{
	Use:     "search <query>",
	Short:   "Search for components",
	GroupID: "component",
	Long:    "Search the component registry by keyword and return matching references.",
	Example: `  cyfr search sentiment
  cyfr search "http client" --json`,
	Args: cobra.MinimumNArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("component", map[string]any{
			"action": "search",
			"query":  args[0],
		})
		if err != nil {
			output.Errorf("Search failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var inspectCmd = &cobra.Command{
	Use:     "inspect [type] <reference>",
	Short:   "Show component details",
	GroupID: "component",
	Long:    "Display metadata, version history, and capability declarations for a component.",
	Example: `  cyfr inspect c:local.claude:0.1.0
  cyfr inspect c local.claude:0.1.0
  cyfr inspect local.sentiment:1.0.0`,
	Args: cobra.RangeArgs(1, 2),
	Run: func(cmd *cobra.Command, args []string) {
		args = joinTypeShorthand(args)
		normalized, err := normalizeComponentRef(args[0])
		if err != nil {
			output.Errorf("Invalid component reference: %v", err)
		}
		client := newClient()
		result, err := client.CallTool("component", map[string]any{
			"action":    "inspect",
			"reference": normalized,
		})
		if err != nil {
			output.Errorf("Inspect failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var pullCmd = &cobra.Command{
	Use:     "pull [type] <reference>",
	Short:   "Fetch component to cache",
	GroupID: "component",
	Long:    "Download a component WASM artifact to the local cache so it is available for offline execution.",
	Example: `  cyfr pull c:local.claude:0.1.0
  cyfr pull cyfr.sentiment:1.0.0`,
	Args: cobra.RangeArgs(1, 2),
	Run: func(cmd *cobra.Command, args []string) {
		args = joinTypeShorthand(args)
		normalized, err := normalizeComponentRef(args[0])
		if err != nil {
			output.Errorf("Invalid component reference: %v", err)
		}
		client := newClient()
		result, err := client.CallTool("component", map[string]any{
			"action":    "pull",
			"reference": normalized,
		})
		if err != nil {
			output.Errorf("Pull failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var resolveCmd = &cobra.Command{
	Use:     "resolve [type] <reference>",
	Short:   "Resolve component location",
	GroupID: "component",
	Long:    "Resolve a component reference to its registry URL and cached file path.",
	Example: `  cyfr resolve c:local.claude:0.1.0
  cyfr resolve cyfr.sentiment:1.0.0`,
	Args: cobra.RangeArgs(1, 2),
	Run: func(cmd *cobra.Command, args []string) {
		args = joinTypeShorthand(args)
		normalized, err := normalizeComponentRef(args[0])
		if err != nil {
			output.Errorf("Invalid component reference: %v", err)
		}
		client := newClient()
		result, err := client.CallTool("component", map[string]any{
			"action":    "resolve",
			"reference": normalized,
		})
		if err != nil {
			output.Errorf("Resolve failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var publishCmd = &cobra.Command{
	Use:     "publish [type] <reference>",
	Short:   "Sign and publish component",
	GroupID: "component",
	Long:    "Sign a local component and publish it to the registry, making it available for execution.",
	Example: `  cyfr publish r:local.sentiment:1.0.0
  cyfr publish local.sentiment:1.0.0`,
	Args: cobra.RangeArgs(1, 2),
	Run: func(cmd *cobra.Command, args []string) {
		args = joinTypeShorthand(args)
		normalized, err := normalizeComponentRef(args[0])
		if err != nil {
			output.Errorf("Invalid component reference: %v", err)
		}
		client := newClient()
		result, err := client.CallTool("component", map[string]any{
			"action":    "publish",
			"reference": normalized,
		})
		if err != nil {
			output.Errorf("Publish failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

// normalizeComponentRef normalizes a component reference to canonical format.
// Returns an error if the reference is invalid or missing a type prefix.
func normalizeComponentRef(s string) (string, error) {
	return ref.Normalize(s)
}
