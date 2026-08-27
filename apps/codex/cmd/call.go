package cmd

import (
	"encoding/json"
	"fmt"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(callCmd)
}

var callCmd = &cobra.Command{
	Use:     "call <tool> [json-args]",
	Short:   "Invoke any MCP tool directly",
	GroupID: "admin",
	Long:    "Directly invoke any registered MCP tool by name, passing an optional JSON object as arguments. Useful for debugging, scripting, and accessing tools that don't have a dedicated CLI command.",
	Example: `  cyfr call system '{"action":"status"}'
  cyfr call component '{"action":"search","query":"sentiment"}'
  cyfr call vault '{"action":"list"}'`,
	Args: cobra.RangeArgs(1, 2),
	RunE: func(cmd *cobra.Command, args []string) error {
		toolName := args[0]

		var toolArgs map[string]any
		if len(args) > 1 {
			if err := json.Unmarshal([]byte(args[1]), &toolArgs); err != nil {
				return fmt.Errorf("Invalid JSON: %v", err)
			}
		} else {
			toolArgs = map[string]any{}
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), toolName, toolArgs)
		if err != nil {
			return handleToolError(err)
		}

		output.JSON(result)
		return nil
	},
}
