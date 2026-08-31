// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Shared Mac detection for keyboard-shortcut hooks (Cmd on Mac, Ctrl
// elsewhere). navigator.platform is deprecated, so prefer the User-Agent
// Client Hints platform ("macOS", "iOS") where the browser provides it
// (Chromium) and fall back to navigator.platform ("MacIntel", "iPhone",
// ...) on Safari and Firefox, which still ship it. The final "" keeps the
// regex off `undefined` in an environment that exposes neither.
export const isMac = /Mac|iP(od|hone|ad)|iOS/.test(
  navigator.userAgentData?.platform ?? navigator.platform ?? ""
)
