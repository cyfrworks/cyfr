// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/cyfr/codex/internal/ref"

	"github.com/spf13/cobra"
)

// joinTypeShorthand checks if the first CLI arg is a known type shorthand
// (c, r, f, catalyst, reagent, formula) and the second arg exists.
// If so, it joins them as "type:ref" and returns a modified args slice.
// This enables: "cyfr run c local.claude:0.1.0" → "cyfr run c:local.claude:0.1.0"
func joinTypeShorthand(args []string) []string {
	if len(args) >= 2 && ref.IsTypePrefix(args[0]) {
		joined := args[0] + ":" + args[1]
		return append([]string{joined}, args[2:]...)
	}
	return args
}

// parseReference converts a CLI reference string into the canonical
// string format expected by the Opus executor.
//
// The CLI does minimal input normalization only — full parsing and validation
// is handled server-side by Sanctum.ComponentRef.
//
// Normalizations performed:
//   - --type flag injection when ref has no type prefix
//   - Everything else passes through as-is
//
// Refs containing '@' are passed through unchanged — ref.ParseRef + Validate
// reject them (personal slugs are bare; '@' is invalid anywhere in a ref).
func parseReference(rawRef string, compType string) (string, error) {
	// Reject local file paths — components must be registered first
	if strings.HasSuffix(rawRef, ".wasm") || strings.HasPrefix(rawRef, "./") || strings.HasPrefix(rawRef, "/") {
		return "", errors.New("Local file execution is no longer supported. Register the component first:\n  cyfr register\n  cyfr run <reference>")
	}

	// If --type flag given and ref has no type prefix, prepend it
	if compType != "" {
		if colonIdx := strings.Index(rawRef, ":"); colonIdx >= 0 {
			firstPart := rawRef[:colonIdx]
			if !strings.Contains(firstPart, ".") && ref.IsTypePrefix(firstPart) {
				// Already has a type prefix, pass through
				return rawRef, nil
			}
		}
		rawRef = compType + ":" + rawRef
	}

	return rawRef, nil
}

func init() {
	runCmd.Flags().Bool("list", false, "List running executions")
	runCmd.Flags().String("logs", "", "View execution logs")
	runCmd.Flags().String("cancel", "", "Cancel a running execution")
	runCmd.Flags().String("input", "", "JSON input for execution")
	runCmd.Flags().String("type", "", "Component type: catalyst, reagent, or formula")
	runCmd.Flags().String("profile", "", "Profile (id or label) whose consent this runs under")
	rootCmd.AddCommand(runCmd)
}

var runCmd = &cobra.Command{
	Use:     "run [type] [reference]",
	Short:   "Execute a component [interactive]",
	GroupID: "component",
	Args:    cobra.RangeArgs(0, 2),
	Long: `Execute a component by reference. The type can be specified as a prefix
(catalyst:, c:, reagent:, r:, formula:, f:) or as a separate first argument.

Pass --input to supply a JSON object as execution input. Use --list to see
running executions, --logs to stream output, and --cancel to abort.

Run without arguments for interactive selection.`,
	Example: `  cyfr run c:local.openai
  cyfr run c:local.openai:0.1.0
  cyfr run c local.openai
  cyfr run catalyst:local.openai
  cyfr run local.openai --type catalyst
  cyfr run cyfr.sentiment:1.0.0
  cyfr run c:local.openai --input '{"text":"hello"}'
  cyfr run --list
  cyfr run --logs exec_abc123
  cyfr run --cancel exec_abc123`,
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()

		if listFlag, _ := cmd.Flags().GetBool("list"); listFlag {
			result, err := client.CallTool(cmd.Context(), "execution", map[string]any{
				"action": "list",
			})
			if err != nil {
				return handleToolError(err)
			}
			return renderResult(result)
		}

		if logsID, _ := cmd.Flags().GetString("logs"); logsID != "" {
			result, err := client.CallTool(cmd.Context(), "execution", map[string]any{
				"action":       "logs",
				"execution_id": logsID,
			})
			if err != nil {
				return handleToolError(err)
			}
			return renderResult(result)
		}

		if cancelID, _ := cmd.Flags().GetString("cancel"); cancelID != "" {
			result, err := client.CallTool(cmd.Context(), "execution", map[string]any{
				"action":       "cancel",
				"execution_id": cancelID,
			})
			if err != nil {
				return handleToolError(err)
			}
			if flagJSON {
				output.JSON(result)
			} else {
				fmt.Println("Execution cancelled.")
			}
			return nil
		}

		// CLI shorthand: "cyfr run c local.claude:0.1.0" → join as "c:local.claude:0.1.0"
		args = joinTypeShorthand(args)
		compType, _ := cmd.Flags().GetString("type")
		refString, err := pickTarget(cmd.Context(), args, selector{
			Title: "Select a component to run",
			Empty: "No components found. Register one first.",
			Usage: "Usage: cyfr run <reference>",
			Fetch: func(ctx context.Context) ([]prompt.Option, error) {
				return prompt.FetchComponents(ctx, client)
			},
			Normalize: func(ctx context.Context, arg string) (string, error) {
				// Inject --type, then resolve a missing version for
				// registry refs.
				withType, err := parseReference(arg, compType)
				if err != nil {
					return "", err
				}
				return resolveComponentRef(ctx, client, withType)
			},
		})
		if err != nil {
			return err
		}

		var execInput map[string]any
		if len(args) >= 1 {
			if inputStr, _ := cmd.Flags().GetString("input"); inputStr != "" {
				if err := json.Unmarshal([]byte(inputStr), &execInput); err != nil {
					return fmt.Errorf("Invalid JSON input: %w", err)
				}
			}
		} else {
			// The ref came from the picker — offer to collect input the
			// same way.
			supplyInput, err := prompt.Confirm("Supply JSON input?")
			if err != nil {
				if prompt.IsAborted(err) {
					return prompt.ErrAborted
				}
				return fmt.Errorf("Prompt failed: %w", err)
			}
			if supplyInput {
				inputStr, err := prompt.InputText("JSON input", `{"key":"value"}`)
				if err != nil {
					if prompt.IsAborted(err) {
						return prompt.ErrAborted
					}
					return fmt.Errorf("Prompt failed: %w", err)
				}
				if inputStr != "" {
					if err := json.Unmarshal([]byte(inputStr), &execInput); err != nil {
						return fmt.Errorf("Invalid JSON input: %w", err)
					}
				}
			}
		}

		toolArgs := map[string]any{
			"action":    "run",
			"reference": refString,
		}
		if execInput != nil {
			toolArgs["input"] = execInput
		}
		// Which profile's consent this runs under. With several profiles
		// and no selector the server refuses rather than guessing.
		if profile, _ := cmd.Flags().GetString("profile"); profile != "" {
			toolArgs["profile"] = profile
		}

		result, err := client.CallTool(cmd.Context(), "execution", toolArgs)
		if err != nil {
			return handleToolError(err)
		}
		return renderResult(result)
	},
}
