// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"fmt"
	"hash/fnv"
	"os"
)

// standInID is the file's identity as find's '%D %i' writes it: on
// Windows, where no test reaches one file by two paths, its host path's.
func standInID(_ os.FileInfo, host string) string {
	h := fnv.New64a()
	h.Write([]byte(host))
	return fmt.Sprintf("0 %d", h.Sum64())
}
