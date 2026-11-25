// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"io"
	"os"
	"path/filepath"

	"github.com/cyfr/codex/internal/scaffold"
)

// canReplaceIn is nil on Windows, whose engine (Docker Desktop) hands a
// bind mount's bytes to no other account than the person's.
func canReplaceIn(string) error { return nil }

// canRead is nil on Windows, as canReplaceIn is.
func canRead(string, bool) error { return nil }

// closedToYou is false on Windows, which has no sudo.
func closedToYou(error) bool { return false }

// keepOwner does nothing on Windows, which has no sudo.
func keepOwner(string, string) error { return nil }

// returnToSudoAccount does nothing on Windows, which has no sudo.
func returnToSudoAccount(string, []string, io.Writer) {}

// noLinkIn is nil on Windows, where no restore runs as another account.
func noLinkIn(string) error { return nil }

// putProjectFile writes data over the project's file name, mode, its
// directory made first, as scaffold.ReplaceFile does.
func putProjectFile(name string, data []byte, mode os.FileMode) error {
	if err := scaffold.MakeDir(filepath.Dir(name)); err != nil {
		return err
	}
	return scaffold.ReplaceFile(name, data, mode)
}

// removeProjectFile removes the project's file name through an os.Root of
// the project, as scaffold.ReplaceFile writes one, so no folder link it
// does not follow carries the removal outside; one that is not there is no
// failure.
func removeProjectFile(name string) error {
	root, err := os.OpenRoot(".")
	if err != nil {
		return err
	}
	defer root.Close()
	if err := root.Remove(name); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
