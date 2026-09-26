# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

# Independent app suites have no Host. Preserve an umbrella boot's identity.
try do
  Prima.Boot.id()
rescue
  Prima.Boot.NotInitializedError -> Prima.Boot.mint()
end

# Owned by the test-runner process so it outlives every test and no two
# tests race to create it. `Prima.Test.SourceTree` fills it lazily.
Prima.Test.SourceTree.ensure_table()

# The throwaway storage roots Arca's configuration names, removed after
# the run.
base_path = Application.fetch_env!(:arca, :base_path)
File.mkdir_p!(base_path)

seed_path = Application.fetch_env!(:arca, :seed_path)
File.mkdir_p!(Path.join(seed_path, "components"))

# The cap port every capped write asks. `Cyfr.Application` writes it at
# boot, and no host boots here, so the suite installs the one
# implementation itself — before the first test that writes a tenant byte.
Prima.Caps.install!(Sanctum.Tenancy.Caps)

# The platform settings Sanctum reads (the caps, the session idle timeout,
# the webhook skew window). The host installs every setting's declaration
# at its boot; with none booted here, the suite installs these itself.
Sanctum.Test.Settings.install!()

# The unit-locator port: the overlaid roots' unit boundaries are the
# component domain's to spell. An umbrella run's boot installed that
# domain's locators and keeps them; this build has no component domain,
# and installs the persistence suite's stand-ins.
try do
  Arca.Storage.UnitLocator.impl!()
rescue
  Arca.Storage.UnitLocator.NotInstalledError ->
    Arca.Storage.UnitLocator.install!(Arca.Test.UnitLocator.locators())
end

# The one redaction vocabulary, which the host feeds Phoenix at boot.
# Nothing boots here, so the suite does what the boot does, before any
# test reads a filtered parameter.
Application.put_env(:phoenix, :filter_parameters, Prima.Sanitizer.filter_parameters())

# A suite database built from a different schema would run stale, since
# the baseline still reads as applied; refuse it before any test touches it.
Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, &Arca.SchemaFingerprint.verify!/0)

# Every connection is lent by a test's sandbox owner, and never taken by a
# process on its own: in the pool's default automatic mode a process no
# test allowed (the decision log's writer, spawned from an asynchronous
# test) is handed a real connection and its rows commit for the tests
# after it to see.
Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, :manual)

# The athanor rows the fixtures name by hand, committed once for the run.
Sanctum.TestContext.seed_athanors!()

ExUnit.after_suite(fn _ ->
  File.rm_rf(base_path)
  File.rm_rf(seed_path)
end)

ExUnit.start()
