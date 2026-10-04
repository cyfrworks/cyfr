# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.SeedWitDriftTest do
  @moduledoc """
  Every WIT file a seed component vendors matches the canonical `wit/`
  tree — the ABI is the host's, not the component's.

  Checks source-local seed WIT matches Prima.WIT.
  Locus.Builder uses source-local WIT when present.

  Three rules, matching what the copies actually are:

    * `deps/**/*.wit` of each component's newest shipped version —
      byte-identical to the canonical file (modulo the canonical tree's
      SPDX header, which seed copies do not carry). A shipped version is
      immutable (CI's `seed-guards` job), so an older version keeps the
      copy it shipped with when the canonical file's documentation moves
      on, and only the newest, the one a new version copies, is held to
      it. One newest copy is exempt, by name: `http` 1.1.2's `cyfr-http`
      predates the documented `connection` member, which it never names;
      its next version takes the canonical file.
    * `world.wit` — a SUBSET: a seed world deliberately imports only what
      its component uses, so every `import` line must exist in the
      canonical world for its type, but not vice versa.
    * `cyfr:vault/read` — imported only by a world whose manifest declares
      a credential need the component reads itself (one with no `attach`
      rule, or `disclose: true`). A component whose every need CYFR
      attaches is handed no value and has nothing to read.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  # Newest vendored copies a shipped version keeps from before the
  # canonical file it copies moved on, each with its reason.
  @shipped_before_canonical %{
    "seed/components/catalysts/local/http/1.1.2/src/wit/deps/cyfr-http/interfaces.wit" =>
      "documents no connection member, which this version never names"
  }

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
    |> Prima.Test.SourceTree.files!()
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

  # The version directory a vendored file belongs to.
  defp version_dir(path) do
    [dir, _after] = String.split(path, "/src/wit/", parts: 2)
    dir
  end

  # The newest shipped version directory of each component.
  defp newest_versions do
    [@root, "seed/components/*/local/*/*/cyfr-manifest.json"]
    |> Path.join()
    |> Prima.Test.SourceTree.files!()
    |> Enum.map(&Path.dirname/1)
    |> Enum.group_by(&Path.dirname/1)
    |> Enum.map(fn {_component, dirs} ->
      hd(Compendium.Semver.sort_desc_by(dirs, &Path.basename/1))
    end)
    |> MapSet.new()
  end

  defp drifted(paths) do
    for path <- paths,
        String.contains?(path, "/deps/"),
        rel_in_wit = Path.join(wit_type(path), deps_rel(path)),
        File.read!(path) != canonical_body(rel_in_wit) do
      Path.relative_to(path, @root)
    end
  end

  test "the newest version's vendored deps/*.wit are byte-identical to the canonical tree" do
    newest = newest_versions()
    held = Enum.filter(seed_wit_files(), &MapSet.member?(newest, version_dir(&1)))

    assert held != []

    offenders = drifted(held) -- Map.keys(@shipped_before_canonical)

    assert offenders == [],
           "seed-vendored WIT drifted from wit/: #{inspect(offenders)} — " <>
             "copy the canonical file (sans SPDX header) into a new version; the ABI is the host's"
  end

  test "each exempt copy is its component's newest, and still differs from the canonical file" do
    newest = newest_versions()

    for {rel, reason} <- @shipped_before_canonical do
      path = Path.join(@root, rel)
      assert MapSet.member?(newest, version_dir(path)), "#{rel} is no longer newest: drop it"
      assert drifted([path]) == [rel], "#{rel} matches the canonical file again: drop it"
      assert reason != ""
    end
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

  test "a world imports cyfr:vault/read only where the component reads a need itself" do
    worlds = for path <- seed_wit_files(), Path.basename(path) == "world.wit", do: path

    readers =
      for path <- worlds,
          Enum.any?(
            imports(File.read!(path)),
            &String.starts_with?(&1, "import cyfr:vault/read@")
          ),
          do: path

    assert readers != []

    offenders =
      for path <- readers, not reads_a_need?(version_dir(path)) do
        Path.relative_to(path, @root)
      end

    assert offenders == [],
           "a world imports cyfr:vault/read though CYFR attaches every need: #{inspect(offenders)}"
  end

  defp reads_a_need?(dir) do
    dir
    |> Path.join("cyfr-manifest.json")
    |> File.read!()
    |> Jason.decode!()
    |> Prima.Manifest.Needs.from_manifest()
    |> List.wrap()
    |> Enum.any?(fn need ->
      need.kind in ~w(api_key oauth bundle) and
        (Prima.Manifest.Needs.disclose_only?(need) or need.disclose == true)
    end)
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
