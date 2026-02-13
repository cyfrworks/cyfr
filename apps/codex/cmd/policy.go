package cmd

import (
	"encoding/json"
	"fmt"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(policyCmd)
	policyCmd.AddCommand(policySetCmd)
	policyCmd.AddCommand(policyShowCmd)
	policyCmd.AddCommand(policyResetCmd)
	policyCmd.AddCommand(policyListCmd)
}

var policyCmd = &cobra.Command{
	Use:     "policy",
	Short:   "Manage host policies",
	GroupID: "governance",
	Long:    "View and update host-level policies that govern component execution, including allowed domains, rate limits, and resource constraints.",
}

var policySetCmd = &cobra.Command{
	Use:   "set [type] <component_ref> <field> <value>",
	Short: "Set a policy field",
	Long:  "Update a single field on a component's host policy via MCP.",
	Example: `  cyfr policy set c:local.claude:0.1.0 allowed_domains '["api.anthropic.com"]'
  cyfr policy set acme.sentiment:1.0.0 rate_limit 100`,
	Args: cobra.RangeArgs(3, 4),
	Run: func(cmd *cobra.Command, args []string) {
		args = joinTypeShorthand(args)
		componentRef, err := normalizeComponentRef(args[0])
		if err != nil {
			output.Errorf("Invalid component reference: %v", err)
		}
		field := args[1]
		value := args[2]

		client := newClient()
		result, err := client.CallTool("policy", map[string]any{
			"action":        "update_field",
			"component_ref": componentRef,
			"field":         field,
			"value":         value,
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Policy field '%s' updated for %s.\n", field, componentRef)
		}
	},
}

var policyShowCmd = &cobra.Command{
	Use:     "show [type] <component_ref>",
	Short:   "Show policy for a component",
	Long:    "Display the full policy document for a component in a human-readable format.",
	Example: `  cyfr policy show c:local.claude:0.1.0
  cyfr policy show acme.sentiment:1.0.0`,
	Args: cobra.RangeArgs(1, 2),
	Run: func(cmd *cobra.Command, args []string) {
		args = joinTypeShorthand(args)
		componentRef, err := normalizeComponentRef(args[0])
		if err != nil {
			output.Errorf("Invalid component reference: %v", err)
		}
		client := newClient()
		result, err := client.CallTool("policy", map[string]any{
			"action":        "get",
			"component_ref": componentRef,
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			// Pretty-print the policy
			if policy, ok := result["policy"]; ok {
				policyJSON, _ := json.MarshalIndent(policy, "", "  ")
				fmt.Printf("Policy for %s:\n%s\n", componentRef, string(policyJSON))
			} else {
				output.KeyValue(result)
			}
		}
	},
}

var policyResetCmd = &cobra.Command{
	Use:     "reset [type] <component_ref>",
	Short:   "Remove policy for a component",
	Long:    "Delete the custom policy for a component so it falls back to system defaults.",
	Example: `  cyfr policy reset c:local.claude:0.1.0
  cyfr policy reset acme.sentiment:1.0.0`,
	Args: cobra.RangeArgs(1, 2),
	Run: func(cmd *cobra.Command, args []string) {
		args = joinTypeShorthand(args)
		componentRef, err := normalizeComponentRef(args[0])
		if err != nil {
			output.Errorf("Invalid component reference: %v", err)
		}
		client := newClient()
		result, err := client.CallTool("policy", map[string]any{
			"action":        "delete",
			"component_ref": componentRef,
		})
		if err != nil {
			output.Errorf("Failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Policy reset for %s.\n", componentRef)
		}
		_ = result
	},
}

var policyListCmd = &cobra.Command{
	Use:     "list",
	Short:   "List all policies",
	Long:    "List all components that have custom policies applied.",
	Example: "  cyfr policy list",
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("policy", map[string]any{
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
