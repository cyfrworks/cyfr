package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/spf13/cobra"
)

func init() {
	setupCmd.Flags().StringArray("secret", nil, "Pre-supply secrets as NAME=VALUE (repeatable)")
	rootCmd.AddCommand(setupCmd)
}

var setupCmd = &cobra.Command{
	Use:     "setup [type:ref | type ref]",
	Short:   "Configure a component for execution [interactive]",
	GroupID: "component",
	Long: `Interactive setup wizard that configures secrets, grants, and policies
for a component in one step. Chains existing MCP tools (secret.set,
secret.grant, policy.update_field) into a single flow.

Grants and policies are always propagated to all registered versions of the
component. Use cyfr secret grant or cyfr policy set for per-version control.

Individual commands (cyfr secret set/grant, cyfr policy set) still work
independently — this is a convenience wrapper.`,
	Example: `  cyfr setup c:local.claude
  cyfr setup c:local.claude --secret ANTHROPIC_API_KEY=sk-ant-...`,
	Args: cobra.RangeArgs(0, 2),
	Run:  runSetup,
}

func runSetup(cmd *cobra.Command, args []string) {
	client := newClient()
	var componentRef string
	var targetRefs []string // versions to apply grants/policy to

	// Parse --secret flags into a map
	secretFlags, _ := cmd.Flags().GetStringArray("secret")
	preSupplied := parseSecretFlags(secretFlags)

	// Resolve component reference.
	// We need a versioned ref to fetch the manifest via setup_plan.
	switch {
	case len(args) >= 1:
		args = joinTypeShorthand(args)
		targetRefs = resolveAllVersions(client, args[0])
		componentRef = targetRefs[0]
	case prompt.IsInteractive(flagNoInteractive):
		opts, err := prompt.FetchLocalComponentsLatest(client)
		if err != nil {
			handleToolError(err)
		}
		if len(opts) == 0 {
			output.Error("No components found. Register one first with: cyfr register")
		}
		selected, err := prompt.SelectOne("Select a component to set up", opts)
		if err != nil {
			if prompt.IsAborted(err) {
				os.Exit(130)
			}
			output.Errorf("Prompt failed: %v", err)
		}
		componentRef = selected
		// Resolve all versions for the version selector
		baseRef := prompt.StripVersion(selected)
		targetRefs = resolveAllVersions(client, baseRef)
	default:
		output.Error("Usage: cyfr setup <reference>")
	}

	// Version selector: let the user choose which versions to configure.
	// Default is "All versions"; user can pick specific ones instead.
	if len(targetRefs) >= 1 && prompt.IsInteractive(flagNoInteractive) {
		allLabel := fmt.Sprintf("All versions (%d)", len(targetRefs))
		versionOpts := []prompt.Option{{Label: allLabel, Value: "__all__"}}
		for _, r := range targetRefs {
			versionOpts = append(versionOpts, prompt.Option{Label: r, Value: r})
		}
		selected, err := prompt.SelectMany("Apply to which versions?", versionOpts, "__all__")
		if err != nil {
			if prompt.IsAborted(err) {
				os.Exit(130)
			}
			output.Errorf("Prompt failed: %v", err)
		}
		// If "All versions" is selected (or nothing was deselected), keep all.
		// Otherwise use only the specifically selected refs.
		hasAll := false
		var specific []string
		for _, s := range selected {
			if s == "__all__" {
				hasAll = true
			} else {
				specific = append(specific, s)
			}
		}
		if !hasAll && len(specific) > 0 {
			targetRefs = specific
		}
	}

	// Get setup plan from server (always uses a versioned ref)
	plan, err := fetchSetupPlan(client, componentRef)
	if err != nil {
		handleToolError(err, "Failed to get setup plan")
	}

	if flagJSON {
		output.JSON(plan)
		return
	}

	if len(targetRefs) > 1 {
		fmt.Printf("\n  Applying to %d versions.\n", len(targetRefs))
	}

	// Show component info
	if desc, ok := plan["description"].(string); ok && desc != "" {
		fmt.Printf("\n  %s\n", desc)
	}

	// Extract plan fields
	secrets := extractListField(plan, "secrets")
	policyCurrent := extractMapField(plan, "policy_current")
	policyRecommended := extractMapField(plan, "policy_recommended")
	configurableFields := extractStringListField(plan, "configurable_fields")

	// Show dependency hints
	deps := extractListField(plan, "dependencies")
	if len(deps) > 0 {
		var depRefs []string
		for _, d := range deps {
			if dm, ok := d.(map[string]any); ok {
				if ref, ok := dm["ref"].(string); ok {
					depRefs = append(depRefs, ref)
				}
			}
		}
		if len(depRefs) > 0 {
			fmt.Printf("\n  Dependencies need setup too: %s\n", strings.Join(depRefs, ", "))
		}
	}

	// Collect secret values
	var secretsToSet []secretAction
	var secretsToGrant []string

	for _, s := range secrets {
		sm, ok := s.(map[string]any)
		if !ok {
			continue
		}
		name, _ := sm["name"].(string)
		desc, _ := sm["description"].(string)
		required, _ := sm["required"].(bool)
		alreadySet, _ := sm["already_set"].(bool)
		alreadyGranted, _ := sm["already_granted"].(bool)

		// Check if pre-supplied via --secret flag
		if val, ok := preSupplied[name]; ok {
			secretsToSet = append(secretsToSet, secretAction{name: name, value: val})
			if !alreadyGranted {
				secretsToGrant = append(secretsToGrant, name)
			}
			continue
		}

		if prompt.IsInteractive(flagNoInteractive) {
			// Build title with description
			title := fmt.Sprintf("  %s", name)
			if desc != "" {
				title = fmt.Sprintf("  %s — %s", name, desc)
			}
			if !alreadySet && required {
				title += " (required)"
			}

			// Pre-fill with existing value if configured
			existingValue := ""
			if alreadySet {
				existingValue = fetchSecretValue(client, name)
			}

			value, err := prompt.InputSecret(title, "", existingValue)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}

			if value == "" && !alreadySet && required {
				output.Errorf("Secret %s is required", name)
			}

			// Skip if unchanged
			if value == existingValue {
				if !alreadyGranted {
					secretsToGrant = append(secretsToGrant, name)
				}
				continue
			}

			if value != "" {
				secretsToSet = append(secretsToSet, secretAction{name: name, value: value})
			}
			if !alreadyGranted {
				secretsToGrant = append(secretsToGrant, name)
			}
		} else {
			// Non-interactive: skip already-set secrets, error on missing required
			if !alreadySet && required {
				output.Errorf("Missing required secret: %s (use --secret %s=VALUE)", name, name)
			}
			if !alreadyGranted && alreadySet {
				secretsToGrant = append(secretsToGrant, name)
			}
		}
	}

	// Build merged policy view: current values + recommendations for unset fields.
	// "current" fields are already stored — "recommended" fields need to be applied.
	// Use configurable_fields from setup_plan to show only relevant fields.
	policyView := buildPolicyView(policyCurrent, policyRecommended, configurableFields)

	// Walk through each policy field — pre-filled with current or recommended value.
	// Enter to keep, type to change.
	var policyFields []policyAction
	if len(policyView) > 0 && prompt.IsInteractive(flagNoInteractive) {
		fmt.Println("\n  Policy:")
		for _, pv := range policyView {
			currentStr := formatPolicyValue(pv.value)
			newVal, err := prompt.InputText(fmt.Sprintf("    %s", pv.field), "", currentStr)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}

			// If unchanged, skip (unless it was a recommendation that needs to be applied)
			if newVal == currentStr && pv.source == "current" {
				continue
			}
			// Parse back to the right type for the MCP call
			policyFields = append(policyFields, policyAction{field: pv.field, value: parsePolicyInput(pv.field, newVal, pv.value)})
		}
		fmt.Println()
	} else {
		// Non-interactive: apply all recommended values as-is
		for _, pv := range policyView {
			if pv.source == "recommended" {
				policyFields = append(policyFields, policyAction{field: pv.field, value: pv.value})
			}
		}
	}

	// Check if there's anything to apply
	if len(secretsToSet) == 0 && len(secretsToGrant) == 0 && len(policyFields) == 0 {
		fmt.Println("  Fully configured. No changes needed.")
		return
	}

	// Apply: set secrets (secrets are global, not per-version)
	for _, s := range secretsToSet {
		_, err := client.CallTool("secret", map[string]any{
			"action": "set",
			"name":   s.name,
			"value":  s.value,
		})
		if err != nil {
			handleToolError(err, fmt.Sprintf("Failed to set secret %s", s.name))
		}
		fmt.Printf("  Secret '%s' stored.\n", s.name)
	}

	// Collect all secret names that need granting
	allGrantNames := make(map[string]bool)
	for _, name := range secretsToGrant {
		allGrantNames[name] = true
	}
	for _, s := range secretsToSet {
		allGrantNames[s.name] = true
	}

	// Apply: grant secrets to selected versions
	for name := range allGrantNames {
		for _, targetRef := range targetRefs {
			_, err := client.CallTool("secret", map[string]any{
				"action":        "grant",
				"component_ref": targetRef,
				"name":          name,
			})
			if err != nil {
				handleToolError(err, fmt.Sprintf("Failed to grant secret %s to %s", name, targetRef))
			}
		}
		if len(targetRefs) == 1 {
			fmt.Printf("  Granted '%s' access to secret '%s'.\n", targetRefs[0], name)
		} else {
			fmt.Printf("  Granted %d versions access to secret '%s'.\n", len(targetRefs), name)
		}
	}

	// Apply: set policy fields for selected versions
	for _, pf := range policyFields {
		valueStr := marshalPolicyValue(pf.value)
		for _, targetRef := range targetRefs {
			_, err := client.CallTool("policy", map[string]any{
				"action":        "update_field",
				"component_ref": targetRef,
				"field":         pf.field,
				"value":         valueStr,
			})
			if err != nil {
				handleToolError(err, fmt.Sprintf("Failed to set policy field %s for %s", pf.field, targetRef))
			}
		}
	}
	if len(policyFields) > 0 {
		if len(targetRefs) == 1 {
			fmt.Printf("  Policy updated for %s.\n", targetRefs[0])
		} else {
			fmt.Printf("  Policy updated for %d versions.\n", len(targetRefs))
		}
	}

	fmt.Printf("\n  Setup complete. Run: cyfr run %s --input '{...}'\n", componentRef)
}

type secretAction struct {
	name  string
	value string
}

type policyAction struct {
	field string
	value any
}

type policyViewEntry struct {
	field  string
	value  any
	source string // "current" or "recommended"
}

// allPolicyFieldNames is the ordered list of all known policy fields.
// Used as fallback when configurable_fields is not available from setup_plan.
var allPolicyFieldNames = []string{
	"allowed_domains", "allowed_methods", "allowed_private_ips",
	"allowed_paths", "allowed_actions",
	"rate_limit", "timeout",
	"max_memory_bytes", "max_request_size", "max_response_size",
	"allowed_tools", "batch_timeout", "max_concurrent_tasks",
}

// buildPolicyView merges stored policy (current) and manifest recommendations
// into a single view. Current values take precedence; recommended values fill
// in the gaps. Fields present in neither are omitted.
//
// When configurableFields is provided (from setup_plan response), only those
// fields are shown. Otherwise falls back to the full list.
func buildPolicyView(current, recommended map[string]any, configurableFields []string) []policyViewEntry {
	fieldList := allPolicyFieldNames
	if len(configurableFields) > 0 {
		fieldList = configurableFields
	}

	var view []policyViewEntry
	for _, f := range fieldList {
		if current != nil {
			if v, ok := current[f]; ok {
				view = append(view, policyViewEntry{field: f, value: v, source: "current"})
				continue
			}
		}
		if recommended != nil {
			if v, ok := recommended[f]; ok {
				view = append(view, policyViewEntry{field: f, value: v, source: "recommended"})
				continue
			}
		}
	}
	return view
}

// parseSecretFlags parses --secret NAME=VALUE flags into a map.
func parseSecretFlags(flags []string) map[string]string {
	m := make(map[string]string, len(flags))
	for _, f := range flags {
		parts := strings.SplitN(f, "=", 2)
		if len(parts) == 2 {
			m[parts[0]] = parts[1]
		}
	}
	return m
}

// fetchSecretValue retrieves the current value of a secret for pre-filling.
// Returns empty string on error (non-fatal — input will just be empty).
func fetchSecretValue(client *mcp.Client, name string) string {
	result, err := client.CallTool("secret", map[string]any{
		"action": "get",
		"name":   name,
	})
	if err != nil {
		return ""
	}
	if v, ok := result["value"].(string); ok {
		return v
	}
	return ""
}

// fetchSetupPlan calls the component setup_plan MCP action.
func fetchSetupPlan(client *mcp.Client, componentRef string) (map[string]any, error) {
	return client.CallTool("component", map[string]any{
		"action":    "setup_plan",
		"reference": componentRef,
	})
}

// extractMapField safely extracts a map field from the plan result.
func extractMapField(plan map[string]any, key string) map[string]any {
	if v, ok := plan[key]; ok {
		if m, ok := v.(map[string]any); ok {
			return m
		}
	}
	return nil
}

// extractStringListField safely extracts a string list field from the plan result.
func extractStringListField(plan map[string]any, key string) []string {
	if v, ok := plan[key]; ok {
		if l, ok := v.([]any); ok {
			result := make([]string, 0, len(l))
			for _, item := range l {
				if s, ok := item.(string); ok {
					result = append(result, s)
				}
			}
			return result
		}
	}
	return nil
}

// extractListField safely extracts a list field from the plan result.
func extractListField(plan map[string]any, key string) []any {
	if v, ok := plan[key]; ok {
		if l, ok := v.([]any); ok {
			return l
		}
	}
	return nil
}

// formatPolicyValue formats a policy value for display.
func formatPolicyValue(v any) string {
	switch val := v.(type) {
	case string:
		return val
	case float64:
		return fmt.Sprintf("%.0f", val)
	case map[string]any:
		// Rate limit: {"requests": 100, "window": "1m"}
		if req, ok := val["requests"]; ok {
			if win, ok := val["window"]; ok {
				return fmt.Sprintf("%.0f requests / %v", req, win)
			}
		}
		b, _ := json.Marshal(val)
		return string(b)
	case []any:
		parts := make([]string, 0, len(val))
		for _, item := range val {
			parts = append(parts, fmt.Sprintf("%v", item))
		}
		return "[" + strings.Join(parts, ", ") + "]"
	default:
		return fmt.Sprintf("%v", v)
	}
}

// parsePolicyInput converts user text input back to the appropriate type for the
// MCP update_field call. If the text matches the formatted original, returns the
// original value (preserving type). Otherwise attempts JSON parse, falling back
// to the raw string.
func parsePolicyInput(field, input string, original any) any {
	// If user didn't change the formatted value, use the original typed value
	if input == formatPolicyValue(original) {
		return original
	}
	// Try JSON parse (handles arrays, objects, numbers)
	var parsed any
	if err := json.Unmarshal([]byte(input), &parsed); err == nil {
		return parsed
	}
	return input
}

// marshalPolicyValue converts a policy value to string for the MCP update_field call.
func marshalPolicyValue(v any) string {
	switch val := v.(type) {
	case string:
		return val
	default:
		b, _ := json.Marshal(val)
		return string(b)
	}
}
