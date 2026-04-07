package prompt

import (
	"fmt"
	"sort"
	"strings"

	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/ref"
)

// FetchComponents calls component list and returns options for selection.
// Each option's value is the full component_ref (e.g. "catalyst:local.claude:0.1.0").
// Uses the "list" action which runs locally and is fast, rather than "search"
// which may hit the remote registry.
func FetchComponents(client *mcp.Client) ([]Option, error) {
	result, err := client.CallTool("component", map[string]any{
		"action": "list",
	})
	if err != nil {
		return nil, fmt.Errorf("fetch components: %w", err)
	}
	return extractComponents(result)
}

// FetchLocalComponents calls component list and returns options for selection.
// Uses the "list" action which is a fast local-only operation.
func FetchLocalComponents(client *mcp.Client) ([]Option, error) {
	result, err := client.CallTool("component", map[string]any{
		"action": "list",
	})
	if err != nil {
		return nil, fmt.Errorf("fetch local components: %w", err)
	}
	return extractComponents(result)
}

// FetchLocalComponentsLatest calls component list and deduplicates results
// by base ref (type:namespace.name), keeping only the highest version per
// component. The label shows the base ref for a clean picker, but the value
// is the full versioned ref (needed for manifest lookup).
func FetchLocalComponentsLatest(client *mcp.Client) ([]Option, error) {
	result, err := client.CallTool("component", map[string]any{
		"action": "list",
	})
	if err != nil {
		return nil, fmt.Errorf("fetch local components: %w", err)
	}
	return extractComponentsLatest(result)
}

// extractComponentsLatest builds options deduped by base ref.
// For each unique type:namespace.name, keeps the highest version.
// The label is the base ref, the value is the full versioned ref.
func extractComponentsLatest(result map[string]any) ([]Option, error) {
	raw, ok := result["components"]
	if !ok {
		return nil, nil
	}
	items, ok := raw.([]any)
	if !ok {
		return nil, fmt.Errorf("unexpected type for components: expected array")
	}

	type entry struct {
		baseRef    string
		versionRef string
		version    string
	}
	best := make(map[string]entry)
	for _, item := range items {
		m, ok := item.(map[string]any)
		if !ok {
			continue
		}
		r, _ := m["component_ref"].(string)
		if r == "" {
			continue
		}
		v, _ := m["version"].(string)
		baseRef := StripVersion(r)
		if prev, exists := best[baseRef]; !exists || ref.CompareVersions(v, prev.version) > 0 {
			best[baseRef] = entry{baseRef: baseRef, versionRef: r, version: v}
		}
	}

	var opts []Option
	for _, e := range best {
		opts = append(opts, Option{Label: e.baseRef, Value: e.versionRef})
	}
	sort.Slice(opts, func(i, j int) bool { return opts[i].Label < opts[j].Label })
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
	sort.Slice(versions, func(i, j int) bool {
		return ref.CompareVersions(versions[i], versions[j]) > 0
	})
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
		"action":        "list_component_grants",
		"component_ref": componentRef,
	})
	if err != nil {
		return nil, fmt.Errorf("fetch granted secrets: %w", err)
	}
	secrets, ok := result["granted_secrets"]
	if !ok {
		return nil, nil
	}
	arr, ok := secrets.([]any)
	if !ok {
		return nil, nil
	}
	names := make([]string, 0, len(arr))
	for _, v := range arr {
		if s, ok := v.(string); ok {
			names = append(names, s)
		}
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

// FetchGuides calls aqua list and returns options for selection.
func FetchGuides(client *mcp.Client) ([]Option, error) {
	result, err := client.CallTool("aqua", map[string]any{
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
