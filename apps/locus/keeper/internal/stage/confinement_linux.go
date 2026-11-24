// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package stage

import (
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"unsafe"

	"golang.org/x/sys/unix"
)

// The confinement a space's files need. Every Locus container runs with its
// system paths unmasked, since a /proc that Docker has masked lets no space
// mount its own, and on a host with AppArmor under the profile cyfr-locus,
// which denies again what Docker masked or made read-only and lets a space
// mount its files and make its own message queues. The keeper proves that
// confinement at boot by behaviour (Confinement), and every space's
// start-time proof makes a queue (probeQueue): an older or half-loaded
// profile refuses the boot, naming LoadProfile.

// ProfileLabel is the AppArmor label of a process the profile confines.
const ProfileLabel = "cyfr-locus (enforce)"

// LoadProfile is the one command that loads this release's profile on the
// host: cyfr prints the profile built into it, and root writes and loads it.
const LoadProfile = "cyfr apparmor-profile | sudo sh -c 'cat > /etc/apparmor.d/cyfr-locus && apparmor_parser -r -W /etc/apparmor.d/cyfr-locus'"

// PolicyRefusal begins a space's start-time refusal that is the host's
// policy's, which the keeper answers with that sentence alone.
const PolicyRefusal = "policy: "

//go:embed docker_paths.json
var dockerPathsJSON []byte

// DockerPaths are the paths Docker masks (a process may not read them) and
// makes read-only (it may not write them) in a container whose system paths
// it confines, for the engine the fixture names: what the profile stands in
// for. A path with a `*` is a pattern.
func DockerPaths() (masked, readonly []string, err error) {
	var paths struct {
		Masked   []string `json:"masked"`
		Readonly []string `json:"readonly"`
	}
	if err := json.Unmarshal(dockerPathsJSON, &paths); err != nil {
		return nil, nil, err
	}
	return paths.Masked, paths.Readonly, nil
}

// AppArmorLabel is this process's AppArmor label, or "" where the host
// enforces no AppArmor.
func AppArmorLabel() string {
	for _, path := range []string{"/proc/self/attr/apparmor/current", "/proc/self/attr/current"} {
		raw, err := os.ReadFile(path)
		if err == nil {
			return strings.TrimRight(string(raw), "\x00\n")
		}
	}
	return ""
}

// Confinement proves, in the keeper's own container, that the host enforces
// the profile this release needs: its label is the profile's, and every
// path Docker masks is unreadable and every path it makes read-only is
// unwritable, by the keeper, which is root there. It answers false, and
// no error, where the host enforces no AppArmor: nothing then stands in
// the masks' place.
func Confinement() (enforced bool, err error) {
	label := AppArmorLabel()
	if label == "" {
		return false, nil
	}
	if label != ProfileLabel {
		return true, fmt.Errorf("the container runs under the AppArmor label %q, not the profile cyfr-locus: start it with security_opt apparmor=cyfr-locus, as docker-compose.yml does", label)
	}
	masked, readonly, err := DockerPaths()
	if err != nil {
		return true, err
	}
	for _, pattern := range masked {
		paths, _ := filepath.Glob(pattern)
		for _, path := range paths {
			if err := refused(path, unix.O_RDONLY); err != nil {
				return true, policyFault(fmt.Sprintf("lets the container read %s, which Docker masks", path))
			}
		}
	}
	for _, path := range readonly {
		target, err := writableBelow(path)
		if err != nil {
			continue
		}
		if err := refused(target, unix.O_WRONLY); err != nil {
			return true, policyFault(fmt.Sprintf("lets the container write %s, which Docker makes read-only", target))
		}
	}
	return true, nil
}

// policyFault is the boot's refusal for a profile that is not this
// release's.
func policyFault(what string) error {
	return fmt.Errorf("the host's AppArmor profile cyfr-locus %s, so it is not this release's. Run `%s` on the host", what, LoadProfile)
}

// refused answers nil when opening path as flags is refused by policy (or
// path is absent), an error when it opens.
func refused(path string, flags int) error {
	fd, err := unix.Open(path, flags|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
	if err == nil {
		_ = unix.Close(fd)
		return errors.New("opened")
	}
	return nil
}

// writableBelow is path itself when it is a file, otherwise the first file
// below it that root's mode lets root write: the one a read-only mount
// alone would keep it from.
func writableBelow(path string) (string, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return path, nil
	}
	found := ""
	_ = filepath.WalkDir(path, func(p string, d fs.DirEntry, err error) error {
		if err != nil || found != "" {
			return fs.SkipDir
		}
		if d.Type().IsRegular() {
			if info, err := d.Info(); err == nil && info.Mode().Perm()&0o200 != 0 {
				if st, ok := info.Sys().(*unix.Stat_t); !ok || st.Uid == 0 {
					found = p
					return fs.SkipAll
				}
			}
		}
		return nil
	})
	if found == "" {
		return "", fs.ErrNotExist
	}
	return found, nil
}

// probeQueue makes a POSIX message queue in the space and removes it: the
// profile this release needs lets a space do so, an older one does not.
func probeQueue() error {
	name, _ := unix.BytePtrFromString("cyfr-locus-probe")
	fd, _, errno := unix.Syscall6(unix.SYS_MQ_OPEN, uintptr(unsafe.Pointer(name)), uintptr(unix.O_CREAT|unix.O_EXCL|unix.O_RDWR|unix.O_CLOEXEC), 0o600, 0, 0, 0)
	if errno != 0 {
		return fmt.Errorf("%sa space cannot make a POSIX message queue (%v), so the host's AppArmor profile cyfr-locus is not this release's. Run `%s` on the host", PolicyRefusal, errno, LoadProfile)
	}
	_ = unix.Close(int(fd))
	_, _, _ = unix.Syscall(unix.SYS_MQ_UNLINK, uintptr(unsafe.Pointer(name)), 0, 0)
	return nil
}
