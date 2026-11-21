// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !linux

package cmd

import "context"

// watchSessionLock is the app's main process's own on macOS and Windows,
// which hears the system's lock and sleep and sends lock.
func watchSessionLock(context.Context, func(string)) error { return nil }
