// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package stage

import (
	"fmt"
	"os"
	"strings"
)

// The confinement a space's files need. Every Locus container runs with its
// system paths unmasked, since a /proc that Docker has masked lets no space
// mount its own, and on a host with AppArmor under this release's profile,
// which denies again what Docker masked or made read-only and lets a space
// mount its files and make its own message queues. The profile's name
// carries its content (cyfr's package apparmor), Docker starts a container
// only under a profile the host has loaded by that name, and the keeper
// proves at boot that it runs under its image's name, enforced
// (Confinement). The profile's content is its tests' to prove.

// ProfileNameFile is where the image keeps the name of the profile its
// release runs under: cyfr's apps/codex/internal/apparmor/name.
const ProfileNameFile = "/etc/cyfr/apparmor-profile"

// LoadProfile is the one command that loads this release's profile on the
// host, its name in place of %[1]s: cyfr prints the profile built into it,
// and root writes and loads it.
const LoadProfile = "cyfr apparmor-profile | sudo sh -c 'cat > /etc/apparmor.d/%[1]s && apparmor_parser -r -W /etc/apparmor.d/%[1]s'"

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

// ProfileName is the name of the profile the file at path names, "" when
// it names none.
func ProfileName(path string) string {
	raw, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(raw))
}

// Confinement proves, in the keeper's own container, that the host
// enforces this release's profile: the container's label is the image's
// profile name, in enforce mode. It answers false, and no error, where the
// host enforces no AppArmor: nothing then stands in the masks' place.
func Confinement() (enforced bool, err error) {
	label := AppArmorLabel()
	if label == "" {
		return false, nil
	}
	name := ProfileName(ProfileNameFile)
	if name == "" {
		return true, fmt.Errorf("the image names no AppArmor profile at %s", ProfileNameFile)
	}
	if label != name+" (enforce)" {
		return true, fmt.Errorf("the container runs under the AppArmor label %q, not this release's profile %s (enforce). Run `%s` on the host, and start the stack under it as docker-compose.yml names it from .env's CYFR_LOCUS_APPARMOR, which cyfr init and cyfr update write",
			label, name, fmt.Sprintf(LoadProfile, name))
	}
	return true, nil
}
