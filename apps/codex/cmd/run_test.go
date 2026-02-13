package cmd

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolveLocalReference_ReturnsRelativePath(t *testing.T) {
	// Set up a temp directory with a component structure.
	tmp := t.TempDir()
	wasmDir := filepath.Join(tmp, "components", "catalysts", "local", "claude", "0.1.0")
	if err := os.MkdirAll(wasmDir, 0o755); err != nil {
		t.Fatal(err)
	}
	wasmFile := filepath.Join(wasmDir, "catalyst.wasm")
	if err := os.WriteFile(wasmFile, []byte("fake"), 0o644); err != nil {
		t.Fatal(err)
	}

	// Change to the temp dir so relative paths resolve correctly.
	origDir, _ := os.Getwd()
	t.Cleanup(func() { os.Chdir(origDir) })
	os.Chdir(tmp)

	result := resolveLocalReference("local.claude:0.1.0", "catalyst")
	if result == nil {
		t.Fatal("expected non-nil result")
	}
	localPath, ok := result["local"].(string)
	if !ok {
		t.Fatalf("expected string local path, got %T", result["local"])
	}

	// Must be relative, not absolute.
	if filepath.IsAbs(localPath) {
		t.Errorf("expected relative path, got absolute: %s", localPath)
	}
	expected := filepath.Join("components", "catalysts", "local", "claude", "0.1.0", "catalyst.wasm")
	if localPath != expected {
		t.Errorf("got %q, want %q", localPath, expected)
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

func TestParseReference_RegistryRefUnchanged(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"cyfr.sentiment:1.0.0", "cyfr.sentiment:1.0.0"},
		{"acme.stripe:2.0.0", "acme.stripe:2.0.0"},
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
