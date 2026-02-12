package output

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// captureStdout captures stdout output from a function call.
func captureStdout(t *testing.T, fn func()) string {
	t.Helper()

	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("failed to create pipe: %v", err)
	}
	os.Stdout = w

	fn()

	w.Close()
	os.Stdout = old

	buf := make([]byte, 4096)
	n, _ := r.Read(buf)
	r.Close()
	return string(buf[:n])
}

func TestJSON_ValidOutput(t *testing.T) {
	data := map[string]any{"name": "test", "count": 42}

	out := captureStdout(t, func() {
		JSON(data)
	})

	// Should be valid JSON
	var parsed map[string]any
	if err := json.Unmarshal([]byte(strings.TrimSpace(out)), &parsed); err != nil {
		t.Fatalf("output is not valid JSON: %v\noutput: %s", err, out)
	}

	// Should be indented (contains newline + spaces)
	if !strings.Contains(out, "\n") || !strings.Contains(out, "  ") {
		t.Error("expected indented JSON output")
	}

	if parsed["name"] != "test" {
		t.Errorf("expected name 'test', got %v", parsed["name"])
	}
}

func TestTable_Output(t *testing.T) {
	headers := []string{"NAME", "STATUS"}
	rows := []map[string]string{
		{"NAME": "alpha", "STATUS": "running"},
		{"NAME": "beta", "STATUS": "stopped"},
	}

	out := captureStdout(t, func() {
		Table(headers, rows)
	})

	if !strings.Contains(out, "NAME") {
		t.Error("expected headers in output")
	}
	if !strings.Contains(out, "alpha") {
		t.Error("expected 'alpha' in output")
	}
	if !strings.Contains(out, "beta") {
		t.Error("expected 'beta' in output")
	}
	if !strings.Contains(out, "running") {
		t.Error("expected 'running' in output")
	}
}

func TestKeyValue_SortedOutput(t *testing.T) {
	data := map[string]any{
		"zebra":    "last",
		"alpha":    "first",
		"middle":   "mid",
	}

	out := captureStdout(t, func() {
		KeyValue(data)
	})

	alphaIdx := strings.Index(out, "alpha")
	middleIdx := strings.Index(out, "middle")
	zebraIdx := strings.Index(out, "zebra")

	if alphaIdx < 0 || middleIdx < 0 || zebraIdx < 0 {
		t.Fatalf("expected all keys in output, got: %s", out)
	}

	if !(alphaIdx < middleIdx && middleIdx < zebraIdx) {
		t.Errorf("expected alphabetical order: alpha(%d) < middle(%d) < zebra(%d)", alphaIdx, middleIdx, zebraIdx)
	}
}

func TestSuccess_Output(t *testing.T) {
	out := captureStdout(t, func() {
		Success("operation complete")
	})

	trimmed := strings.TrimSpace(out)
	if trimmed != "operation complete" {
		t.Errorf("expected 'operation complete', got %q", trimmed)
	}
}
