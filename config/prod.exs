# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
import Config

# For production, require all settings to be explicit at runtime

# The pinned wasm-tools every component is validated with
# (`Prima.ComponentFeatures`), where both images install it
# (scripts/wasm-tools.sh); `CYFR_WASM_TOOLS` names another for a cyfr
# release run outside its image.
config :prima, :wasm_tools, "/usr/local/bin/wasm-tools"
