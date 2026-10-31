// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package install prepares the machine CYFR runs on: it observes what the
// system already has, decides what is missing against one policy, shows
// the changes, and applies them through a fixed root entry
// (`cyfr internal install-apply`) that accepts only the actions this
// package defines.
//
// policy.json is the one definition of the supported system and its
// packages. scripts/generate-install-policy.py writes the install script's
// copy of it, and tests/fixtures/install_prerequisites.json holds the
// decisions both sides make on the same facts.
package install

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"slices"
	"time"
)

//go:embed policy.json
var policyJSON []byte

// Policy is policy.json: the system automatic preparation supports and
// what it installs there.
type Policy struct {
	Version int `json:"version"`
	System  struct {
		ID            string   `json:"id"`
		VersionID     string   `json:"version_id"`
		Codename      string   `json:"codename"`
		Name          string   `json:"name"`
		Architectures []string `json:"architectures"`
	} `json:"system"`
	Universe struct {
		Component string `json:"component"`
		Command   string `json:"command"`
	} `json:"universe"`
	Bootstrap []struct {
		Package   string   `json:"package"`
		Installed string   `json:"installed,omitempty"`
		Commands  []string `json:"commands,omitempty"`
		Universe  bool     `json:"universe"`
	} `json:"bootstrap"`
	Docker struct {
		Packages []struct {
			Package  string `json:"package"`
			Universe bool   `json:"universe"`
		} `json:"packages"`
		MinimumMajor int    `json:"minimum_major"`
		Group        string `json:"group"`
		Service      string `json:"service"`
		Endpoint     string `json:"endpoint"`
	} `json:"docker"`
	InstallPath string `json:"install_path"`
	Lock        struct {
		Path    string `json:"path"`
		Seconds int    `json:"seconds"`
	} `json:"lock"`
}

// Load answers the embedded policy.
func Load() Policy {
	var p Policy
	if err := json.Unmarshal(policyJSON, &p); err != nil {
		panic(fmt.Sprintf("install: policy.json does not parse: %v", err))
	}
	return p
}

// LockWait is how long each of the three locks is waited for: the
// machine-wide install lock, apt's package-list lock and dpkg's lock.
func (p Policy) LockWait() time.Duration {
	return time.Duration(p.Lock.Seconds) * time.Second
}

// Supports reports whether automatic preparation runs on s.
func (p Policy) Supports(s System) bool {
	return s.ID == p.System.ID && s.VersionID == p.System.VersionID && slices.Contains(p.System.Architectures, s.Arch)
}

// dockerPackage reports whether name is one of the Docker packages the
// root entry may install, and whether it comes from universe.
func (p Policy) dockerPackage(name string) (known, universe bool) {
	for _, pkg := range p.Docker.Packages {
		if pkg.Package == name {
			return true, pkg.Universe
		}
	}
	return false, false
}
