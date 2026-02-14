package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/cyfr/codex/internal/output"
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
	Long: `Execute a component by reference. The type can be specified as a prefix
(catalyst:, c:, reagent:, r:, formula:, f:) or as a separate first argument.

Pass --input to supply a JSON object as execution input. Use --list to see
running executions, --logs to stream output, and --cancel to abort.`,
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
				output.Error(err.Error())
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
				output.Error(err.Error())
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
				output.Error(err.Error())
			}
			if flagJSON {
				output.JSON(result)
			} else {
				fmt.Println("Execution cancelled.")
			}
			_ = result
			return
		}

		if len(args) < 1 {
			output.Error("Usage: cyfr run <reference>")
		}

		// CLI shorthand: "cyfr run c local.claude:0.1.0" → join as "c:local.claude:0.1.0"
		args = joinTypeShorthand(args)

		compType, _ := cmd.Flags().GetString("type")

		// Parse the reference (may contain type prefix). The type is
		// embedded in the reference string — the server extracts it
		// from the reference via Sanctum.ComponentRef.parse/1.
		rawRef := args[0]
		refMap := parseReference(rawRef, compType)
		toolArgs := map[string]any{
			"action":    "run",
			"reference": refMap,
		}

		if inputStr, _ := cmd.Flags().GetString("input"); inputStr != "" {
			var input map[string]any
			if err := json.Unmarshal([]byte(inputStr), &input); err != nil {
				output.Errorf("Invalid JSON input: %v", err)
			}
			toolArgs["input"] = input
		}

		result, err2 := client.CallTool("execution", toolArgs)
		if err2 != nil {
			output.Error(err2.Error())
		}

		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}
