// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

// noTranscriptWords start the error Claude Code writes, word for word, when
// it is started to resume a session its folder holds no transcript of
// (2.1.318, and 2.1.323 in the live probe). They are the harness's words,
// not CYFR's: the driver reads them, and nothing looser, so that no other
// failure at a start reads as `gone`, after which the session is
// forgotten.
const noTranscriptWords = "No conversation found with session ID"
