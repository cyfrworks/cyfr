package cmd

import (
	"fmt"

	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/ref"
	"github.com/spf13/cobra"
)

// validateTincturePublisher rejects obviously invalid publisher slugs (e.g. a
// leading '@', uppercase, or illegal characters) before the MCP call. The
// server enforces the same rules; this early check gives the user a clearer
// inline error without a round-trip. Mirrors Sanctum.ComponentRef.validate_namespace/1.
func validateTincturePublisher(slug string) {
	if err := ref.ValidateNamespace(slug); err != nil {
		output.Errorf("Invalid publisher %q: %v", slug, err)
	}
}

func init() {
	rootCmd.AddCommand(tinctureCmd)
	tinctureCmd.AddCommand(tinctureVisibilityCmd)
	tinctureVisibilityCmd.AddCommand(tinctureVisibilitySetCmd)
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
	Long: `Control whether a tincture is publicly accessible at /t/:publisher/:name
without authentication. Tinctures default to private (accessible only via Prism shell).`,
}

var tinctureVisibilitySetCmd = &cobra.Command{
	Use:   "set <publisher> <name> <true|false>",
	Short: "Set tincture visibility",
	Example: `  cyfr tincture visibility set local my-dashboard true
  cyfr tincture visibility set local my-dashboard false`,
	Args: cobra.ExactArgs(3),
	Run: func(cmd *cobra.Command, args []string) {
		publisher := args[0]
		name := args[1]
		public := args[2] == "true"

		validateTincturePublisher(publisher)

		client := newClient()
		result, err := client.CallTool("tincture_visibility", map[string]any{
			"action":    "set",
			"publisher": publisher,
			"name":      name,
			"public":    public,
		})
		if err != nil {
			handleToolError(err, "Visibility update failed")
		}
		if flagJSON {
			output.JSON(result)
			return
		}
		if public {
			fmt.Printf("%s/%s is now public at /t/%s/%s\n", publisher, name, publisher, name)
		} else {
			fmt.Printf("%s/%s is now private (Prism shell only)\n", publisher, name)
		}
	},
}

var tinctureVisibilityGetCmd = &cobra.Command{
	Use:   "get <publisher> <name>",
	Short: "Check tincture visibility",
	Example: `  cyfr tincture visibility get local my-dashboard`,
	Args: cobra.ExactArgs(2),
	Run: func(cmd *cobra.Command, args []string) {
		publisher := args[0]
		name := args[1]

		validateTincturePublisher(publisher)

		client := newClient()
		result, err := client.CallTool("tincture_visibility", map[string]any{
			"action":    "get",
			"publisher": publisher,
			"name":      name,
		})
		if err != nil {
			handleToolError(err, "Visibility query failed")
		}
		if flagJSON {
			output.JSON(result)
			return
		}
		public := result["public"]
		if public == true {
			fmt.Printf("%s/%s: public (accessible at /t/%s/%s)\n", publisher, name, publisher, name)
		} else {
			fmt.Printf("%s/%s: private (Prism shell only)\n", publisher, name)
		}
	},
}
