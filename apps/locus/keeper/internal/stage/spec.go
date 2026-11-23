// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package stage prepares and executes one spawned process in a session of
// its own. A stage sharing the keeper's namespaces starts as the allocated
// uid and gid with no supplementary groups. An isolated stage keeps the
// keeper's ids until the keeper maps its namespace; after reading its Spec
// from fd 3 it becomes the allocated ids and drops its capabilities. The
// stage creates the home, applies the limits, builds the environment from
// nothing, and executes the command with stdio on fds 0-2, its control
// channel on fd 3 when requested, and its relay on fd 4 when isolated.
package stage

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// Path is the system's PATH: a build's and a pooled program's, the end of
// a kept program's, and the keeper's own.
const Path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

// CyfrBin holds CYFR's drivers and the stub alone (Dockerfile.locus). It
// is first on a kept program's PATH, so nothing a person installs is
// found in their place.
const CyfrBin = "/opt/cyfr/bin"

// Spec is what the keeper hands a stage process over its spec pipe.
type Spec struct {
	UID      int    `json:"uid"`
	GID      int    `json:"gid"`
	User     string `json:"user"`
	HomeRoot string `json:"home_root"`
	Home     string `json:"home"`
	// Kept says Home is a kept home, made by its uid before the spawn and
	// kept after it: the stage uses it as it is, under HomeRoot, the
	// kept-homes root, and makes only its tmp directory when it is gone.
	Kept   bool              `json:"kept"`
	Argv   []string          `json:"argv"`
	Env    map[string]string `json:"env"`
	Limits protocol.Limits   `json:"limits"`
	// Control says the keeper handed the control channel's socket on
	// ControlFD, to become the command's fd 3.
	Control bool `json:"control"`
	// Cgroup is the memory-bounded group the keeper moved this process
	// into before it sent the spec, as cgroup.Own reads /proc/self/cgroup:
	// a spawn's bound by the spawn's name. The stage executes the command
	// only from inside it: a spec naming none is refused, so no command runs
	// outside a bound.
	Cgroup string `json:"cgroup"`
}

// Validate checks the spec independently of the keeper: a non-root uid
// and gid, a user name, a home named for the uid under the home root, a
// valid command, and limits within the ceilings.
func (s Spec) Validate() error {
	if s.UID <= 0 || s.GID <= 0 {
		return errors.New("uid and gid must be non-zero")
	}
	if s.User == "" || strings.ContainsAny(s.User, "\x00\n=") {
		return errors.New("user must be a plain name")
	}
	if s.Kept {
		if err := (home.Kept{Root: s.HomeRoot, First: s.UID, Last: s.UID}).Validate(s.Home, s.UID); err != nil {
			return err
		}
	} else if err := home.Validate(s.HomeRoot, s.Home, s.UID); err != nil {
		return err
	}
	if err := protocol.ValidateCommand(s.Argv, s.Env); err != nil {
		return err
	}
	c := protocol.Ceilings
	l := s.Limits
	// A kept spawn's file size may be unlimited (protocol.KeptUnbounded).
	fsizeOK := l.Fsize != 0 && (l.Fsize <= c.Fsize || (s.Kept && l.Fsize == protocol.Unlimited))
	if l.Nofile == 0 || l.Nofile > c.Nofile || l.Nproc == 0 || l.Nproc > c.Nproc || l.Core > c.Core || !fsizeOK {
		return fmt.Errorf("limits %+v are outside the ceilings %+v", l, c)
	}
	// A pooled uid's group is named for its uid; a kept spawn's for the
	// spawn, since the spawns of one kept home share its uid.
	if s.Cgroup != "/"+cgroup.Name(s.UID) &&
		!(s.Kept && strings.HasPrefix(s.Cgroup, "/"+cgroup.SpawnName("")) && cgroup.ValidName(strings.TrimPrefix(s.Cgroup, "/"))) {
		return fmt.Errorf("cgroup %q is not the group of uid %d", s.Cgroup, s.UID)
	}
	return nil
}

// SearchPath is the spawn's PATH. A kept program's is CyfrBin, then the
// home's .local/bin, where what the person installs goes, then Path; every
// other spawn's is Path.
func (s Spec) SearchPath() string {
	if s.Kept {
		return CyfrBin + ":" + filepath.Join(s.Home, ".local", "bin") + ":" + Path
	}
	return Path
}

// Environ is the complete environment of the spawned process: HOME, USER,
// LOGNAME, TMPDIR (inside the home) and PATH (SearchPath), then the spec's
// own variables, sorted by name. A kept program is also given npm's prefix
// and XDG_BIN_HOME in the home's .local, so what it installs lands on its
// PATH, unless its own variables name them. Nothing is inherited.
func (s Spec) Environ() []string {
	env := []string{
		"HOME=" + s.Home,
		"LOGNAME=" + s.User,
		"PATH=" + s.SearchPath(),
		"TMPDIR=" + filepath.Join(s.Home, "tmp"),
		"USER=" + s.User,
	}
	own := make(map[string]string, len(s.Env)+2)
	if s.Kept {
		own["NPM_CONFIG_PREFIX"] = filepath.Join(s.Home, ".local")
		own["XDG_BIN_HOME"] = filepath.Join(s.Home, ".local", "bin")
	}
	for name, value := range s.Env {
		own[name] = value
	}
	names := make([]string, 0, len(own))
	for name := range own {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		env = append(env, name+"="+own[name])
	}
	return env
}

// LookPath resolves the command's name the way a shell would with the
// spawn's SearchPath: a name containing a slash is used as given,
// otherwise the first executable regular file named file in one of its
// directories.
func (s Spec) LookPath(file string) (string, error) {
	if strings.Contains(file, "/") {
		return file, nil
	}
	for _, dir := range filepath.SplitList(s.SearchPath()) {
		candidate := filepath.Join(dir, file)
		info, err := os.Stat(candidate)
		if err == nil && info.Mode().IsRegular() && info.Mode()&0o111 != 0 {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("%s: %w", file, fs.ErrNotExist)
}
