package prompt

import (
	"fmt"
	"strings"

	"github.com/cyfr/codex/internal/mcp"
)

// FetchComponents calls component search and returns options for selection.
// Each option's value is the full component_ref (e.g. "catalyst:local.claude:0.1.0").
func FetchComponents(client *mcp.Client) ([]Option, error) {
	result, err := client.CallTool("component", map[string]any{
		"action": "search",
		"query":  "",
	})
	if err != nil {
		return nil, fmt.Errorf("fetch components: %w", err)
	}
	return extractComponents(result)
}

// FetchLocalComponents calls component search with source=local (skips remote
// registry) and returns options for selection. Use this for interactive pickers
// where the remote roundtrip is not needed.
func FetchLocalComponents(client *mcp.Client) ([]Option, error) {
	result, err := client.CallTool("component", map[string]any{
		"action": "search",
		"query":  "",
		"source": "local",
	})
	if err != nil {
		return nil, fmt.Errorf("fetch local components: %w", err)
	}
	return extractComponents(result)
}

// FetchLocalComponentsLatest calls component search with source=local and
// deduplicates results by base ref (type:namespace.name), keeping only the
// highest version per component. The label shows the base ref for a clean
// picker, but the value is the full versioned ref (needed for manifest lookup).
func FetchLocalComponentsLatest(client *mcp.Client) ([]Option, error) {
	result, err := client.CallTool("component", map[string]any{
		"action": "search",
		"query":  "",
		"source": "local",
	})
	if err != nil {
		return nil, fmt.Errorf("fetch local components: %w", err)
	}
	return extractComponentsLatest(result)
}

// extractComponentsLatest builds options deduped by base ref.
// For each unique type:namespace.name, keeps the first occurrence (search
// results are ordered by version descending). The label is the base ref,
// the value is the full versioned ref.
func extractComponentsLatest(result map[string]any) ([]Option, error) {
	raw, ok := result["components"]
	if !ok {
		return nil, nil
	}
	items, ok := raw.([]any)
	if !ok {
		return nil, fmt.Errorf("unexpected type for components: expected array")
	}

	seen := make(map[string]bool)
	var opts []Option
	for _, item := range items {
		m, ok := item.(map[string]any)
		if !ok {
			continue
		}
		ref, _ := m["component_ref"].(string)
		if ref == "" {
			continue
		}
		baseRef := StripVersion(ref)
		if seen[baseRef] {
			continue
		}
		seen[baseRef] = true
		opts = append(opts, Option{Label: baseRef, Value: ref})
	}
	return opts, nil
}

// StripVersion removes the version segment from a component ref string.
// "catalyst:local.claude:0.1.0" → "catalyst:local.claude"
// If the ref has no version (already a base ref), returns it unchanged.
func StripVersion(ref string) string {
	// Typed ref: type:rest — find last colon in rest
	firstColon := strings.IndexByte(ref, ':')
	if firstColon < 0 {
		return ref
	}
	rest := ref[firstColon+1:]
	// rest is either "namespace.name:version" or "namespace.name"
	lastColon := strings.LastIndexByte(rest, ':')
	if lastColon < 0 {
		return ref // already a base ref
	}
	// Check if the part after the last colon looks like a version (starts with digit)
	candidate := rest[lastColon+1:]
	if len(candidate) > 0 && candidate[0] >= '0' && candidate[0] <= '9' {
		return ref[:firstColon+1+lastColon]
	}
	return ref
}

// extractComponents builds options from the component search response.
// Each component has "component_ref", "name", "component_type", "version".
func extractComponents(result map[string]any) ([]Option, error) {
	raw, ok := result["components"]
	if !ok {
		return nil, nil
	}
	items, ok := raw.([]any)
	if !ok {
		return nil, fmt.Errorf("unexpected type for components: expected array")
	}

	var opts []Option
	for _, item := range items {
		m, ok := item.(map[string]any)
		if !ok {
			continue
		}
		ref, _ := m["component_ref"].(string)
		name, _ := m["name"].(string)
		version, _ := m["version"].(string)
		if ref == "" {
			continue
		}
		label := name
		if version != "" {
			label = fmt.Sprintf("%s:%s", name, version)
		}
		opts = append(opts, Option{Label: label, Value: ref})
	}
	return opts, nil
}

// FetchVersions queries available versions of a component by name and optional
// namespace/type. It calls the component search tool and filters results to
// exact name (and optionally namespace) matches, returning a slice of version
// strings.
func FetchVersions(client *mcp.Client, name, namespace, componentType string) ([]string, error) {
	args := map[string]any{
		"action": "search",
		"query":  name,
	}
	if componentType != "" {
		args["type"] = componentType
	}

	result, err := client.CallTool("component", args)
	if err != nil {
		return nil, fmt.Errorf("fetch versions: %w", err)
	}

	raw, ok := result["components"]
	if !ok {
		return nil, nil
	}
	items, ok := raw.([]any)
	if !ok {
		return nil, nil
	}

	var versions []string
	for _, item := range items {
		m, ok := item.(map[string]any)
		if !ok {
			continue
		}
		n, _ := m["name"].(string)
		if n != name {
			continue
		}
		if namespace != "" {
			pub, _ := m["publisher"].(string)
			if pub != namespace {
				continue
			}
		}
		v, _ := m["version"].(string)
		if v != "" {
			versions = append(versions, v)
		}
	}
	return versions, nil
}

// FetchSecrets calls secret list and returns options for selection.
func FetchSecrets(client *mcp.Client) ([]Option, error) {
	result, err := client.CallTool("secret", map[string]any{
		"action": "list",
	})
	if err != nil {
		return nil, fmt.Errorf("fetch secrets: %w", err)
	}
	return extractOptions(result, "secrets", "name", "name")
}

// FetchGrantedSecrets returns the names of secrets already granted to a component.
func FetchGrantedSecrets(client *mcp.Client, componentRef string) ([]string, error) {
	result, err := client.CallTool("secret", map[string]any{
		"action":        "resolve_granted",
		"component_ref": componentRef,
	})
	if err != nil {
		return nil, fmt.Errorf("fetch granted secrets: %w", err)
	}
	secrets, ok := result["secrets"]
	if !ok {
		return nil, nil
	}
	// resolve_granted returns secrets as a map of name -> value
	m, ok := secrets.(map[string]any)
	if !ok {
		return nil, nil
	}
	names := make([]string, 0, len(m))
	for name := range m {
		names = append(names, name)
	}
	return names, nil
}

// FetchKeys calls key list and returns options for selection.
func FetchKeys(client *mcp.Client) ([]Option, error) {
	result, err := client.CallTool("key", map[string]any{
		"action": "list",
	})
	if err != nil {
		return nil, fmt.Errorf("fetch keys: %w", err)
	}
	return extractOptions(result, "keys", "name", "name")
}

// FetchPermissionSubjects calls permission list and returns options for selection.
func FetchPermissionSubjects(client *mcp.Client) ([]Option, error) {
	result, err := client.CallTool("permission", map[string]any{
		"action": "list",
	})
	if err != nil {
		return nil, fmt.Errorf("fetch permissions: %w", err)
	}
	return extractOptions(result, "permissions", "subject", "subject")
}

// FetchPolicies calls policy list and returns options for selection.
func FetchPolicies(client *mcp.Client) ([]Option, error) {
	result, err := client.CallTool("policy", map[string]any{
		"action": "list",
	})
	if err != nil {
		return nil, fmt.Errorf("fetch policies: %w", err)
	}
	return extractOptions(result, "policies", "component_ref", "component_ref")
}

// FetchGuides calls guide list and returns options for selection.
func FetchGuides(client *mcp.Client) ([]Option, error) {
	result, err := client.CallTool("guide", map[string]any{
		"action": "list",
	})
	if err != nil {
		return nil, fmt.Errorf("fetch guides: %w", err)
	}
	return extractOptions(result, "guides", "name", "name")
}

// extractOptions pulls an array from an MCP response map and builds Option slices.
// It looks for result[listKey] as a []any of map[string]any, then extracts
// labelKey and valueKey from each entry.
func extractOptions(result map[string]any, listKey, labelKey, valueKey string) ([]Option, error) {
	raw, ok := result[listKey]
	if !ok {
		// Try the result itself as a flat list — some responses return
		// the list at the top level without a wrapper key.
		return extractOptionsFlat(result, labelKey, valueKey)
	}

	items, ok := raw.([]any)
	if !ok {
		return nil, fmt.Errorf("unexpected type for %q: expected array", listKey)
	}

	var opts []Option
	for _, item := range items {
		switch v := item.(type) {
		case string:
			// Flat string array (e.g. secrets: ["KEY1", "KEY2"])
			opts = append(opts, Option{Label: v, Value: v})
		case map[string]any:
			label := fmt.Sprintf("%v", v[labelKey])
			value := fmt.Sprintf("%v", v[valueKey])
			if label == "<nil>" || value == "<nil>" {
				continue
			}
			opts = append(opts, Option{Label: label, Value: value})
		}
	}
	return opts, nil
}

// extractOptionsFlat handles the case where the result map itself contains
// the data rather than a nested array.
func extractOptionsFlat(result map[string]any, labelKey, valueKey string) ([]Option, error) {
	// If the result has a single array value, try to use that
	for _, v := range result {
		if items, ok := v.([]any); ok {
			var opts []Option
			for _, item := range items {
				m, ok := item.(map[string]any)
				if !ok {
					continue
				}
				label := fmt.Sprintf("%v", m[labelKey])
				value := fmt.Sprintf("%v", m[valueKey])
				if label == "<nil>" || value == "<nil>" {
					continue
				}
				opts = append(opts, Option{Label: label, Value: value})
			}
			if len(opts) > 0 {
				return opts, nil
			}
		}
	}
	return nil, nil
}
