# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.UnitFixtures do
  @moduledoc """
  Lay component units for tests WITHOUT spelling the physical layout:
  the version-dir shape is `Compendium.ComponentPath`'s, and the join
  under the storage or seed root is the Local adapter's. Tests that
  hand-build `["components", ...]` trees re-spell what those modules
  exist to own, and every layout change breaks each spelling.

  These are FIXTURES, not ingresses: bytes land straight on the
  filesystem — no rows minted, no caps consulted, no overlay involved —
  which is exactly what a test that then exercises the real ingress
  wants as its starting state.
  """

  alias Compendium.ComponentPath

  @doc """
  Lay a complete component unit under the context's athanor tree.
  Returns the unit's absolute directory.

  Options:
    * `manifest:` — the manifest map (default: a minimal valid one)
    * `wasm:` — artifact bytes, or `false` to omit the artifact
    * `files:` — extra `{relative_path, content}` entries
  """
  def tenant_component!(ctx, type, publisher, name, version, opts \\ []) do
    dir =
      Arca.Adapters.Local.build_path(
        Sanctum.Context.actor(ctx),
        ComponentPath.version_dir(type, publisher, name, version)
      )

    write_unit!(dir, type, publisher, name, version, opts)
    dir
  end

  @doc """
  Lay a component unit in the SEED tree (`:seed_path`) — install media
  the overlay reads through. Same options as `tenant_component!/6`.
  """
  def seed_component!(type, publisher, name, version, opts \\ []) do
    seed = Application.fetch_env!(:arca, :seed_path)
    dir = Path.join([seed | ComponentPath.version_dir(type, publisher, name, version)])
    write_unit!(dir, type, publisher, name, version, opts)
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

  defp write_unit!(dir, type, publisher, name, version, opts) do
    File.mkdir_p!(dir)

    manifest =
      Keyword.get_lazy(opts, :manifest, fn ->
        %{
          "name" => name,
          "type" => type,
          "version" => version,
          "publisher" => publisher,
          "description" => "Test #{name}"
        }
      end)

    File.write!(Path.join(dir, ComponentPath.manifest_name()), Jason.encode!(manifest))

    # A tincture's artifact is its directory itself (`artifact_path/4`) —
    # its files arrive via `files:`; the WASM types get a default binary.
    case {type, Keyword.get(opts, :wasm, <<0>>)} do
      {"tincture", _} ->
        :ok

      {_, false} ->
        :ok

      {_, bytes} ->
        artifact = List.last(ComponentPath.wasm_path(type, publisher, name, version))
        File.write!(Path.join(dir, artifact), bytes)
    end

    for {rel, content} <- Keyword.get(opts, :files, []) do
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    :ok
  end
end
