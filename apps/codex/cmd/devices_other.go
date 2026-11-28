// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !linux

package cmd

// hasDevice is false: only Linux runs a person's computer of their own.
func hasDevice(string, uint32) bool { return false }
