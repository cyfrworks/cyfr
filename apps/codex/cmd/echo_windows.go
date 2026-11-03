// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

// echoOff does nothing on Windows, where cyfr login holds no device and
// no secret is typed.
func echoOff() func() { return func() {} }
