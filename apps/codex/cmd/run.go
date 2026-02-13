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
// Supported formats:
//
//	"catalyst:local.name:version"         → {"local": "/abs/components/catalysts/local/name/version/catalyst.wasm"}
//	"c:local.name:version"                → same as above (shorthand)
//	"local.name:version"                  → {"local": "/abs/components/{type}s/local/name/version/{type}.wasm"}
//	"namespace.name:version"              → {"registry": "namespace.name:version"}
//	"./path/to/catalyst.wasm"             → {"local": "/abs/path/to/catalyst.wasm"}
//	"components/catalysts/.../file.wasm"  → {"local": "/abs/path/..."}
//	"local:name:version"                  → (deprecated) same as local.name:version
//	"acme/sentiment@1.0.0"               → {"registry": "acme/sentiment:1.0.0"}
func parseReference(rawRef string, compType string) map[string]any {
	// Local file references (ends in .wasm or starts with ./ or /)
	if strings.HasSuffix(rawRef, ".wasm") || strings.HasPrefix(rawRef, "./") || strings.HasPrefix(rawRef, "/") {
		absPath, err := filepath.Abs(rawRef)
		if err != nil {
			absPath = rawRef
		}
		return map[string]any{"local": absPath}
	}

	// Legacy colon-separated: local:name:version → deprecation warning + convert
	if strings.HasPrefix(rawRef, "local:") {
		parts := strings.SplitN(rawRef, ":", 3)
		if len(parts) == 3 && parts[1] != "" && parts[2] != "" {
			fmt.Fprintf(os.Stderr, "Warning: 'local:name:version' format is deprecated. Use 'local.%s:%s' instead.\n", parts[1], parts[2])
			rawRef = fmt.Sprintf("local.%s:%s", parts[1], parts[2])
		}
	}

	// Registry references with @ version separator → normalize to colon
	if strings.Contains(rawRef, "@") {
		rawRef = strings.Replace(rawRef, "@", ":", 1)
	}

	// Parse as canonical component ref
	parsed, err := ref.Parse(rawRef)
	if err != nil {
		// Fall back to treating as registry reference
		return map[string]any{"registry": rawRef}
	}

	// Use type from parsed ref if available, otherwise use compType flag
	if parsed.Type != "" && compType == "" {
		compType = parsed.Type
	}

	canonical := parsed.String()

	// If namespace is "local", resolve to filesystem path
	if parsed.Namespace == "local" {
		return resolveLocalReference(canonical, compType)
	}

	// All other namespaces are registry references
	return map[string]any{"registry": canonical}
}

// resolveLocalReference resolves a canonical ref to an absolute WASM path.
// It probes components/{catalysts,reagents,formulas}/local/{name}/{version}/{type}.wasm.
// If compType is provided (from --type flag or type prefix in ref), it resolves directly.
// Otherwise it auto-detects by checking which directory contains a matching WASM file.
func resolveLocalReference(canonicalRef string, compType string) map[string]any {
	parsed, err := ref.Parse(canonicalRef)
	if err != nil {
		output.Errorf("Invalid local reference %q: %v", canonicalRef, err)
		return nil
	}
	namespace := parsed.Namespace
	name := parsed.Name
	version := parsed.Version

	// Use type from parsed ref if available
	if parsed.Type != "" && compType == "" {
		compType = parsed.Type
	}

	// Component type is required — no auto-detection
	if compType == "" {
		output.Errorf("Component type is required. Use a type prefix (e.g., c:%s) or --type flag.", canonicalRef)
		return nil
	}

	singular := compType
	plural := singular + "s"
	wasmPath := filepath.Join("components", plural, namespace, name, version, singular+".wasm")
	absPath, err := filepath.Abs(wasmPath)
	if err != nil {
		output.Errorf("Failed to resolve path: %v", err)
		return nil
	}
	if _, err := os.Stat(absPath); err != nil {
		output.Errorf("Component not found at %s", absPath)
		return nil
	}
	return map[string]any{"local": absPath}
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
	Example: `  cyfr run c:local.openai:0.1.0
  cyfr run c local.openai:0.1.0
  cyfr run catalyst:local.openai:0.1.0
  cyfr run local.openai:0.1.0 --type catalyst
  cyfr run cyfr.sentiment:1.0.0
  cyfr run ./path/to/catalyst.wasm
  cyfr run local.openai:0.1.0 --input '{"text":"hello"}'
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
				output.Errorf("Failed: %v", err)
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
				output.Errorf("Failed: %v", err)
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
				output.Errorf("Failed: %v", err)
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

		// Parse the reference (may contain type prefix)
		rawRef := args[0]
		parsed, err := ref.Parse(rawRef)
		if err == nil && parsed.Type != "" {
			// Type from ref takes precedence over --type flag
			if compType != "" && compType != parsed.Type {
				fmt.Fprintf(os.Stderr, "Warning: --type %s ignored; using type from ref: %s\n", compType, parsed.Type)
			}
			compType = parsed.Type
		}

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

		if compType != "" {
			toolArgs["type"] = compType
		}

		result, err2 := client.CallTool("execution", toolArgs)
		if err2 != nil {
			output.Errorf("Execution failed: %v", err2)
		}

		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}
