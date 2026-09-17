# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.SeedBundle do
  @moduledoc """
  A private seed tree for one test: the shipped AQUA tree and the named
  catalysts at their newest shipped version, copied from the repository's
  `seed/` without build droppings. Points `:seed_path` at it until the
  test exits.
  """

  @repo_seed Path.expand("../../../../seed", __DIR__)

  @doc "Point `:seed_path` at an empty temp tree until the test exits."
  @spec isolate!() :: String.t()
  def isolate! do
    dir = Path.join(System.tmp_dir!(), "seed_isolate_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:cyfr, :seed_path)
    Application.put_env(:cyfr, :seed_path, dir)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:cyfr, :seed_path, previous),
        else: Application.delete_env(:cyfr, :seed_path)

      File.rm_rf!(dir)
    end)

    dir
  end

  @doc "Copy `source` into a private tree and point `:seed_path` at it until the test exits."
  @spec isolate_from!(String.t()) :: String.t()
  def isolate_from!(source) when is_binary(source) do
    dir = Path.join(System.tmp_dir!(), "seed_isolate_#{System.unique_integer([:positive])}")
    File.cp_r!(source, dir)
    previous = Application.get_env(:cyfr, :seed_path)
    Application.put_env(:cyfr, :seed_path, dir)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:cyfr, :seed_path, previous),
        else: Application.delete_env(:cyfr, :seed_path)

      File.rm_rf!(dir)
    end)

    dir
  end

  @type unit :: %{
          name: String.t(),
          version: String.t(),
          type: String.t(),
          rel: String.t(),
          ref: String.t(),
          manifest: map()
        }

  @doc """
  Shipped local catalysts that declare `model/chat@1`, newest version
  each. The tree is the roster: a new provider is a new unit, not a
  test-list edit. Raises when none speak the contract.
  """
  @spec model_chat_units(String.t()) :: [unit()]
  def model_chat_units(seed \\ @repo_seed) when is_binary(seed) do
    units =
      seed
      |> shipped_units("catalysts")
      |> Enum.filter(&Cyfr.Models.speaks_chat?(&1.manifest))
      |> newest_by_name()
      |> Enum.sort_by(& &1.name)

    if units == [],
      do: raise("no model/chat@1 catalyst under #{seed}"),
      else: units
  end

  @doc """
  The newest shipped local unit of `kind`/`name` (`catalysts` or
  `formulas`). Raises when that name is absent.
  """
  @spec local_unit!(String.t(), String.t(), String.t()) :: unit()
  def local_unit!(seed \\ @repo_seed, kind, name)
      when is_binary(seed) and is_binary(kind) and is_binary(name) do
    case seed |> shipped_units(kind) |> Enum.filter(&(&1.name == name)) |> newest_by_name() do
      [unit] -> unit
      [] -> raise("no #{kind}/local/#{name} under #{seed}")
    end
  end

  defp shipped_units(seed, kind) do
    glob = Path.join([seed, "components", kind, "local", "*", "*", "cyfr-manifest.json"])

    for path <- Cyfr.Test.SourceTree.files!(glob) do
      version_dir = Path.dirname(path)
      components = Path.join(seed, "components")
      manifest = Jason.decode!(File.read!(path))
      type = manifest["type"]
      name = Path.basename(Path.dirname(version_dir))
      version = Path.basename(version_dir)

      %{
        name: name,
        version: version,
        type: type,
        rel: Path.relative_to(version_dir, components),
        ref: "#{type}:local.#{name}",
        manifest: manifest
      }
    end
  end

  defp newest_by_name(units) do
    units
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {_name, versions} ->
      hd(Compendium.Semver.sort_desc_by(versions, & &1.version))
    end)
  end

  @doc "Lay the tree, set `:seed_path` to it, and answer its path."
  @spec lay!([String.t()]) :: String.t()
  def lay!(catalysts) when is_list(catalysts) do
    dir = Path.join(System.tmp_dir!(), "seed_bundle_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.cp_r!(Path.join(@repo_seed, "aqua"), Path.join(dir, "aqua"))

    for name <- catalysts do
      versions =
        [@repo_seed, "components", "catalysts", "local", name, "*"]
        |> Path.join()
        |> Cyfr.Test.SourceTree.files!()
        |> Enum.map(&Path.basename/1)
        |> Compendium.Semver.sort_desc()

      version = hd(versions)
      src = Path.join([@repo_seed, "components", "catalysts", "local", name, version])
      dest = Path.join([dir, "components", "catalysts", "local", name, version])
      copy_unit!(src, dest)
    end

    previous = Application.get_env(:cyfr, :seed_path)
    Application.put_env(:cyfr, :seed_path, dir)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:cyfr, :seed_path, previous),
        else: Application.delete_env(:cyfr, :seed_path)

      File.rm_rf!(dir)
    end)

    dir
  end

  defp copy_unit!(src, dest) do
    src
    |> Path.join("**")
    |> Cyfr.Test.SourceTree.files!(match_dot: false)
    |> Enum.reject(&(String.contains?(&1, "/target/") or File.dir?(&1)))
    |> Enum.each(fn file ->
      target = Path.join(dest, Path.relative_to(file, src))
      File.mkdir_p!(Path.dirname(target))
      File.cp!(file, target)
    end)
  end
end
