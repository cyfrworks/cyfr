package cmd

import (
	"strings"
	"testing"
)

func TestParseReference_LocalRef_ReturnsRegistry(t *testing.T) {
	tests := []struct {
		input    string
		compType string
		want     string
	}{
		{"c:local.claude:0.1.0", "", "c:local.claude:0.1.0"},
		{"c:local.claude", "", "c:local.claude"},
		{"local.claude:0.1.0", "catalyst", "catalyst:local.claude:0.1.0"},
		{"local.claude", "catalyst", "catalyst:local.claude"},
	}
	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			result, err := parseReference(tt.input, tt.compType)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if result != tt.want {
				t.Errorf("got %q, want %q", result, tt.want)
			}
		})
	}
}

func TestParseReference_DirectWasm_RejectsLocalFile(t *testing.T) {
	_, err := parseReference("./components/catalysts/local/claude/0.1.0/catalyst.wasm", "catalyst")
	if err == nil {
		t.Fatal("expected an error for a local file path")
	}
	if !strings.Contains(err.Error(), "Local file execution is no longer supported") {
		t.Errorf("expected 'Local file execution is no longer supported' in error, got: %v", err)
	}
}

func TestParseReference_RegistryRefWithTypeInjected(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"cyfr.sentiment:1.0.0", "catalyst:cyfr.sentiment:1.0.0"},
		{"acme.stripe:2.0.0", "catalyst:acme.stripe:2.0.0"},
	}
	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			result, err := parseReference(tt.input, "catalyst")
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if result != tt.want {
				t.Errorf("got %q, want %q", result, tt.want)
			}
		})
	}
}

// The following tests verify error paths. parseReference now returns the
// error instead of exiting, so they assert on it directly.

func TestParseReference_DirectWasm_OutsideProject(t *testing.T) {
	_, err := parseReference("/some/outside/path/outside.wasm", "catalyst")
	if err == nil {
		t.Fatal("expected an error for a local file path")
	}
	if !strings.Contains(err.Error(), "Local file execution is no longer supported") {
		t.Errorf("expected 'Local file execution is no longer supported' in error, got: %v", err)
	}
}

func TestParseReference_DirectWasm_Nonexistent(t *testing.T) {
	_, err := parseReference("./nonexistent.wasm", "catalyst")
	if err == nil {
		t.Fatal("expected an error for a local file path")
	}
	if !strings.Contains(err.Error(), "Local file execution is no longer supported") {
		t.Errorf("expected 'Local file execution is no longer supported' in error, got: %v", err)
	}
}

func TestJoinTypeShorthand(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want []string
	}{
		{"shorthand c", []string{"c", "local.claude:0.1.0"}, []string{"c:local.claude:0.1.0"}},
		{"shorthand r", []string{"r", "local.parser:1.0.0"}, []string{"r:local.parser:1.0.0"}},
		{"no shorthand", []string{"local.claude:0.1.0"}, []string{"local.claude:0.1.0"}},
		{"non-type first arg", []string{"local", "claude:0.1.0"}, []string{"local", "claude:0.1.0"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := joinTypeShorthand(tt.args)
			if len(got) != len(tt.want) {
				t.Fatalf("got %v, want %v", got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("arg[%d]: got %q, want %q", i, got[i], tt.want[i])
				}
			}
		})
	}
}

// TestParseReference_AtSignPassthrough asserts the wire-format guarantee:
// parseReference does not rewrite '@' to ':'. The '@' flows through to
// ref.ParseRef + Validate which reject it (personal slugs are bare).
func TestParseReference_AtSignPassthrough(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		compType string
		want     string
	}{
		{
			name:  "personal slug with @ prefix passes through unchanged",
			input: "c:@alice.foo:0.1.0",
			want:  "c:@alice.foo:0.1.0",
		},
		{
			name:  "@ in name passes through unchanged",
			input: "c:local.supabase@0.1.0",
			want:  "c:local.supabase@0.1.0",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := parseReference(tt.input, tt.compType)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if result != tt.want {
				t.Errorf("parseReference(%q) = %q, want %q ('@' must NOT be rewritten — personal slugs are bare, '@' is reserved for digest refs)", tt.input, result, tt.want)
			}
		})
	}
}

func TestParseReference_TypeInjection(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		compType string
		want     string
	}{
		{
			name:     "untyped ref with compType flag injects type",
			input:    "local.openai",
			compType: "catalyst",
			want:     "catalyst:local.openai",
		},
		{
			name:     "untyped ref with version and compType flag",
			input:    "local.openai:0.1.0",
			compType: "catalyst",
			want:     "catalyst:local.openai:0.1.0",
		},
		{
			name:     "typed ref with conflicting compType - ref wins",
			input:    "catalyst:local.openai:0.1.0",
			compType: "reagent",
			want:     "catalyst:local.openai:0.1.0",
		},
		{
			name:     "typed ref with empty compType",
			input:    "catalyst:local.openai:0.1.0",
			compType: "",
			want:     "catalyst:local.openai:0.1.0",
		},
		{
			name:     "untyped ref with empty compType - no type injected",
			input:    "local.openai",
			compType: "",
			want:     "local.openai",
		},
		{
			name:     "shorthand type in compType flag is passed through",
			input:    "local.openai",
			compType: "c",
			want:     "c:local.openai",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := parseReference(tt.input, tt.compType)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if result != tt.want {
				t.Errorf("got %q, want %q", result, tt.want)
			}
		})
	}
}
