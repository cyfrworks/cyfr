package ref

import (
	"testing"
)

func TestParse(t *testing.T) {
	tests := []struct {
		name      string
		input     string
		want      ComponentRef
		wantErr   bool
		errSubstr string
	}{
		{
			name:  "canonical with version",
			input: "cyfr.sentiment:1.0.0",
			want:  ComponentRef{Namespace: "cyfr", Name: "sentiment", Version: "1.0.0"},
		},
		{
			name:  "canonical no version",
			input: "cyfr.sentiment",
			want:  ComponentRef{Namespace: "cyfr", Name: "sentiment", Version: "latest"},
		},
		{
			name:  "legacy name:version",
			input: "sentiment:1.0.0",
			want:  ComponentRef{Namespace: "local", Name: "sentiment", Version: "1.0.0"},
		},
		{
			name:  "bare name",
			input: "sentiment",
			want:  ComponentRef{Namespace: "local", Name: "sentiment", Version: "latest"},
		},
		{
			name:  "legacy 3-part colon-separated",
			input: "local:sentiment:1.0.0",
			want:  ComponentRef{Namespace: "local", Name: "sentiment", Version: "1.0.0"},
		},
		{
			name:    "empty string",
			input:   "",
			wantErr: true,
		},
		{
			name:  "whitespace trimming",
			input: "  cyfr.sentiment:1.0.0  ",
			want:  ComponentRef{Namespace: "cyfr", Name: "sentiment", Version: "1.0.0"},
		},
		{
			name:      "nothing after dot",
			input:     "a.",
			wantErr:   true,
			errSubstr: "invalid",
		},
		{
			name:      "colon with empty name",
			input:     ":foo",
			wantErr:   true,
			errSubstr: "invalid",
		},
		{
			name:  "namespace with hyphen",
			input: "my-org.my-tool:2.0.0",
			want:  ComponentRef{Namespace: "my-org", Name: "my-tool", Version: "2.0.0"},
		},
		{
			name:  "legacy 3-part with custom namespace",
			input: "acme:stripe:3.0.0",
			want:  ComponentRef{Namespace: "acme", Name: "stripe", Version: "3.0.0"},
		},
		// Typed refs
		{
			name:  "typed catalyst:namespace.name:version",
			input: "catalyst:local.claude:0.1.0",
			want:  ComponentRef{Type: "catalyst", Namespace: "local", Name: "claude", Version: "0.1.0"},
		},
		{
			name:  "typed reagent:namespace.name:version",
			input: "reagent:cyfr.sentiment:1.0.0",
			want:  ComponentRef{Type: "reagent", Namespace: "cyfr", Name: "sentiment", Version: "1.0.0"},
		},
		{
			name:  "typed formula:namespace.name:version",
			input: "formula:local.list-models:0.1.0",
			want:  ComponentRef{Type: "formula", Namespace: "local", Name: "list-models", Version: "0.1.0"},
		},
		{
			name:  "shorthand c: = catalyst",
			input: "c:local.claude:0.1.0",
			want:  ComponentRef{Type: "catalyst", Namespace: "local", Name: "claude", Version: "0.1.0"},
		},
		{
			name:  "shorthand r: = reagent",
			input: "r:local.parser:1.0.0",
			want:  ComponentRef{Type: "reagent", Namespace: "local", Name: "parser", Version: "1.0.0"},
		},
		{
			name:  "shorthand f: = formula",
			input: "f:local.list-models:0.1.0",
			want:  ComponentRef{Type: "formula", Namespace: "local", Name: "list-models", Version: "0.1.0"},
		},
		{
			name:  "typed with legacy name:version remainder",
			input: "catalyst:claude:0.1.0",
			want:  ComponentRef{Type: "catalyst", Namespace: "local", Name: "claude", Version: "0.1.0"},
		},
		{
			name:  "typed with bare name remainder",
			input: "r:parser",
			want:  ComponentRef{Type: "reagent", Namespace: "local", Name: "parser", Version: "latest"},
		},
		{
			name:  "typed whitespace trimming",
			input: "  c:local.claude:0.1.0  ",
			want:  ComponentRef{Type: "catalyst", Namespace: "local", Name: "claude", Version: "0.1.0"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Parse(tt.input)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("expected error, got nil")
				}
				if tt.errSubstr != "" && !containsSubstr(err.Error(), tt.errSubstr) {
					t.Errorf("expected error containing %q, got %q", tt.errSubstr, err.Error())
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tt.want {
				t.Errorf("Parse(%q) = %+v, want %+v", tt.input, got, tt.want)
			}
		})
	}
}

func TestString_RoundTrip(t *testing.T) {
	// Untyped round-trip
	input := "cyfr.sentiment:1.0.0"
	parsed, err := Parse(input)
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}
	if got := parsed.String(); got != input {
		t.Errorf("String() = %q, want %q", got, input)
	}

	// Typed round-trip
	typedInput := "catalyst:local.claude:0.1.0"
	typedParsed, err := Parse(typedInput)
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}
	if got := typedParsed.String(); got != typedInput {
		t.Errorf("String() = %q, want %q", got, typedInput)
	}

	// Shorthand normalizes to full type
	shortInput := "c:local.claude:0.1.0"
	shortParsed, err := Parse(shortInput)
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}
	if got := shortParsed.String(); got != typedInput {
		t.Errorf("String() = %q, want %q (shorthand should expand)", got, typedInput)
	}
}

func TestNormalize(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		// Typed refs — these should succeed
		{"catalyst:local.claude:0.1.0", "catalyst:local.claude:0.1.0"},
		{"c:local.claude:0.1.0", "catalyst:local.claude:0.1.0"},
		{"r:parser:1.0.0", "reagent:local.parser:1.0.0"},
		{"f:list-models", "formula:local.list-models:latest"},
		{"reagent:cyfr.sentiment:1.0.0", "reagent:cyfr.sentiment:1.0.0"},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			got, err := Normalize(tt.input)
			if err != nil {
				t.Fatalf("Normalize(%q) error: %v", tt.input, err)
			}
			if got != tt.want {
				t.Errorf("Normalize(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestNormalize_RejectsUntyped(t *testing.T) {
	untypedInputs := []string{
		"cyfr.sentiment:1.0.0",
		"sentiment:1.0.0",
		"sentiment",
		"local:tool:2.0.0",
	}

	for _, input := range untypedInputs {
		t.Run(input, func(t *testing.T) {
			_, err := Normalize(input)
			if err == nil {
				t.Fatalf("Normalize(%q) should have returned an error for untyped ref", input)
			}
			if !containsSubstr(err.Error(), "type prefix") {
				t.Errorf("error should mention 'type prefix', got: %v", err)
			}
		})
	}
}

func TestNormalize_Error(t *testing.T) {
	_, err := Normalize("")
	if err == nil {
		t.Fatal("expected error for empty string")
	}
}

func TestIsTypePrefix(t *testing.T) {
	// Full names
	if !IsTypePrefix("catalyst") {
		t.Error("expected catalyst to be a type prefix")
	}
	if !IsTypePrefix("reagent") {
		t.Error("expected reagent to be a type prefix")
	}
	if !IsTypePrefix("formula") {
		t.Error("expected formula to be a type prefix")
	}
	// Shorthands
	if !IsTypePrefix("c") {
		t.Error("expected c to be a type prefix")
	}
	if !IsTypePrefix("r") {
		t.Error("expected r to be a type prefix")
	}
	if !IsTypePrefix("f") {
		t.Error("expected f to be a type prefix")
	}
	// Non-types
	if IsTypePrefix("local") {
		t.Error("expected local NOT to be a type prefix")
	}
	if IsTypePrefix("my-tool") {
		t.Error("expected my-tool NOT to be a type prefix")
	}
}

func TestExpandTypeShorthand(t *testing.T) {
	if got := ExpandTypeShorthand("c"); got != "catalyst" {
		t.Errorf("ExpandTypeShorthand(c) = %q, want catalyst", got)
	}
	if got := ExpandTypeShorthand("r"); got != "reagent" {
		t.Errorf("ExpandTypeShorthand(r) = %q, want reagent", got)
	}
	if got := ExpandTypeShorthand("f"); got != "formula" {
		t.Errorf("ExpandTypeShorthand(f) = %q, want formula", got)
	}
	if got := ExpandTypeShorthand("catalyst"); got != "catalyst" {
		t.Errorf("ExpandTypeShorthand(catalyst) = %q, want catalyst", got)
	}
}

func containsSubstr(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
