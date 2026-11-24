// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !releaseproof

package cmd

import (
	"reflect"
	"testing"

	"github.com/cyfr/codex/internal/release"
)

// A build without the releaseproof tag reads every release from GitHub,
// verified: its manifest, scaffold and app installer fetches are the
// signed ones, which only release_proof.go replaces.
func TestABuildWithoutTheProofTagFetchesVerifiedReleases(t *testing.T) {
	if reflect.ValueOf(fetchManifest).Pointer() != reflect.ValueOf(release.FetchManifest).Pointer() {
		t.Error("fetchManifest is not release.FetchManifest")
	}
	if reflect.ValueOf(fetchScaffold).Pointer() != reflect.ValueOf(fetchVerifiedScaffold).Pointer() {
		t.Error("fetchScaffold is not fetchVerifiedScaffold")
	}
	if reflect.ValueOf(appPackageSum).Pointer() != reflect.ValueOf(release.PackageChecksum).Pointer() {
		t.Error("appPackageSum is not release.PackageChecksum")
	}
	if reflect.ValueOf(fetchAppPackage).Pointer() != reflect.ValueOf(release.FetchPackage).Pointer() {
		t.Error("fetchAppPackage is not release.FetchPackage")
	}
}
