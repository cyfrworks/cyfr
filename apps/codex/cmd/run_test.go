// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sync"
	"testing"

	"github.com/spf13/pflag"
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
			if result != tt.want {
				t.Errorf("got %q, want %q", result, tt.want)
			}
		})
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
			if result != tt.want {
				t.Errorf("got %q, want %q", result, tt.want)
			}
		})
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
			result := parseReference(tt.input, tt.compType)
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
			result := parseReference(tt.input, tt.compType)
			if result != tt.want {
				t.Errorf("got %q, want %q", result, tt.want)
			}
		})
	}
}

// `cyfr run --list` asks for the running runs alone and prints them as a
// table, and says so when nothing runs.
func TestRunList_RunningOnlyAsATable(t *testing.T) {
	forgetRunFlags(t)
	srv := newCLIServer(t, "", `{"executions":[`+
		`{"execution_id":"exec_1","reference":"reagent:local.math:0.1.0","status":"running",`+
		`"started_at":"2026-11-14T08:00:00Z","input":{"a":1},"duration_ms":null}],"count":1,"user_id":"u1"}`)

	out, err := runCLI(t, srv, "run", "--list")
	if err != nil {
		t.Fatalf("cyfr run --list: %v", err)
	}
	if name, args := srv.call(0); name != "execution" ||
		!reflect.DeepEqual(args, map[string]any{"action": "list", "status": "running"}) {
		t.Fatalf("asked %s %v, want execution {action: list, status: running}", name, args)
	}
	want := "execution_id  reference                 status   started_at\n" +
		"------------  ---------                 ------   ----------\n" +
		"exec_1        reagent:local.math:0.1.0  running  2026-11-14T08:00:00Z\n"
	if out != want {
		t.Fatalf("printed\n%s\nwant\n%s", out, want)
	}

	forgetRunFlags(t)
	idle := newCLIServer(t, "", `{"executions":[],"count":0,"user_id":"u1"}`)
	if out, err := runCLI(t, idle, "run", "--list"); err != nil || out != "Nothing is running.\n" {
		t.Fatalf("an idle list printed %q (%v)", out, err)
	}
}

// An --input that is JSON but not an object is refused in words before
// anything is asked of the server.
func TestRunInput_NotAnObjectIsRefusedInWords(t *testing.T) {
	for _, input := range []string{`[1,2]`, `"text"`, `3`, `null`} {
		forgetRunFlags(t)
		srv := newCLIServer(t, "")
		_, err := runCLI(t, srv, "run", "reagent:local.math:0.1.0", "--input", input)
		if err == nil || err.Error() != `The input must be a JSON object, such as '{"text":"hello"}'.` {
			t.Fatalf("--input %s answered %v", input, err)
		}
		if srv.count() != 0 {
			t.Fatalf("--input %s still asked the server %d times", input, srv.count())
		}
	}
}

// Ctrl-C while `cyfr run` waits for its run ends the wait and says the
// run goes on, naming how to see and stop it; it exits 130.
func TestRun_CtrlCSaysTheRunGoesOn(t *testing.T) {
	forgetRunFlags(t)
	asked, ended := make(chan struct{}), make(chan struct{})
	var once sync.Once
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		once.Do(func() { close(asked) })
		select {
		case <-r.Context().Done():
		case <-ended:
		}
	}))
	// Cleanups run last first: the handler is let go before the server
	// waits for it.
	t.Cleanup(srv.Close)
	t.Cleanup(func() { close(ended) })
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CYFR_TOKEN", "cyfr-test-session")

	err := interruptAt(t, asked, func(ctx context.Context) error {
		_, err := runCommand(t, ctx, "run", "reagent:local.math:0.1.0", "--url", srv.URL)
		return err
	})
	wantInterrupted(t, err, "Stopped waiting. A run CYFR already started goes on: "+
		"cyfr run --list shows it, and cyfr run --cancel <id> stops it.")
}

// forgetRunFlags puts `cyfr run`'s flags back to their defaults, now and
// when t ends: cobra keeps a flag's value from one execution to the next,
// and each run here is a process of its own.
func forgetRunFlags(t *testing.T) {
	t.Helper()
	reset := func() {
		runCmd.Flags().VisitAll(func(f *pflag.Flag) {
			_ = f.Value.Set(f.DefValue)
			f.Changed = false
		})
	}
	reset()
	t.Cleanup(reset)
}
