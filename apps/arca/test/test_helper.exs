# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# MinIO backs the :s3_integration suites; each runs only when selected.
ExUnit.configure(exclude: [:s3_integration])

# Owned by the test-runner process so it outlives every test and no two
# tests race to create it. `Cyfr.Test.SourceTree` fills it lazily.
Cyfr.Test.SourceTree.ensure_table()

# The throwaway storage roots `config/config.exs` names: the tenant root
# and a seed tree with an empty bundle, both removed after the run.
base_path = Application.fetch_env!(:arca, :base_path)
File.mkdir_p!(base_path)

seed_path = Application.fetch_env!(:arca, :seed_path)
File.mkdir_p!(Path.join(seed_path, "components"))

# The cap port every capped write asks. Nothing above this app implements
# it here, so the suite installs its own admitting double — the ceilings
# are the tenancy domain's, and a case about a refusal needs that domain.
Cyfr.Caps.install!(Arca.Test.Caps)

# Port 5's wiring, likewise: the overlaid roots' unit boundaries are the
# component domain's to spell. An umbrella run is configured with that
# domain's locators and keeps them; a build of the contracts and this app
# alone has no component domain, and takes the suite's stand-ins.
if Application.get_env(:arca, :overlay_locators) in [nil, %{}] do
  Application.put_env(:arca, :overlay_locators, Arca.Test.UnitLocator.locators())
end

Arca.Storage.install_locators!()

# A suite database built from a different schema would run stale, since
# the baseline still reads as applied; refuse it before any test touches it.
Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, &Arca.SchemaFingerprint.verify!/0)

# The athanor rows the fixtures name by hand, committed once for the run.
Arca.Test.Actor.seed_athanors!()

ExUnit.after_suite(fn _ ->
  File.rm_rf(base_path)
  File.rm_rf(seed_path)
end)

ExUnit.start()
