package cmd

import (
	"fmt"
	"os"
	"sort"

	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/output"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/cyfr/codex/internal/ref"
	"github.com/spf13/cobra"
)

var flagNoPropagate bool

func init() {
	registerCmd.Flags().BoolVar(&flagNoPropagate, "no-propagate", false,
		"Skip automatic propagation of secret grants and policies from previous versions")
	rootCmd.AddCommand(registerCmd)
}

var registerCmd = &cobra.Command{
	Use:     "register",
	Short:   "Scan and register all local components",
	GroupID: "component",
	Long:    "Scan the components/ directory for local and agent components and register them in the Compendium registry, making them available for search and registry references.",
	Example: `  cyfr register
  cyfr register --json
  cyfr register --no-propagate`,
	Args: cobra.NoArgs,
	Run: func(cmd *cobra.Command, args []string) {
		client := newClient()
		result, err := client.CallTool("component", map[string]any{
			"action": "register",
		})
		if err != nil {
			output.Errorf("Register failed: %v", err)
		}
		if flagJSON {
			output.JSON(result)
		} else {
			output.KeyValue(result)
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

		// Propagate grants and policies from previous versions to newly registered ones.
		propagateGrantsAndPolicy(client, result, flagNoPropagate)
	},
}

// propagateGrantsAndPolicy copies secret grants and host policies from the
// latest existing version to each newly registered version. This is best-effort:
// registration already succeeded, so errors here are logged as warnings.
func propagateGrantsAndPolicy(client *mcp.Client, result map[string]any, noPropagate bool) {
	if noPropagate {
		return
	}

	raw, ok := result["components"]
	if !ok {
		return
	}
	items, ok := raw.([]any)
	if !ok {
		return
	}

	for _, item := range items {
		comp, ok := item.(map[string]any)
		if !ok {
			continue
		}
		status, _ := comp["status"].(string)
		if status != "registered" {
			continue
		}

		name, _ := comp["name"].(string)
		version, _ := comp["version"].(string)
		compType, _ := comp["component_type"].(string)
		publisher, _ := comp["publisher"].(string)
		if name == "" || version == "" {
			continue
		}

		sourceRef, newRef := findPropagationRefs(client, name, version, compType, publisher)
		if sourceRef == "" {
			continue
		}

		grantsCopied := propagateSecrets(client, sourceRef, newRef)
		policyCopied := propagatePolicy(client, sourceRef, newRef)

		if grantsCopied > 0 || policyCopied {
			fmt.Fprintf(os.Stderr, "\n  Propagated from %s:\n", sourceRef)
			if grantsCopied > 0 {
				fmt.Fprintf(os.Stderr, "    %d secret %s\n", grantsCopied, pluralize("grant", grantsCopied))
			}
			if policyCopied {
				fmt.Fprintf(os.Stderr, "    host policy\n")
			}
			fmt.Fprintf(os.Stderr, "  → %s\n", newRef)
		}
	}
}

// findPropagationRefs searches for the latest previous version of a component
// and returns (sourceRef, newRef). Returns ("", "") if no previous version exists.
func findPropagationRefs(client *mcp.Client, name, newVersion, compType, publisher string) (string, string) {
	expandedType := ref.ExpandType(compType)
	if publisher == "" {
		publisher = "local"
	}

	versions, err := prompt.FetchVersions(client, name, publisher, expandedType)
	if err != nil || len(versions) == 0 {
		return "", ""
	}

	// Sort versions descending so the latest is first.
	sort.Slice(versions, func(i, j int) bool {
		return compareSemver(versions[i], versions[j]) > 0
	})

	// Find the latest version that isn't the newly registered one.
	var sourceVersion string
	for _, v := range versions {
		if v != newVersion {
			sourceVersion = v
			break
		}
	}
	if sourceVersion == "" {
		return "", ""
	}

	// Build refs directly from known parts — no extra search call needed.
	parsed := ref.ParsedRef{
		Type:      expandedType,
		Namespace: publisher,
		Name:      name,
	}
	sourceRef := parsed.WithVersion(sourceVersion)
	newRef := parsed.WithVersion(newVersion)
	return sourceRef, newRef
}

// propagateSecrets copies secret grants from sourceRef to newRef.
// Returns the number of grants copied.
func propagateSecrets(client *mcp.Client, sourceRef, newRef string) int {
	granted, err := prompt.FetchGrantedSecrets(client, sourceRef)
	if err != nil || len(granted) == 0 {
		return 0
	}

	copied := 0
	for _, secretName := range granted {
		_, err := client.CallTool("secret", map[string]any{
			"action":        "grant",
			"component_ref": newRef,
			"name":          secretName,
		})
		if err != nil {
			fmt.Fprintf(os.Stderr, "  Warning: failed to propagate secret grant '%s': %v\n", secretName, err)
			continue
		}
		copied++
	}
	return copied
}

// propagatePolicy copies the host policy from sourceRef to newRef.
// Returns true if a policy was copied.
func propagatePolicy(client *mcp.Client, sourceRef, newRef string) bool {
	policyResult, err := client.CallTool("policy", map[string]any{
		"action":        "get",
		"component_ref": sourceRef,
	})
	if err != nil {
		return false
	}

	policy, ok := policyResult["policy"].(map[string]any)
	if !ok || len(policy) == 0 {
		return false
	}

	// Apply each policy field individually using update_field, which is the
	// same approach used by cyfr setup.
	for field, value := range policy {
		valueStr := marshalPolicyValue(value)
		_, err := client.CallTool("policy", map[string]any{
			"action":        "update_field",
			"component_ref": newRef,
			"field":         field,
			"value":         valueStr,
		})
		if err != nil {
			fmt.Fprintf(os.Stderr, "  Warning: failed to propagate policy field '%s': %v\n", field, err)
		}
	}
	return true
}

// compareSemver compares two semver-like version strings.
// Returns >0 if a > b, <0 if a < b, 0 if equal.
// Handles versions like "0.1.0", "1.0.0", "0.13.2".
func compareSemver(a, b string) int {
	aParts := parseSemverParts(a)
	bParts := parseSemverParts(b)
	for i := 0; i < 3; i++ {
		if aParts[i] != bParts[i] {
			return aParts[i] - bParts[i]
		}
	}
	return 0
}

// parseSemverParts splits a version string into [major, minor, patch].
func parseSemverParts(v string) [3]int {
	var parts [3]int
	idx := 0
	for i := 0; i < len(v) && idx < 3; i++ {
		if v[i] == '.' {
			idx++
			continue
		}
		if v[i] >= '0' && v[i] <= '9' {
			parts[idx] = parts[idx]*10 + int(v[i]-'0')
		}
	}
	return parts
}
