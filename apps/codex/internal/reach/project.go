// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// projectName is Docker Compose's default project name for dir: its base
// name lowercased, every character outside [a-z0-9_-] dropped, then any
// leading character that is not a letter or a digit.
func projectName(dir string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(filepath.Base(dir)) {
		if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '_' || r == '-' {
			b.WriteRune(r)
		}
	}
	return strings.TrimLeft(b.String(), "_-")
}

// The file names docker compose loads from the project directory when no
// file is named, each list in its order of preference: one main file and
// at most one override file read after it.
var (
	composeMainFiles     = []string{"compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"}
	composeOverrideFiles = []string{"compose.override.yml", "compose.override.yaml", "docker-compose.override.yml", "docker-compose.override.yaml"}
)

// defaultFiles is the file set docker compose loads by default, relative
// to the project directory: its one main file and the override file, if
// there is one. It is refused when it is not determined: two main files,
// of which compose loads one and warns, or two override files.
func (e *Engine) defaultFiles() ([]string, error) {
	present := func(names []string) []string {
		var found []string
		for _, name := range names {
			if _, err := os.Lstat(filepath.Join(e.dir, name)); err == nil {
				found = append(found, name)
			}
		}
		return found
	}
	mains, overrides := present(composeMainFiles), present(composeOverrideFiles)
	switch {
	case len(mains) == 0:
		return nil, fmt.Errorf("reach: %s holds no compose file (%s), so the stack cannot be started from it", e.dir, strings.Join(composeMainFiles, ", "))
	case len(mains) > 1:
		return nil, fmt.Errorf("reach: the project holds %s, of which docker compose loads one; keep one", strings.Join(mains, " and "))
	case len(overrides) > 1:
		return nil, fmt.Errorf("reach: the project holds the override files %s, of which docker compose loads one; keep one", strings.Join(overrides, ", "))
	}
	return append(mains, overrides...), nil
}
