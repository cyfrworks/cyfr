# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.UnitFixtures do
  @moduledoc """
  Lay component units for tests WITHOUT spelling the physical layout:
  the version-dir shape is `Compendium.ComponentPath`'s, and where a
  unit's bytes are kept is `Arca.Overlay`'s — a committed revision's
  prefix, resolved through the unit's row. Tests that hand-build
  `["components", ...]` trees, or read a unit's files off the disk,
  re-spell what those modules exist to own, and every layout change
  breaks each spelling.

  A tenant unit lands through the facade, the one way a unit lands
  (`Arca.Overlay.commit_unit/4`): its row committed, its revision in its
  prefix, no cap consulted — the starting state a test that then
  exercises the real ingress wants. Its files are read back through the
  facade too (`unit_file!/3`, `unit_exists?/3`), and edited through it
  (`unit_write!/4`). A seed unit is install media and lands on the disk
  the overlay reads it from (`seed_component!/5`).
  """

  alias Compendium.ComponentPath

  @doc """
  Lay a complete component unit under the context's athanor: one commit
  of the manifest, the artifact and the extra files. Returns the unit's
  path segments.

  Options:
    * `manifest:` — the manifest map (default: a minimal valid one), or
      the manifest's bytes as given, for a manifest that is not JSON
    * `wasm:` — artifact bytes, or `false` to omit the artifact
    * `files:` — extra `{relative_path, content}` entries, the path a
      string with `/` between its segments
  """
  def tenant_component!(ctx, type, publisher, name, version, opts \\ []) do
    unit = ComponentPath.version_dir(type, publisher, name, version)

    {:ok, _written} =
      Arca.Overlay.commit_unit(
        Sanctum.Context.actor(ctx),
        unit,
        {:files, unit_files(type, publisher, name, version, opts)},
        cap: :exempt
      )

    unit
  end

  @doc """
  Lay one unit at `unit` (its path segments) from `files` — `{relative,
  bytes}` pairs, the path a string with `/` between its segments, the
  unit's completion object among them — as one commit through the
  facade. The shape-agnostic form of `tenant_component!/6`, for a test
  that spells the files itself. Returns the unit's segments.
  """
  def lay_unit!(ctx, unit, files) when is_list(unit) and is_list(files) do
    source = {:files, for({rel, bytes} <- files, do: {segments(rel), bytes})}

    {:ok, _written} =
      Arca.Overlay.commit_unit(Sanctum.Context.actor(ctx), unit, source, cap: :exempt)

    unit
  end

  @doc "One file of a unit, read through the facade; raises when it is not there."
  def unit_file!(ctx, unit, relative) when is_list(unit) and is_binary(relative) do
    case unit_file(ctx, unit, relative) do
      {:ok, bytes} -> bytes
      {:error, reason} -> raise "#{Enum.join(unit, "/")}/#{relative}: #{inspect(reason)}"
    end
  end

  @doc "One file of a unit, read through the facade."
  def unit_file(ctx, unit, relative) when is_list(unit) and is_binary(relative),
    do: Arca.get(Sanctum.Context.actor(ctx), unit ++ segments(relative))

  @doc "Whether a unit holds the file, asked through the facade."
  def unit_exists?(ctx, unit, relative) when is_list(unit) and is_binary(relative),
    do: Arca.exists?(Sanctum.Context.actor(ctx), unit ++ segments(relative))

  @doc "An edit of one file inside a committed unit, through the facade."
  def unit_write!(ctx, unit, relative, bytes)
      when is_list(unit) and is_binary(relative) and is_binary(bytes) do
    :ok = Arca.put(Sanctum.Context.actor(ctx), unit ++ segments(relative), bytes)
  end

  @doc """
  Lay a component unit in the SEED tree (`:seed_path`) — install media
  the overlay reads through. Same options as `tenant_component!/6`.
  Returns the unit's absolute directory in the seed tree.
  """
  def seed_component!(type, publisher, name, version, opts \\ []) do
    seed = Application.fetch_env!(:arca, :seed_path)
    dir = Path.join([seed | ComponentPath.version_dir(type, publisher, name, version)])
    File.mkdir_p!(dir)

    for {rel, content} <- unit_files(type, publisher, name, version, opts) do
      path = Path.join([dir | rel])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    dir
  end

  @doc """
  Lay a unit in the seed tree, copy it into the athanor, and register it.
  `:seed_path` must be a writable tree, not the tracked repo seed.
  """
  def ship_and_register!(ctx, type, publisher, name, version, opts \\ []) do
    seed_component!(type, publisher, name, version, opts)
    unit = ComponentPath.version_dir(type, publisher, name, version)
    :ok = Arca.Overlay.pull_shipped(Sanctum.Context.actor(ctx), unit)
    Compendium.Registry.register_from_arca(ctx, unit)
  end

  @doc """
  Plant `wasm` in a writable seed tree and register it, so bootstrap
  can mint it. `:seed_path` must already be a private tree.
  """
  def ship_bytes!(ctx, wasm, metadata) when is_binary(wasm) and is_map(metadata) do
    type = metadata[:type] || metadata["type"]
    name = metadata[:name] || metadata["name"]
    version = metadata[:version] || metadata["version"]
    publisher = metadata[:publisher] || metadata["publisher"] || "local"

    manifest =
      case metadata[:manifest] || metadata["manifest"] do
        json when is_binary(json) -> Jason.decode!(json)
        map when is_map(map) -> map
        _ -> %{}
      end
      |> Map.merge(%{
        "name" => name,
        "type" => type,
        "version" => version,
        "publisher" => publisher
      })

    ship_and_register!(ctx, type, publisher, name, version, manifest: manifest, wasm: wasm)
  end

  # The unit's files as `{segments, bytes}`: the manifest, the artifact
  # (a tincture's artifact is its directory itself, `artifact_path/4` —
  # its files arrive via `files:`; the WASM types get a default binary)
  # and the extras.
  defp unit_files(type, publisher, name, version, opts) do
    manifest =
      case Keyword.get(opts, :manifest) do
        nil ->
          Jason.encode!(%{
            "name" => name,
            "type" => type,
            "version" => version,
            "publisher" => publisher,
            "description" => "Test #{name}"
          })

        map when is_map(map) ->
          Jason.encode!(map)

        bytes when is_binary(bytes) ->
          bytes
      end

    artifact =
      case {type, Keyword.get(opts, :wasm, <<0>>)} do
        {"tincture", _} ->
          []

        {_, false} ->
          []

        {_, bytes} ->
          [{[List.last(ComponentPath.wasm_path(type, publisher, name, version))], bytes}]
      end

    extras = for {rel, content} <- Keyword.get(opts, :files, []), do: {segments(rel), content}
    [{[ComponentPath.manifest_name()], manifest}] ++ artifact ++ extras
  end

  defp segments(relative), do: relative |> String.split("/") |> Enum.reject(&(&1 == ""))
end
