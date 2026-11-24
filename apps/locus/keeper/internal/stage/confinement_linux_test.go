// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package stage

import (
	_ "embed"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

//go:embed docker_paths.json
var dockerPathsJSON []byte

// releaseProfileName is the file that names this tree's profile.
const releaseProfileName = "../../../../codex/internal/apparmor/name"

// Under this release's profile, with the system paths unmasked as every
// Locus container runs, every path Docker 29.1.3 masks (docker_paths.json)
// refuses a read and every file below a path it makes read-only refuses a
// write, to root: the profile stands in for Docker's two lists whole. Only
// the policy's EACCES counts as a denial; any other error fails, and so
// does an open. A masked directory refuses its own listing, so its own
// refusal is what is seen of it. Keeper CI's real-kernel step runs this as
// root under the profile and refuses a skip.
func TestTheProfileDeniesWhatDockerMasks(t *testing.T) {
	if os.Getuid() != 0 {
		t.Skip("the denials are root's to try: needs root")
	}
	name := ProfileName(releaseProfileName)
	if label := AppArmorLabel(); name == "" || label != name+" (enforce)" {
		t.Skipf("this process runs under %q, not this release's profile %q", label, name)
	}
	var lists struct{ Masked, Readonly []string }
	if err := json.Unmarshal(dockerPathsJSON, &lists); err != nil || len(lists.Masked) == 0 || len(lists.Readonly) == 0 {
		t.Fatalf("Docker's lists: %+v %v", lists, err)
	}
	tried := 0
	try := func(path string, flags int, what string) {
		tried++
		fd, err := unix.Open(path, flags|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
		switch {
		case err == nil:
			_ = unix.Close(fd)
			t.Errorf("%s, which Docker %s, opens under the profile", path, what)
		case errors.Is(err, unix.ENOENT):
			tried--
		case !errors.Is(err, unix.EACCES):
			t.Errorf("%s, which Docker %s: %v, which is no denial of the policy", path, what, err)
		}
	}
	for _, pattern := range lists.Masked {
		paths, _ := filepath.Glob(pattern)
		for _, path := range paths {
			try(path, unix.O_RDONLY, "masks")
		}
	}
	for _, top := range lists.Readonly {
		_ = filepath.WalkDir(top, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if info, err := d.Info(); err == nil && d.Type().IsRegular() && info.Mode().Perm()&0o200 != 0 {
				try(path, unix.O_WRONLY, "makes read-only")
			}
			return nil
		})
	}
	if tried == 0 {
		t.Fatal("no path of Docker's lists exists here to try")
	}
	t.Logf("%d paths refused", tried)
}
