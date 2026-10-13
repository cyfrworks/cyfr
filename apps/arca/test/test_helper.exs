# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# MinIO backs the :s3_integration suites; each runs only when selected.
# The other adapter's tests are excluded (`Arca.Test.Adapter`).
ExUnit.configure(exclude: [:s3_integration | Arca.Test.Adapter.exclusions()])

# The cap port every capped write asks. Nothing above this app implements
# it here, so the suite installs its own admitting double — the ceilings
# are the tenancy domain's, and a case about a refusal needs that domain.
#
# Only when nothing has installed one, exactly as the locators
# (`Arca.Test.SuiteBoot`). The port is one process-wide term and this file
# runs in the same VM as every other app's suite, so installing
# unconditionally replaced the real implementation `Cyfr.Application` had
# already put there: the cap refusals under `apps/cyfr/test/arca` then
# asked the double and were admitted, which is how
# `mix test apps/arca/test apps/cyfr/test/arca` found three of them failing.
try do
  Prima.Caps.impl!()
rescue
  Prima.Caps.NotInstalledError -> Prima.Caps.install!(Arca.Test.Caps)
end

# The installation mode every person mint reads. Sanctum's boot installs
# it, and no Sanctum starts here, so the suite installs the ordinary mode
# itself — only when nothing has, exactly as the ports above.
unless Arca.InstallationClaims.installed?() do
  Arca.InstallationClaims.install_mode!(:ordinary)
end

# The boot identity, the storage roots, the schema check, the sandbox mode
# and the seeded athanors, as every database app's suite has them.
Arca.Test.SuiteBoot.boot!(seed: &Arca.Test.Actor.seed_athanors!/0, stand_ins: true)

ExUnit.start()
