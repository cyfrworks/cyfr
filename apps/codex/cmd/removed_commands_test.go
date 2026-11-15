// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"strings"
	"testing"
)

// The command line signs no one in, confirms nothing and attaches to no
// program: people act on the screen. Each command that did, and each one
// no API key may run (a person's act, or the platform's), is unknown now,
// refused before any request reaches CYFR.
func TestRemovedCommandsAreUnknown(t *testing.T) {
	for _, args := range [][]string{
		{"login"}, {"logout"}, {"open"}, {"device", "approve", "k"},
		{"admin", "list"}, {"settings", "list"}, {"thread", "list"}, {"report", "list"},
		{"aqua", "reset"}, {"athanor", "provision"},
		{"mcp", "add", "x", "{}"}, {"mcp", "update", "x", "{}"}, {"mcp", "reset-home", "x"},
		{"registry", "sync"}, {"registry", "publisher", "claim", "acme.com"}, {"registry", "publisher", "verify", "acme.com"},
		{"push", "c:local.x:0.1.0"}, {"deprecate", "c:local.x:0.1.0"}, {"yank", "c:local.x:0.1.0"},
		{"profile", "grant", "c:local.x"}, {"schedule", "create"}, {"webhook", "create"},
		{"profile", "revoke", "prof_x"}, {"athanor", "settings", "--set", "aqua.answer_mode=all"},
		{"registry", "tokens", "issue", "acme.com"}, {"registry", "tokens", "revoke", "acme.com", "tok_1"},
		{"registry", "members", "add", "acme.com", "alice"}, {"registry", "members", "update", "acme.com", "alice", "--role", "admin"},
		{"registry", "members", "remove", "acme.com", "alice"},
		{"decision", "list", "--global"}, {"decision", "get", "--global", "call_1"},
		{"webhook", "update", "hook", "--profile", "prof_x"},
	} {
		srv := newCLIServer(t, "")
		_, err := runCLI(t, srv, args...)
		if err == nil || srv.count() != 0 {
			t.Errorf("cyfr %s ran (error %v, %d requests)", strings.Join(args, " "), err, srv.count())
		}
	}
}

// `cyfr notify --help` says what it sends and to whom: the whole body,
// the person's id in it, a public target only, and no grant.
func TestNotifyHelpSaysWhatItSends(t *testing.T) {
	for _, want := range []string{`"event"`, `"payload"`, `"source": "cyfr"`, `"user_id"`, `"timestamp"`,
		"the target learns your\nperson's id", "public address", "no grant"} {
		if !strings.Contains(notifyCmd.Long, want) {
			t.Errorf("cyfr notify --help does not say %q:\n%s", want, notifyCmd.Long)
		}
	}
}
