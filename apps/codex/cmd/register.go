package cmd

import (
	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(registerCmd)
}

var registerCmd = &cobra.Command{
	Use:     "register <directory>",
	Short:   "Register a local component",
	GroupID: "component",
	Long:    "Register a local component directory with the Compendium registry, making it available for registry references in formulas.",
	Example: `  cyfr register components/catalysts/local/my-tool/0.1.0/
  cyfr register ./my-component/0.1.0/ --json`,
	Args: cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("component", map[string]any{
			"action":    "register",
			"directory": args[0],
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
