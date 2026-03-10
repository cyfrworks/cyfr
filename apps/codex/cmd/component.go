package cmd

import (
	"fmt"
	"os"
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
	publishCmd.Flags().String("registry", "", "OCI registry to push to (e.g., ghcr.io/youruser)")
	rootCmd.AddCommand(publishCmd)
	rootCmd.AddCommand(registryCmd)
	registryCmd.AddCommand(registryDiscoverCmd)
	registryCmd.AddCommand(registryLoginCmd)
	newCmd.Flags().String("version", "0.1.0", "Component version (semver)")
	rootCmd.AddCommand(newCmd)
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
			"query":  strings.Join(args, " "),
		})
		if err != nil {
			handleToolError(err, "Search failed")
		}
		if flagJSON {
			output.JSON(result)
			return
		}

		components, ok := result["components"].([]any)
		if !ok || len(components) == 0 {
			fmt.Println("No components found.")
			return
		}

		// Server handles deduplication and version merging.
		type searchRow struct {
			reference   string
			compType    string
			description string
			version     string
		}

		var rows []searchRow

		for _, c := range components {
			comp, ok := c.(map[string]any)
			if !ok {
				continue
			}

			compType := strVal(comp, "component_type")

			// Build reference from component_ref or fields
			reference := strVal(comp, "component_ref")
			if reference == "" {
				name := strVal(comp, "name")
				publisher := strVal(comp, "publisher")
				if publisher == "" {
					publisher = strVal(comp, "publisher_name")
				}
				if publisher != "" && name != "" {
					reference = publisher + "." + name
				} else if name != "" {
					reference = name
				}
				if compType != "" {
					reference = compType + ":" + reference
				}
			}

			// Build version display from server-provided fields
			localVersion := strVal(comp, "local_version")
			remoteLatest := strVal(comp, "remote_latest")
			updateAvailable := false
			if ua, ok := comp["update_available"].(bool); ok {
				updateAvailable = ua
			}

			versionDisplay := ""
			switch {
			case updateAvailable && localVersion != "" && remoteLatest != "":
				versionDisplay = localVersion + " → " + remoteLatest
			case localVersion != "":
				versionDisplay = localVersion
			case remoteLatest != "":
				versionDisplay = remoteLatest + " (remote)"
			default:
				versionDisplay = strVal(comp, "version")
			}

			rows = append(rows, searchRow{
				reference:   reference,
				compType:    compType,
				description: strVal(comp, "description"),
				version:     versionDisplay,
			})
		}

		headers := []string{"REFERENCE", "TYPE", "VERSION", "DESCRIPTION"}
		tableRows := make([]map[string]string, 0, len(rows))
		for _, r := range rows {
			tableRows = append(tableRows, map[string]string{
				"REFERENCE":   r.reference,
				"TYPE":        r.compType,
				"VERSION":     r.version,
				"DESCRIPTION": r.description,
			})
		}
		output.Table(headers, tableRows)
		fmt.Fprintf(cmd.ErrOrStderr(), "\n%d result(s)\n", len(rows))

		// Show incomplete warning if remote search failed
		if note, ok := result["note"].(string); ok && note != "" {
			fmt.Fprintf(os.Stderr, "\nWarning: %s\n", note)
		}
	},
}

var inspectCmd = &cobra.Command{
	Use:     "inspect [type] [reference]",
	Short:   "Show component details [interactive]",
	GroupID: "component",
	Long:    "Display metadata, version history, and capability declarations for a component. Run without arguments for interactive selection.",
	Example: `  cyfr inspect c:local.claude:0.1.0
  cyfr inspect c local.claude:0.1.0
  cyfr inspect local.sentiment:1.0.0`,
	Args: cobra.RangeArgs(0, 2),
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		var normalized string
		var originalInput string

		switch {
		case len(args) >= 1:
			args = joinTypeShorthand(args)
			originalInput = args[0]
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
			handleToolError(err, "Inspect failed")
		}
		printResolutionFeedback(result, originalInput)
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
			printInspectDependencies(result)
		}
	},
}

var pullCmd = &cobra.Command{
	Use:     "pull [type] <reference>",
	Short:   "Fetch component to cache",
	GroupID: "component",
	Long:    "Download a component WASM artifact to the local cache so it is available for offline execution. Supports both local registry references and OCI registry references.\nAutomatically pulls required dependencies declared in the component manifest.",
	Example: `  cyfr pull c:local.claude:0.1.0
  cyfr pull cyfr.sentiment:1.0.0
  cyfr pull ghcr.io/youruser/cyfr/catalysts/claude:0.1.0`,
	Args: cobra.RangeArgs(1, 2),
	Run: func(cmd *cobra.Command, args []string) {
		args = joinTypeShorthand(args)
		client := newClient()
		originalInput := args[0]
		normalized := resolveComponentRef(client, args[0])
		progressID := randomHex(8)

		cleanup := streamProgress(client, "progress_id", progressID)
		defer cleanup()

		result, err := client.CallTool("component", map[string]any{
			"action":      "pull",
			"reference":   normalized,
			"progress_id": progressID,
		})
		if err != nil {
			handleToolError(err, "Pull failed")
		}
		printResolutionFeedback(result, originalInput)
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
			printDependencyInfo(result)
		}
	},
}

var publishCmd = &cobra.Command{
	Use:     "publish [type] <reference>",
	Short:   "Sign and publish component",
	GroupID: "component",
	Long: `Sign a local component and publish it to the registry.
Defaults to registry.cyfr.run. Use --registry to push to a different OCI-compatible registry.`,
	Example: `  cyfr publish c:local.claude:0.2.0
  cyfr publish r:local.sentiment:1.0.0 --registry ghcr.io/youruser`,
	Args: cobra.RangeArgs(1, 2),
	Run: func(cmd *cobra.Command, args []string) {
		args = joinTypeShorthand(args)
		client := newClient()
		normalized := resolveComponentRef(client, args[0])

		if !ref.ParseRef(normalized).HasVersion {
			output.Error("Publishing requires an explicit version (e.g., c:local.claude:0.1.0)")
		}

		progressID := randomHex(8)

		cleanup := streamProgress(client, "progress_id", progressID)
		defer cleanup()

		toolArgs := map[string]any{
			"action":      "publish",
			"reference":   normalized,
			"progress_id": progressID,
		}
		if registry, _ := cmd.Flags().GetString("registry"); registry != "" {
			toolArgs["registry"] = registry
		}
		result, err := client.CallTool("component", toolArgs)
		if err != nil {
			handleToolError(err, "Publish failed")
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
	},
}

var newCmd = &cobra.Command{
	Use:     "new <type> <name>",
	Short:   "Scaffold a new component",
	GroupID: "component",
	Long:    "Create a new component project with directory structure, WIT files, manifest, and starter Rust source.",
	Example: `  cyfr new catalyst my-api
  cyfr new formula my-workflow --version 0.2.0
  cyfr new reagent my-transform`,
	Args: cobra.ExactArgs(2),
	Run: func(cmd *cobra.Command, args []string) {
		componentType := ref.ExpandType(args[0])
		name := args[1]
		version, _ := cmd.Flags().GetString("version")

		client := newClient()
		result, err := client.CallTool("component", map[string]any{
			"action":  "new",
			"type":    componentType,
			"name":    name,
			"version": version,
		})
		if err != nil {
			handleToolError(err, "Scaffold failed")
		}
		if flagJSON {
			output.JSON(result)
			return
		}

		reference := strVal(result, "reference")
		fmt.Printf("Created %s\n", reference)

		if files, ok := result["files"].([]any); ok {
			for _, f := range files {
				if s, ok := f.(string); ok {
					fmt.Printf("  %s\n", s)
				}
			}
		}

		if steps, ok := result["next_steps"].([]any); ok && len(steps) > 0 {
			fmt.Println("\nNext steps:")
			for i, s := range steps {
				if str, ok := s.(string); ok {
					fmt.Printf("  %d. %s\n", i+1, str)
				}
			}
		}
	},
}

var registryCmd = &cobra.Command{
	Use:     "registry",
	Short:   "OCI registry operations",
	GroupID: "admin",
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
			handleToolError(err, "Discover failed")
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
		if err := saveOCICredentials(registry, username, password); err != nil {
			output.Errorf("Failed to save credentials: %v", err)
		}

		fmt.Printf("Login credentials stored for %s\n", registry)
	},
}

// printDependencyInfo displays auto-pulled dependencies and warnings after a pull.
func printDependencyInfo(result map[string]any) {
	if pulled, ok := result["pulled_dependencies"].([]any); ok && len(pulled) > 0 {
		refs := make([]string, 0, len(pulled))
		for _, p := range pulled {
			if s, ok := p.(string); ok {
				refs = append(refs, s)
			}
		}
		if len(refs) > 0 {
			fmt.Printf("\nPulled %d %s: %s\n", len(refs), pluralize("dependency", len(refs)), strings.Join(refs, ", "))
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
			fmt.Fprintf(os.Stderr, "\nWarning: %d optional %s not available: %s\n", len(refs), pluralize("dependency", len(refs)), strings.Join(refs, ", "))
		}
	}
}

// printInspectDependencies displays dependency information when inspecting a component.
// Prefers resolved dependency data (top-level fields from inspect enrichment),
// falls back to raw manifest data for backward compatibility.
func printInspectDependencies(result map[string]any) {
	// Check for resolved dependency fields (enriched inspect response)
	if deps, ok := result["dependencies"]; ok {
		fmt.Println("\nDependency Tree:")
		if tree, ok := deps.([]any); ok {
			printDepTree(tree, "  ")
		}

		if allSat, ok := result["all_satisfied"].(bool); ok {
			if allSat {
				fmt.Println("\nAll required dependencies satisfied.")
			} else {
				fmt.Println("\nMissing required dependencies:")
				if missing, ok := result["missing"].([]any); ok {
					for _, m := range missing {
						if s, ok := m.(string); ok {
							fmt.Printf("  - %s\n", s)
						}
					}
				}
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
				fmt.Fprintf(os.Stderr, "\nOptional dependencies not available: %s\n", strings.Join(refs, ", "))
			}
		}

		if hasDyn, ok := result["has_dynamic"].(bool); ok && hasDyn {
			fmt.Println("\nThis component discovers additional dependencies at runtime.")
		}

		return
	}

	// Fallback: display from raw manifest
	manifest, ok := result["manifest"]
	if !ok {
		return
	}
	mMap, ok := manifest.(map[string]any)
	if !ok {
		return
	}
	deps, ok := mMap["dependencies"]
	if !ok {
		return
	}
	dMap, ok := deps.(map[string]any)
	if !ok {
		return
	}

	if static, ok := dMap["static"].([]any); ok && len(static) > 0 {
		fmt.Println("\nDependencies:")
		for _, dep := range static {
			if d, ok := dep.(map[string]any); ok {
				ref := d["ref"]
				optional := d["optional"]
				reason := d["reason"]
				marker := ""
				if opt, ok := optional.(bool); ok && opt {
					marker = " (optional)"
				}
				line := fmt.Sprintf("  - %v%s", ref, marker)
				if reason != nil && reason != "" {
					line += fmt.Sprintf(" — %v", reason)
				}
				fmt.Println(line)
			}
		}
	}

	if dynamic, ok := dMap["dynamic"].(map[string]any); ok {
		if desc, ok := dynamic["description"].(string); ok {
			fmt.Printf("\nDynamic: %s\n", desc)
		}
	}
}

// printDepTree recursively prints a dependency tree with indentation.
func printDepTree(nodes []any, indent string) {
	for _, node := range nodes {
		if n, ok := node.(map[string]any); ok {
			ref := n["dependency_ref"]
			marker := ""
			if opt, ok := n["optional"]; ok {
				// optional may be int (0/1) or bool
				switch v := opt.(type) {
				case bool:
					if v {
						marker = " (optional)"
					}
				case float64:
					if v != 0 {
						marker = " (optional)"
					}
				}
			}
			if cycle, ok := n["cycle"].(bool); ok && cycle {
				marker += " (cycle)"
			}
			fmt.Printf("%s- %v%s\n", indent, ref, marker)
			if children, ok := n["children"].([]any); ok && len(children) > 0 {
				printDepTree(children, indent+"  ")
			}
		}
	}
}

// printResolutionFeedback prints a message to stderr when the server auto-resolved
// a version-less ref to a specific version.
func printResolutionFeedback(result map[string]any, originalInput string) {
	if resolvedFrom, ok := result["resolved_from"].(string); ok && resolvedFrom != "" {
		if resolvedTo, ok := result["resolved_to"].(string); ok && resolvedTo != "" {
			fmt.Fprintf(os.Stderr, "Resolved %s -> %s\n", originalInput, resolvedTo)
		}
	}
}

func pluralize(word string, count int) string {
	if count == 1 {
		return word
	}
	if strings.HasSuffix(word, "y") {
		return word[:len(word)-1] + "ies"
	}
	return word + "s"
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

// resolveAllVersions resolves a component reference for admin operations
// (grants, policies). If a version is present, returns a single-element slice.
// If no version is given, returns a single name-level ref (e.g., "catalyst:local.claude")
// which the server interprets as applying to all versions of the component.
func resolveAllVersions(_ *mcp.Client, s string) []string {
	if strings.Contains(s, "@") {
		s = strings.Replace(s, "@", ":", 1)
	}

	parsed := ref.ParseRef(s)
	if parsed.HasVersion {
		return []string{s}
	}

	// Pass name-level ref directly to the server.
	// The server's normalize_or_name_ref handles this correctly,
	// applying grants/policies to all versions of the component.
	return []string{parsed.NameRef()}
}

// resolveComponentRef normalizes a component reference and, when the version
// is missing, either auto-resolves (non-interactive) or prompts the user.
//
// If the ref already contains an explicit version, it is returned after
// basic normalization (@ → :). If the version is omitted:
//   - Non-interactive mode: passes the version-less ref through to the server
//     for auto-resolution (the server resolves to latest)
//   - Interactive mode: fetches installed versions and asks for confirmation
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
		// Non-interactive: pass through to server for auto-resolution.
		// The server-side Compendium.Resolver will resolve to latest version.
		return s
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
