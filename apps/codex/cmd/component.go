package cmd

import (
	"context"
	"errors"
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
	searchCmd.Flags().BoolVarP(&flagVersions, "versions", "v", false, "Show all available versions")
	rootCmd.AddCommand(searchCmd)
	inspectCmd.Flags().Bool("readme", false, "Include README.md content in output")
	rootCmd.AddCommand(inspectCmd)
	rootCmd.AddCommand(pullCmd)
	pushCmd.Flags().String("registry", "", "OCI registry to push to (e.g., ghcr.io/youruser)")
	rootCmd.AddCommand(pushCmd)
	rootCmd.AddCommand(registryCmd)
	registryCmd.AddCommand(registryDiscoverCmd)
	// Note: `registry login` (interactive username/password prompt) was removed.
	// Push credentials for cyfr.run are now per-user opaque push tokens,
	// provisioned automatically by `cyfr login` (device-flow) via the
	// /v1/identity/probe handoff.
	newCmd.Flags().String("version", "0.1.0", "Component version (semver)")
	newCmd.Flags().String("template", "", "Scaffold template (tincture only: react)")
	rootCmd.AddCommand(newCmd)
	forkCmd.Flags().String("name", "", "New component name (defaults to original)")
	forkCmd.Flags().String("version", "", "New component version (defaults to original)")
	rootCmd.AddCommand(forkCmd)
	deprecateCmd.Flags().String("reason", "", "Human-readable explanation surfaced to pullers (required)")
	_ = deprecateCmd.MarkFlagRequired("reason")
	rootCmd.AddCommand(deprecateCmd)
	yankCmd.Flags().String("reason", "", "Optional explanation surfaced to pullers")
	rootCmd.AddCommand(yankCmd)
}

var searchCmd = &cobra.Command{
	Use:     "search <query>",
	Short:   "Search for components",
	GroupID: "component",
	Long:    "Search the component registry by keyword and return matching references.",
	Example: `  cyfr search sentiment
  cyfr search supabase --versions
  cyfr search "http client" --json`,
	Args: cobra.MinimumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		result, err := client.CallTool(cmd.Context(), "component", map[string]any{
			"action": "search",
			"query":  strings.Join(args, " "),
		})
		if err != nil {
			return handleToolError(err, "Search failed")
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}

		components, ok := result["components"].([]any)
		if !ok || len(components) == 0 {
			fmt.Println("No components found.")
			return nil
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
				// The server returns the owning slug in `namespace_slug`.
				publisher := strVal(comp, "namespace_slug")
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

		// Show all available versions per component when --versions flag is set
		if flagVersions {
			fmt.Println()
			for _, c := range components {
				comp, ok := c.(map[string]any)
				if !ok {
					continue
				}
				name := strVal(comp, "name")
				// See the namespace_slug comment above — same rationale.
				publisher := strVal(comp, "namespace_slug")
				if publisher == "" {
					publisher = strVal(comp, "publisher")
				}
				remoteVersions, _ := comp["remote_versions"].([]any)
				if len(remoteVersions) > 1 {
					label := name
					if publisher != "" {
						label = publisher + "." + name
					}
					fmt.Printf("  %s versions: ", label)
					for i, v := range remoteVersions {
						if i > 0 {
							fmt.Print(", ")
						}
						fmt.Print(v)
					}
					fmt.Println()
				}
			}
		}

		// Show incomplete warning if remote search failed
		if note, ok := result["note"].(string); ok && note != "" {
			fmt.Fprintf(os.Stderr, "\nWarning: %s\n", note)
		}
		return nil
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
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		var normalized string
		var originalInput string

		switch {
		case len(args) >= 1:
			args = joinTypeShorthand(args)
			originalInput = args[0]
			var err error
			normalized, err = resolveComponentRef(cmd.Context(), client, args[0])
			if err != nil {
				return err
			}
		case prompt.IsInteractive(flagNoInteractive):
			opts, err := prompt.FetchComponents(cmd.Context(), client)
			if err != nil {
				return handleToolError(err)
			}
			if len(opts) == 0 {
				return errors.New("No components found. Register one first.")
			}
			selected, err := prompt.SelectOne("Select a component to inspect", opts)
			if err != nil {
				if prompt.IsAborted(err) {
					os.Exit(130)
				}
				return fmt.Errorf("Prompt failed: %v", err)
			}
			normalized = selected
		default:
			return errors.New("Usage: cyfr inspect <reference>")
		}

		callArgs := map[string]any{
			"action":    "inspect",
			"reference": normalized,
		}
		if includeReadme, _ := cmd.Flags().GetBool("readme"); includeReadme {
			callArgs["include_readme"] = true
		}
		result, err := client.CallTool(cmd.Context(), "component", callArgs)
		if err != nil {
			return handleToolError(err, "Inspect failed")
		}
		printResolutionFeedback(result, originalInput)
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
			printInspectDependencies(result)
			if readme, ok := result["readme"].(string); ok && readme != "" {
				fmt.Println("\n--- README ---")
				fmt.Println(readme)
			}
		}
		return nil
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
	RunE: func(cmd *cobra.Command, args []string) error {
		args = joinTypeShorthand(args)
		client := newClient()
		originalInput := args[0]
		normalized, err := resolveComponentRef(cmd.Context(), client, args[0])
		if err != nil {
			return err
		}
		progressID := randomHex(8)

		result, err := client.CallToolWithProgress(cmd.Context(), "component", map[string]any{
			"action":      "pull",
			"reference":   normalized,
			"progress_id": progressID,
		}, progressPrinter())
		if err != nil {
			return handleToolError(err, "Pull failed")
		}
		printResolutionFeedback(result, originalInput)
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
			printDependencyInfo(result)
		}
		return nil
	},
}

var pushCmd = &cobra.Command{
	Use:     "push [type] <reference>",
	Short:   "Sign and push component to the registry",
	GroupID: "component",
	Long: `Sign a local component and push it to the registry.
Defaults to registry.cyfr.run. Use --registry to push to a different OCI-compatible registry.`,
	Example: `  cyfr push c:local.claude:0.2.0
  cyfr push r:local.sentiment:1.0.0 --registry ghcr.io/youruser`,
	Args: cobra.RangeArgs(1, 2),
	RunE: func(cmd *cobra.Command, args []string) error {
		args = joinTypeShorthand(args)
		client := newClient()
		normalized, err := resolveComponentRef(cmd.Context(), client, args[0])
		if err != nil {
			return err
		}

		if !ref.ParseRef(normalized).HasVersion {
			return errors.New("Pushing requires an explicit version (e.g., c:local.claude:0.1.0)")
		}

		progressID := randomHex(8)

		toolArgs := map[string]any{
			"action":      "push",
			"reference":   normalized,
			"progress_id": progressID,
		}
		if registry, _ := cmd.Flags().GetString("registry"); registry != "" {
			toolArgs["registry"] = registry
		}
		result, err := client.CallToolWithProgress(cmd.Context(), "component", toolArgs, progressPrinter())
		if err != nil {
			return handleToolError(err, "Push failed")
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
		return nil
	},
}

var newCmd = &cobra.Command{
	Use:     "new <type> <name>",
	Short:   "Scaffold a new component",
	GroupID: "component",
	Long: `Create a new component project with the appropriate scaffold.

WASM types (catalyst, reagent, formula) get Cargo/WIT scaffolding and starter Rust source.
Tinctures get HTML/JS/CSS scaffolding. Use --template react for a React + TypeScript + Vite project.`,
	Example: `  cyfr new catalyst my-api
  cyfr new formula my-workflow --version 0.2.0
  cyfr new reagent my-transform
  cyfr new tincture my-dashboard
  cyfr new tincture my-dashboard --template react`,
	Args: cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		componentType := ref.ExpandType(args[0])
		name := args[1]
		version, _ := cmd.Flags().GetString("version")
		template, _ := cmd.Flags().GetString("template")

		toolArgs := map[string]any{
			"action":  "create",
			"type":    componentType,
			"name":    name,
			"version": version,
		}
		if template != "" {
			toolArgs["template"] = template
		}

		client := newClient()
		result, err := client.CallTool(cmd.Context(), "component", toolArgs)
		if err != nil {
			return handleToolError(err, "Scaffold failed")
		}
		if flagJSON {
			output.JSON(result)
			return nil
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
		return nil
	},
}

var forkCmd = &cobra.Command{
	Use:     "fork [type] <reference>",
	Short:   "Fork a component to local namespace",
	GroupID: "component",
	Long: `Fork a published component into your local namespace for editing.

Copies source code, manifest, and compiled artifact. Requires source code
(src/ directory) to be present — pull with source included first.`,
	Example: `  cyfr fork c:acme.my-tool:1.0.0
  cyfr fork r:cyfr.sentiment:1.0.0 --name my-sentiment
  cyfr fork c:acme.my-tool:1.0.0 --version 0.1.0`,
	Args: cobra.RangeArgs(1, 2),
	RunE: func(cmd *cobra.Command, args []string) error {
		args = joinTypeShorthand(args)
		client := newClient()
		normalized, err := resolveComponentRef(cmd.Context(), client, args[0])
		if err != nil {
			return err
		}

		toolArgs := map[string]any{
			"action":    "fork",
			"reference": normalized,
		}
		if name, _ := cmd.Flags().GetString("name"); name != "" {
			toolArgs["name"] = name
		}
		if version, _ := cmd.Flags().GetString("version"); version != "" {
			toolArgs["version"] = version
		}

		result, err := client.CallTool(cmd.Context(), "component", toolArgs)
		if err != nil {
			return handleToolError(err, "Fork failed")
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}

		reference := strVal(result, "reference")
		forkedFrom := strVal(result, "forked_from")
		fmt.Printf("Forked %s → %s\n", forkedFrom, reference)

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
		return nil
	},
}

var deprecateCmd = &cobra.Command{
	Use:     "deprecate <reference>",
	Short:   "Mark a component version deprecated",
	GroupID: "component",
	Long: `Mark a component version as deprecated on the registry.

Pinned pulls still succeed with a warning header; non-pinned resolution
demotes deprecated versions behind active ones. Requires --reason
(surfaced to pullers).

Must pass a fully-qualified ref including version. You must hold a push
token for the component's namespace (i.e. you are the publisher).`,
	Example: `  cyfr deprecate c:alice.widget:1.0.0 --reason "use v2 — better schemas"
  cyfr deprecate r:acme.com.http:2.0.0 --reason "security fix in 2.1.0"`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		normalized, err := resolveComponentRef(cmd.Context(), client, args[0])
		if err != nil {
			return err
		}
		if !ref.ParseRef(normalized).HasVersion {
			return errors.New("Deprecate requires a pinned version (e.g., c:alice.widget:1.0.0)")
		}
		reason, _ := cmd.Flags().GetString("reason")

		result, err := client.CallTool(cmd.Context(), "component", map[string]any{
			"action":    "deprecate",
			"reference": normalized,
			"reason":    reason,
		})
		if err != nil {
			return handleToolError(err, "Deprecate failed")
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		fmt.Printf("Deprecated %s\n  reason: %s\n", normalized, reason)
		return nil
	},
}

var yankCmd = &cobra.Command{
	Use:     "yank <reference>",
	Short:   "Mark a component version yanked",
	GroupID: "component",
	Long: `Mark a component version as yanked on the registry.

Stronger signal than deprecate: yanked versions are excluded from search
and non-pinned resolution. Pinned pulls still succeed (reproducibility).
Reason is optional.

Must pass a fully-qualified ref including version. You must hold a push
token for the component's namespace.`,
	Example: `  cyfr yank c:alice.widget:1.0.0
  cyfr yank r:acme.com.http:2.0.0 --reason "accidental push"`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		normalized, err := resolveComponentRef(cmd.Context(), client, args[0])
		if err != nil {
			return err
		}
		if !ref.ParseRef(normalized).HasVersion {
			return errors.New("Yank requires a pinned version (e.g., c:alice.widget:1.0.0)")
		}
		reason, _ := cmd.Flags().GetString("reason")

		result, err := client.CallTool(cmd.Context(), "component", map[string]any{
			"action":    "yank",
			"reference": normalized,
			"reason":    reason,
		})
		if err != nil {
			return handleToolError(err, "Yank failed")
		}
		if flagJSON {
			output.JSON(result)
			return nil
		}
		if reason == "" {
			fmt.Printf("Yanked %s\n", normalized)
		} else {
			fmt.Printf("Yanked %s\n  reason: %s\n", normalized, reason)
		}
		return nil
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
	RunE: func(cmd *cobra.Command, args []string) error {
		client := newClient()
		result, err := client.CallTool(cmd.Context(), "component", map[string]any{
			"action":   "discover",
			"registry": args[0],
		})
		if err != nil {
			return handleToolError(err, "Discover failed")
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
		}
		return nil
	},
}

// `registry login <registry>` removed post auth-refactor. cyfr.run push
// credentials are now per-user opaque push tokens (`cyfr_pt_*`), provisioned
// automatically after `cyfr login` via the device-flow probe handoff.
// Namespace management (publisher claim/verify, tokens, members) lives under
// `cyfr registry ...` subcommands defined in cmd/registry.go.

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

// resolveAllVersions resolves a component reference for admin operations
// (grants, policies). If a version is present, returns a single-element slice.
// If no version is given, returns a single name-level ref (e.g., "catalyst:local.claude")
// which the server interprets as applying to all versions of the component.
//
// Refs containing '@' are passed through unchanged — ref.ParseRef + Validate
// reject them (personal slugs are bare; '@' is invalid anywhere in a ref).
func resolveAllVersions(_ *mcp.Client, s string) []string {
	parsed := ref.ParseRef(s)
	if parsed.HasVersion {
		return []string{s}
	}

	// Pass name-level ref directly to the server.
	// The server's normalize_or_name_ref handles this correctly,
	// applying grants/policies to all versions of the component.
	return []string{parsed.NameRef()}
}

// resolveComponentRef resolves a component reference, auto-resolving the
// version when it's missing. If the ref already contains an explicit version,
// returns it as-is. If the version is omitted:
//   - Non-interactive mode: passes the version-less ref through to the server
//     for auto-resolution (the server resolves to latest)
//   - Interactive mode: fetches installed versions and asks for confirmation
//
// Refs containing '@' are passed through unchanged — see resolveAllVersions
// for the rationale.
func resolveComponentRef(ctx context.Context, client *mcp.Client, s string) (string, error) {
	parsed := ref.ParseRef(s)
	if parsed.HasVersion {
		return s, nil
	}

	// Version is missing — resolve it.
	if !prompt.IsInteractive(flagNoInteractive) {
		// Non-interactive: pass through to server for auto-resolution.
		// The server-side Compendium.Resolver will resolve to latest version.
		return s, nil
	}

	componentType := ""
	if parsed.Type != "" {
		componentType = ref.ExpandType(parsed.Type)
	}

	versions, err := prompt.FetchVersions(ctx, client, parsed.Name, parsed.Namespace, componentType)
	if err != nil {
		return "", fmt.Errorf("Failed to fetch versions: %v", err)
	}

	if len(versions) == 0 {
		// No known versions — pass through for server-side resolution (e.g. pull from registry).
		return s, nil
	}

	// Auto-resolve to latest version (versions are sorted descending).
	resolved := parsed.WithVersion(versions[0])
	fmt.Printf("Resolved to latest: %s\n", resolved)
	return resolved, nil
}
