// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

import { defineConfig } from "vite";

export default defineConfig({
  base: "./",
  build: {
    outDir: "dist",
    emptyOutDir: true,
    target: "es2022",
    // One bundle, so a warm open's assets are a known, small set.
    chunkSizeWarningLimit: 8192,
  },
});
