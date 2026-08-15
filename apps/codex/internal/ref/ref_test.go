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
	if !IsTypePrefix("tincture") {
		t.Error("expected tincture to be a type prefix")
	}
	if !IsTypePrefix("t") {
		t.Error("expected t to be a type prefix")
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
		{"t", "tincture"},
		{"catalyst", "catalyst"},
		{"reagent", "reagent"},
		{"formula", "formula"},
		{"tincture", "tincture"},
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
			// Post auth-refactor: '@' is NOT normalized. ParseRef is a pure
			// shape extractor; Validate() is what rejects '@' (see the
			// TestValidate_RejectsAt test). The last-dot split here sees no
			// explicit version colon, so it takes the final '.' (between
			// "supabase@0.1" and "0") as the namespace/name boundary. That's
			// nonsense, but it's the correct last-dot behavior given a
			// malformed input — Validate catches it before anything uses it.
			// Pre-refactor this test asserted normalization to ':' which
			// masked invalid user input entirely.
			input: "c:local.supabase@0.1.0",
			want:  ParsedRef{Type: "c", Namespace: "local.supabase@0.1", Name: "0"},
		},
		{
			// Publisher namespace (multi-dot) — last-dot split yields
			// namespace="stripe.com", name="api".
			input: "c:stripe.com.api:0.1.0",
			want:  ParsedRef{Type: "c", Namespace: "stripe.com", Name: "api", Version: "0.1.0", HasVersion: true},
		},
		{
			// Multi-label publisher — last-dot split yields
			// namespace="api.stripe.com", name="widget".
			input: "c:api.stripe.com.widget:1.0.0",
			want:  ParsedRef{Type: "c", Namespace: "api.stripe.com", Name: "widget", Version: "1.0.0", HasVersion: true},
		},
		{
			// Version with pre-release tag — last-colon split preserves
			// the ":0.1.0-beta.1" intact.
			input: "c:stripe.com.api:0.1.0-beta.1",
			want:  ParsedRef{Type: "c", Namespace: "stripe.com", Name: "api", Version: "0.1.0-beta.1", HasVersion: true},
		},
		{
			// Personal bare slug.
			input: "c:alice.foo:0.1.0",
			want:  ParsedRef{Type: "c", Namespace: "alice", Name: "foo", Version: "0.1.0", HasVersion: true},
		},
		{
			input: "  c:local.claude:0.1.0  ",
			want:  ParsedRef{Type: "c", Namespace: "local", Name: "claude", Version: "0.1.0", HasVersion: true},
		},
		{
			input: "t:local.dash:0.1.0",
			want:  ParsedRef{Type: "t", Namespace: "local", Name: "dash", Version: "0.1.0", HasVersion: true},
		},
		{
			input: "tincture:local.dash",
			want:  ParsedRef{Type: "tincture", Namespace: "local", Name: "dash"},
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

func TestCompareVersions(t *testing.T) {
	tests := []struct {
		a, b string
		want int
	}{
		{"0.3.3", "0.3.2", 1},
		{"0.3.2", "0.3.3", -1},
		{"0.3.3", "0.3.3", 0},
		{"1.0.0", "0.9.9", 1},
		{"0.10.0", "0.9.0", 1},
		{"1.0.0", "1.0", 1},
		{"1.0", "1.0.0", -1},
	}
	for _, tt := range tests {
		got := CompareVersions(tt.a, tt.b)
		if got != tt.want {
			t.Errorf("CompareVersions(%q, %q) = %d, want %d", tt.a, tt.b, got, tt.want)
		}
	}
}

func TestValidate_Personal(t *testing.T) {
	ok := []string{"alice", "alice-bob", "alice-123-bob", "a", "0"}
	for _, s := range ok {
		if err := ValidateNamespace(s); err != nil {
			t.Errorf("ValidateNamespace(%q) unexpected error: %v", s, err)
		}
	}

	bad := []string{
		"-alice",   // leading hyphen
		"alice-",   // trailing hyphen
		"alice--x", // consecutive hyphens
		"Alice",    // uppercase
		// 40 a's — exceeds 39-char limit
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
	}
	for _, s := range bad {
		if err := ValidateNamespace(s); err == nil {
			t.Errorf("ValidateNamespace(%q) expected error, got nil", s)
		}
	}
}

func TestValidate_Publisher(t *testing.T) {
	ok := []string{"stripe.com", "api.stripe.com", "a.b"}
	for _, s := range ok {
		if err := ValidateNamespace(s); err != nil {
			t.Errorf("ValidateNamespace(%q) unexpected error: %v", s, err)
		}
	}

	bad := []struct {
		input, contains string
	}{
		{".stripe.com", "leading"},
		{"stripe.com.", "trailing"},
		{"stripe..com", "empty"},
		{"stripe.com:8080", "port"},
		{"192.168.1.1", "IP"},
		{"Stripe.com", "RFC 1035"},
	}
	for _, tt := range bad {
		err := ValidateNamespace(tt.input)
		if err == nil {
			t.Errorf("ValidateNamespace(%q) expected error, got nil", tt.input)
			continue
		}
		if !stringContains(err.Error(), tt.contains) {
			t.Errorf("ValidateNamespace(%q) error = %q, want containing %q",
				tt.input, err.Error(), tt.contains)
		}
	}
}

func TestValidate_RejectsAt(t *testing.T) {
	if err := ValidateNamespace("@alice"); err == nil || !stringContains(err.Error(), "@") {
		t.Errorf("ValidateNamespace(\"@alice\") expected @ error, got %v", err)
	}

	// '@' anywhere in the ref surfaces via Validate on the parsed shape.
	p := ParseRef("c:local.supabase@0.1.0")
	if err := Validate(p); err == nil || !stringContains(err.Error(), "@") {
		t.Errorf("Validate on ref with '@' in name — expected @ error, got %v", err)
	}
}

func TestValidateParsedRefs(t *testing.T) {
	// Happy paths
	happy := []string{
		"c:alice.foo:0.1.0",
		"c:stripe.com.api:0.1.0",
		"c:api.stripe.com.widget:1.2.3",
		"c:local.foo:0.1.0",
		"c:stripe.com.api:0.1.0-beta.1",
	}
	for _, s := range happy {
		if err := Validate(ParseRef(s)); err != nil {
			t.Errorf("Validate(ParseRef(%q)) unexpected error: %v", s, err)
		}
	}

	// Rejections — each should produce a non-nil error
	bad := []string{
		"c:@alice.foo:0.1.0",        // '@' banned
		"c:Alice.foo:0.1.0",         // uppercase personal
		"c:stripe..com.foo:0.1.0",   // empty publisher label
		"c:alice.foo:not-a-version", // bad semver
	}
	for _, s := range bad {
		if err := Validate(ParseRef(s)); err == nil {
			t.Errorf("Validate(ParseRef(%q)) expected error, got nil", s)
		}
	}
}

// Local helper because testing doesn't re-export strings.Contains at the
// package boundary and we don't want to import strings just for tests.
func stringContains(haystack, needle string) bool {
	return len(haystack) >= len(needle) && indexOf(haystack, needle) >= 0
}

func indexOf(haystack, needle string) int {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return i
		}
	}
	return -1
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
