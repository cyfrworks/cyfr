package cmd

import (
	"encoding/json"
	"fmt"
	"net/url"
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
	Short:   "Configure a component for execution",
	GroupID: "component",
	Long: `Interactive setup wizard that configures secrets, grants, and policies
for a component in one step. Chains existing MCP tools (secret.set,
secret.grant, policy.update_field) into a single flow.

Individual commands (cyfr secret set/grant, cyfr policy set) still work
independently — this is a convenience wrapper.`,
	Example: `  cyfr setup
  cyfr setup c:local.claude:0.1.0
  cyfr setup c local.claude:0.1.0
  cyfr setup c:local.claude:0.1.0 --secret ANTHROPIC_API_KEY=sk-ant-...
  cyfr setup c:local.claude:0.1.0 --secret ANTHROPIC_API_KEY=sk-ant-... --no-interactive`,
	Args: cobra.RangeArgs(0, 2),
	Run:  runSetup,
}

func runSetup(cmd *cobra.Command, args []string) {
	client := newClient()
	var componentRef string

	// Parse --secret flags into a map
	secretFlags, _ := cmd.Flags().GetStringArray("secret")
	preSupplied := parseSecretFlags(secretFlags)

	// Resolve component reference
	switch {
	case len(args) >= 1:
		args = joinTypeShorthand(args)
		componentRef = resolveComponentRef(client, args[0])
	case prompt.IsInteractive(flagNoInteractive):
		opts, err := prompt.FetchLocalComponents(client)
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
	default:
		output.Error("Usage: cyfr setup <reference>")
	}

	// Get setup plan from server
	plan, err := fetchSetupPlan(client, componentRef)
	if err != nil {
		output.Errorf("Failed to get setup plan: %v", err)
	}

	if flagJSON {
		output.JSON(plan)
		return
	}

	// Show component info
	if desc, ok := plan["description"].(string); ok && desc != "" {
		fmt.Printf("\n  %s\n", desc)
	}

	// Extract plan fields
	secrets := extractListField(plan, "secrets")
	policyCurrent := extractMapField(plan, "policy_current")
	policyRecommended := extractMapField(plan, "policy_recommended")

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
	policyView := buildPolicyView(policyCurrent, policyRecommended)

	// Handle domain_from_secrets: may override the allowed_domains recommendation
	if policyRecommended != nil {
		domains := extractDomains(policyRecommended, secretsToSet, preSupplied)
		if len(domains) > 0 {
			for i, pv := range policyView {
				if pv.field == "allowed_domains" && pv.source == "recommended" {
					policyView[i].value = domains
					break
				}
			}
		}
	}

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

	// Apply: set secrets
	for _, s := range secretsToSet {
		_, err := client.CallTool("secret", map[string]any{
			"action": "set",
			"name":   s.name,
			"value":  s.value,
		})
		if err != nil {
			output.Errorf("Failed to set secret %s: %v", s.name, err)
		}
		fmt.Printf("  Secret '%s' stored.\n", s.name)
	}

	// Apply: grant secrets
	for _, name := range secretsToGrant {
		_, err := client.CallTool("secret", map[string]any{
			"action":        "grant",
			"component_ref": componentRef,
			"name":          name,
		})
		if err != nil {
			output.Errorf("Failed to grant secret %s: %v", name, err)
		}
		fmt.Printf("  Granted '%s' access to secret '%s'.\n", componentRef, name)
	}

	// Also grant any secrets that were newly set
	for _, s := range secretsToSet {
		// Check if already in the grant list
		alreadyGranting := false
		for _, name := range secretsToGrant {
			if name == s.name {
				alreadyGranting = true
				break
			}
		}
		if !alreadyGranting {
			_, err := client.CallTool("secret", map[string]any{
				"action":        "grant",
				"component_ref": componentRef,
				"name":          s.name,
			})
			if err != nil {
				output.Errorf("Failed to grant secret %s: %v", s.name, err)
			}
			fmt.Printf("  Granted '%s' access to secret '%s'.\n", componentRef, s.name)
		}
	}

	// Apply: set policy fields
	for _, pf := range policyFields {
		valueStr := marshalPolicyValue(pf.value)
		_, err := client.CallTool("policy", map[string]any{
			"action":        "update_field",
			"component_ref": componentRef,
			"field":         pf.field,
			"value":         valueStr,
		})
		if err != nil {
			output.Errorf("Failed to set policy field %s: %v", pf.field, err)
		}
	}
	if len(policyFields) > 0 {
		fmt.Printf("  Policy updated for %s.\n", componentRef)
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

// policyFields is the ordered list of policy fields to display.
var policyFieldNames = []string{
	"allowed_domains", "allowed_methods", "rate_limit", "timeout",
	"max_memory_bytes", "max_request_size", "max_response_size",
	"allowed_tools",
}

// buildPolicyView merges stored policy (current) and manifest recommendations
// into a single view. Current values take precedence; recommended values fill
// in the gaps. Fields present in neither are omitted.
func buildPolicyView(current, recommended map[string]any) []policyViewEntry {
	var view []policyViewEntry
	for _, f := range policyFieldNames {
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

// extractListField safely extracts a list field from the plan result.
func extractListField(plan map[string]any, key string) []any {
	if v, ok := plan[key]; ok {
		if l, ok := v.([]any); ok {
			return l
		}
	}
	return nil
}

// extractDomains handles domain_from_secrets: parses URLs from secret values
// to extract hostnames for allowed_domains.
func extractDomains(policyRecommended map[string]any, secretsToSet []secretAction, preSupplied map[string]string) []string {
	dfs, ok := policyRecommended["domain_from_secrets"]
	if !ok {
		return nil
	}
	dfsList, ok := dfs.([]any)
	if !ok {
		return nil
	}

	// Build lookup from secrets being set
	secretValues := make(map[string]string)
	for _, s := range secretsToSet {
		secretValues[s.name] = s.value
	}
	for k, v := range preSupplied {
		secretValues[k] = v
	}

	// Also include static allowed_domains from recommendation
	var domains []string
	if ad, ok := policyRecommended["allowed_domains"].([]any); ok {
		for _, d := range ad {
			if ds, ok := d.(string); ok && ds != "" {
				domains = append(domains, ds)
			}
		}
	}

	for _, secretName := range dfsList {
		name, ok := secretName.(string)
		if !ok {
			continue
		}
		urlStr, ok := secretValues[name]
		if !ok || urlStr == "" {
			continue
		}
		host := extractHostFromURL(urlStr)
		if host != "" {
			domains = append(domains, host)
		}
	}

	return domains
}

// extractHostFromURL parses a URL and returns its hostname.
// Falls back to the raw value if parsing fails.
func extractHostFromURL(rawURL string) string {
	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.Host == "" {
		// Warn but use raw value as domain
		return rawURL
	}
	return parsed.Hostname()
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
