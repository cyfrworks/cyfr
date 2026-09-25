// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
	"fmt"

	"github.com/cyfr/codex/internal/ops"
	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

func init() {
	rootCmd.AddCommand(decisionCmd)
	decisionCmd.AddCommand(decisionListCmd)
	decisionCmd.AddCommand(decisionGetCmd)
	decisionCmd.AddCommand(decisionCorrelateCmd)

	addDecisionListFlags(decisionListCmd.Flags())
	decisionGetCmd.Flags().Bool("global", false, "Read the decision whatever its athanor (platform admins only)")
}

// addDecisionListFlags declares `cyfr decision list`'s flags on flags.
func addDecisionListFlags(flags *pflag.FlagSet) {
	flags.String("tool", "", "Filter by tool name")
	flags.String("admission", "", "Filter by admission (admitted, refused)")
	flags.String("refusal-class", "", "Filter by refusal class, e.g. forbidden or unauthenticated")
	flags.String("since", "", "ISO8601 timestamp — return decisions made at or after this time")
	flags.String("request", "", "Filter by request ID — returns every call in that chain")
	flags.Int("limit", 20, "Maximum number of results")
	flags.Bool("global", false, "Read every athanor's decisions and the host's own (platform admins only)")
	flags.String("athanor", "", "With --global: one athanor's decisions, or none for the host's own")
}

// decisionHeaders are the columns of `cyfr decision list`.
var decisionHeaders = []string{"call_id", "tool", "action", "admission", "refusal_class", "completion", "inserted_at"}

var decisionCmd = &cobra.Command{
	Use:     "decision",
	Short:   "View admission decisions",
	GroupID: "admin",
	Long: "List, inspect, and correlate admission decisions. Every call the server admitted or " +
		"refused is recorded once under its call ID, with how the admitted work ended.",
}

var decisionListCmd = &cobra.Command{
	Use:   "list",
	Short: "List recent admission decisions",
	Long: "List the athanor's recent admission decisions, newest first, with optional filters. " +
		"With --global a platform admin reads every athanor's decisions and the host's own.",
	Example: `  cyfr decision list
  cyfr decision list --admission refused --refusal-class forbidden
  cyfr decision list --request req_01H...   # every call in one request's chain
  cyfr decision list --global --athanor none   # the host's own decisions`,
	RunE: func(cmd *cobra.Command, args []string) error {
		toolArgs, err := decisionListArgs(cmd.Flags())
		if err != nil {
			return err
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Decision, toolArgs)
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		output.Table(decisionHeaders, decisionRows(result))
		return nil
	},
}

var decisionGetCmd = &cobra.Command{
	Use:   "get <call_id>",
	Short: "Show one admission decision",
	Long: "Show every field of one admission decision by its call ID (call_…). " +
		"With --global a platform admin reads it whatever its athanor.",
	Example: `  cyfr decision get call_01abc123
  cyfr decision get --global call_01abc123`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		global, _ := cmd.Flags().GetBool("global")
		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Decision, decisionGetArgs(args[0], global))
		if err != nil {
			return handleToolError(err)
		}
		return renderResult(result)
	},
}

var decisionCorrelateCmd = &cobra.Command{
	Use:   "correlate <request_id>",
	Short: "Cross-reference a request's decisions with its logs and executions",
	Long: "Show every decision made under a request ID, with the request logs, executions " +
		"and policy logs it left.",
	Example: "  cyfr decision correlate req_01abc123",
	Args:    cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Decision, ops.DecisionCorrelateArgs{RequestId: args[0]})
		if err != nil {
			return handleToolError(err)
		}
		return renderResult(result)
	},
}

// decisionListArgs maps the list flags onto `decision.list`, or onto
// `decision.list_global` with --global. --athanor names a tenant only a
// global read may choose.
func decisionListArgs(flags *pflag.FlagSet) (any, error) {
	global, _ := flags.GetBool("global")
	athanor, _ := flags.GetString("athanor")
	if athanor != "" && !global {
		return nil, errors.New("--athanor needs --global")
	}

	var filters ops.DecisionListArgs
	if v, _ := flags.GetString("tool"); v != "" {
		filters.Tool = ops.Value(v)
	}
	if v, _ := flags.GetString("admission"); v != "" {
		filters.Admission = ops.Value(v)
	}
	if v, _ := flags.GetString("refusal-class"); v != "" {
		filters.RefusalClass = ops.Value(v)
	}
	if v, _ := flags.GetString("since"); v != "" {
		filters.Since = ops.Value(v)
	}
	if v, _ := flags.GetString("request"); v != "" {
		filters.RequestId = ops.Value(v)
	}
	if v, _ := flags.GetInt("limit"); v != 20 {
		filters.Limit = ops.Value(v)
	}

	if !global {
		return filters, nil
	}
	globalArgs := ops.DecisionListGlobalArgs{
		RequestId:    filters.RequestId,
		Tool:         filters.Tool,
		Admission:    filters.Admission,
		RefusalClass: filters.RefusalClass,
		Since:        filters.Since,
		Limit:        filters.Limit,
	}
	if athanor != "" {
		globalArgs.AthanorId = ops.Value(athanor)
	}
	return globalArgs, nil
}

// decisionGetArgs is `decision.get`, or `decision.get_global` with --global.
func decisionGetArgs(callID string, global bool) any {
	if global {
		return ops.DecisionGetGlobalArgs{CallId: callID}
	}
	return ops.DecisionGetArgs{CallId: callID}
}

// decisionRows renders a list answer's decisions as table rows. A field a
// decision leaves empty — no class on an admission, no completion yet —
// is blank rather than "<nil>".
func decisionRows(result map[string]any) []map[string]string {
	decisions, _ := result["decisions"].([]any)
	rows := make([]map[string]string, 0, len(decisions))
	for _, entry := range decisions {
		m, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		row := make(map[string]string, len(decisionHeaders))
		for _, h := range decisionHeaders {
			if v, present := m[h]; present && v != nil {
				row[h] = fmt.Sprintf("%v", v)
			} else {
				row[h] = ""
			}
		}
		rows = append(rows, row)
	}
	return rows
}
