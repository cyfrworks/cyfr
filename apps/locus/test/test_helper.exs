# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# The compile tests shell out to a real toolchain: `cargo component` for Rust
# components, `npm`/`node` for tinctures. Tagged tests are excluded when the
# tool is not on PATH, so a machine without the Rust or Node toolchain runs
# the rest of the suite instead of failing tests that were never about the
# code under test. CI installs both, so nothing is skipped there.
excludes =
  Enum.concat(
    if(System.find_executable("cargo-component"), do: [], else: [:requires_cargo_component]),
    if(System.find_executable("node"), do: [], else: [:requires_node])
  )

if excludes != [] do
  IO.puts("locus: skipping #{inspect(excludes)} — toolchain not found on PATH")
  ExUnit.configure(exclude: excludes)
end

# The cyfr dep is runtime: false (the builder release loads it without
# starting it), so the test run starts it here explicitly.
{:ok, _} = Application.ensure_all_started(:cyfr)

# A suite database built from a different schema would run stale, since the
# baseline still reads as applied; refuse it before any test touches it.
Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, &Arca.SchemaFingerprint.verify!/0)

ExUnit.start()
