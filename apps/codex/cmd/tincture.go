// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"fmt"
	"github.com/cyfr/codex/internal/ops"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/ref"
	"github.com/spf13/cobra"
)

// validateTincturePublisher rejects obviously invalid publisher slugs (e.g. a
// leading '@', uppercase, or illegal characters) before the MCP call. The
// server enforces the same rules; this early check gives the user a clearer
// inline error without a round-trip. Mirrors Sanctum.ComponentRef.validate_namespace/1.
func validateTincturePublisher(slug string) error {
	if err := ref.ValidateNamespace(slug); err != nil {
		return fmt.Errorf("Invalid publisher %q: %w", slug, err)
	}
	return nil
}

// tincturePublicPath is the public URL path the tincture_visibility tool
// returns for a tincture (`/t/<athanor>/<publisher>/<name>`). The server owns
// the URL shape; the CLI never composes it. When the server omits it, the
// athanor/publisher/name triple is shown instead.
func tincturePublicPath(result map[string]any, publisher, name string) string {
	if url, _ := result["url"].(string); url != "" {
		return url
	}
	athanor, _ := result["athanor"].(string)
	return fmt.Sprintf("athanor=%s publisher=%s name=%s", athanor, publisher, name)
}

func init() {
	rootCmd.AddCommand(tinctureCmd)
	tinctureCmd.AddCommand(tinctureVisibilityCmd)
	tinctureVisibilityCmd.AddCommand(tinctureVisibilityGetCmd)
}

var tinctureCmd = &cobra.Command{
	Use:     "tincture",
	Short:   "Manage tincture frontends",
	GroupID: "component",
	Long:    "Commands for managing tincture frontends — visibility, public access, etc.",
}

var tinctureVisibilityCmd = &cobra.Command{
	Use:   "visibility",
	Short: "Manage tincture public/private visibility",
	Long: `Control whether a tincture is publicly accessible at /t/:athanor/:publisher/:name
without authentication. Tinctures default to private (accessible only via Prism shell).`,
}

var tinctureVisibilityGetCmd = &cobra.Command{
	Use:     "get <publisher> <name>",
	Short:   "Check tincture visibility",
	Example: `  cyfr tincture visibility get local my-dashboard`,
	Args:    cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		publisher := args[0]
		name := args[1]

		if err := validateTincturePublisher(publisher); err != nil {
			return err
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), ops.TinctureVisibility, map[string]any{
			"action":    ops.TinctureVisibilityGet,
			"publisher": publisher,
			"name":      name,
		})
		if err != nil {
			return handleToolError(err, "Visibility query failed")
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		public := result["public"]
		if public == true {
			fmt.Printf("%s/%s: public (accessible at %s)\n", publisher, name, tincturePublicPath(result, publisher, name))
		} else {
			fmt.Printf("%s/%s: private (Prism shell only)\n", publisher, name)
		}
		return nil
	},
}
