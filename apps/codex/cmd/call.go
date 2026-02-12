package cmd

import (
	"encoding/json"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(callCmd)
}

var callCmd = &cobra.Command{
	Use:     "call <tool> [json-args]",
	Short:   "Invoke any MCP tool directly",
	GroupID: "advanced",
	Long:    "Directly invoke any registered MCP tool by name, passing an optional JSON object as arguments. Useful for debugging, scripting, and accessing tools that don't have a dedicated CLI command.",
	Example: `  cyfr call system '{"action":"status"}'
  cyfr call component '{"action":"search","query":"sentiment"}'
  cyfr call secret '{"action":"list"}'`,
	Args: cobra.RangeArgs(1, 2),
	Run: func(cmd *cobra.Command, args []string) {
		toolName := args[0]

		var toolArgs map[string]any
		if len(args) > 1 {
			if err := json.Unmarshal([]byte(args[1]), &toolArgs); err != nil {
				output.Errorf("Invalid JSON: %v", err)
			}
		} else {
			toolArgs = map[string]any{}
		}

		client := newClient()
		result, err := client.CallTool(toolName, toolArgs)
		if err != nil {
			output.Errorf("Failed: %v", err)
		}

		output.JSON(result)
	},
}
