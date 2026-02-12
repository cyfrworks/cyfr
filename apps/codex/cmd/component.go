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
	Use:     "inspect <reference>",
	Short:   "Show component details",
	GroupID: "component",
	Long:    "Display metadata, version history, and capability declarations for a component.",
	Example: "  cyfr inspect local.sentiment:1.0.0",
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("component", map[string]any{
			"action":    "inspect",
			"reference": normalizeComponentRef(args[0]),
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
	Use:     "pull <reference>",
	Short:   "Fetch component to cache",
	GroupID: "component",
	Long:    "Download a component WASM artifact to the local cache so it is available for offline execution.",
	Example: "  cyfr pull cyfr.sentiment:1.0.0",
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("component", map[string]any{
			"action":    "pull",
			"reference": normalizeComponentRef(args[0]),
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
	Use:     "resolve <reference>",
	Short:   "Resolve component location",
	GroupID: "component",
	Long:    "Resolve a component reference to its registry URL and cached file path.",
	Example: "  cyfr resolve cyfr.sentiment:1.0.0",
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("component", map[string]any{
			"action":    "resolve",
			"reference": normalizeComponentRef(args[0]),
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
	Use:     "publish <reference>",
	Short:   "Sign and publish component",
	GroupID: "component",
	Long:    "Sign a local component and publish it to the registry, making it available for execution.",
	Example: "  cyfr publish local.sentiment:1.0.0",
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("component", map[string]any{
			"action":    "publish",
			"reference": normalizeComponentRef(args[0]),
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
// Falls back to the original string if parsing fails.
func normalizeComponentRef(s string) string {
	normalized, err := ref.Normalize(s)
	if err != nil {
		return s
	}
	return normalized
}
