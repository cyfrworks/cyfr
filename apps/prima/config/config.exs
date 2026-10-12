# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# Standalone contract compilation and tests need no control-plane runtime
# configuration. Umbrella builds supply the root application's config.
import Config

# The checkout's pinned wasm-tools (scripts/wasm-tools.sh install _tools),
# which an island run holds at its own root.
config :prima, :wasm_tools, Path.expand("../../../_tools/wasm-tools", __DIR__)
