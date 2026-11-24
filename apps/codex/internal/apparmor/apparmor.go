// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package apparmor holds the AppArmor profile cyfr-locus, which every Locus
// container runs under on a host with AppArmor, built into cyfr: the bytes
// root writes to /etc/apparmor.d/cyfr-locus are this release's own, never a
// file a project's writer could change.
package apparmor

import _ "embed"

// Profile is the profile's text.
//
//go:embed cyfr-locus
var Profile []byte

// Target is where the host keeps the profile, which it loads from there at
// every boot. It is the machine's, shared by every CYFR on it.
const Target = "/etc/apparmor.d/cyfr-locus"
