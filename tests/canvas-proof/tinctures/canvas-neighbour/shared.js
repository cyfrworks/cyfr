// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
//
// canvas-neighbour's script at a same-site path, a module with no effect of
// its own. Its page imports it; a canvas beside it may not import it from
// here. The canvas proof also places these bytes in canvas-probe's version
// (tests/canvas-proof/run.sh), where the probe's module imports them
// statically as its own sibling file.
export const SHARED = "canvas-neighbour/shared.js"
