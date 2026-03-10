package cmd

import (
	"fmt"
	"os"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(buildCmd)
	buildCmd.AddCommand(buildCompileCmd)
	buildCmd.AddCommand(buildToolchainsCmd)
	buildCmd.AddCommand(buildValidateCmd)
}

var buildCmd = &cobra.Command{
	Use:     "build",
	Short:   "Build WASM components",
	GroupID: "component",
	Long:    "Compile, validate, and manage WASM component builds.",
}

var buildCompileCmd = &cobra.Command{
	Use:   "compile [type] <reference>",
	Short: "Compile a component by reference",
	Long: `Compile a scaffolded component's Rust source to WASM, save the binary,
and auto-register it. The component must already exist (use 'cyfr new' to scaffold).

The type can be given as a prefix (c:, r:, f:) or as a separate first argument.`,
	Example: `  cyfr build compile catalyst:local.my-api:0.1.0
  cyfr build compile c local.my-api:0.1.0`,
	Args: cobra.RangeArgs(1, 2),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		args = joinTypeShorthand(args)
		normalized := resolveComponentRef(client, args[0])
		buildID := randomHex(8)

		cleanup := streamProgress(client, "build_id", buildID)
		defer cleanup()

		fmt.Fprintf(os.Stderr, "Compiling %s...\n", normalized)

		result, err := client.CallTool("build", map[string]any{
			"action":    "compile",
			"reference": normalized,
			"build_id":  buildID,
		})
		if err != nil {
			handleToolError(err, "Compile failed")
		}
		if flagJSON {
			output.JSON(result)
			return
		}

		status := strVal(result, "status")
		digest := strVal(result, "digest")
		size := result["size"]

		fmt.Printf("Status: %s\n", status)
		fmt.Printf("Reference: %s\n", normalized)
		fmt.Printf("Digest: %s\n", digest)
		if s, ok := size.(float64); ok {
			fmt.Printf("Size: %.0f bytes\n", s)
		}
		if registered, ok := result["registered"].(float64); ok && registered > 0 {
			fmt.Printf("Registered: %.0f component(s)\n", registered)
		}
		if pulled, ok := result["pulled_dependencies"].([]any); ok && len(pulled) > 0 {
			fmt.Printf("Pulled dependencies:\n")
			for _, p := range pulled {
				fmt.Printf("  + %s\n", p)
			}
		}
		if failed, ok := result["failed_pulls"].([]any); ok && len(failed) > 0 {
			fmt.Fprintf(os.Stderr, "Failed to pull:\n")
			for _, f := range failed {
				fmt.Fprintf(os.Stderr, "  ! %s\n", f)
			}
		}
		if regErr, ok := result["registration_error"].(string); ok {
			fmt.Fprintf(os.Stderr, "\nWarning: compiled successfully but registration failed:\n  %s\n", regErr)
			fmt.Fprintln(os.Stderr, "Check cyfr-manifest.json and re-run 'cyfr register' to debug.")
		}
	},
}

var buildToolchainsCmd = &cobra.Command{
	Use:   "toolchains",
	Short: "List available build toolchains",
	Long:  "Show which compilation toolchains are installed and available.",
	Args:  cobra.NoArgs,
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("build", map[string]any{
			"action": "toolchains",
		})
		if err != nil {
			handleToolError(err, "Toolchains query failed")
		}
		if flagJSON {
			output.JSON(result)
			return
		}

		toolchains, ok := result["toolchains"].(map[string]any)
		if !ok {
			fmt.Println("No toolchain information available.")
			return
		}

		for name, info := range toolchains {
			tc, ok := info.(map[string]any)
			if !ok {
				continue
			}
			available := "no"
			if a, ok := tc["available"].(bool); ok && a {
				available = "yes"
			}
			desc := ""
			if d, ok := tc["description"].(string); ok {
				desc = d
			}
			fmt.Printf("%-10s available=%s  %s\n", name, available, desc)
		}
	},
}

var buildValidateCmd = &cobra.Command{
	Use:   "validate <base64>",
	Short: "Validate a WASM binary",
	Long:  "Validate a base64-encoded WASM binary and show its metadata.",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("build", map[string]any{
			"action":      "validate",
			"wasm_base64": args[0],
		})
		if err != nil {
			handleToolError(err, "Validate failed")
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}
