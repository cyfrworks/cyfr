package cmd

import (
	"fmt"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

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
	Long: `Control whether a tincture is publicly accessible at /public/:publisher/:name
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
			fmt.Printf("%s/%s is now public at /public/%s/%s\n", publisher, name, publisher, name)
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
			fmt.Printf("%s/%s: public (accessible at /public/%s/%s)\n", publisher, name, publisher, name)
		} else {
			fmt.Printf("%s/%s: private (Prism shell only)\n", publisher, name)
		}
	},
}
