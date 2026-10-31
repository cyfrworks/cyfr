// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// canvas-broken's working version (1.0.0), a vanilla page: it reads its own
// version from its served path, draws `broken <version>` and becomes ready.
// The versions the proof writes after it (fixture.exs) fail at validation
// or die live; this one holds, so it is what a failed validation keeps and
// what restoring the kept version brings back.
const version = new URL(import.meta.url).pathname.split("/").filter(Boolean).slice(-2)[0]
document.getElementById("root").textContent = `broken ${version}`
cyfr.ready()
