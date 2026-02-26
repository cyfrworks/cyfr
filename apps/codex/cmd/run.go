package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
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

// parseReference converts a CLI reference string into the map format
// expected by the Opus executor.
//
// The CLI does minimal input normalization only — full parsing and validation
// is handled server-side by Sanctum.ComponentRef.
//
// Normalizations performed:
//   - Local .wasm files → {"local": relative_path}
//   - "@" version separator → ":" (input convenience)
//   - --type flag injection when ref has no type prefix
//   - Everything else passes through as {"registry": raw_string}
func parseReference(rawRef string, compType string) map[string]any {
	// Local file references (ends in .wasm or starts with ./ or /)
	if strings.HasSuffix(rawRef, ".wasm") || strings.HasPrefix(rawRef, "./") || strings.HasPrefix(rawRef, "/") {
		absPath, err := filepath.Abs(rawRef)
		if err != nil {
			output.Errorf("Failed to resolve path: %v", err)
			return nil
		}
		if _, err := os.Stat(absPath); err != nil {
			output.Errorf("Component not found at %s", absPath)
			return nil
		}
		cwd, err := os.Getwd()
		if err != nil {
			output.Errorf("Failed to determine working directory: %v", err)
			return nil
		}
		relPath, err := filepath.Rel(cwd, absPath)
		if err != nil || strings.HasPrefix(relPath, "..") {
			output.Errorf("Local path %s is outside the project directory. Local components must be within the project tree.", absPath)
			return nil
		}
		return map[string]any{"local": relPath}
	}

	// Registry references with @ version separator → normalize to colon
	if strings.Contains(rawRef, "@") {
		rawRef = strings.Replace(rawRef, "@", ":", 1)
	}

	// If the ref already has a type prefix, pass through as-is
	if colonIdx := strings.Index(rawRef, ":"); colonIdx >= 0 {
		firstPart := rawRef[:colonIdx]
		if !strings.Contains(firstPart, ".") && ref.IsTypePrefix(firstPart) {
			return map[string]any{"registry": rawRef}
		}
	}

	// OCI-style references: contain "/" (e.g., ghcr.io/user/catalysts/tool:1.0.0)
	// but are not local paths (./ or /)
	if strings.Contains(rawRef, "/") {
		return map[string]any{"oci": rawRef}
	}

	// If --type flag given and ref has no type prefix, prepend it
	if compType != "" {
		rawRef = compType + ":" + rawRef
	}

	return map[string]any{"registry": rawRef}
}

func init() {
	runCmd.Flags().Bool("list", false, "List running executions")
	runCmd.Flags().String("logs", "", "View execution logs")
	runCmd.Flags().String("cancel", "", "Cancel a running execution")
	runCmd.Flags().String("input", "", "JSON input for execution")
	runCmd.Flags().String("type", "", "Component type: catalyst, reagent, or formula")
	rootCmd.AddCommand(runCmd)
}

var runCmd = &cobra.Command{
	Use:     "run [type] [reference]",
	Short:   "Execute a component",
	GroupID: "exec",
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
  cyfr run ./path/to/catalyst.wasm
  cyfr run c:local.openai --input '{"text":"hello"}'
  cyfr run --list
  cyfr run --logs exec_abc123
  cyfr run --cancel exec_abc123`,
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()

		if listFlag, _ := cmd.Flags().GetBool("list"); listFlag {
			result, err := client.CallTool("execution", map[string]any{
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
			return
		}

		if logsID, _ := cmd.Flags().GetString("logs"); logsID != "" {
			result, err := client.CallTool("execution", map[string]any{
				"action":       "logs",
				"execution_id": logsID,
			})
			if err != nil {
				handleToolError(err)
			}
			if flagJSON {
				output.JSON(result)
			} else {
				output.KeyValue(result)
			}
			return
		}

		if cancelID, _ := cmd.Flags().GetString("cancel"); cancelID != "" {
			result, err := client.CallTool("execution", map[string]any{
				"action":       "cancel",
				"execution_id": cancelID,
			})
			if err != nil {
				handleToolError(err)
			}
			if flagJSON {
				output.JSON(result)
			} else {
				fmt.Println("Execution cancelled.")
			}
			_ = result
			return
		}

		var refMap map[string]any
		var execInput map[string]any

		switch {
		case len(args) >= 1:
			// CLI shorthand: "cyfr run c local.claude:0.1.0" → join as "c:local.claude:0.1.0"
			args = joinTypeShorthand(args)
			compType, _ := cmd.Flags().GetString("type")
			rawRef := args[0]
			refMap = parseReference(rawRef, compType)

			// Resolve missing version for registry refs
			if regRef, ok := refMap["registry"].(string); ok {
				refMap["registry"] = resolveComponentRef(client, regRef)
			}

			if inputStr, _ := cmd.Flags().GetString("input"); inputStr != "" {
				if err := json.Unmarshal([]byte(inputStr), &execInput); err != nil {
					output.Errorf("Invalid JSON input: %v", err)
				}
			}
		case prompt.IsInteractive(flagNoInteractive):
			compOpts, err := prompt.FetchComponents(client)
			if err != nil {
				handleToolError(err)
			}
			if len(compOpts) == 0 {
				output.Error("No components found. Register one first.")
			}
			selected, err := prompt.SelectOne("Select a component to run", compOpts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			refMap = map[string]any{"registry": selected}

			supplyInput, err := prompt.Confirm("Supply JSON input?")
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			if supplyInput {
				inputStr, err := prompt.InputText("JSON input", `{"key":"value"}`)
				if err != nil {
					if prompt.IsAborted(err) {
						os.Exit(130)
					}
					output.Errorf("Prompt failed: %v", err)
				}
				if inputStr != "" {
					if err := json.Unmarshal([]byte(inputStr), &execInput); err != nil {
						output.Errorf("Invalid JSON input: %v", err)
					}
				}
			}
		default:
			output.Error("Usage: cyfr run <reference>")
		}

		toolArgs := map[string]any{
			"action":    "run",
			"reference": refMap,
		}
		if execInput != nil {
			toolArgs["input"] = execInput
		}

		result, err2 := client.CallTool("execution", toolArgs)
		if err2 != nil {
			handleToolError(err2)
		}

		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}
