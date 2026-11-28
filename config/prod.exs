# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
import Config

# The pinned wasm-tools every component is validated with
# (`Prima.ComponentFeatures`), where the cyfr image installs it
# (scripts/wasm-tools.sh); the locus image validates nothing, its runner's
# engine refusing a refused feature at compile. `CYFR_WASM_TOOLS` names
# another for a cyfr release run outside its image.
config :prima, :wasm_tools, "/usr/local/bin/wasm-tools"

config :cyfr, CyfrWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"
