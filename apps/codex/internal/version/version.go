// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package version carries the CLI's build identity, injected via -ldflags.
package version

var (
	// Version is the release version, e.g. "0.5.8". "dev" for local builds.
	Version = "dev"
	// Commit is the short commit hash the binary was built from.
	Commit = "none"
	// Date is the build timestamp.
	Date = "unknown"
)
