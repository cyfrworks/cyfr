package cmd

import (
	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(registerCmd)
}

var registerCmd = &cobra.Command{
	Use:     "register",
	Short:   "Scan and register all local components",
	GroupID: "component",
	Long:    "Scan the components/ directory for local and agent components and register them in the Compendium registry, making them available for search and registry references.",
	Example: `  cyfr register
  cyfr register --json`,
	Args: cobra.NoArgs,
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("component", map[string]any{
			"action": "register",
		})
		if err != nil {
			output.Errorf("Register failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}
