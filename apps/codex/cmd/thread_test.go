// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/ops"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

// identityVectors is the part of tests/fixtures/identity.json, the vector
// file of Prima.Identity, that names people by their identifiers.
type identityVectors struct {
	Identifiers map[string]string `json:"identifiers"`
}

func vectorIdentifiers(t *testing.T) []string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "tests", "fixtures", "identity.json"))
	if err != nil {
		t.Fatalf("read the vector file: %v", err)
	}
	var v identityVectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	if len(v.Identifiers) == 0 {
		t.Fatal("the vector file names no identifier")
	}
	identifiers := make([]string, 0, len(v.Identifiers))
	for _, identifier := range v.Identifiers {
		identifiers = append(identifiers, identifier)
	}
	return identifiers
}

// An argument is read as the handle, identifier or user id it is spelled
// as: a leading @ makes a handle, whose spelling the server reads; only
// the identifier grammar Prima.Identity holds makes an identifier; and an
// email is no form at all: it is sent as the user id it is not.
func TestPersonKeyReadsTheThreeForms(t *testing.T) {
	for _, identifier := range vectorIdentifiers(t) {
		if got := personKey(identifier); got != "identifier" {
			t.Errorf("personKey(%q) = %q, want identifier", identifier, got)
		}
	}

	hex := strings.Repeat("ab", 32)
	cases := map[string]string{
		"@alice":                      "handle",
		"@Not A Handle":               "handle",
		"@":                           "handle",
		"alice":                       "user_id",
		"someone@example.com":         "user_id",
		"usr_01a0f6f8-1629-79c3-9217": "user_id",
		"per_" + strings.ToUpper(hex): "user_id",
		"per_" + hex[:62]:             "user_id",
		"per_" + hex + "0":            "user_id",
		" per_" + hex:                 "user_id",
		"per_x":                       "user_id",
	}
	for target, want := range cases {
		if got := personKey(target); got != want {
			t.Errorf("personKey(%q) = %q, want %q", target, got, want)
		}
	}
}

// Each subcommand calls shared_thread with its own action and exactly the
// arguments its words name: a person by the one field their form fills.
func TestThreadSubcommandsSendTheirActionAndArguments(t *testing.T) {
	identifier := vectorIdentifiers(t)[0]
	cases := []struct {
		path string
		args []string
		want map[string]any
	}{
		{"thread list", nil, map[string]any{"action": "list"}},
		{"thread create", []string{"Trip"}, map[string]any{"action": "create", "title": "Trip"}},
		{"thread pair", []string{"usr_b"}, map[string]any{"action": "pair", "user": "usr_b"}},
		{"thread people", []string{"sth_1"}, map[string]any{"action": "people", "thread": "sth_1"}},
		{"thread add", []string{"sth_1", "@alice"}, map[string]any{"action": "add", "thread": "sth_1", "handle": "@alice"}},
		{"thread add", []string{"sth_1", identifier}, map[string]any{"action": "add", "thread": "sth_1", "identifier": identifier}},
		{"thread add", []string{"sth_1", "usr_b"}, map[string]any{"action": "add", "thread": "sth_1", "user_id": "usr_b"}},
		{"thread remove", []string{"sth_1", identifier}, map[string]any{"action": "remove", "thread": "sth_1", "identifier": identifier}},
		{"thread remove", []string{"sth_1", "usr_b"}, map[string]any{"action": "remove", "thread": "sth_1", "user_id": "usr_b"}},
		{"thread leave", []string{"sth_1"}, map[string]any{"action": "leave", "thread": "sth_1"}},
		{"thread post", []string{"sth_1", "hello there"}, map[string]any{"action": "post", "thread": "sth_1", "content": "hello there"}},
	}

	for _, tc := range cases {
		srv := newCLIServer(t, "")
		flagURL = srv.URL
		t.Cleanup(func() { flagURL = "" })

		c := findCommand(t, tc.path)
		if err := c.ValidateArgs(tc.args); err != nil {
			t.Errorf("%s %q: the arguments are refused: %v", tc.path, tc.args, err)
			continue
		}
		c.SetContext(t.Context())
		var err error
		captureStdout(t, func() { err = c.RunE(c, tc.args) })
		if err != nil {
			t.Errorf("%s %q: %v", tc.path, tc.args, err)
			continue
		}

		srv.mu.Lock()
		requests := len(srv.requests)
		var tool any
		if requests > 0 {
			tool = srv.requests[0]["name"]
		}
		srv.mu.Unlock()
		if requests != 1 || tool != ops.SharedThread {
			t.Errorf("%s %q made %d call(s), the first to %v; want one to %s", tc.path, tc.args, requests, tool, ops.SharedThread)
			continue
		}
		if got := srv.arguments(0); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%s %q sent %v, want %v", tc.path, tc.args, got, tc.want)
		}
	}
}

// A removal names someone this server holds a row for: a handle is refused
// before any call is made.
func TestThreadRemoveRefusesAHandle(t *testing.T) {
	srv := newCLIServer(t, "")
	flagURL = srv.URL
	t.Cleanup(func() { flagURL = "" })

	err := threadRemoveCmd.RunE(threadRemoveCmd, []string{"sth_1", "@alice"})
	if err == nil || !strings.Contains(err.Error(), "user id or person identifier") {
		t.Errorf("remove @alice answered %v, want a refusal naming the two forms", err)
	}
	srv.mu.Lock()
	defer srv.mu.Unlock()
	if len(srv.requests) != 0 {
		t.Errorf("a refused removal still called the home: %v", srv.requests)
	}
}

// The help speaks of threads and people, names the forms a person is
// given in, and never says workspace, group, room, email, handle or
// registry.
func TestThreadHelpVocabulary(t *testing.T) {
	if !strings.Contains(threadAddCmd.Use, "<@name|identifier|user_id>") {
		t.Errorf("usage %q does not name the three forms", threadAddCmd.Use)
	}
	if !strings.Contains(threadRemoveCmd.Use, "<user_id|identifier>") {
		t.Errorf("usage %q does not name the two forms", threadRemoveCmd.Use)
	}
	for _, form := range []string{"user id", "person identifier", "name (@name)"} {
		if !strings.Contains(threadCmd.Long, form) {
			t.Errorf("thread help does not name %s", form)
		}
	}

	banned := []string{"workspace", "group", "room", "email", "handle", "registry", "member"}
	for _, root := range []*cobra.Command{threadCmd, athanorCmd} {
		var walk func(c *cobra.Command)
		walk = func(c *cobra.Command) {
			texts := []string{c.Use, c.Short, c.Long, c.Example}
			c.Flags().VisitAll(func(f *pflag.Flag) { texts = append(texts, f.Usage) })
			for _, text := range texts {
				lower := strings.ToLower(text)
				for _, word := range banned {
					if strings.Contains(lower, word) {
						t.Errorf("%q help says %q: %q", c.CommandPath(), word, text)
					}
				}
			}
			for _, sub := range c.Commands() {
				walk(sub)
			}
		}
		walk(root)
	}
}
