// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package release

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"time"
)

// httpClient bounds the GitHub API call on its own, so a caller passing
// context.Background() still cannot hang on a stalled connection.
// `http.DefaultClient` has no timeout at all.
var httpClient = &http.Client{Timeout: 10 * time.Second}

// versionPattern is a release version as its tag names it: SemVer 2.0's
// MAJOR.MINOR.PATCH, optionally with a pre-release (0.6.0-alpha.1,
// 1.0.0-rc.2), in ASCII, without a prefix, leading zeros or build
// metadata. A tag names the URLs and file names `cyfr update` reads.
// tests/fixtures/release_manifest.json's versions hold this rule,
// tests/ci-release-graph.py's SEMVER and the release workflow's version
// step to one list.
var versionPattern = regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?$`)

// IsVersion reports whether v is a release version (versionPattern).
func IsVersion(v string) bool { return versionPattern.MatchString(v) }

// IsPrerelease reports whether v is a release version with a pre-release.
func IsPrerelease(v string) bool { return IsVersion(v) && strings.Contains(v, "-") }

// ErrNoRelease is Latest's answer when GitHub lists no published release
// to take.
var ErrNoRelease = errors.New("no CYFR release is published yet")

// apiURL is the GitHub releases endpoint for the CYFR repo. It is a package
// variable so tests can point it at an httptest server.
var apiURL = "https://api.github.com/repos/cyfrworks/cyfr/releases?per_page=20"

// listedRelease is a release as the GitHub releases API lists it.
type listedRelease struct {
	TagName    string `json:"tag_name"`
	Draft      bool   `json:"draft"`
	Prerelease bool   `json:"prerelease"`
}

// Latest returns the release an install or an update takes when no version
// is named: the newest published release that is not a pre-release and,
// while none is published, the newest pre-release. A pre-release is one
// GitHub marks as such or whose tag carries a pre-release; drafts and tags
// outside the release-version grammar are skipped, and newest is the
// greatest by Compare, whatever order the API lists them in. None left is
// ErrNoRelease. tests/fixtures/release_manifest.json's selection holds the
// rule, which scripts/install.sh and Cyfr.ReleaseChannel keep too.
func Latest(ctx context.Context) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, apiURL, nil)
	if err != nil {
		return "", err
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("GitHub API returned status %d", resp.StatusCode)
	}

	var releases []listedRelease
	if err := json.NewDecoder(resp.Body).Decode(&releases); err != nil {
		return "", err
	}
	if latest := pick(releases); latest != "" {
		return latest, nil
	}
	return "", ErrNoRelease
}

// pick is Latest's choice from a listing, "" when it holds none to take.
func pick(releases []listedRelease) string {
	release, prerelease := "", ""
	for _, r := range releases {
		if r.Draft || !IsVersion(r.TagName) {
			continue
		}
		newest := &release
		if r.Prerelease || IsPrerelease(r.TagName) {
			newest = &prerelease
		}
		if *newest == "" || IsNewer(r.TagName, *newest) {
			*newest = r.TagName
		}
	}
	if release != "" {
		return release
	}
	return prerelease
}

// IsNewer reports whether latest is a release version of strictly higher
// precedence than current (Compare). Either side not a release version
// (a "dev" build, say) answers false, so an unreleased or local build is
// never replaced and never told of a newer release.
func IsNewer(latest, current string) bool {
	if !IsVersion(latest) || !IsVersion(current) {
		return false
	}
	return Compare(latest, current) > 0
}

// Compare orders two release versions by SemVer 2.0 precedence: -1, 0 or
// 1 as a is lower than, equal to or higher than b. MAJOR, MINOR and PATCH
// compare numerically; a version with a pre-release is lower than the one
// without (1.0.0-rc.1 < 1.0.0); pre-releases compare identifier by
// identifier, numeric ones numerically and below alphanumeric ones, which
// compare in ASCII order, and a shorter run of equal identifiers is lower.
// Both must be release versions (IsVersion).
func Compare(a, b string) int {
	aCore, aPre, _ := strings.Cut(a, "-")
	bCore, bPre, _ := strings.Cut(b, "-")
	if c := compareIdentifiers(strings.Split(aCore, "."), strings.Split(bCore, ".")); c != 0 {
		return c
	}
	switch {
	case aPre == bPre:
		return 0
	case aPre == "":
		return 1
	case bPre == "":
		return -1
	}
	return compareIdentifiers(strings.Split(aPre, "."), strings.Split(bPre, "."))
}

// compareIdentifiers compares dot-separated identifiers in order, the
// shorter list lower when one is a prefix of the other.
func compareIdentifiers(a, b []string) int {
	for i := 0; i < len(a) && i < len(b); i++ {
		if c := compareIdentifier(a[i], b[i]); c != 0 {
			return c
		}
	}
	return compareInts(len(a), len(b))
}

// compareIdentifier compares one identifier pair: numeric identifiers,
// which carry no leading zero, by length and then digit by digit, so no
// size overflows; a numeric one below an alphanumeric one; alphanumeric
// ones in ASCII order.
func compareIdentifier(a, b string) int {
	aNum, bNum := numeric(a), numeric(b)
	switch {
	case aNum && bNum:
		if c := compareInts(len(a), len(b)); c != 0 {
			return c
		}
		return strings.Compare(a, b)
	case aNum:
		return -1
	case bNum:
		return 1
	}
	return strings.Compare(a, b)
}

func numeric(s string) bool {
	return s != "" && strings.Trim(s, "0123456789") == ""
}

func compareInts(a, b int) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}
