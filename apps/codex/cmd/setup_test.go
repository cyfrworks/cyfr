package cmd

import (
	"testing"
)

func TestParseSecretFlags(t *testing.T) {
	tests := []struct {
		name     string
		flags    []string
		expected map[string]string
	}{
		{
			name:     "empty",
			flags:    nil,
			expected: map[string]string{},
		},
		{
			name:     "single secret",
			flags:    []string{"API_KEY=sk-abc123"},
			expected: map[string]string{"API_KEY": "sk-abc123"},
		},
		{
			name:     "multiple secrets",
			flags:    []string{"KEY1=val1", "KEY2=val2"},
			expected: map[string]string{"KEY1": "val1", "KEY2": "val2"},
		},
		{
			name:     "value with equals sign",
			flags:    []string{"URL=https://example.com?key=value"},
			expected: map[string]string{"URL": "https://example.com?key=value"},
		},
		{
			name:     "no equals sign is ignored",
			flags:    []string{"BADFORMAT"},
			expected: map[string]string{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := parseSecretFlags(tt.flags)
			if len(result) != len(tt.expected) {
				t.Fatalf("expected %d entries, got %d", len(tt.expected), len(result))
			}
			for k, v := range tt.expected {
				if result[k] != v {
					t.Errorf("key %s: expected %q, got %q", k, v, result[k])
				}
			}
		})
	}
}

func TestBuildPolicyView(t *testing.T) {
	t.Run("current takes precedence over recommended", func(t *testing.T) {
		current := map[string]any{"timeout": "5m", "allowed_domains": []any{"a.com"}}
		recommended := map[string]any{"timeout": "3m", "allowed_domains": []any{"b.com"}, "rate_limit": map[string]any{"requests": float64(100), "window": "1m"}}
		view := buildPolicyView(current, recommended, nil)
		// timeout and allowed_domains should be "current", rate_limit should be "recommended"
		fieldSource := make(map[string]string)
		for _, v := range view {
			fieldSource[v.field] = v.source
		}
		if fieldSource["timeout"] != "current" {
			t.Errorf("timeout: expected current, got %s", fieldSource["timeout"])
		}
		if fieldSource["allowed_domains"] != "current" {
			t.Errorf("allowed_domains: expected current, got %s", fieldSource["allowed_domains"])
		}
		if fieldSource["rate_limit"] != "recommended" {
			t.Errorf("rate_limit: expected recommended, got %s", fieldSource["rate_limit"])
		}
	})

	t.Run("nil current shows all recommended", func(t *testing.T) {
		recommended := map[string]any{"timeout": "3m", "allowed_domains": []any{"b.com"}}
		view := buildPolicyView(nil, recommended, nil)
		if len(view) != 2 {
			t.Fatalf("expected 2 entries, got %d", len(view))
		}
		for _, v := range view {
			if v.source != "recommended" {
				t.Errorf("%s: expected recommended, got %s", v.field, v.source)
			}
		}
	})

	t.Run("both nil returns empty", func(t *testing.T) {
		view := buildPolicyView(nil, nil, nil)
		if len(view) != 0 {
			t.Errorf("expected empty, got %d entries", len(view))
		}
	})

	t.Run("fields not in either are omitted", func(t *testing.T) {
		current := map[string]any{"timeout": "5m"}
		view := buildPolicyView(current, nil, nil)
		if len(view) != 1 {
			t.Fatalf("expected 1 entry, got %d", len(view))
		}
		if view[0].field != "timeout" {
			t.Errorf("expected timeout, got %s", view[0].field)
		}
	})

	t.Run("configurableFields filters to only specified fields", func(t *testing.T) {
		current := map[string]any{"timeout": "5m", "allowed_domains": []any{"a.com"}, "allowed_paths": []any{"data/"}}
		recommended := map[string]any{"rate_limit": map[string]any{"requests": float64(100), "window": "1m"}}
		configurable := []string{"timeout", "allowed_domains", "rate_limit"}
		view := buildPolicyView(current, recommended, configurable)

		fields := make(map[string]bool)
		for _, v := range view {
			fields[v.field] = true
		}
		// allowed_paths is in current but NOT in configurableFields, so it should be excluded
		if fields["allowed_paths"] {
			t.Error("allowed_paths should be filtered out by configurableFields")
		}
		if !fields["timeout"] {
			t.Error("timeout should be included")
		}
		if !fields["allowed_domains"] {
			t.Error("allowed_domains should be included")
		}
		if !fields["rate_limit"] {
			t.Error("rate_limit should be included from recommended")
		}
	})

	t.Run("configurableFields with no matching data returns empty", func(t *testing.T) {
		configurable := []string{"allowed_tools", "batch_timeout"}
		view := buildPolicyView(nil, nil, configurable)
		if len(view) != 0 {
			t.Errorf("expected empty, got %d entries", len(view))
		}
	})
}

func TestExtractStringListField(t *testing.T) {
	tests := []struct {
		name     string
		plan     map[string]any
		key      string
		expected []string
	}{
		{"extracts string list", map[string]any{"fields": []any{"a", "b", "c"}}, "fields", []string{"a", "b", "c"}},
		{"missing key returns nil", map[string]any{}, "fields", nil},
		{"non-list value returns nil", map[string]any{"fields": "not_a_list"}, "fields", nil},
		{"skips non-string items", map[string]any{"fields": []any{"a", float64(42), "b"}}, "fields", []string{"a", "b"}},
		{"nil plan returns nil", nil, "fields", nil},
		{"empty list returns empty", map[string]any{"fields": []any{}}, "fields", []string{}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := extractStringListField(tt.plan, tt.key)
			if tt.expected == nil {
				if result != nil {
					t.Errorf("expected nil, got %v", result)
				}
				return
			}
			if len(result) != len(tt.expected) {
				t.Fatalf("expected %d items, got %d", len(tt.expected), len(result))
			}
			for i, v := range tt.expected {
				if result[i] != v {
					t.Errorf("index %d: expected %q, got %q", i, v, result[i])
				}
			}
		})
	}
}

func TestFormatPolicyValue(t *testing.T) {
	tests := []struct {
		name     string
		value    any
		expected string
	}{
		{"string", "30s", "30s"},
		{"float", float64(100), "100"},
		{"rate_limit", map[string]any{"requests": float64(100), "window": "1m"}, "100 requests / 1m"},
		{"array", []any{"GET", "POST"}, "[GET, POST]"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := formatPolicyValue(tt.value)
			if result != tt.expected {
				t.Errorf("expected %q, got %q", tt.expected, result)
			}
		})
	}
}
