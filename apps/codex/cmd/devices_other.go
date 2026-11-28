// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !linux

package cmd

// hasDevices is false: only Linux runs a person's computer of their own.
func hasDevices() bool { return false }
