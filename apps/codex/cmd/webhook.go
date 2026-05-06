package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(webhookCmd)
	webhookCmd.AddCommand(webhookCreateCmd)
	webhookCmd.AddCommand(webhookGetCmd)
	webhookCmd.AddCommand(webhookListCmd)
	webhookCmd.AddCommand(webhookUpdateCmd)
	webhookCmd.AddCommand(webhookRevokeCmd)
	webhookCmd.AddCommand(webhookRotateCmd)

	webhookCreateCmd.Flags().String("name", "", "Webhook name (required in non-interactive mode)")
	webhookCreateCmd.Flags().String("target", "", "Target component reference (e.g. f:local.handle-github-push)")
	webhookCreateCmd.Flags().String("signature-header", "", "HTTP header carrying the signature (default x-cyfr-signature)")
	webhookCreateCmd.Flags().String("rate-limit", "", "Rate limit override (e.g. 100/1m)")
	webhookCreateCmd.Flags().String("description", "", "Optional description")
	webhookCreateCmd.Flags().String("input", "", `Static input template as inline JSON object (e.g. '{"channel":"alerts"}')`)
	webhookCreateCmd.Flags().String("input-file", "", "Path to a JSON file containing the input template")

	webhookUpdateCmd.Flags().String("target", "", "New target component reference")
	webhookUpdateCmd.Flags().String("signature-header", "", "New signature header")
	webhookUpdateCmd.Flags().String("rate-limit", "", "New rate limit")
	webhookUpdateCmd.Flags().String("description", "", "New description")
	webhookUpdateCmd.Flags().String("input", "", "New input template (inline JSON object)")
	webhookUpdateCmd.Flags().String("input-file", "", "Path to JSON file with new input template")
}

var webhookCmd = &cobra.Command{
	Use:     "webhook",
	Short:   "Manage inbound webhooks",
	GroupID: "security",
	Long: `Manage inbound webhook receivers.

Each webhook is a stable URL at /hooks/<slug> that verifies an HMAC-SHA256
signature against a stored secret and invokes a target component
synchronously. The webhook can carry a static "input_template" (JSON object)
that gets merged into the invocation payload alongside the request envelope
(headers, body, metadata) under the reserved key '_webhook'.`,
}

var webhookCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create a new webhook",
	Long: `Create a new webhook bound to a target component. Returns a stable URL and
an HMAC secret. The secret is shown exactly once — copy it now.

Run without --name for an interactive form.`,
	Example: `  cyfr webhook create --name github-push --target f:local.handle-github-push
  cyfr webhook create --name slack-alerts --target f:local.notify --input '{"channel":"alerts"}'
  cyfr webhook create --name stripe --target f:local.handle-stripe --signature-header stripe-signature`,
	Run: func(cmd *cobra.Command, args []string) {
		name, _ := cmd.Flags().GetString("name")
		target, _ := cmd.Flags().GetString("target")
		sigHeader, _ := cmd.Flags().GetString("signature-header")
		rateLimit, _ := cmd.Flags().GetString("rate-limit")
		description, _ := cmd.Flags().GetString("description")
		inputJSON, _ := cmd.Flags().GetString("input")
		inputFile, _ := cmd.Flags().GetString("input-file")

		var inputTemplate map[string]any

		if name == "" {
			if !prompt.IsInteractive(flagNoInteractive) {
				output.Error("--name is required. Usage: cyfr webhook create --name <name> --target <ref>")
			}

			form, err := prompt.RunWebhookCreateForm()
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			name = form.Name
			target = form.TargetRef

			if form.SignatureHeader != "" {
				sigHeader = form.SignatureHeader
			}
			if form.RateLimit != "" {
				rateLimit = form.RateLimit
			}
			if form.Description != "" {
				description = form.Description
			}

			parsed, err := parseInputTemplate(form.InputTemplate, "")
			if err != nil {
				output.Errorf("Invalid input_template: %v", err)
			}
			inputTemplate = parsed
		} else {
			if target == "" {
				output.Error("--target is required when --name is set. Usage: cyfr webhook create --name <name> --target <ref>")
			}

			parsed, err := parseInputTemplate(inputJSON, inputFile)
			if err != nil {
				output.Errorf("Invalid input_template: %v", err)
			}
			inputTemplate = parsed
		}

		toolArgs := map[string]any{
			"action":     "create",
			"name":       name,
			"target_ref": target,
		}
		if inputTemplate != nil {
			toolArgs["input_template"] = inputTemplate
		}
		if sigHeader != "" {
			toolArgs["signature_header"] = sigHeader
		}
		if rateLimit != "" {
			toolArgs["rate_limit"] = rateLimit
		}
		if description != "" {
			toolArgs["description"] = description
		}

		client := newClient()
		result, err := client.CallTool("webhook", toolArgs)
		if err != nil {
			handleToolError(err)
		}

		if flagJSON {
			output.JSON(result)
		} else {
			renderWebhookCreated(result)
		}
	},
}

var webhookGetCmd = &cobra.Command{
	Use:     "get <name>",
	Short:   "Get webhook info",
	Long:    "Show metadata for a webhook including target component, signature header, and input template. The HMAC secret is never returned.",
	Example: "  cyfr webhook get github-push",
	Args:    cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("webhook", map[string]any{
			"action": "get",
			"name":   args[0],
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			renderWebhookDetail(result)
		}
	},
}

var webhookListCmd = &cobra.Command{
	Use:     "list",
	Short:   "List all webhooks",
	Long:    "List all webhooks with their names, target components, and URLs. HMAC secrets are never shown.",
	Example: "  cyfr webhook list",
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("webhook", map[string]any{
			"action": "list",
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			renderWebhookList(result)
		}
	},
}

var webhookUpdateCmd = &cobra.Command{
	Use:   "update <name>",
	Short: "Update a webhook (no secret rotation)",
	Long: `Update mutable fields on a webhook: target component, signature header,
input template, description, or rate limit. The HMAC secret is unchanged —
use 'cyfr webhook rotate' to replace it.`,
	Example: `  cyfr webhook update github-push --target f:local.new-handler
  cyfr webhook update slack-alerts --input '{"channel":"on-call"}'`,
	Args: cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		name := args[0]

		toolArgs := map[string]any{
			"action": "update",
			"name":   name,
		}

		if target, _ := cmd.Flags().GetString("target"); target != "" {
			toolArgs["target_ref"] = target
		}
		if sigHeader, _ := cmd.Flags().GetString("signature-header"); sigHeader != "" {
			toolArgs["signature_header"] = sigHeader
		}
		if rateLimit, _ := cmd.Flags().GetString("rate-limit"); rateLimit != "" {
			toolArgs["rate_limit"] = rateLimit
		}
		if description, _ := cmd.Flags().GetString("description"); description != "" {
			toolArgs["description"] = description
		}

		inputJSON, _ := cmd.Flags().GetString("input")
		inputFile, _ := cmd.Flags().GetString("input-file")
		if inputJSON != "" || inputFile != "" {
			parsed, err := parseInputTemplate(inputJSON, inputFile)
			if err != nil {
				output.Errorf("Invalid input_template: %v", err)
			}
			if parsed != nil {
				toolArgs["input_template"] = parsed
			}
		}

		// Reject no-op updates client-side (server will too, but a clearer message helps).
		if len(toolArgs) <= 2 {
			output.Error("No fields to update. Pass at least one of --target, --signature-header, --rate-limit, --description, --input, or --input-file.")
		}

		client := newClient()
		result, err := client.CallTool("webhook", toolArgs)
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Webhook '%s' updated.\n", name)
			output.KeyValue(result)
		}
	},
}

var webhookRevokeCmd = &cobra.Command{
	Use:     "revoke [name]",
	Short:   "Revoke (disable) a webhook",
	Long:    "Disable a webhook so its URL stops accepting POSTs. The audit trail is preserved. Run without arguments for interactive selection.",
	Example: "  cyfr webhook revoke github-push",
	Args:    cobra.RangeArgs(0, 1),
	Run: func(cmd *cobra.Command, args []string) {
		name := selectWebhookName(args, "Select a webhook to revoke", "Revoke webhook '%s'? The URL stops accepting POSTs.")

		client := newClient()
		result, err := client.CallTool("webhook", map[string]any{
			"action": "revoke",
			"name":   name,
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Webhook '%s' revoked.\n", name)
		}
		_ = result
	},
}

var webhookRotateCmd = &cobra.Command{
	Use:     "rotate [name]",
	Short:   "Rotate the HMAC secret for a webhook",
	Long:    "Generate a new HMAC secret. The old secret stops working immediately. Update the sender's configuration with the new secret. Run without arguments for interactive selection.",
	Example: "  cyfr webhook rotate github-push",
	Args:    cobra.RangeArgs(0, 1),
	Run: func(cmd *cobra.Command, args []string) {
		name := selectWebhookName(args, "Select a webhook to rotate", "Rotate webhook '%s'? The old secret stops working immediately.")

		client := newClient()
		result, err := client.CallTool("webhook", map[string]any{
			"action": "rotate",
			"name":   name,
		})
		if err != nil {
			handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			renderWebhookRotated(result)
		}
	},
}

// ============================================================================
// Helpers
// ============================================================================

// parseInputTemplate accepts either an inline JSON string (--input) or a
// path to a JSON file (--input-file) and returns a validated map. Returns
// nil if both inputs are empty.
func parseInputTemplate(inline, file string) (map[string]any, error) {
	var raw []byte

	switch {
	case inline != "" && file != "":
		return nil, fmt.Errorf("--input and --input-file are mutually exclusive")
	case inline != "":
		raw = []byte(inline)
	case file != "":
		bytes, err := os.ReadFile(file)
		if err != nil {
			return nil, fmt.Errorf("reading %s: %w", file, err)
		}
		raw = bytes
	default:
		return nil, nil
	}

	if strings.TrimSpace(string(raw)) == "" || strings.TrimSpace(string(raw)) == "{}" {
		return map[string]any{}, nil
	}

	var decoded any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return nil, fmt.Errorf("not valid JSON: %w", err)
	}

	obj, ok := decoded.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("must be a JSON object (not array or scalar)")
	}

	if _, exists := obj["_webhook"]; exists {
		return nil, fmt.Errorf("reserved key '_webhook' is not allowed")
	}

	return obj, nil
}

func selectWebhookName(args []string, promptTitle, confirmTemplate string) string {
	switch {
	case len(args) >= 1:
		return args[0]
	case prompt.IsInteractive(flagNoInteractive):
		client := newClient()
		opts, err := prompt.FetchWebhooks(client)
		if err != nil {
			handleToolError(err)
		}
		if len(opts) == 0 {
			output.Error("No webhooks found. Create one with 'cyfr webhook create'.")
		}
		selected, err := prompt.SelectOne(promptTitle, opts)
		if err != nil {
			if prompt.IsAborted(err) {
				os.Exit(130)
			}
			output.Errorf("Prompt failed: %v", err)
		}
		confirmed, err := prompt.Confirm(fmt.Sprintf(confirmTemplate, selected))
		if err != nil {
			if prompt.IsAborted(err) {
				os.Exit(130)
			}
			output.Errorf("Prompt failed: %v", err)
		}
		if !confirmed {
			fmt.Println("Cancelled.")
			os.Exit(0)
		}
		return selected
	default:
		output.Error("Usage: provide <name> or run interactively")
		return "" // unreachable
	}
}

// renderWebhookCreated prints the human-readable result for `webhook create`,
// surfacing the URL, name, target, and one-time secret prominently. The URL
// is constructed server-side using `CYFR_PUBLIC_URL` so it's correct
// regardless of whether the CLI is talking to a local or remote server.
func renderWebhookCreated(result map[string]any) {
	name, _ := result["name"].(string)
	target, _ := result["target_ref"].(string)

	fmt.Printf("Webhook '%s' created.\n\n", name)
	renderWebhookEndpoint(result)
	if target != "" {
		fmt.Printf("  Target: %s\n", target)
	}
	renderWebhookSecret(result, "Secret")
}

// renderWebhookRotated prints the result of a successful rotation.
func renderWebhookRotated(result map[string]any) {
	name, _ := result["name"].(string)

	fmt.Printf("Webhook '%s' rotated.\n\n", name)
	renderWebhookEndpoint(result)
	renderWebhookSecret(result, "New secret")
	if _, ok := result["secret"].(string); ok {
		fmt.Println("  The old secret is now invalid.")
	}
}

// renderWebhookDetail prints a single webhook's fields for `webhook get`.
func renderWebhookDetail(result map[string]any) {
	if name, ok := result["name"].(string); ok {
		fmt.Printf("Webhook: %s\n\n", name)
	}
	renderWebhookEndpoint(result)
	if v, ok := result["target_ref"].(string); ok && v != "" {
		fmt.Printf("  Target:           %s\n", v)
	}
	if v, ok := result["signature_header"].(string); ok && v != "" {
		fmt.Printf("  Signature header: %s\n", v)
	}
	if v, ok := result["rate_limit"].(string); ok && v != "" {
		fmt.Printf("  Rate limit:       %s\n", v)
	}
	if v, ok := result["description"].(string); ok && v != "" {
		fmt.Printf("  Description:      %s\n", v)
	}
	if v, ok := result["created_at"].(string); ok && v != "" {
		fmt.Printf("  Created:          %s\n", v)
	}
	if v, ok := result["rotated_at"].(string); ok && v != "" {
		fmt.Printf("  Rotated:          %s\n", v)
	}
	if tmpl, ok := result["input_template"].(map[string]any); ok && len(tmpl) > 0 {
		raw, _ := json.MarshalIndent(tmpl, "    ", "  ")
		fmt.Printf("  Input template:\n    %s\n", string(raw))
	}
}

// renderWebhookList prints a table of webhooks for `webhook list`.
func renderWebhookList(result map[string]any) {
	hooksAny, _ := result["webhooks"].([]any)
	if len(hooksAny) == 0 {
		fmt.Println("No webhooks. Create one with `cyfr webhook create`.")
		return
	}

	headers := []string{"NAME", "TARGET", "URL", "CREATED"}
	rows := make([]map[string]string, 0, len(hooksAny))
	for _, h := range hooksAny {
		hook, ok := h.(map[string]any)
		if !ok {
			continue
		}
		name, _ := hook["name"].(string)
		target, _ := hook["target_ref"].(string)
		url, _ := hook["url"].(string)
		created, _ := hook["created_at"].(string)
		rows = append(rows, map[string]string{
			"NAME":    name,
			"TARGET":  target,
			"URL":     url,
			"CREATED": created,
		})
	}
	output.Table(headers, rows)
}

// renderWebhookEndpoint prints the webhook's full URL (preferred) or its path.
func renderWebhookEndpoint(result map[string]any) {
	if url, ok := result["url"].(string); ok && url != "" {
		if strings.HasPrefix(url, "/") {
			fmt.Printf("  Path:   %s\n", url)
			fmt.Println("  (Set CYFR_PUBLIC_URL on the server to display the full URL.)")
		} else {
			fmt.Printf("  URL:    %s\n", url)
		}
		return
	}
	if slug, ok := result["slug"].(string); ok && slug != "" {
		fmt.Printf("  Path:   /hooks/%s\n", slug)
	}
}

func renderWebhookSecret(result map[string]any, label string) {
	secret, ok := result["secret"].(string)
	if !ok || secret == "" {
		return
	}
	fmt.Printf("\n  %s: %s\n\n", label, secret)
	fmt.Println("  Copy this secret now. It will not be shown again.")
}
