// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build releaseproof

// The Compose proof's update cases (tests/compose-proof/run.sh), the
// update proofs (tests/update-proof/run.sh,
// tests/desktop-proof/native/update.sh) and the install proof
// (tests/install-screen-proof) build cyfr with this tag: a candidate has
// no release on GitHub, so `cyfr update` reads each release's manifest,
// scaffold and app installer, and `cyfr init` its release's scaffold, from
// a folder fixed at the build, never from the network. The release refuses every binary built
// with a tag or holding this file (scripts/ci/release-binary-check.sh, a
// post hook of each build in .goreleaser.yml), and a build without the tag
// fetches every release verified (release_proof_off_test.go).

package cmd

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/cyfr/codex/internal/release"
	"github.com/cyfr/codex/internal/scaffold"
)

// releaseProofMarker is in every binary this file is built into and in no
// other source: scripts/ci/release-binary-check.sh, which the release runs
// on each binary it publishes, refuses one that holds it.
const releaseProofMarker = "cyfr release proof build: it reads releases from a local folder, unsigned"

// proofReleases is the folder of the releases this build updates between,
// set at the build (-ldflags -X): VERSION/release.json,
// VERSION/cyfr-scaffold.tar.gz, and the app's installers by their release
// names with VERSION/checksums.txt naming their sums, for each, unsigned;
// and the file latest, naming the newest release, which none is without.
var proofReleases string

func init() {
	if proofReleases == "" {
		panic(releaseProofMarker + "; a releaseproof build names its releases folder with -ldflags -X github.com/cyfr/codex/cmd.proofReleases=DIR")
	}
	latestRelease = func(context.Context) (string, error) {
		data, err := os.ReadFile(filepath.Join(proofReleases, "latest"))
		if errors.Is(err, fs.ErrNotExist) {
			return "", release.ErrNoRelease
		}
		if err != nil {
			return "", fmt.Errorf("the proof's newest release: %w", err)
		}
		return strings.TrimSpace(string(data)), nil
	}
	fetchManifest = func(_ context.Context, version string) (*release.Manifest, error) {
		data, err := os.ReadFile(filepath.Join(proofReleases, version, "release.json"))
		if err != nil {
			return nil, fmt.Errorf("the proof's release %s: %w", version, err)
		}
		return release.ParseManifest(data)
	}
	appPackageSum = func(_ context.Context, version, goos, goarch string) (string, error) {
		name := release.PackageName(version, goos, goarch)
		data, err := os.ReadFile(filepath.Join(proofReleases, version, "checksums.txt"))
		if err != nil {
			return "", fmt.Errorf("the proof's checksums %s: %w", version, err)
		}
		for _, line := range strings.Split(string(data), "\n") {
			if fields := strings.Fields(line); len(fields) == 2 && fields[1] == name {
				return fields[0], nil
			}
		}
		return "", fmt.Errorf("%w: the proof's checksums %s name no %s", release.ErrUnverified, version, name)
	}
	fetchAppPackage = func(_ context.Context, version, goos, goarch, want string) ([]byte, error) {
		name := release.PackageName(version, goos, goarch)
		data, err := os.ReadFile(filepath.Join(proofReleases, version, name))
		if err != nil {
			return nil, fmt.Errorf("the proof's installer %s: %w", name, err)
		}
		if sum := sha256.Sum256(data); hex.EncodeToString(sum[:]) != want {
			return nil, fmt.Errorf("%w: the proof's %s is not the sum its checksums name", release.ErrUnverified, name)
		}
		return data, nil
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
	// cyfr init lays the scaffold down as scaffold.Download does a fetched
	// one, keeping every file that exists.
	downloadScaffold = func(version string) error {
		r, err := fetchScaffold(version)
		if err != nil {
			return err
		}
		return r.Write(false)
	}
}
