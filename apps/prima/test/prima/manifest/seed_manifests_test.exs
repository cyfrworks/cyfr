# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Manifest.SeedManifestsTest do
  @moduledoc """
  Every manifest CYFR ships under `seed/components/` parses under the one
  manifest grammar, attaching and disclosing included: a shipped version
  is immutable, so a need its manifest declares without `attach` is read
  as disclose-only, with no legacy branch, and no shipped manifest is
  refused by a rule written after it.
  """

  use ExUnit.Case, async: true

  alias Prima.Manifest
  alias Prima.Manifest.{Caps, Needs, Provides}

  @seed Path.expand("../../../../../seed/components", __DIR__)
  @manifests @seed |> Path.join("**/cyfr-manifest.json") |> Path.wildcard() |> Enum.sort()

  for path <- @manifests, do: @external_resource(path)

  # The storage boundary's guest-scope predicate is the caller's; the
  # shipped manifests ask `data/` alone.
  defp guest_path?(path), do: path == "data" or String.starts_with?(path, "data/")

  test "the seed holds the shipped manifests" do
    assert length(@manifests) >= 14
    assert Enum.any?(@manifests, &String.contains?(&1, "/catalysts/local/openai/"))
  end

  for path <- @manifests do
    @path path
    @relative Path.relative_to(path, Path.expand("../..", @seed))

    test "#{@relative} parses under the final grammar" do
      manifest = @path |> File.read!() |> Jason.decode!()

      assert Manifest.validate(manifest, &guest_path?/1) == :ok

      assert Caps.from_manifest(manifest, &guest_path?/1) != nil or
               not Map.has_key?(manifest, "caps")

      assert Provides.validate(manifest) == :ok

      for need <- Needs.from_manifest(manifest) || [] do
        # A shipped need that names no attach rule is disclose-only.
        if not Map.has_key?(manifest["needs"][need.name], "attach") do
          assert Needs.disclose_only?(need), need.name
        end
      end
    end
  end

  test "the 1.3.x model catalysts' keys are disclose-only needs" do
    needs =
      @manifests
      |> Enum.filter(&String.contains?(&1, "/1.3."))
      |> Enum.flat_map(fn path ->
        path |> File.read!() |> Jason.decode!() |> Needs.from_manifest()
      end)

    assert length(needs) >= 5
    assert Enum.all?(needs, &(&1.kind == "api_key" and Needs.disclose_only?(&1)))
  end
end
