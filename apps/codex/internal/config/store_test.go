package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadFrom_NonexistentReturnsDefault(t *testing.T) {
	cfg, err := LoadFrom("/tmp/cyfr-test-nonexistent/config.json")
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if cfg.CurrentContext != "local" {
		t.Errorf("expected current context 'local', got %q", cfg.CurrentContext)
	}
	ctx := cfg.Contexts["local"]
	if ctx == nil {
		t.Fatal("expected 'local' context to exist")
	}
	if ctx.URL != "http://localhost:4000" {
		t.Errorf("expected URL 'http://localhost:4000', got %q", ctx.URL)
	}
}

func TestSaveToAndLoadFrom_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")

	cfg := &Config{
		CurrentContext: "staging",
		Contexts: map[string]*Context{
			"local":   {URL: "http://localhost:4000"},
			"staging": {URL: "https://staging.example.com"},
		},
	}

	if err := cfg.SaveTo(path); err != nil {
		t.Fatalf("SaveTo failed: %v", err)
	}

	loaded, err := LoadFrom(path)
	if err != nil {
		t.Fatalf("LoadFrom failed: %v", err)
	}

	if loaded.CurrentContext != "staging" {
		t.Errorf("expected current context 'staging', got %q", loaded.CurrentContext)
	}
	if len(loaded.Contexts) != 2 {
		t.Errorf("expected 2 contexts, got %d", len(loaded.Contexts))
	}
	if loaded.Contexts["staging"].URL != "https://staging.example.com" {
		t.Errorf("staging URL mismatch: %q", loaded.Contexts["staging"].URL)
	}
}

func TestCurrentURL_ReturnsContextURL(t *testing.T) {
	cfg := &Config{
		CurrentContext: "prod",
		Contexts: map[string]*Context{
			"prod": {URL: "https://prod.example.com"},
		},
	}
	if got := cfg.CurrentURL(); got != "https://prod.example.com" {
		t.Errorf("expected 'https://prod.example.com', got %q", got)
	}
}

func TestCurrentURL_FallbackDefault(t *testing.T) {
	cfg := &Config{
		CurrentContext: "",
		Contexts:       map[string]*Context{},
	}
	if got := cfg.CurrentURL(); got != "http://localhost:4000" {
		t.Errorf("expected fallback 'http://localhost:4000', got %q", got)
	}
}

func TestCurrent_NilWhenMissing(t *testing.T) {
	cfg := &Config{
		CurrentContext: "nonexistent",
		Contexts:       map[string]*Context{},
	}
	if ctx := cfg.Current(); ctx != nil {
		t.Errorf("expected nil for missing context, got %+v", ctx)
	}
}

func TestSetSessionID_Persists(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")

	cfg := &Config{
		CurrentContext: "local",
		Contexts: map[string]*Context{
			"local": {URL: "http://localhost:4000"},
		},
	}
	if err := cfg.SaveTo(path); err != nil {
		t.Fatalf("SaveTo failed: %v", err)
	}

	// SetSessionID uses Save() which writes to ~/.cyfr, so we test
	// the session assignment + SaveTo manually to avoid touching home dir.
	ctx := cfg.Current()
	ctx.SessionID = "test-session-123"
	if err := cfg.SaveTo(path); err != nil {
		t.Fatalf("SaveTo after session set failed: %v", err)
	}

	loaded, err := LoadFrom(path)
	if err != nil {
		t.Fatalf("LoadFrom failed: %v", err)
	}
	if loaded.Contexts["local"].SessionID != "test-session-123" {
		t.Errorf("expected session ID 'test-session-123', got %q", loaded.Contexts["local"].SessionID)
	}
}

func TestLoadFrom_InvalidJSON(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")

	if err := os.WriteFile(path, []byte("{invalid json"), 0600); err != nil {
		t.Fatalf("failed to write test file: %v", err)
	}

	_, err := LoadFrom(path)
	if err == nil {
		t.Fatal("expected error for invalid JSON")
	}
	if got := err.Error(); !contains(got, "parse config") {
		t.Errorf("expected error containing 'parse config', got %q", got)
	}
}

func TestSaveTo_CreatesParentDir(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "nested", "deep", "config.json")

	cfg := defaultConfig()
	if err := cfg.SaveTo(path); err != nil {
		t.Fatalf("SaveTo should create parent dirs, got: %v", err)
	}

	if _, err := os.Stat(path); err != nil {
		t.Errorf("expected file to exist at %s", path)
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && containsAt(s, substr)
}

func containsAt(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
