# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# The build tests shell out to a real toolchain: `cargo component` for Rust
# components, `npm`/`node` for tinctures and for every test that needs a
# build to run at all. Tagged tests are excluded when the tool is not on
# PATH, so a machine without the Rust or Node toolchain runs the rest of
# the suite instead of failing tests that were never about the code under
# test. CI installs both, so nothing is skipped there.
excludes =
  Enum.concat(
    if(System.find_executable("cargo-component"), do: [], else: [:requires_cargo_component]),
    if(System.find_executable("node"), do: [], else: [:requires_node])
  )

if excludes != [] do
  IO.puts("locus: skipping #{inspect(excludes)} — toolchain not found on PATH")
  ExUnit.configure(exclude: excludes)
end

ExUnit.start()
