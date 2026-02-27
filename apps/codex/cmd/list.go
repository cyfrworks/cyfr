package cmd

import (
	"fmt"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	listCmd.Flags().String("type", "", "Filter by component type (catalyst, reagent, formula)")
	rootCmd.AddCommand(listCmd)
}

var listCmd = &cobra.Command{
	Use:     "list",
	Short:   "List installed components",
	GroupID: "component",
	Long:    "List all components installed in the local registry. Shows reference, type, source, and description.",
	Example: `  cyfr list
  cyfr list --type catalyst
  cyfr list --json`,
	Args: cobra.NoArgs,
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		toolArgs := map[string]any{
			"action": "list",
		}
		if t, _ := cmd.Flags().GetString("type"); t != "" {
			toolArgs["type"] = t
		}
		result, err := client.CallTool("component", toolArgs)
		if err != nil {
			handleToolError(err, "List failed")
		}
		if flagJSON {
			output.JSON(result)
			return
		}

		components, ok := result["components"].([]any)
		if !ok || len(components) == 0 {
			fmt.Println("No components installed.")
			fmt.Println("\nHint: use 'cyfr register' to index local components or 'cyfr pull <ref>' to download from the registry.")
			return
		}

		headers := []string{"REFERENCE", "TYPE", "DESCRIPTION"}
		rows := make([]map[string]string, 0, len(components))
		for _, c := range components {
			comp, ok := c.(map[string]any)
			if !ok {
				continue
			}
			reference := strVal(comp, "component_ref")
			if reference == "" {
				reference = strVal(comp, "id")
			}
			rows = append(rows, map[string]string{
				"REFERENCE":   reference,
				"TYPE":        strVal(comp, "component_type"),
				"DESCRIPTION": strVal(comp, "description"),
			})
		}
		output.Table(headers, rows)
		fmt.Fprintf(cmd.ErrOrStderr(), "\n%d component(s) installed.\n", len(rows))
	},
}

func strVal(m map[string]any, key string) string {
	if v, ok := m[key]; ok {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return ""
}

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max-3] + "..."
}
