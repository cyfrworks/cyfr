// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package stage prepares and executes one spawned process. `cyfr-keeper
// stage` starts already running as the allocated uid and gid with no
// supplementary groups, in a session of its own. It reads its Spec from
// fd 3, creates the home, applies the limits, builds the environment from
// nothing, and executes the command with the backend's pipes on fds 0-2
// and, for a spawn with a control channel, that channel's socket on fd 3.
package stage

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/cyfr/keeper/internal/cgroup"
	"github.com/cyfr/keeper/internal/home"
	"github.com/cyfr/keeper/internal/protocol"
)

// Path is the PATH every spawned process receives.
const Path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

// Spec is what the spawner hands a stage process over its spec pipe.
type Spec struct {
	UID      int               `json:"uid"`
	GID      int               `json:"gid"`
	User     string            `json:"user"`
	HomeRoot string            `json:"home_root"`
	Home     string            `json:"home"`
	Argv     []string          `json:"argv"`
	Env      map[string]string `json:"env"`
	Limits   protocol.Limits   `json:"limits"`
	// Control says the spawner handed the control channel's socket on
	// ControlFD, to become the command's fd 3.
	Control bool `json:"control"`
	// Cgroup is the memory-bounded group the spawner moved this process
	// into before it sent the spec, as /proc/self/cgroup names it; empty
	// for a spawn without a bound. The stage executes the command only
	// from inside it.
	Cgroup string `json:"cgroup"`
}

// Validate checks the spec independently of the spawner: a non-root uid
// and gid, a user name, a home named for the uid under the home root, a
// valid command, and limits within the ceilings.
func (s Spec) Validate() error {
	if s.UID <= 0 || s.GID <= 0 {
		return errors.New("uid and gid must be non-zero")
	}
	if s.User == "" || strings.ContainsAny(s.User, "\x00\n=") {
		return errors.New("user must be a plain name")
	}
	if err := home.Validate(s.HomeRoot, s.Home, s.UID); err != nil {
		return err
	}
	if err := protocol.ValidateCommand(s.Argv, s.Env); err != nil {
		return err
	}
	c := protocol.Ceilings
	l := s.Limits
	if l.Nofile == 0 || l.Nofile > c.Nofile || l.Nproc == 0 || l.Nproc > c.Nproc || l.Core > c.Core || l.Fsize == 0 || l.Fsize > c.Fsize {
		return fmt.Errorf("limits %+v are outside the ceilings %+v", l, c)
	}
	if s.Cgroup != "" && s.Cgroup != "/"+cgroup.Name(s.UID) {
		return fmt.Errorf("cgroup %q is not the group of uid %d", s.Cgroup, s.UID)
	}
	return nil
}

// Environ is the complete environment of the spawned process: HOME, USER,
// LOGNAME, TMPDIR (inside the home) and PATH, then the spec's own
// variables, sorted by name. Nothing is inherited.
func (s Spec) Environ() []string {
	env := []string{
		"HOME=" + s.Home,
		"LOGNAME=" + s.User,
		"PATH=" + Path,
		"TMPDIR=" + filepath.Join(s.Home, "tmp"),
		"USER=" + s.User,
	}
	names := make([]string, 0, len(s.Env))
	for name := range s.Env {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		env = append(env, name+"="+s.Env[name])
	}
	return env
}

// LookPath resolves a command name the way a shell would with Path: a name
// containing a slash is used as given, otherwise the first executable
// regular file named file in a Path directory.
func LookPath(file string) (string, error) {
	if strings.Contains(file, "/") {
		return file, nil
	}
	for _, dir := range filepath.SplitList(Path) {
		candidate := filepath.Join(dir, file)
		info, err := os.Stat(candidate)
		if err == nil && info.Mode().IsRegular() && info.Mode()&0o111 != 0 {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("%s: %w", file, fs.ErrNotExist)
}
