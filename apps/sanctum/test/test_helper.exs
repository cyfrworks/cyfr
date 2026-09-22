# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

# Independent app suites have no Host. Preserve an umbrella boot's identity.
try do
  Cyfr.Boot.id()
rescue
  Cyfr.Boot.NotInitializedError -> Cyfr.Boot.mint()
end

# Owned by the test-runner process so it outlives every test and no two
# tests race to create it. `Cyfr.Test.SourceTree` fills it lazily.
Cyfr.Test.SourceTree.ensure_table()

# The throwaway storage roots Arca's configuration names, removed after
# the run.
base_path = Application.fetch_env!(:arca, :base_path)
File.mkdir_p!(base_path)

seed_path = Application.fetch_env!(:arca, :seed_path)
File.mkdir_p!(Path.join(seed_path, "components"))

# The cap port every capped write asks. `Cyfr.Application` writes it at
# boot, and no host boots here, so the suite installs the one
# implementation itself — before the first test that writes a tenant byte.
Cyfr.Caps.install!(Sanctum.Tenancy.Caps)

# Port 5's wiring: the overlaid roots' unit boundaries are the component
# domain's to spell. An umbrella run is configured with that domain's
# locators and keeps them; this build has no component domain, and takes
# the persistence suite's stand-ins.
if Application.get_env(:arca, :overlay_locators) in [nil, %{}] do
  Application.put_env(:arca, :overlay_locators, Arca.Test.UnitLocator.locators())
end

Arca.Storage.install_locators!()

# The one redaction vocabulary, which the host feeds Phoenix at boot.
# Nothing boots here, so the suite does what the boot does, before any
# test reads a filtered parameter.
Application.put_env(:phoenix, :filter_parameters, Cyfr.Sanitizer.filter_parameters())

# A suite database built from a different schema would run stale, since
# the baseline still reads as applied; refuse it before any test touches it.
Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, &Arca.SchemaFingerprint.verify!/0)

# The athanor rows the fixtures name by hand, committed once for the run.
Sanctum.TestContext.seed_athanors!()

ExUnit.after_suite(fn _ ->
  File.rm_rf(base_path)
  File.rm_rf(seed_path)
end)

ExUnit.start()
