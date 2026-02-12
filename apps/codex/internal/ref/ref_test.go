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
	input := "cyfr.sentiment:1.0.0"
	parsed, err := Parse(input)
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}
	if got := parsed.String(); got != input {
		t.Errorf("String() = %q, want %q", got, input)
	}
}

func TestNormalize(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"cyfr.sentiment:1.0.0", "cyfr.sentiment:1.0.0"},
		{"sentiment:1.0.0", "local.sentiment:1.0.0"},
		{"sentiment", "local.sentiment:latest"},
		{"local:tool:2.0.0", "local.tool:2.0.0"},
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

func TestNormalize_Error(t *testing.T) {
	_, err := Normalize("")
	if err == nil {
		t.Fatal("expected error for empty string")
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
