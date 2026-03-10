package cmd

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/cyfr/codex/internal/ref"
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
	GroupID: "security",
	Long:    "View and update host-level policies that govern component execution, including allowed domains, rate limits, and resource constraints.",
}

var policySetCmd = &cobra.Command{
	Use:   "set [type] [component_ref] [field] [value]",
	Short: "Set a policy field",
	Long: `Update a single field on a component's host policy via MCP.
Omit the version to apply to all registered versions. Run without arguments
for interactive selection.`,
	Example: `  cyfr policy set c:local.claude allowed_domains '["api.anthropic.com"]'   (all versions)
  cyfr policy set c:local.claude:0.1.0 allowed_domains '["api.anthropic.com"]'
  cyfr policy set acme.sentiment:1.0.0 rate_limit 100`,
	Args: cobra.RangeArgs(0, 4),
	Run: func(cmd *cobra.Command, args []string) {
		args = joinTypeShorthand(args)
		var componentRefs []string
		var field, value string

		client := newClient()

		switch {
		case len(args) >= 3:
			componentRefs = resolveAllVersions(client, args[0])
			field = args[1]
			value = args[2]
		case prompt.IsInteractive(flagNoInteractive):
			// Select component
			compOpts, err := prompt.FetchComponents(client)
			if err != nil {
				handleToolError(err)
			}
			if len(compOpts) == 0 {
				output.Error("No components found. Register one first.")
			}
			selected, err := prompt.SelectOne("Select a component", compOpts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			componentRefs = []string{selected}

			// Input field name
			field, err = prompt.InputText("Policy field name", "allowed_domains")
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}

			// Input value
			value, err = prompt.InputText("Field value", "")
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
		default:
			output.Error("Usage: cyfr policy set <component_ref> <field> <value>")
		}

		// Detect if we're operating at name level (no version)
		isNameLevel := len(componentRefs) == 1 && !ref.ParseRef(componentRefs[0]).HasVersion

		for _, r := range componentRefs {
			result, err := client.CallTool("policy", map[string]any{
				"action":        "update_field",
				"component_ref": r,
				"field":         field,
				"value":         value,
			})
			if err != nil {
				handleToolError(err)
			}
			if flagJSON {
				output.JSON(result)
			} else {
				fmt.Printf("Policy field '%s' updated for %s.\n", field, r)
				if isNameLevel {
					fmt.Fprintf(os.Stderr, "  Applied to all versions of %s\n", r)
				}
			}
		}
	},
}

var policyShowCmd = &cobra.Command{
	Use:   "show [type] [component_ref]",
	Short: "Show policy for a component",
	Long: `Display the full policy document for a component in a human-readable format.
Run without arguments for interactive selection.`,
	Example: `  cyfr policy show c:local.claude:0.1.0
  cyfr policy show acme.sentiment:1.0.0`,
	Args: cobra.RangeArgs(0, 2),
	Run: func(cmd *cobra.Command, args []string) {
		args = joinTypeShorthand(args)
		var componentRef string

		client := newClient()

		switch {
		case len(args) >= 1:
			componentRef = resolveAllVersions(client, args[0])[0]
		case prompt.IsInteractive(flagNoInteractive):
			opts, err := prompt.FetchPolicies(client)
			if err != nil {
				handleToolError(err)
			}
			if len(opts) == 0 {
				output.Error("No policies found.")
			}
			selected, err := prompt.SelectOne("Select a component policy", opts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			componentRef = selected
		default:
			output.Error("Usage: cyfr policy show <component_ref>")
		}

		result, err := client.CallTool("policy", map[string]any{
			"action":        "get",
			"component_ref": componentRef,
		})
		if err != nil {
			handleToolError(err)
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
	Use:   "reset [type] [component_ref]",
	Short: "Remove policy for a component",
	Long: `Delete the custom policy for a component so it falls back to system defaults.
Omit the version to reset policies for all registered versions. Run without
arguments for interactive selection.`,
	Example: `  cyfr policy reset c:local.claude                (all versions)
  cyfr policy reset c:local.claude:0.1.0          (specific version)
  cyfr policy reset acme.sentiment:1.0.0`,
	Args: cobra.RangeArgs(0, 2),
	Run: func(cmd *cobra.Command, args []string) {
		args = joinTypeShorthand(args)
		var componentRefs []string

		client := newClient()

		switch {
		case len(args) >= 1:
			componentRefs = resolveAllVersions(client, args[0])
		case prompt.IsInteractive(flagNoInteractive):
			opts, err := prompt.FetchPolicies(client)
			if err != nil {
				handleToolError(err)
			}
			if len(opts) == 0 {
				output.Error("No policies found.")
			}
			selected, err := prompt.SelectOne("Select a policy to reset", opts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			confirmed, err := prompt.Confirm(fmt.Sprintf("Reset policy for '%s'? It will fall back to system defaults.", selected))
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			if !confirmed {
				fmt.Println("Cancelled.")
				return
			}
			componentRefs = []string{selected}
		default:
			output.Error("Usage: cyfr policy reset <component_ref>")
		}

		// Detect if we're operating at name level (no version)
		isNameLevel := len(componentRefs) == 1 && !ref.ParseRef(componentRefs[0]).HasVersion

		for _, r := range componentRefs {
			result, err := client.CallTool("policy", map[string]any{
				"action":        "delete",
				"component_ref": r,
			})
			if err != nil {
				handleToolError(err)
			}
			if flagJSON {
				output.JSON(result)
			} else {
				fmt.Printf("Policy reset for %s.\n", r)
				if isNameLevel {
					fmt.Fprintf(os.Stderr, "  Applied to all versions of %s\n", r)
				}
			}
			_ = result
		}
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
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}
