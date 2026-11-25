// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package brainwire

import (
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/cyfr/locus/keeper/internal/stage"
)

// PacksRoot is where a session's space holds the packs the person
// switched on, read only (stage.ScrollsPath): one folder for each pack,
// named by CYFR's name for it, holding the pack's files as published. The
// keeper binds it there for a program whose driver loads packs, and the
// program loads each pack its own way; a space with no pack on has none.
// A driver lists the folders and nothing else: it opens no pack's file
// and writes nowhere, and CYFR tells the model nothing of what was loaded.
// The drivers' tests point it elsewhere.
var PacksRoot = stage.ScrollsPath

// Packs answers the absolute path of each pack folder under PacksRoot,
// in name order: its directories, never a link or a file, and no name
// beginning with a dot. A root that is absent or cannot be listed answers
// none, and the program starts as it does with no pack on.
func Packs() []string {
	entries, err := os.ReadDir(PacksRoot)
	if err != nil {
		return nil
	}
	var folders []string
	for _, e := range entries {
		if e.Type()&os.ModeType != os.ModeDir || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		folders = append(folders, filepath.Join(PacksRoot, e.Name()))
	}
	sort.Strings(folders)
	return folders
}
