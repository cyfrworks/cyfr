package cmd

import (
	"os"
	"os/exec"
	"path/filepath"
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
			result := parseReference(tt.input, tt.compType)
			if result == nil {
				t.Fatal("expected non-nil result")
			}
			reg, ok := result["registry"].(string)
			if !ok {
				t.Fatalf("expected registry key, got %v", result)
			}
			if reg != tt.want {
				t.Errorf("got %q, want %q", reg, tt.want)
			}
		})
	}
}

func TestParseReference_DirectWasm_ReturnsRelativePath(t *testing.T) {
	tmp := t.TempDir()
	wasmDir := filepath.Join(tmp, "components", "catalysts", "local", "claude", "0.1.0")
	if err := os.MkdirAll(wasmDir, 0o755); err != nil {
		t.Fatal(err)
	}
	wasmFile := filepath.Join(wasmDir, "catalyst.wasm")
	if err := os.WriteFile(wasmFile, []byte("fake"), 0o644); err != nil {
		t.Fatal(err)
	}

	origDir, _ := os.Getwd()
	t.Cleanup(func() { os.Chdir(origDir) })
	os.Chdir(tmp)

	result := parseReference("./components/catalysts/local/claude/0.1.0/catalyst.wasm", "catalyst")
	if result == nil {
		t.Fatal("expected non-nil result")
	}
	localPath, ok := result["local"].(string)
	if !ok {
		t.Fatalf("expected string local path, got %T", result["local"])
	}
	if filepath.IsAbs(localPath) {
		t.Errorf("expected relative path, got absolute: %s", localPath)
	}
	expected := filepath.Join("components", "catalysts", "local", "claude", "0.1.0", "catalyst.wasm")
	if localPath != expected {
		t.Errorf("got %q, want %q", localPath, expected)
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
			result := parseReference(tt.input, "catalyst")
			if result == nil {
				t.Fatal("expected non-nil result")
			}
			reg, ok := result["registry"].(string)
			if !ok {
				t.Fatalf("expected registry key, got %v", result)
			}
			if reg != tt.want {
				t.Errorf("got %q, want %q", reg, tt.want)
			}
		})
	}
}

// The following tests verify error paths. Since output.Errorf calls os.Exit(1),
// we test these by re-invoking the test binary as a subprocess.

func TestParseReference_DirectWasm_OutsideProject(t *testing.T) {
	if os.Getenv("TEST_SUBPROCESS") == "1" {
		// Subprocess: create a wasm file outside the working directory.
		outsideDir := os.Getenv("TEST_OUTSIDE_DIR")
		cwd := os.Getenv("TEST_CWD")
		os.Chdir(cwd)
		parseReference(filepath.Join(outsideDir, "outside.wasm"), "catalyst")
		return
	}

	// Create two separate temp dirs: "project" (cwd) and "outside".
	projectDir := t.TempDir()
	outsideDir := t.TempDir()

	wasmFile := filepath.Join(outsideDir, "outside.wasm")
	if err := os.WriteFile(wasmFile, []byte("fake"), 0o644); err != nil {
		t.Fatal(err)
	}

	cmd := exec.Command(os.Args[0], "-test.run=^TestParseReference_DirectWasm_OutsideProject$")
	cmd.Env = append(os.Environ(),
		"TEST_SUBPROCESS=1",
		"TEST_OUTSIDE_DIR="+outsideDir,
		"TEST_CWD="+projectDir,
	)
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatal("expected subprocess to exit with error")
	}
	if !strings.Contains(string(out), "outside the project directory") {
		t.Errorf("expected 'outside the project directory' in output, got: %s", out)
	}
}

func TestParseReference_DirectWasm_Nonexistent(t *testing.T) {
	if os.Getenv("TEST_SUBPROCESS") == "1" {
		parseReference("./nonexistent.wasm", "catalyst")
		return
	}

	cmd := exec.Command(os.Args[0], "-test.run=^TestParseReference_DirectWasm_Nonexistent$")
	cmd.Env = append(os.Environ(), "TEST_SUBPROCESS=1")
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatal("expected subprocess to exit with error")
	}
	if !strings.Contains(string(out), "Component not found") {
		t.Errorf("expected 'Component not found' in output, got: %s", out)
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

func TestParseReference_TypeInjection(t *testing.T) {
	tests := []struct {
		name         string
		input        string
		compType     string
		wantRegistry string
	}{
		{
			name:         "untyped ref with compType flag injects type",
			input:        "local.openai",
			compType:     "catalyst",
			wantRegistry: "catalyst:local.openai",
		},
		{
			name:         "untyped ref with version and compType flag",
			input:        "local.openai:0.1.0",
			compType:     "catalyst",
			wantRegistry: "catalyst:local.openai:0.1.0",
		},
		{
			name:         "typed ref with conflicting compType - ref wins",
			input:        "catalyst:local.openai:0.1.0",
			compType:     "reagent",
			wantRegistry: "catalyst:local.openai:0.1.0",
		},
		{
			name:         "typed ref with empty compType",
			input:        "catalyst:local.openai:0.1.0",
			compType:     "",
			wantRegistry: "catalyst:local.openai:0.1.0",
		},
		{
			name:         "untyped ref with empty compType - no type injected",
			input:        "local.openai",
			compType:     "",
			wantRegistry: "local.openai",
		},
		{
			name:         "shorthand type in compType flag is passed through",
			input:        "local.openai",
			compType:     "c",
			wantRegistry: "c:local.openai",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := parseReference(tt.input, tt.compType)
			if result == nil {
				t.Fatal("expected non-nil result")
			}
			reg, ok := result["registry"].(string)
			if !ok {
				t.Fatalf("expected registry key, got %v", result)
			}
			if reg != tt.wantRegistry {
				t.Errorf("registry: got %q, want %q", reg, tt.wantRegistry)
			}
		})
	}
}
