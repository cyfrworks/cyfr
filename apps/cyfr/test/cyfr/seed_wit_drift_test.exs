# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.SeedWitDriftTest do
  @moduledoc """
  Every WIT file a seed component vendors matches the canonical `wit/`
  tree — the ABI is the host's, not the component's.

  Checks source-local seed WIT matches Compendium.WITSource.
  Locus.Builder uses source-local WIT when present.

  Two rules, matching what the copies actually are:

    * `deps/**/*.wit` — byte-identical to the canonical file (modulo the
      canonical tree's SPDX header, which seed copies do not carry);
    * `world.wit` — a SUBSET: a seed world deliberately imports only what
      its component uses, so every `import` line must exist in the
      canonical world for its type, but not vice versa.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  defp canonical_body(rel) do
    [@root, "wit", rel]
    |> Path.join()
    |> File.read!()
    |> String.split("\n")
    # SPDX + Copyright + blank
    |> Enum.drop(3)
    |> Enum.join("\n")
  end

  defp seed_wit_files do
    [@root, "seed/components/*/local/*/*/src/wit/**/*.wit"]
    |> Path.join()
    |> Cyfr.Test.SourceTree.files!()
  end

  # "catalysts" | "formulas" | ... from the seed path → the canonical
  # per-type wit directory ("catalyst", "formula", ...).
  defp wit_type(path) do
    path
    |> Path.relative_to(Path.join(@root, "seed/components"))
    |> Path.split()
    |> hd()
    |> String.trim_trailing("s")
  end

  test "vendored deps/*.wit are byte-identical to the canonical tree" do
    offenders =
      for path <- seed_wit_files(),
          String.contains?(path, "/deps/"),
          rel_in_wit = Path.join(wit_type(path), deps_rel(path)),
          File.read!(path) != canonical_body(rel_in_wit) do
        Path.relative_to(path, @root)
      end

    assert offenders == [],
           "seed-vendored WIT drifted from wit/: #{inspect(offenders)} — " <>
             "copy the canonical file (sans SPDX header); the ABI is the host's"
  end

  test "vendored world.wit imports are a subset of the canonical world's" do
    offenders =
      for path <- seed_wit_files(),
          Path.basename(path) == "world.wit",
          canonical = canonical_body(Path.join(wit_type(path), "world.wit")),
          import_line <- imports(File.read!(path)),
          not String.contains?(canonical, import_line) do
        "#{Path.relative_to(path, @root)}: #{import_line}"
      end

    assert offenders == [],
           "seed world.wit imports absent from the canonical world: #{inspect(offenders)}"
  end

  defp deps_rel(path) do
    [_, after_deps] = String.split(path, "/src/wit/", parts: 2)
    after_deps
  end

  defp imports(world_source) do
    world_source
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "import "))
  end
end
