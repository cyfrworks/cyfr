# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Compendium.ReleaseDigestTest do
  use ExUnit.Case, async: true

  alias Compendium.ReleaseDigest

  doctest Compendium.ReleaseDigest

  @artifact "sha256:0123456789abcdef"

  defp compute!(manifest) do
    {:ok, digest} = ReleaseDigest.compute(@artifact, manifest)
    digest
  end

  describe "compute/2" do
    test "binds the artifact digest" do
      assert compute!(nil) != elem(ReleaseDigest.compute("sha256:other", nil), 1)
      assert compute!(nil) == compute!(%{})
      assert "sha256:" <> hex = compute!(nil)
      assert String.length(hex) == 64
    end

    test "presentational manifest fields never change the identity" do
      base = %{"caps" => %{"egress" => %{"domains" => ["a.example"]}}}

      described =
        Map.merge(base, %{
          "description" => "A different description",
          "schema" => %{"input" => %{}},
          "examples" => [%{"name" => "one"}],
          "tags" => ["x"],
          "name" => "thing",
          "version" => "1.0.0"
        })

      assert compute!(base) == compute!(described)
    end

    test "every security block changes the identity" do
      blocks = %{
        "dependencies" => %{"static" => [%{"ref" => "catalyst:local.http"}]},
        "needs" => %{
          "api_key" => %{"type" => "api_key:anthropic.com", "reason" => "to call the API"}
        },
        "caps" => %{"egress" => %{"domains" => ["a.example"]}}
      }

      for {block, value} <- blocks do
        assert compute!(%{}) != compute!(%{block => value}),
               "#{block} did not affect the release digest"
      end
    end

    test "a widened capability changes the identity even at identical bytes" do
      narrow = %{"caps" => %{"egress" => %{"domains" => ["a.example"]}}}
      wide = %{"caps" => %{"egress" => %{"domains" => ["*"]}}}

      assert compute!(narrow) != compute!(wide)
    end

    test "key order and absent-vs-empty are handled canonically" do
      a = %{"caps" => %{"limits" => %{"timeout" => "1m"}}, "needs" => %{}}
      b = %{"needs" => %{}, "caps" => %{"limits" => %{"timeout" => "1m"}}}

      assert compute!(a) == compute!(b)
      # Absent block and empty-map block are deliberately distinct: an empty
      # `needs` block is a declaration, not silence.
      assert compute!(%{}) != compute!(%{"needs" => %{}})
    end

    test "floats in a security block are refused, floats elsewhere are ignored" do
      assert {:error, {:invalid_manifest, {:invalid_value, ["caps", "t"], :float_not_permitted}}} =
               ReleaseDigest.compute(@artifact, %{"caps" => %{"t" => 1.5}})

      # Presentational floats never reach the canonicalizer.
      assert {:ok, _} = ReleaseDigest.compute(@artifact, %{"examples" => [%{"score" => 0.5}]})
    end

    test "a nil inside a security block is refused" do
      assert {:error,
              {:invalid_manifest, {:invalid_value, ["needs", "google"], :nil_not_permitted}}} =
               ReleaseDigest.compute(@artifact, %{"needs" => %{"google" => nil}})
    end

    test "rejects a missing or malformed artifact digest" do
      assert {:error, {:invalid_artifact_digest, nil}} = ReleaseDigest.compute(nil, %{})
      assert {:error, {:invalid_artifact_digest, ""}} = ReleaseDigest.compute("", %{})
      assert {:error, {:invalid_manifest, "nope"}} = ReleaseDigest.compute(@artifact, "nope")
    end
  end

  # ============================================================================
  # The refusal must be vacuous for everything we actually ship
  # ============================================================================

  describe "bundled and vendored manifests" do
    @manifests Path.wildcard(
                 Path.join([__DIR__, "../../../../seed/components/**/cyfr-manifest.json"])
               )

    test "every checked-in manifest yields a release digest" do
      # If this fails, some real manifest carries a float or null in a
      # security block and would be unpublishable — fix the manifest (or the
      # subset), never loosen the canonicalizer.
      assert @manifests != [], "no manifests found — check the fixture glob"

      for path <- @manifests do
        manifest = path |> File.read!() |> Jason.decode!()

        assert {:ok, "sha256:" <> _} = ReleaseDigest.compute("sha256:test", manifest),
               "#{path} cannot produce a release digest"
      end
    end

    test "the digest is stable across re-encodings of the same manifest" do
      for path <- Enum.take(@manifests, 25) do
        manifest = path |> File.read!() |> Jason.decode!()
        round_tripped = manifest |> Jason.encode!() |> Jason.decode!()

        assert ReleaseDigest.compute("sha256:test", manifest) ==
                 ReleaseDigest.compute("sha256:test", round_tripped)
      end
    end
  end
end
