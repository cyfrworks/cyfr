package ref

import (
	"testing"
)

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

func TestExpandType(t *testing.T) {
	tests := []struct {
		input, want string
	}{
		{"c", "catalyst"},
		{"r", "reagent"},
		{"f", "formula"},
		{"catalyst", "catalyst"},
		{"reagent", "reagent"},
		{"formula", "formula"},
		{"unknown", "unknown"},
	}
	for _, tt := range tests {
		if got := ExpandType(tt.input); got != tt.want {
			t.Errorf("ExpandType(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestParseRef(t *testing.T) {
	tests := []struct {
		input string
		want  ParsedRef
	}{
		{
			input: "c:local.supabase:0.1.0",
			want:  ParsedRef{Type: "c", Namespace: "local", Name: "supabase", Version: "0.1.0", HasVersion: true},
		},
		{
			input: "catalyst:local.claude:0.1.0",
			want:  ParsedRef{Type: "catalyst", Namespace: "local", Name: "claude", Version: "0.1.0", HasVersion: true},
		},
		{
			input: "c:local.supabase",
			want:  ParsedRef{Type: "c", Namespace: "local", Name: "supabase"},
		},
		{
			input: "local.supabase:0.1.0",
			want:  ParsedRef{Namespace: "local", Name: "supabase", Version: "0.1.0", HasVersion: true},
		},
		{
			input: "local.supabase",
			want:  ParsedRef{Namespace: "local", Name: "supabase"},
		},
		{
			input: "supabase:0.1.0",
			want:  ParsedRef{Name: "supabase", Version: "0.1.0", HasVersion: true},
		},
		{
			input: "supabase",
			want:  ParsedRef{Name: "supabase"},
		},
		{
			input: "c:supabase:0.1.0",
			want:  ParsedRef{Type: "c", Name: "supabase", Version: "0.1.0", HasVersion: true},
		},
		{
			input: "c:supabase",
			want:  ParsedRef{Type: "c", Name: "supabase"},
		},
		{
			// @ version separator is normalised to :
			input: "c:local.supabase@0.1.0",
			want:  ParsedRef{Type: "c", Namespace: "local", Name: "supabase", Version: "0.1.0", HasVersion: true},
		},
		{
			input: "  c:local.claude:0.1.0  ",
			want:  ParsedRef{Type: "c", Namespace: "local", Name: "claude", Version: "0.1.0", HasVersion: true},
		},
		{
			input: "",
			want:  ParsedRef{},
		},
	}

	for _, tt := range tests {
		got := ParseRef(tt.input)
		if got != tt.want {
			t.Errorf("ParseRef(%q)\n  got  %+v\n  want %+v", tt.input, got, tt.want)
		}
	}
}

func TestParsedRef_HasTypePrefix(t *testing.T) {
	if !(ParsedRef{Type: "c"}).HasTypePrefix() {
		t.Error("expected HasTypePrefix for type 'c'")
	}
	if (ParsedRef{}).HasTypePrefix() {
		t.Error("expected !HasTypePrefix for empty type")
	}
}

func TestParsedRef_WithVersion(t *testing.T) {
	tests := []struct {
		ref     ParsedRef
		version string
		want    string
	}{
		{
			ref:     ParsedRef{Type: "c", Namespace: "local", Name: "supabase"},
			version: "0.1.0",
			want:    "c:local.supabase:0.1.0",
		},
		{
			ref:     ParsedRef{Namespace: "local", Name: "supabase"},
			version: "0.1.0",
			want:    "local.supabase:0.1.0",
		},
		{
			ref:     ParsedRef{Type: "c", Name: "supabase"},
			version: "0.1.0",
			want:    "c:local.supabase:0.1.0",
		},
		{
			ref:     ParsedRef{Name: "supabase"},
			version: "0.1.0",
			want:    "local.supabase:0.1.0",
		},
	}
	for _, tt := range tests {
		if got := tt.ref.WithVersion(tt.version); got != tt.want {
			t.Errorf("WithVersion(%q) = %q, want %q", tt.version, got, tt.want)
		}
	}
}
