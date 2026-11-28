// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/cyfr/codex/internal/ops"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(webhookCmd)
	webhookCmd.AddCommand(webhookGetCmd)
	webhookCmd.AddCommand(webhookListCmd)
	webhookCmd.AddCommand(webhookUpdateCmd)
	webhookCmd.AddCommand(webhookRevokeCmd)
	webhookCmd.AddCommand(webhookRotateCmd)

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
signature against a stored secret, answers as soon as it accepts the
delivery, and then runs a target component: the answer does not say how
the run ends. The webhook can carry a static "input_template" (JSON object)
that gets merged into the invocation payload alongside the request envelope
(headers, body, metadata) under the reserved key '_webhook'.`,
}

var webhookGetCmd = &cobra.Command{
	Use:     "get <name>",
	Short:   "Get webhook info",
	Long:    "Show metadata for a webhook including target component, the headers it reads (signature, and the timestamp and idempotency headers when set), and input template. The HMAC secret is never returned.",
	Example: "  cyfr webhook get github-push",
	Args:    cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Webhook, ops.WebhookGetArgs{Name: args[0]})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			renderWebhookDetail(result)
		}
		return nil
	},
}

var webhookListCmd = &cobra.Command{
	Use:     "list",
	Short:   "List all webhooks",
	Long:    "List all webhooks with their names, target components, and URLs. HMAC secrets are never shown.",
	Example: "  cyfr webhook list",
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Webhook, ops.WebhookListArgs{})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			renderWebhookList(result)
		}
		return nil
	},
}

var webhookUpdateCmd = &cobra.Command{
	Use:   "update <name>",
	Short: "Update a webhook (no secret rotation)",
	Long: `Update mutable fields on a webhook: target component, signature header,
input template, description, or rate limit. The HMAC secret is unchanged —
use 'cyfr webhook rotate' to replace it. The grant a webhook runs under is
changed on CYFR's Webhooks page.`,
	Example: `  cyfr webhook update github-push --target f:local.new-handler
  cyfr webhook update slack-alerts --input '{"channel":"on-call"}'`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		name := args[0]

		toolArgs := ops.WebhookUpdateArgs{Name: name}

		if target, _ := cmd.Flags().GetString("target"); cmd.Flags().Changed("target") {
			toolArgs.TargetRef = ops.Value(target)
		}
		if sigHeader, _ := cmd.Flags().GetString("signature-header"); cmd.Flags().Changed("signature-header") {
			toolArgs.SignatureHeader = ops.Value(sigHeader)
		}
		if rateLimit, _ := cmd.Flags().GetString("rate-limit"); cmd.Flags().Changed("rate-limit") {
			toolArgs.RateLimit = ops.Value(rateLimit)
		}
		if description, _ := cmd.Flags().GetString("description"); cmd.Flags().Changed("description") {
			toolArgs.Description = ops.Value(description)
		}

		inputJSON, _ := cmd.Flags().GetString("input")
		inputFile, _ := cmd.Flags().GetString("input-file")
		if inputJSON != "" || inputFile != "" {
			parsed, err := parseInputTemplate(inputJSON, inputFile)
			if err != nil {
				return fmt.Errorf("Invalid input_template: %w", err)
			}
			if parsed != nil {
				toolArgs.InputTemplate = ops.Value(parsed)
			}
		}

		// Reject no-op updates client-side (server will too, but a clearer message helps).
		if toolArgs.TargetRef.IsZero() && toolArgs.SignatureHeader.IsZero() && toolArgs.RateLimit.IsZero() && toolArgs.Description.IsZero() && toolArgs.InputTemplate.IsZero() {
			return errors.New("No fields to update. Pass at least one of --target, --signature-header, --rate-limit, --description, --input, or --input-file.")
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Webhook, toolArgs)
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Webhook '%s' updated.\n", name)
			output.KeyValue(result)
		}
		return nil
	},
}

var webhookRevokeCmd = &cobra.Command{
	Use:     "revoke [name]",
	Short:   "Revoke (disable) a webhook",
	Long:    "Disable a webhook: its URL stops accepting POSTs now, whichever secret signs them, so revoking ends an old secret before the time a rotation leaves it is up. The audit trail is preserved. Run without arguments for interactive selection.",
	Example: "  cyfr webhook revoke github-push",
	Args:    cobra.RangeArgs(0, 1),
	RunE: func(cmd *cobra.Command, args []string) error {
		name, err := selectWebhookName(cmd.Context(), args, "Select a webhook to revoke", "Revoke webhook '%s'? The URL stops accepting POSTs.")
		if err != nil || name == "" {
			return err
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Webhook, ops.WebhookRevokeArgs{Name: name})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			fmt.Printf("Webhook '%s' revoked.\n", name)
		}
		return nil
	},
}

var webhookRotateCmd = &cobra.Command{
	Use:     "rotate [name]",
	Short:   "Rotate the HMAC secret for a webhook",
	Long:    "Generate a new HMAC secret. The old secret keeps working for a while after a rotation, so the sender's configuration can move to the new one; the answer says until when. 'cyfr webhook revoke' ends the webhook now. Run without arguments for interactive selection.",
	Example: "  cyfr webhook rotate github-push",
	Args:    cobra.RangeArgs(0, 1),
	RunE: func(cmd *cobra.Command, args []string) error {
		name, err := selectWebhookName(cmd.Context(), args, "Select a webhook to rotate", "Rotate webhook '%s'? The old secret keeps working for a while; the answer says until when.")
		if err != nil || name == "" {
			return err
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.Webhook, ops.WebhookRotateArgs{Name: name})
		if err != nil {
			return handleToolError(err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			renderWebhookRotated(result)
		}
		return nil
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

// selectWebhookName resolves the webhook a command acts on — see pickTarget
// for the argument/picker/confirm contract (a declined confirm returns ""
// with a nil error; callers stop there).
func selectWebhookName(ctx context.Context, args []string, promptTitle, confirmTemplate string) (string, error) {
	return pickTarget(ctx, args, selector{
		Title:   promptTitle,
		Confirm: confirmTemplate,
		Empty:   "No webhooks found. Make one on CYFR's Webhooks page.",
		Usage:   "Usage: provide <name> or run interactively",
		Fetch: func(ctx context.Context) ([]prompt.Option, error) {
			return prompt.FetchWebhooks(ctx, newClient())
		},
	})
}

// renderWebhookRotated prints the result of a successful rotation.
func renderWebhookRotated(result map[string]any) {
	name, _ := result["name"].(string)

	fmt.Printf("Webhook '%s' rotated.\n\n", name)
	renderWebhookEndpoint(result)
	renderWebhookSecret(result, "New secret")
	if until, err := time.Parse(time.RFC3339Nano, fmt.Sprint(result["previous_expires_at"])); err == nil {
		fmt.Printf("  The old secret keeps working until %s, %s from now. To end it now, revoke the webhook: cyfr webhook revoke %s\n",
			until.UTC().Format("2006-01-02 15:04:05 UTC"), hoursAndMinutes(until.Sub(webhookNow())), name)
	}
}

// webhookNow is the clock a rotation's span is read against; tests stand
// in for it.
var webhookNow = time.Now

// hoursAndMinutes is d to the nearest minute, in hours and minutes.
func hoursAndMinutes(d time.Duration) string {
	minutes := int(d.Round(time.Minute) / time.Minute)
	if minutes < 0 {
		minutes = 0
	}
	unit := func(n int, one string) string {
		if n == 1 {
			return "1 " + one
		}
		return strconv.Itoa(n) + " " + one + "s"
	}
	switch h, m := minutes/60, minutes%60; {
	case h == 0:
		return unit(m, "minute")
	case m == 0:
		return unit(h, "hour")
	default:
		return unit(h, "hour") + " " + unit(m, "minute")
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
	if v, ok := result["timestamp_header"].(string); ok && v != "" {
		fmt.Printf("  Timestamp header: %s\n", v)
	}
	if v, ok := result["idempotency_key_header"].(string); ok && v != "" {
		fmt.Printf("  Idempotency key:  %s\n", v)
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
		fmt.Println("No webhooks. Make one on CYFR's Webhooks page.")
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

// renderWebhookEndpoint prints the webhook's URL, which the server always
// answers absolute, at its shared address.
func renderWebhookEndpoint(result map[string]any) {
	if url, ok := result["url"].(string); ok && url != "" {
		fmt.Printf("  URL:    %s\n", url)
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
