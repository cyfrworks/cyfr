# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# The cyfr↔opus execution flow (tagged `:requires_opus`) is the product's core
# path and ships as one BEAM. Exclude those tests only when opus is not part of
# the loaded application set — i.e. when this suite is run scoped to apps/cyfr
# alone. An umbrella-root run (local or CI) has opus loaded and includes them.
if is_nil(Application.spec(:opus)) do
  ExUnit.configure(exclude: [:requires_opus])
end

ExUnit.start()
