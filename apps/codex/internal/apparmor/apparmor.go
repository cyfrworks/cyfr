// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package apparmor holds the AppArmor profile every Locus container runs
// under on a host with AppArmor, built into cyfr: the bytes root writes to
// /etc/apparmor.d are this release's own, never a file a project's writer
// could change. The profile's name carries its content (Name), so a
// machine that holds this release's name holds this release's policy.
package apparmor

import (
	"bytes"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
)

// template is the profile's text, Placeholder standing in its name's place.
//
//go:embed cyfr-locus
var template []byte

// Placeholder is the name's place in the profile's text.
const Placeholder = "cyfr-locus-000000000000"

// Name is the name of the profile whose text, Placeholder in its name's
// place, is text: cyfr-locus- and the first 12 hex digits of the text's
// SHA-256. The file name beside the profile holds this release's, for the
// image, the dev loop and CI, which read it rather than derive it.
func Name(text []byte) string {
	sum := sha256.Sum256(text)
	return "cyfr-locus-" + hex.EncodeToString(sum[:])[:12]
}

// ProfileName is this release's profile's name.
var ProfileName = Name(template)

// Profile is this release's profile as root loads it, under its name.
var Profile = bytes.ReplaceAll(template, []byte(Placeholder), []byte(ProfileName))

// Target is where the host keeps the profile named name, which it loads
// from there at every boot. It is the machine's, shared by every CYFR on
// it.
func Target(name string) string { return "/etc/apparmor.d/" + name }
