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

// componentTypes lists the plural directory names for each component type.
var componentTypes = []string{"catalysts", "reagents", "formulas"}

// parseReference converts a CLI reference string into the map format
// expected by the Opus executor.
//
// Supported formats:
//
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

	canonical := parsed.String()

	// If namespace is "local", resolve to filesystem path
	if parsed.Namespace == "local" {
		return resolveLocalReference(canonical, compType)
	}

	// All other namespaces are registry references
	return map[string]any{"registry": canonical}
}

// resolveLocalReference resolves a canonical "local.name:version" to an absolute WASM path.
// It probes components/{catalysts,reagents,formulas}/local/{name}/{version}/{type}.wasm.
// If compType is provided, it uses that directly. Otherwise it auto-detects by
// checking which directory contains a matching WASM file.
func resolveLocalReference(canonicalRef string, compType string) map[string]any {
	parsed, err := ref.Parse(canonicalRef)
	if err != nil {
		output.Errorf("Invalid local reference %q: %v", canonicalRef, err)
		return nil
	}
	namespace := parsed.Namespace
	name := parsed.Name
	version := parsed.Version

	// If --type flag was provided, resolve directly
	if compType != "" {
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

	// Auto-detect: probe each component type directory
	var found []string
	var foundPath string
	for _, plural := range componentTypes {
		singular := strings.TrimSuffix(plural, "s")
		wasmPath := filepath.Join("components", plural, namespace, name, version, singular+".wasm")
		absPath, err := filepath.Abs(wasmPath)
		if err != nil {
			continue
		}
		if _, err := os.Stat(absPath); err == nil {
			found = append(found, plural)
			foundPath = absPath
		}
	}

	switch len(found) {
	case 0:
		output.Errorf("No component found for %s — checked components/{catalysts,reagents,formulas}/%s/%s/%s/", canonicalRef, namespace, name, version)
		return nil
	case 1:
		return map[string]any{"local": foundPath}
	default:
		output.Errorf("Ambiguous reference %s — found in %s. Use --type to disambiguate.", canonicalRef, strings.Join(found, ", "))
		return nil
	}
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
	Use:     "run [reference]",
	Short:   "Execute a component",
	GroupID: "exec",
	Long: `Execute a component by reference. Pass --input to supply a JSON object
as execution input. Use --list to see running executions, --logs to
stream output, and --cancel to abort.`,
	Example: `  cyfr run local.openai:0.1.0
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

		compType, _ := cmd.Flags().GetString("type")
		ref := parseReference(args[0], compType)
		toolArgs := map[string]any{
			"action":    "run",
			"reference": ref,
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

		result, err := client.CallTool("execution", toolArgs)
		if err != nil {
			output.Errorf("Execution failed: %v", err)
		}

		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}
