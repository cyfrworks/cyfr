// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

// noRolloutWords start the error Codex answers `thread/resume` and
// `thread/delete` with, word for word, when its folder holds no rollout of
// the thread named (0.167.0, and 0.169.0 against its own binary). They are
// Codex's words, not CYFR's: the driver reads them, and nothing looser, so
// that no other failure at a start reads as `gone`, after which the
// session is forgotten, and no other failure of a removal as the thread
// proved absent.
const noRolloutWords = "no rollout found for thread id"
