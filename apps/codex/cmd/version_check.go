package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/release"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

// updateCheckTTL bounds how often the CLI hits the GitHub releases API to learn
// the latest version.
const updateCheckTTL = 24 * time.Hour

func init() {
	cobra.AddTemplateFunc("upgradeNotice", upgradeNotice)
	rootCmd.SetVersionTemplate("cyfr version {{.Version}}{{with upgradeNotice}}\n\n{{.}}{{end}}\n")
}

// upgradeNotice returns a one-line "newer version available" message, or "" if
// the CLI is already current, the check is opted out via CYFR_NO_UPDATE_CHECK,
// stdout is not a terminal, or the latest version can't be determined. It is
// safe to call from any command's human-readable output path: it never errors
// and blocks at most as long as the HTTP timeout in cachedLatest.
func upgradeNotice() string {
	if os.Getenv("CYFR_NO_UPDATE_CHECK") != "" {
		return ""
	}
	if !term.IsTerminal(int(os.Stdout.Fd())) {
		return ""
	}
	latest := cachedLatest()
	if latest == "" || !release.IsNewer(latest, Version) {
		return ""
	}
	return fmt.Sprintf("** %s available — run 'cyfr upgrade' to update", latest)
}

// versionCheck is the cached result of the most recent latest-version lookup.
type versionCheck struct {
	Latest    string    `json:"latest"`
	CheckedAt time.Time `json:"checked_at"`
}

// cachedLatest returns the latest known release version. It serves a cached
// value while it is fresher than updateCheckTTL, otherwise it refreshes from
// GitHub with a short timeout and rewrites the cache. On any lookup failure it
// falls back to the stale cached value (which may be "").
func cachedLatest() string {
	path, err := versionCheckPath()
	if err != nil {
		return ""
	}

	var cache versionCheck
	if data, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(data, &cache)
		if cache.Latest != "" && time.Since(cache.CheckedAt) < updateCheckTTL {
			return cache.Latest
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	latest, err := release.Latest(ctx)
	if err != nil {
		return cache.Latest // stale fallback (may be "")
	}

	writeVersionCache(path, versionCheck{Latest: latest, CheckedAt: time.Now()})
	return latest
}

// versionCheckPath returns ~/.cyfr/version-check.json.
func versionCheckPath() (string, error) {
	dir, err := config.DefaultConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "version-check.json"), nil
}

// writeVersionCache persists the lookup result, ignoring errors — a missing or
// unwritable cache only means the next invocation checks again.
func writeVersionCache(path string, vc versionCheck) {
	data, err := json.Marshal(vc)
	if err != nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return
	}
	_ = os.WriteFile(path, data, 0600)
}
