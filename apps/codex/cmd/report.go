// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
	"fmt"
	"strings"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/ref"
	"github.com/spf13/cobra"
)

func init() {
	reportCmd.Flags().String("category", "", "Abuse category (required): impersonation | malware | dmca | spam | other")
	reportCmd.Flags().String("details", "", "Explanation of the abuse (required, ≤4096 chars)")
	reportCmd.Flags().String("namespace", "", "Target namespace (if not reporting a specific component)")
	_ = reportCmd.MarkFlagRequired("category")
	_ = reportCmd.MarkFlagRequired("details")
	rootCmd.AddCommand(reportCmd)
}

var validReportCategories = map[string]bool{
	"impersonation": true,
	"malware":       true,
	"dmca":          true,
	"spam":          true,
	"other":         true,
}

var reportCmd = &cobra.Command{
	Use:     "report [component-ref]",
	Short:   "File an abuse report on a component or namespace",
	GroupID: "admin",
	Long: `Submit an abuse report to the cyfr.run admin queue.

Target can be a specific component (positional arg, fully qualified with
version) OR a namespace (--namespace), but at least one is required. Auth:
any valid push token (you must be a registered cyfr user).

Reports appear in the admin UI. Categories:
  impersonation  — namespace squatting / brand impersonation
  malware        — harmful code
  dmca           — copyright takedown request
  spam           — low-quality / promotional spam
  other          — everything else`,
	Example: `  cyfr report c:alice.malware:1.0.0 --category malware --details "ships with eval()"
  cyfr report --namespace badactor --category impersonation --details "impersonates @bob"`,
	Args: cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		category, _ := cmd.Flags().GetString("category")
		details, _ := cmd.Flags().GetString("details")
		namespace, _ := cmd.Flags().GetString("namespace")

		category = strings.ToLower(strings.TrimSpace(category))
		if !validReportCategories[category] {
			return errors.New("Invalid --category. Must be one of: impersonation, malware, dmca, spam, other.")
		}

		var componentRef string
		if len(args) == 1 {
			componentRef = args[0]
			if !ref.ParseRef(componentRef).HasVersion {
				return errors.New("Component ref must be fully qualified with a version (e.g., c:alice.widget:1.0.0).")
			}
		}
		if componentRef == "" && namespace == "" {
			return errors.New("Provide either a component ref or --namespace.")
		}

		client := newClient()
		toolArgs := map[string]any{
			"action":   "report",
			"category": category,
			"details":  details,
		}
		if componentRef != "" {
			toolArgs["target_component_ref"] = componentRef
		}
		if namespace != "" {
			toolArgs["target_namespace"] = namespace
		}

		result, err := client.CallTool(cmd.Context(), "registry", toolArgs)
		if err != nil {
			return handleToolError(err, "Report failed")
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		if id, ok := result["id"].(string); ok {
			fmt.Printf("Report filed: %s\n", id)
		} else {
			fmt.Println("Report filed.")
		}
		return nil
	},
}
