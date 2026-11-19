// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build releaseproof

// The Compose proof's update cases (tests/compose-proof/run.sh) build cyfr
// with this tag: a candidate has no release on GitHub, so `cyfr update`
// reads each release's manifest and scaffold from a folder fixed at the
// build, never from the network. The release refuses every binary built
// with a tag or holding this file (scripts/ci/release-binary-check.sh, a
// post hook of each build in .goreleaser.yml), and a build without the tag
// fetches every release verified (release_proof_off_test.go).

package cmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/cyfr/codex/internal/release"
	"github.com/cyfr/codex/internal/scaffold"
)

// releaseProofMarker is in every binary this file is built into and in no
// other source: scripts/ci/release-binary-check.sh, which the release runs
// on each binary it publishes, refuses one that holds it.
const releaseProofMarker = "cyfr release proof build: it reads releases from a local folder, unsigned"

// proofReleases is the folder of the releases this build updates between,
// set at the build (-ldflags -X): VERSION/release.json and
// VERSION/cyfr-scaffold.tar.gz for each, unsigned.
var proofReleases string

func init() {
	if proofReleases == "" {
		panic(releaseProofMarker + "; a releaseproof build names its releases folder with -ldflags -X github.com/cyfr/codex/cmd.proofReleases=DIR")
	}
	fetchManifest = func(_ context.Context, version string) (*release.Manifest, error) {
		data, err := os.ReadFile(filepath.Join(proofReleases, version, "release.json"))
		if err != nil {
			return nil, fmt.Errorf("the proof's release %s: %w", version, err)
		}
		return release.ParseManifest(data)
	}
	fetchScaffold = func(version string) (scaffoldRelease, error) {
		data, err := os.ReadFile(filepath.Join(proofReleases, version, "cyfr-scaffold.tar.gz"))
		if err != nil {
			return nil, fmt.Errorf("the proof's scaffold %s: %w", version, err)
		}
		r, err := scaffold.Parse(data)
		if err != nil {
			return nil, err
		}
		return r, nil
	}
}
