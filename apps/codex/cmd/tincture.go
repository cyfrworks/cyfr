package cmd

import (
	"fmt"
	"os"

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
		return fmt.Errorf("Invalid publisher %q: %v", slug, err)
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
	Long: `Control whether a tincture is publicly accessible at /t/:athanor/:publisher/:name
without authentication. Tinctures default to private (accessible only via Prism shell).`,
}

var tinctureVisibilitySetCmd = &cobra.Command{
	Use:   "set <publisher> <name> <true|false>",
	Short: "Retired — publishing is a consent decision",
	Args:  cobra.ArbitraryArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		// Visibility is not a policy bit anymore: public-ness IS an active
		// public profile. Point old muscle memory at the consent walk
		// instead of round-tripping to a server verb that no longer exists.
		fmt.Fprintln(os.Stderr, "Publishing is a consent decision, not a toggle.")
		fmt.Fprintln(os.Stderr, "  To publish:   run profile.publish on the tincture's owner profile (plan -> preview -> commit)")
		fmt.Fprintln(os.Stderr, "  To unpublish: run profile.revoke on the tincture's public profile")
		fmt.Fprintln(os.Stderr, "  To check:     cyfr tincture visibility get <publisher> <name>")
		os.Exit(1)
		return nil
	},
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
		result, err := client.CallTool(cmd.Context(), "tincture_visibility", map[string]any{
			"action":    "get",
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
