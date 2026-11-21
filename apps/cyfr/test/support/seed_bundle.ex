# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.SeedBundle do
  @moduledoc """
  A private seed tree for one test: the shipped Aqua tree and the named
  catalysts and formulas at their newest shipped version, copied from the
  repository's `seed/` without build droppings. Points `:seed_path` at it
  until the test exits. A test whose turns run on a few shipped units lays
  those alone, since every unit the seed holds is copied into its
  athanor, indexed and consented.
  """

  @repo_seed Path.expand("../../../../seed", __DIR__)

  @doc "Point `:seed_path` at an empty temp tree until the test exits."
  @spec isolate!() :: String.t()
  def isolate!, do: seed_tree!("seed_isolate", &File.mkdir_p!/1)

  @doc "Copy `source` into a private tree and point `:seed_path` at it until the test exits."
  @spec isolate_from!(String.t()) :: String.t()
  def isolate_from!(source) when is_binary(source),
    do: seed_tree!("seed_isolate", &File.cp_r!(source, &1))

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
      |> Enum.filter(&Prima.Model.speaks_chat?(&1.manifest))
      |> newest_by_name()
      |> Enum.sort_by(& &1.name)

    if units == [],
      do: raise("no model/chat@1 catalyst under #{seed}"),
      else: units
  end

  @doc """
  The newest shipped local unit of `kind`/`name` (`catalysts`,
  `formulas` or `tinctures`). Raises when that name is absent.
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

    for path <- Prima.Test.SourceTree.files!(glob) do
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

  @doc """
  Lay the tree, with the formulas `formulas:` names beside the catalysts,
  set `:seed_path` to it, and answer its path. Its Aqua runs on the crew
  member `seat!/2` lays, on the bundled Claude catalyst, as a shipped
  athanor's does once its person has chosen one.
  """
  @spec lay!([String.t()], formulas: [String.t()]) :: String.t()
  def lay!(catalysts, opts \\ []) when is_list(catalysts) do
    units =
      Enum.map(catalysts, &local_unit!("catalysts", &1)) ++
        Enum.map(Keyword.get(opts, :formulas, []), &local_unit!("formulas", &1))

    seed_tree!("seed_bundle", fn dir ->
      File.mkdir_p!(dir)
      File.cp_r!(Path.join(@repo_seed, "aqua"), Path.join(dir, "aqua"))
      seat!(dir)

      for %{rel: rel} <- units do
        copy_unit!(
          Path.join([@repo_seed, "components", rel]),
          Path.join([dir, "components", rel])
        )
      end
    end)
  end

  @seat_member "claude"

  @doc """
  The crew member a laid tree's Aqua runs on (`seat!/2`).
  """
  @spec seat_member() :: String.t()
  def seat_member, do: @seat_member

  @doc """
  Seat the Aqua tree under `dir` on a crew member of the tree's own: the
  shipped soul names no member and the seed ships no crew, so a tree
  whose turns run on one brain lays a member on it (`member!/3`), and the
  soul's file names it. `opts`: `:member` (`seat_member/0`) and the
  member's own (`member!/3`).
  """
  @spec seat!(Path.t(), keyword()) :: :ok
  def seat!(dir, opts \\ []) do
    {member, opts} = Keyword.pop(opts, :member, @seat_member)
    :ok = member!(dir, member, opts)

    soul = Path.join([dir, "aqua", "aqua.md"])
    "---\n" <> rest = File.read!(soul)
    File.write!(soul, "---\nmember: " <> member <> "\n" <> rest)
  end

  @doc """
  Lay a crew member of the tree's own in the Aqua tree under `dir`, before
  an athanor is filled from it, so the member is one the athanor's seed
  ships and the bootstrap vouches for it. `opts`: `:title` (the name),
  `:description` (the brain it answers on), `:avoid` (none), the brain,
  `:catalyst_ref` (`catalyst:local.claude`) or `:program` with its
  `:install`, `:model` (`claude-sonnet-5-5`) and `:mode` (`auto`).
  """
  @spec member!(Path.t(), String.t(), keyword()) :: :ok
  def member!(dir, name, opts \\ []) do
    program = Keyword.get(opts, :program)

    catalyst =
      if program, do: nil, else: Keyword.get(opts, :catalyst_ref, "catalyst:local.claude")

    crew = Path.join([dir, "aqua", "crew"])
    File.mkdir_p!(crew)

    File.write!(
      Path.join(crew, name <> ".md"),
      Compendium.AquaAgent.serialize(%{
        name: name,
        title: Keyword.get(opts, :title, name),
        description: Keyword.get(opts, :description, "Answers on #{catalyst || program}"),
        avoid: Keyword.get(opts, :avoid),
        disabled: false,
        catalyst_ref: catalyst,
        program: program,
        install: Keyword.get(opts, :install),
        model: Keyword.get(opts, :model, "claude-sonnet-5-5"),
        options: %{},
        mode: Keyword.get(opts, :mode, "auto")
      })
    )
  end

  # A tree of this test's own, filled by `fill`, and `:seed_path` pointed at
  # it until the test exits. Its removal is registered before anything is
  # written, so a fill that fails part-way leaves nothing behind.
  defp seed_tree!(prefix, fill) do
    dir = temp_dir(prefix)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    fill.(dir)
    Prima.Test.Env.put_app_env(:arca, :seed_path, dir)
    dir
  end

  defp copy_unit!(src, dest) do
    src
    |> Path.join("**")
    |> Prima.Test.SourceTree.files!(match_dot: false)
    |> Enum.reject(&(String.contains?(&1, "/target/") or File.dir?(&1)))
    |> Enum.each(fn file ->
      target = Path.join(dest, Path.relative_to(file, src))
      File.mkdir_p!(Path.dirname(target))
      File.cp!(file, target)
    end)
  end

  # `System.unique_integer/1` starts over identically in every fresh VM, so
  # it alone names the same directory for two direct runs of one checkout.
  defp temp_dir(prefix) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}_#{suffix}")
  end
end
