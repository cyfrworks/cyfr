// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !linux && !darwin && !windows

package cmd

// systemAppRoad is none: the CYFR app has no installer for this system.
func systemAppRoad() appRoad { return nil }
