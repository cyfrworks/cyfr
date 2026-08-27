// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

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
	Short:   "Build components",
	GroupID: "component",
	Long:    "Compile, validate, and manage component builds.",
}

var buildCompileCmd = &cobra.Command{
	Use:   "compile [type] <reference>",
	Short: "Compile a component by reference",
	Long: `Compile a scaffolded component's source code, save the output,
and auto-register it. The component must already exist (use 'cyfr new' to scaffold).

WASM types (catalyst, reagent, formula) compile Rust to WASM via cargo-component.
Tinctures with a React scaffold compile via npm + Vite to static HTML/JS/CSS.

The type can be given as a prefix (c:, r:, f:, t:) or as a separate first argument.`,
	Example: `  cyfr build compile catalyst:local.my-api:0.1.0
  cyfr build compile c local.my-api:0.1.0
  cyfr build compile t:local.my-dashboard:0.1.0`,
	Args: cobra.RangeArgs(1, 2),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		args = joinTypeShorthand(args)
		normalized, err := resolveComponentRef(cmd.Context(), client, args[0])
		if err != nil {
			return err
		}
		buildID := randomHex(8)

		fmt.Fprintf(os.Stderr, "Compiling %s...\n", normalized)

		result, err := client.CallToolWithProgress(cmd.Context(), "build", map[string]any{
			"action":    "compile",
			"reference": normalized,
			"build_id":  buildID,
		}, progressPrinter())
		if err != nil {
			return handleToolError(err, "Compile failed")
		}
		if flagJSON {
			output.JSON(result)
			return nil
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
		if registration := strVal(result, "registration"); registration != "" && registration != "done" {
			fmt.Printf("Registration: %s (the server registers the artifact in the background; check 'cyfr component list')\n", registration)
		}
		return nil
	},
}

var buildToolchainsCmd = &cobra.Command{
	Use:   "toolchains",
	Short: "List available build toolchains",
	Long:  "Show which compilation toolchains are installed and available.",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		result, err := client.CallTool(cmd.Context(), "build", map[string]any{
			"action": "toolchains",
		})
		if err != nil {
			return handleToolError(err, "Toolchains query failed")
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}

		toolchains, ok := result["toolchains"].(map[string]any)
		if !ok {
			fmt.Println("No toolchain information available.")
			return nil
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
		return nil
	},
}

var buildValidateCmd = &cobra.Command{
	Use:   "validate <base64>",
	Short: "Validate a WASM binary",
	Long:  "Validate a base64-encoded WASM binary and show its metadata.",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		result, err := client.CallTool(cmd.Context(), "build", map[string]any{
			"action":      "validate",
			"wasm_base64": args[0],
		})
		if err != nil {
			return handleToolError(err, "Validate failed")
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
		return nil
	},
}
