// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/reach"
)

// `cyfr setup link` is http://localhost:<CYFR_PORT>/setup#t=<token>, the
// capability in the fragment; a home with no token, or one the boot refuses
// beside its administrators or malformed, answers the sentence that says
// why, and no link.
func TestSetupLink(t *testing.T) {
	token := strings.Repeat("0f", 32)
	cases := []struct {
		name, env, link, refusal string
	}{
		{"the default port", "CYFR_SETUP_TOKEN=" + token + "\n", "http://localhost:4000/setup#t=" + token, ""},
		{"the home's port", "CYFR_PORT=4123\nCYFR_SETUP_TOKEN='" + token + "'\n", "http://localhost:4123/setup#t=" + token, ""},
		{"administrators and no token", "CYFR_PLATFORM_ADMIN_EMAILS=me@example.com\n", "", "names its administrators in CYFR_PLATFORM_ADMIN_EMAILS"},
		{"no token", "# CYFR_SETUP_TOKEN=\n", "", ".env holds no CYFR_SETUP_TOKEN, so this home has no setup link"},
		{"a token beside administrators", "CYFR_SETUP_TOKEN=" + token + "\nCYFR_PLATFORM_ADMIN_EMAILS=me@example.com\n", "", reach.Refuse("setup_token_with_admins", nil).Message()},
		{"a malformed token", "CYFR_SETUP_TOKEN=" + strings.ToUpper(token) + "\n", "", reach.Refuse("setup_token_refused", map[string]string{"why": "malformed"}).Message()},
		{"a port that is none", "CYFR_PORT=40000000\nCYFR_SETUP_TOKEN=" + token + "\n", "", "CYFR_PORT in .env is \"40000000\""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), ".env")
			if err := os.WriteFile(path, []byte(c.env), 0600); err != nil {
				t.Fatal(err)
			}
			link, err := setupLink(path)
			if c.refusal != "" {
				if err == nil || !strings.Contains(err.Error(), c.refusal) || link != "" {
					t.Fatalf("setup link answered %q, %v; want the refusal %q", link, err, c.refusal)
				}
				if strings.Contains(err.Error(), token) {
					t.Errorf("the refusal holds the token")
				}
				return
			}
			if err != nil || link != c.link {
				t.Errorf("setup link answered %q, %v; want %s", link, err, c.link)
			}
		})
	}
	if _, err := setupLink(filepath.Join(t.TempDir(), ".env")); err == nil || !strings.Contains(err.Error(), "There is no .env here") {
		t.Errorf("setup link with no .env answered %v", err)
	}
}
