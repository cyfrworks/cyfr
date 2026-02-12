package cmd

import (
	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(auditCmd)
	auditCmd.AddCommand(auditListCmd)
	auditCmd.AddCommand(auditExportCmd)

	auditExportCmd.Flags().String("format", "json", "Export format: json, csv")
}

var auditCmd = &cobra.Command{
	Use:     "audit",
	Short:   "Access audit logs",
	GroupID: "governance",
	Long:    "Query and export the immutable audit log that records every action taken through CYFR.",
}

var auditListCmd = &cobra.Command{
	Use:     "list",
	Short:   "List audit events",
	Long:    "Display recent audit events in reverse chronological order.",
	Example: `  cyfr audit list
  cyfr audit list --json`,
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("audit", map[string]any{
			"action": "list",
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var auditExportCmd = &cobra.Command{
	Use:   "export",
	Short: "Export audit events",
	Long:  "Export all audit events in the specified format for external processing.",
	Example: `  cyfr audit export
  cyfr audit export --format csv`,
	Run: func(cmd *cobra.Command, args []string) {
		format, _ := cmd.Flags().GetString("format")

		client := newClient()
		result, err := client.CallTool("audit", map[string]any{
			"action": "export",
			"format": format,
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}
