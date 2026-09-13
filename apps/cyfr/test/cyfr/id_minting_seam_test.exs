# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.IdMintingSeamTest do
  @moduledoc """
  Mechanical guard for the one spelling of row-id minting:
  `Cyfr.UUID7.generate_id("<prefix>")`. Style follows
  `Arca.DbRescueSeamTest`: read the sources, compare literals — a failure
  means a bare `Cyfr.UUID7.generate()` or `Ecto.UUID.generate()` crept
  into a mint site; give the id its prefix instead, so every id in the
  system says what it names.

  Scans cyfr, opus and locus for raw id generation. Only `Cyfr.UUID7`
  may call the underlying UUID generator directly.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  # Bare (unprefixed) generator calls. `generate_id(` never matches: the
  # pattern requires the empty argument list right after `generate`.
  @bare_pattern ~r/\b(?:Cyfr\.UUID7|Ecto\.UUID)\.generate\(\)/

  # Files allowed to keep a bare call, with how many sites and why.
  @allowed %{
    # The generator's own home: `generate_id/1` composes the prefix around
    # the raw UUID; the moduledoc and a doctest show the raw form.
    "apps/cyfr/lib/cyfr/uuid7.ex" => 2
  }

  test "bare UUID minting exists only at the enumerated exceptions" do
    found =
      for dir <- ~w(apps/cyfr/lib apps/opus/lib apps/locus/lib),
          file <- Path.wildcard(Path.join([@root, dir, "**/*.ex"])),
          count = length(Regex.scan(@bare_pattern, Cyfr.Test.SourceTree.read(file))),
          count > 0,
          into: %{} do
        {Path.relative_to(file, @root), count}
      end

    new_sites =
      for {file, count} <- found,
          count > Map.get(@allowed, file, 0),
          do: {file, count - Map.get(@allowed, file, 0)}

    assert new_sites == [],
           """
           Bare `Cyfr.UUID7.generate()` / `Ecto.UUID.generate()` outside
           this test's allowlist:

           #{Enum.map_join(Enum.sort(new_sites), "\n", fn {f, n} -> "  #{f} (+#{n})" end)}

           Mint row ids through `Cyfr.UUID7.generate_id("<prefix>")` so
           every id carries the kind it names. Only a site that genuinely
           needs an unprefixed UUID belongs in the allowlist above, with a
           comment saying why.
           """

    stale = for {file, count} <- @allowed, Map.get(found, file, 0) != count, do: file

    assert stale == [],
           "stale allowlist entries (bare-call count changed — update the " <>
             "roster and its comments): #{inspect(Enum.sort(stale))}"
  end
end
