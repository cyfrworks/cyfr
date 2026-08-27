// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package version carries the CLI's build identity, injected via -ldflags.
//
// It lives below cmd so that internal/mcp can announce the real version in
// clientInfo — cmd imports internal/mcp, so the variables cannot live in cmd
// without a cycle. A hardcoded clientInfo version once announced 0.1.0 from
// every build; the server side had the identical bug and fixed it the same
// way (see Emissary.MCP.Protocol's note).
package version

var (
	// Version is the release version, e.g. "0.5.8". "dev" for local builds.
	Version = "dev"
	// Commit is the short commit hash the binary was built from.
	Commit = "none"
	// Date is the build timestamp.
	Date = "unknown"
)
