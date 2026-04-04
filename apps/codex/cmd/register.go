package cmd

import (
	"fmt"
	"os"
	"strings"

	"github.com/cyfr/codex/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(registerCmd)
}

var registerCmd = &cobra.Command{
	Use:     "register",
	Short:   "Scan and register all local components",
	GroupID: "component",
	Long: `Scan the components/ directory for local components (catalysts, reagents,
formulas, and tinctures) and register them in the Compendium registry, making
them available for search and execution. Run 'cyfr setup' afterwards to
configure secrets and policies for WASM components.`,
	Example: `  cyfr register
  cyfr register --json`,
	Args: cobra.NoArgs,
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		registerID := randomHex(8)

		cleanup := streamProgress(client, "register_id", registerID)
		defer cleanup()

		result, err := client.CallTool("component", map[string]any{
			"action":      "register",
			"register_id": registerID,
		})
		if err != nil {
			handleToolError(err, "Register failed")
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
			printRegisterDependencyInfo(result)
		}
		total, _ := result["total"].(float64)
		if total == 0 {
			fmt.Fprintln(os.Stderr)
			fmt.Fprintln(os.Stderr, "No components found. Check that:")
			fmt.Fprintln(os.Stderr, "  - components/ is volume-mounted into the Docker container")
			fmt.Fprintln(os.Stderr, "  - Each version dir has cyfr-manifest.json and {type}.wasm")
			fmt.Fprintln(os.Stderr, "  - Structure: components/{type}s/{local|agent}/{name}/{version}/")
			if dirs, ok := result["scanned_dirs"]; ok {
				fmt.Fprintf(os.Stderr, "  - Server scanned: %v\n", dirs)
			}
		}
	},
}

// printRegisterDependencyInfo displays dependency warnings and auto-pull results after registration.
func printRegisterDependencyInfo(result map[string]any) {
	if pulled, ok := result["pulled_dependencies"].([]any); ok && len(pulled) > 0 {
		refs := make([]string, 0, len(pulled))
		for _, p := range pulled {
			if s, ok := p.(string); ok {
				refs = append(refs, s)
			}
		}
		if len(refs) > 0 {
			fmt.Printf("\nAuto-pulled %d %s: %s\n", len(refs), pluralize("dependency", len(refs)), strings.Join(refs, ", "))
		}
	}

	if missing, ok := result["missing_local_deps"].([]any); ok && len(missing) > 0 {
		refs := make([]string, 0, len(missing))
		for _, m := range missing {
			if s, ok := m.(string); ok {
				refs = append(refs, s)
			}
		}
		if len(refs) > 0 {
			fmt.Fprintf(os.Stderr, "\nWarning: %d missing local %s:\n", len(refs), pluralize("dependency", len(refs)))
			for _, r := range refs {
				fmt.Fprintf(os.Stderr, "  - %s\n", r)
			}
			fmt.Fprintln(os.Stderr, "Create these in components/ and re-run 'cyfr register'.")
		}
	}

	if failed, ok := result["failed_pulls"].([]any); ok && len(failed) > 0 {
		refs := make([]string, 0, len(failed))
		for _, f := range failed {
			if s, ok := f.(string); ok {
				refs = append(refs, s)
			}
		}
		if len(refs) > 0 {
			fmt.Fprintf(os.Stderr, "\nWarning: Failed to pull %d %s: %s\n", len(refs), pluralize("dependency", len(refs)), strings.Join(refs, ", "))
		}
	}

	if optMissing, ok := result["optional_missing"].([]any); ok && len(optMissing) > 0 {
		refs := make([]string, 0, len(optMissing))
		for _, p := range optMissing {
			if s, ok := p.(string); ok {
				refs = append(refs, s)
			}
		}
		if len(refs) > 0 {
			fmt.Fprintf(os.Stderr, "\nNote: %d optional %s not available: %s\n", len(refs), pluralize("dependency", len(refs)), strings.Join(refs, ", "))
		}
	}
}
