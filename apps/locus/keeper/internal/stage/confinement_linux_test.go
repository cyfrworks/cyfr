// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package stage

import (
	"os"
	"path/filepath"
	"testing"
)

// Under the profile cyfr-locus, with the system paths unmasked as every
// Locus container runs, every path Docker masks is unreadable and every
// path it makes read-only is unwritable, to root: the profile stands in for
// Docker's two lists (docker_paths.json) whole, and the boot's proof says
// so. Keeper CI's real-kernel step runs this as root under the profile and
// refuses a skip.
func TestTheProfileDeniesWhatDockerMasks(t *testing.T) {
	if os.Getuid() != 0 {
		t.Skip("the denials are root's to try: needs root")
	}
	if label := AppArmorLabel(); label != ProfileLabel {
		t.Skipf("this process runs under %q, not the profile cyfr-locus", label)
	}
	masked, readonly, err := DockerPaths()
	if err != nil || len(masked) == 0 || len(readonly) == 0 {
		t.Fatalf("Docker's lists: %v %v %v", masked, readonly, err)
	}
	tried := 0
	for _, pattern := range masked {
		paths, _ := filepath.Glob(pattern)
		for _, path := range paths {
			tried++
			if refused(path, 0) != nil {
				t.Errorf("%s, which Docker masks, is readable under the profile", path)
			}
		}
	}
	for _, path := range readonly {
		target, err := writableBelow(path)
		if err != nil {
			continue
		}
		tried++
		if refused(target, 1) != nil {
			t.Errorf("%s, which Docker makes read-only, is writable under the profile", target)
		}
	}
	if tried == 0 {
		t.Fatal("no path of Docker's lists exists here to try")
	}
	if enforced, err := Confinement(); !enforced || err != nil {
		t.Fatalf("the boot's proof answered %t, %v", enforced, err)
	}
}
