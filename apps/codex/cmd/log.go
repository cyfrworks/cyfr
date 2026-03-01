package cmd

import (
	"fmt"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(logCmd)
	logCmd.AddCommand(logListCmd)
	logCmd.AddCommand(logGetCmd)
	logCmd.AddCommand(logCorrelateCmd)

	logListCmd.Flags().String("tool", "", "Filter by tool name")
	logListCmd.Flags().String("status", "", "Filter by status (pending, success, error)")
	logListCmd.Flags().Int("limit", 20, "Maximum number of results")
	logListCmd.Flags().String("since", "", "ISO8601 timestamp — return logs after this time")
	logListCmd.Flags().String("session", "", "Filter by session ID")
}

var logCmd = &cobra.Command{
	Use:     "log",
	Short:   "View MCP request logs",
	GroupID: "admin",
	Long:    "List, inspect, and correlate MCP request logs. Every tool call is recorded with full input/output, status, and duration.",
}

var logListCmd = &cobra.Command{
	Use:   "list",
	Short: "List recent MCP request logs",
	Long:  "List recent MCP request logs with optional filters for tool, status, and time range.",
	Example: `  cyfr log list
  cyfr log list --tool execution --status error
  cyfr log list --since 2026-03-01T00:00:00Z --limit 50`,
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		toolArgs := map[string]any{
			"action": "list",
		}

		if v, _ := cmd.Flags().GetString("tool"); v != "" {
			toolArgs["tool"] = v
		}
		if v, _ := cmd.Flags().GetString("status"); v != "" {
			toolArgs["status"] = v
		}
		if v, _ := cmd.Flags().GetInt("limit"); v != 20 {
			toolArgs["limit"] = v
		}
		if v, _ := cmd.Flags().GetString("since"); v != "" {
			toolArgs["since"] = v
		}
		if v, _ := cmd.Flags().GetString("session"); v != "" {
			toolArgs["session_id"] = v
		}

		result, err := client.CallTool("mcp_log", toolArgs)
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return
		}

		logs, _ := result["logs"].([]any)
		headers := []string{"id", "tool", "action", "status", "duration_ms", "timestamp"}
		rows := make([]map[string]string, 0, len(logs))
		for _, entry := range logs {
			m, ok := entry.(map[string]any)
			if !ok {
				continue
			}
			row := make(map[string]string, len(headers))
			for _, h := range headers {
				row[h] = fmt.Sprintf("%v", m[h])
			}
			rows = append(rows, row)
		}
		output.Table(headers, rows)
	},
}

var logGetCmd = &cobra.Command{
	Use:     "get <request_id>",
	Short:   "Show full detail for a request log",
	Long:    "Show all fields for a single MCP request log including input and output payloads.",
	Example: "  cyfr log get req_01abc123",
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("mcp_log", map[string]any{
			"action": "get",
			"id":     args[0],
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var logCorrelateCmd = &cobra.Command{
	Use:     "correlate <request_id>",
	Short:   "Cross-reference a request with executions and policy logs",
	Long:    "Show all related records (executions, policy logs) for a given request ID.",
	Example: "  cyfr log correlate req_01abc123",
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("mcp_log", map[string]any{
			"action":     "correlate",
			"request_id": args[0],
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}
