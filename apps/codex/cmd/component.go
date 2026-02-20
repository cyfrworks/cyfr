package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/cyfr/codex/internal/ref"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(searchCmd)
	rootCmd.AddCommand(inspectCmd)
	rootCmd.AddCommand(pullCmd)
	rootCmd.AddCommand(resolveCmd)
	publishCmd.Flags().String("registry", "", "OCI registry to push to (e.g., ghcr.io/youruser)")
	rootCmd.AddCommand(publishCmd)
	rootCmd.AddCommand(registryCmd)
	registryCmd.AddCommand(registryDiscoverCmd)
	registryCmd.AddCommand(registryLoginCmd)
}

var searchCmd = &cobra.Command{
	Use:     "search <query>",
	Short:   "Search for components",
	GroupID: "component",
	Long:    "Search the component registry by keyword and return matching references.",
	Example: `  cyfr search sentiment
  cyfr search "http client" --json`,
	Args: cobra.MinimumNArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("component", map[string]any{
			"action": "search",
			"query":  args[0],
		})
		if err != nil {
			output.Errorf("Search failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var inspectCmd = &cobra.Command{
	Use:     "inspect [type] [reference]",
	Short:   "Show component details",
	GroupID: "component",
	Long:    "Display metadata, version history, and capability declarations for a component. Run without arguments for interactive selection.",
	Example: `  cyfr inspect c:local.claude:0.1.0
  cyfr inspect c local.claude:0.1.0
  cyfr inspect local.sentiment:1.0.0`,
	Args: cobra.RangeArgs(0, 2),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		var normalized string

		switch {
		case len(args) >= 1:
			args = joinTypeShorthand(args)
			normalized = resolveComponentRef(client, args[0])
		case prompt.IsInteractive(flagNoInteractive):
			opts, err := prompt.FetchComponents(client)
			if err != nil {
				handleToolError(err)
			}
			if len(opts) == 0 {
				output.Error("No components found. Register one first.")
			}
			selected, err := prompt.SelectOne("Select a component to inspect", opts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				output.Errorf("Prompt failed: %v", err)
			}
			normalized = selected
		default:
			output.Error("Usage: cyfr inspect <reference>")
		}

		result, err := client.CallTool("component", map[string]any{
			"action":    "inspect",
			"reference": normalized,
		})
		if err != nil {
			output.Errorf("Inspect failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var pullCmd = &cobra.Command{
	Use:     "pull [type] <reference>",
	Short:   "Fetch component to cache",
	GroupID: "component",
	Long:    "Download a component WASM artifact to the local cache so it is available for offline execution. Supports both local registry references and OCI registry references.",
	Example: `  cyfr pull c:local.claude:0.1.0
  cyfr pull cyfr.sentiment:1.0.0
  cyfr pull ghcr.io/youruser/cyfr/catalysts/claude:0.1.0`,
	Args: cobra.RangeArgs(1, 2),
	Run: func(cmd *cobra.Command, args []string) {
		args = joinTypeShorthand(args)
		client := newClient()
		normalized := resolveComponentRef(client, args[0])
		result, err := client.CallTool("component", map[string]any{
			"action":    "pull",
			"reference": normalized,
		})
		if err != nil {
			output.Errorf("Pull failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var resolveCmd = &cobra.Command{
	Use:     "resolve [type] <reference>",
	Short:   "Resolve component location",
	GroupID: "component",
	Long:    "Resolve a component reference to its registry URL and cached file path.",
	Example: `  cyfr resolve c:local.claude:0.1.0
  cyfr resolve cyfr.sentiment:1.0.0`,
	Args: cobra.RangeArgs(1, 2),
	Run: func(cmd *cobra.Command, args []string) {
		args = joinTypeShorthand(args)
		client := newClient()
		normalized := resolveComponentRef(client, args[0])
		result, err := client.CallTool("component", map[string]any{
			"action":    "resolve",
			"reference": normalized,
		})
		if err != nil {
			output.Errorf("Resolve failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var publishCmd = &cobra.Command{
	Use:     "publish [type] <reference>",
	Short:   "Sign and publish component",
	GroupID: "component",
	Long: `Sign a local component and publish it to the registry, making it available for execution.
Use --registry to push the component to an OCI-compatible registry (GHCR, Docker Hub, etc.).`,
	Example: `  cyfr publish r:local.sentiment:1.0.0
  cyfr publish local.sentiment:1.0.0
  cyfr publish c:local.claude:0.1.0 --registry ghcr.io/youruser`,
	Args: cobra.RangeArgs(1, 2),
	Run: func(cmd *cobra.Command, args []string) {
		args = joinTypeShorthand(args)
		client := newClient()
		normalized := resolveComponentRef(client, args[0])
		toolArgs := map[string]any{
			"action":    "publish",
			"reference": normalized,
		}
		if registry, _ := cmd.Flags().GetString("registry"); registry != "" {
			toolArgs["registry"] = registry
		}
		result, err := client.CallTool("component", toolArgs)
		if err != nil {
			output.Errorf("Publish failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var registryCmd = &cobra.Command{
	Use:     "registry",
	Short:   "OCI registry operations",
	GroupID: "component",
	Long:    "Manage OCI-compatible container registries for component distribution.",
}

var registryDiscoverCmd = &cobra.Command{
	Use:   "discover <registry>",
	Short: "List components on a registry",
	Long:  "Discover CYFR components available on an OCI-compatible registry.",
	Example: `  cyfr registry discover ghcr.io/youruser
  cyfr registry discover docker.io/library`,
	Args: cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("component", map[string]any{
			"action":   "discover",
			"registry": args[0],
		})
		if err != nil {
			output.Errorf("Discover failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var registryLoginCmd = &cobra.Command{
	Use:   "login <registry>",
	Short: "Log in to a registry",
	Long:  "Store credentials for an OCI-compatible registry.",
	Example: `  cyfr registry login ghcr.io
  cyfr registry login docker.io`,
	Args: cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		registry := args[0]

		if !prompt.IsInteractive(flagNoInteractive) {
			output.Error("Registry login requires interactive mode")
		}

		username, err := prompt.InputText("Username", "")
		if err != nil {
			if prompt.IsAborted(err) {
				os.Exit(130)
			}
			output.Errorf("Prompt failed: %v", err)
		}

		password, err := prompt.InputSecret("Password or token", "")
		if err != nil {
			if prompt.IsAborted(err) {
				os.Exit(130)
			}
			output.Errorf("Prompt failed: %v", err)
		}

		// Store credentials in ~/.cyfr/oci-credentials.json
		homeDir, err := os.UserHomeDir()
		if err != nil {
			output.Errorf("Failed to get home directory: %v", err)
		}

		credPath := filepath.Join(homeDir, ".cyfr", "oci-credentials.json")
		var creds map[string]any

		if data, err := os.ReadFile(credPath); err == nil {
			_ = json.Unmarshal(data, &creds)
		}
		if creds == nil {
			creds = map[string]any{}
		}
		registries, ok := creds["registries"].(map[string]any)
		if !ok {
			registries = map[string]any{}
		}
		registries[registry] = map[string]any{
			"username": username,
			"password": password,
		}
		creds["registries"] = registries

		if err := os.MkdirAll(filepath.Dir(credPath), 0700); err != nil {
			output.Errorf("Failed to create directory: %v", err)
		}

		data, _ := json.MarshalIndent(creds, "", "  ")
		if err := os.WriteFile(credPath, data, 0600); err != nil {
			output.Errorf("Failed to write credentials: %v", err)
		}

		fmt.Printf("Login credentials stored for %s\n", registry)
	},
}

// normalizeComponentRef applies minimal CLI-level normalization to a
// component reference. Full parsing and validation is done server-side
// by Sanctum.ComponentRef.
func normalizeComponentRef(s string) string {
	if strings.Contains(s, "@") {
		s = strings.Replace(s, "@", ":", 1)
	}
	return s
}

// resolveComponentRef normalizes a component reference and, when the version
// is missing, queries available versions and prompts the user to select one.
//
// If the ref already contains an explicit version, it is returned after
// basic normalization (@ → :). If the version is omitted:
//   - Interactive mode: fetches installed versions and asks for confirmation
//   - Non-interactive mode: exits with an error requesting an explicit version
func resolveComponentRef(client *mcp.Client, s string) string {
	// Basic normalization: @ → :
	if strings.Contains(s, "@") {
		s = strings.Replace(s, "@", ":", 1)
	}

	parsed := ref.ParseRef(s)
	if parsed.HasVersion {
		return s
	}

	// Version is missing — resolve it.
	if !prompt.IsInteractive(flagNoInteractive) {
		output.Errorf("Version required. Example: %s", parsed.WithVersion("0.1.0"))
		return "" // unreachable — Errorf exits
	}

	componentType := ""
	if parsed.Type != "" {
		componentType = ref.ExpandType(parsed.Type)
	}

	versions, err := prompt.FetchVersions(client, parsed.Name, parsed.Namespace, componentType)
	if err != nil {
		output.Errorf("Failed to fetch versions: %v", err)
		return ""
	}

	switch len(versions) {
	case 0:
		output.Errorf("No installed versions found for '%s'. Register first with: cyfr register", parsed.Name)
		return ""
	case 1:
		resolved := parsed.WithVersion(versions[0])
		confirmed, err := prompt.Confirm(fmt.Sprintf("Did you mean %s?", resolved))
		if err != nil {
			if prompt.IsAborted(err) {
				os.Exit(130)
			}
			output.Errorf("Prompt failed: %v", err)
		}
		if !confirmed {
			fmt.Println("Cancelled.")
			os.Exit(0)
		}
		return resolved
	default:
		versionOpts := make([]prompt.Option, len(versions))
		for i, v := range versions {
			versionOpts[i] = prompt.Option{Label: parsed.WithVersion(v), Value: v}
		}
		selected, err := prompt.SelectOne("Select a version", versionOpts)
		if err != nil {
			if prompt.IsAborted(err) {
				os.Exit(130)
			}
			output.Errorf("Prompt failed: %v", err)
		}
		return parsed.WithVersion(selected)
	}
}
