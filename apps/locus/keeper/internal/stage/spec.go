// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package stage prepares and executes one spawned process, or one role's
// process (Spec.Role), in a space of its own: a user, network and IPC
// namespace the keeper cloned the stage into,
// and a pid, mount and cgroup namespace the stage clones the space's first
// process into. The stage keeps the keeper's ids until the keeper maps its
// namespace; after reading its Spec from fd 3 it becomes the allocated ids,
// makes a routed space's loopback and name sockets and hands them up, and
// creates the home. The space's first process builds the space's files and
// drops every capability, and the space's init applies the limits, builds
// the environment from nothing and executes the command with stdio on fds
// 0-2, its control channel on fd 3 when requested, and a relay space's
// relay on fd 4 (space_linux.go).
package stage

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/pool"
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
	Kept bool `json:"kept"`
	// Role names the role whose process this space runs, "" for a spawn's:
	// its Home is the role's run folder, HomeRoot/Role, the keeper made for
	// its uid; its Env is its whole environment, which the keeper built;
	// its control channel is its channel to the keeper; it keeps the
	// keeper's own resource limits, so Limits is zero; and its group is its
	// role's leaf.
	Role   string            `json:"role,omitempty"`
	Argv   []string          `json:"argv"`
	Env    map[string]string `json:"env"`
	Limits protocol.Limits   `json:"limits"`
	// Control says the keeper handed the control channel's socket on
	// ControlFD, to become the command's fd 3.
	Control bool `json:"control"`
	// Terminal says the keeper handed a socket on TerminalFD: the space's
	// first process opens a terminal of the space's own, makes its slave the
	// command's stdin, stdout and stderr, and hands its master up there.
	Terminal bool `json:"terminal"`
	// Reach is the space's (package pool): ReachRelay, whose relay the
	// keeper handed on RelayFD, or ReachRouted, whose route socket the
	// keeper handed on RouteFD.
	Reach string `json:"reach"`
	// Cgroup is the memory-bounded group the keeper moved this process
	// into before it sent the spec, as cgroup.Own reads /proc/self/cgroup:
	// a spawn's bound by the spawn's name. The stage executes the command
	// only from inside it: a spec naming none is refused, so no command runs
	// outside a bound.
	Cgroup string `json:"cgroup"`
	// Packs is the pack generation (package packview) the space binds read
	// only at scrolls.Path, "" for none: <kept root>/.packs/<a>/<d>.
	Packs string `json:"packs,omitempty"`
	// Machine names the image's programs' device a person's machine boots
	// from (package vm), "" for every other space. A machine's space is a
	// relay space whose relay leads nowhere, holding its VMM alone: its
	// home is the machine's folder, and beside the container's directories
	// it is given this device, read only at its path, and /dev/kvm in its
	// /dev, which no other space is.
	Machine string `json:"machine,omitempty"`
}

var generationName = regexp.MustCompile(`^[0-9a-f]{64}$`)

// validPacks reports whether p names a pack generation: a clean absolute
// path ending in .packs/<64 hex>/<64 hex>.
func validPacks(p string) bool {
	if !filepath.IsAbs(p) || filepath.Clean(p) != p {
		return false
	}
	person := filepath.Dir(p)
	return generationName.MatchString(filepath.Base(p)) && generationName.MatchString(filepath.Base(person)) &&
		filepath.Base(filepath.Dir(person)) == ".packs"
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
	if s.Role != "" {
		return s.validateRole()
	}
	if s.Packs != "" && !validPacks(s.Packs) {
		return fmt.Errorf("packs %q is not a pack generation", s.Packs)
	}
	if s.Machine != "" {
		if !filepath.IsAbs(s.Machine) || filepath.Clean(s.Machine) != s.Machine || !strings.HasSuffix(s.Machine, ".sqfs") {
			return fmt.Errorf("machine device %q is not a clean absolute path to a .sqfs", s.Machine)
		}
		if s.Kept || s.Control || s.Terminal || s.Reach != pool.ReachRelay {
			return errors.New("a machine's space is a relay space with no kept home, control channel or terminal")
		}
	}
	if s.Kept {
		if err := (home.Kept{Root: s.HomeRoot, First: s.UID, Last: s.UID}).Validate(s.Home, s.UID); err != nil {
			return err
		}
	} else if err := home.Validate(s.HomeRoot, s.Home, s.UID); err != nil {
		return err
	}
	if s.Reach != pool.ReachRelay && s.Reach != pool.ReachRouted {
		return errors.New("reach must be relay or routed")
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
	// spawn, since the spawns of one kept home share its uid. Either is in
	// its role's group in work, or at the namespace root.
	_, name, ok := cgroup.SplitPath(s.Cgroup)
	if !ok || (name != cgroup.Name(s.UID) && !(s.Kept && strings.HasPrefix(name, cgroup.SpawnName("")))) {
		return fmt.Errorf("cgroup %q is not the group of uid %d", s.Cgroup, s.UID)
	}
	return nil
}

// validateRole checks a role's spec: its run folder under the run root, a
// routed space with its channel and nothing a spawn is given, a command
// and an environment of plain names and values, and its role's leaf.
func (s Spec) validateRole() error {
	if !cgroup.ValidRoleName(s.Role) {
		return fmt.Errorf("role %q", s.Role)
	}
	if !filepath.IsAbs(s.HomeRoot) || filepath.Clean(s.HomeRoot) != s.HomeRoot || s.Home != filepath.Join(s.HomeRoot, s.Role) {
		return fmt.Errorf("the run folder %q is not %s under the run root %q", s.Home, s.Role, s.HomeRoot)
	}
	if s.Kept || s.Terminal || !s.Control || s.Reach != pool.ReachRouted || s.Limits != (protocol.Limits{}) || s.Packs != "" {
		return errors.New("a role's space is routed, holds its channel, and has no kept home, terminal, limits or packs of its own")
	}
	if err := protocol.ValidateCommand(s.Argv, nil); err != nil {
		return err
	}
	for name, value := range s.Env {
		if name == "" || strings.ContainsAny(name, "=\x00") || strings.ContainsRune(value, 0) {
			return fmt.Errorf("env %q is not a plain name and value", name)
		}
	}
	if s.Cgroup != cgroup.RoleLeaf(s.Role) {
		return fmt.Errorf("cgroup %q is not role %s's leaf", s.Cgroup, s.Role)
	}
	return nil
}

// SearchPath is the spawn's PATH. A kept program's is CyfrBin, then the
// home's .local/bin, where what the person installs goes, then Path; a
// role's is its own environment's; every other spawn's is Path.
func (s Spec) SearchPath() string {
	if s.Role != "" {
		return s.Env["PATH"]
	}
	if s.Kept {
		return CyfrBin + ":" + filepath.Join(s.Home, ".local", "bin") + ":" + Path
	}
	return Path
}

// Environ is the complete environment of the spawned process: HOME, USER,
// LOGNAME, TMPDIR (the space's own /tmp) and PATH (SearchPath), then the spec's
// own variables, sorted by name. A kept program is also given npm's prefix
// and XDG_BIN_HOME in the home's .local, so what it installs lands on its
// PATH, unless its own variables name them. Nothing is inherited.
func (s Spec) Environ() []string {
	var env []string
	if s.Role == "" {
		env = []string{
			"HOME=" + s.Home,
			"LOGNAME=" + s.User,
			"PATH=" + s.SearchPath(),
			"TMPDIR=/tmp",
			"USER=" + s.User,
		}
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
