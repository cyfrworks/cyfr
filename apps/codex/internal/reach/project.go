// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// ProjectName is Docker Compose's default project name for the directory
// dir, the -p every engine compose call passes: its base name lowercased,
// every character outside [a-z0-9_-] dropped, then any leading character
// that is not a letter or a digit.
func ProjectName(dir string) string {
	if abs, err := filepath.Abs(dir); err == nil {
		dir = abs
	}
	return projectName(dir)
}

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

// DefaultFiles is the file set docker compose loads by default from the
// project directory dir, each name relative to it: its one main file,
// and its override file, "" when there is none. It is refused when it is
// not determined: no main file, two main files, of which compose loads
// one and warns, or two override files, of which it picks one.
func DefaultFiles(dir string) (main, override string, err error) {
	files, err := defaultFileSet(dir)
	if err != nil {
		return "", "", err
	}
	if len(files) > 1 {
		override = files[1]
	}
	return files[0], override, nil
}

func (e *Engine) defaultFiles() ([]string, error) { return defaultFileSet(e.dir) }

func defaultFileSet(dir string) ([]string, error) {
	present := func(names []string) []string {
		var found []string
		for _, name := range names {
			if _, err := os.Lstat(filepath.Join(dir, name)); err == nil {
				found = append(found, name)
			}
		}
		return found
	}
	mains, overrides := present(composeMainFiles), present(composeOverrideFiles)
	switch {
	case len(mains) == 0:
		return nil, fmt.Errorf("reach: %s holds no compose file (%s), so the stack cannot be started from it", dir, strings.Join(composeMainFiles, ", "))
	case len(mains) > 1:
		return nil, fmt.Errorf("reach: the project holds %s, of which docker compose loads one; keep one", strings.Join(mains, " and "))
	case len(overrides) > 1:
		return nil, fmt.Errorf("reach: the project holds the override files %s, of which docker compose loads one; keep one", strings.Join(overrides, ", "))
	}
	return append(mains, overrides...), nil
}
