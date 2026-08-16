# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# The cyfr↔opus execution flow (tagged `:requires_opus`) is the product's core
# path and ships as one BEAM. Exclude those tests only when opus is not part of
# the loaded application set — i.e. when this suite is run scoped to apps/cyfr
# alone. An umbrella-root run (local or CI) has opus loaded and includes them.
#
# `:requires_opus_modules` is the weaker requirement: the test only calls into
# opus MODULES (tool providers) without needing the running app — e.g. the
# tool-classification and consent-shape tests that enumerate every provider's
# actions. Those run whenever the opus code is loadable (a fresh umbrella
# compile leaves it loaded) and are excluded when it isn't (a cached
# app-scoped run), instead of crashing on an UndefinedFunctionError.
excludes =
  Enum.concat(
    if(is_nil(Application.spec(:opus)), do: [:requires_opus], else: []),
    if(Code.ensure_loaded?(Opus.MCP), do: [], else: [:requires_opus_modules])
  )

if excludes != [], do: ExUnit.configure(exclude: excludes)

# The tmp storage roots configured in config/test.exs.
for key <- [:base_path, :components_path] do
  File.mkdir_p!(Application.fetch_env!(:cyfr, key))
end

# The athanor rows the fixtures name by hand, committed once for the run.
Sanctum.TestContext.seed_athanors!()

ExUnit.start()
