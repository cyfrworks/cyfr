# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.TinctureRegistry do
  @moduledoc """
  Registry for tincture components.

  Scans every athanor's `components/{athanor_id}/tinctures/` tree for
  cyfr-manifest.json files with `"type": "tincture"` and provides lookup APIs
  for the shell and public tincture controllers. Each row carries the
  athanor's route segment (`athanor_segment`) so callers can build public
  URLs without a lookup per render.

  Reads go straight to a protected ETS table owned by the GenServer, so
  lookups never queue behind a `reload/1` scan (which walks Arca and can be
  slow on an object-store backend). The table is named after the registered
  process name, so `server` must be that name (an atom), not a pid.

  """

  use GenServer

  require Logger

  # -- Public API --

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "List all tinctures of the athanor the given scope (a Context or map) names."
  @spec list_tinctures(atom(), map()) :: [map()]
  def list_tinctures(server \\ __MODULE__, scope) do
    athanor_id = extract_athanor_id(scope)

    server
    |> :ets.match_object({{athanor_id, :_, :_}, :_})
    |> Enum.map(fn {_key, tincture} -> tincture end)
  end

  @doc "Rescan the filesystem for tinctures."
  @spec reload(atom()) :: :ok
  def reload(server \\ __MODULE__) do
    # The scan is I/O-bound (Arca walk + per-manifest reads); the default 5s
    # call timeout is too tight on object-store backends.
    GenServer.call(server, :reload, 30_000)
  end

  # -- GenServer Callbacks --

  @impl true
  def init(opts) do
    table =
      opts
      |> Keyword.get(:name, __MODULE__)
      |> :ets.new([:named_table, :protected, :set, read_concurrency: true])

    count = store_tinctures(table, scan_tinctures())
    Logger.info("TinctureRegistry: loaded #{count} tincture(s)")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    count = store_tinctures(state.table, scan_tinctures())
    Logger.info("TinctureRegistry: reloaded #{count} tincture(s)")
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("#{__MODULE__}: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Insert the fresh rows first (a list insert is a single atomic ETS op),
  # then prune keys that vanished — readers never observe an empty table
  # mid-reload. Returns the fresh tincture count.
  defp store_tinctures(table, tinctures) do
    rows = Enum.map(tinctures, &{{&1.athanor_id, &1.publisher, &1.name}, &1})
    fresh_keys = MapSet.new(rows, fn {key, _} -> key end)
    old_keys = :ets.select(table, [{{:"$1", :_}, [], [:"$1"]}])

    :ets.insert(table, rows)

    for key <- old_keys, not MapSet.member?(fresh_keys, key), do: :ets.delete(table, key)

    length(rows)
  end

  # -- Scanning --

  # Derive tincture subdirectory name from ComponentPath (single source of truth)
  @tincture_type_plural "tinctures"

  # Scanning runs through Arca (`list_recursive` + `get`) so the registry
  # populates identically on the Local FS adapter and any configured
  # object-store adapter. The scanner uses a synthetic platform context with
  # `:storage_read` permission only — a read-only walk of the whole
  # `components/` prefix, which only a platform context may list. Athanor
  # route segments are resolved once per scan.
  defp scan_tinctures do
    ctx = scan_context()

    case Arca.list_recursive(ctx, ["components"]) do
      {:ok, leaves} ->
        segments_by_athanor = %{}

        {tinctures, _} =
          leaves
          |> Enum.filter(fn segs -> List.last(segs) == "cyfr-manifest.json" end)
          |> Enum.flat_map(fn manifest_segs -> read_and_parse(ctx, manifest_segs) end)
          |> Enum.map_reduce(segments_by_athanor, &attach_athanor_segment/2)

        tinctures
        |> Enum.reject(&is_nil/1)
        |> pick_latest_versions()

      {:error, reason} ->
        Logger.warning("TinctureRegistry: cannot list components/: #{inspect(reason)}")
        []
    end
  end

  defp scan_context do
    # Server-built filesystem scan of components/ (not cron). Routed through
    # the single server-internal builder (auth_method: :system).
    Sanctum.internal_context(
      user_id: "_system_scan",
      permissions: [:storage_read],
      scope: :platform
    )
  end

  # Look each tincture's athanor up once per scan; a tincture whose athanor
  # is missing or archived has no public URL and is dropped.
  defp attach_athanor_segment(tincture, cache) do
    case Map.fetch(cache, tincture.athanor_id) do
      {:ok, segment} ->
        {put_segment(tincture, segment), cache}

      :error ->
        segment =
          case Sanctum.Tenancy.Athanors.get(tincture.athanor_id) do
            {:ok, %{status: "active"} = athanor} -> Cyfr.TinctureHelpers.athanor_segment(athanor)
            _ -> nil
          end

        {put_segment(tincture, segment), Map.put(cache, tincture.athanor_id, segment)}
    end
  end

  defp put_segment(_tincture, nil), do: nil

  defp put_segment(tincture, segment) do
    entry_url = Cyfr.TinctureHelpers.tincture_path(segment, tincture.publisher, tincture.name)
    %{tincture | athanor_segment: segment, entry_url: entry_url}
  end

  defp read_and_parse(ctx, manifest_segs) do
    # Only consider manifests under tinctures/ — components/ also contains
    # catalysts/reagents/formulas which we ignore here. The seed bundle is
    # not an athanor and carries no route.
    if tincture_path?(manifest_segs) do
      athanor_id = extract_athanor_id(manifest_segs)

      case Arca.get(ctx, manifest_segs) do
        {:ok, raw} ->
          parse_manifest(ctx, manifest_segs, raw, athanor_id)

        {:error, reason} ->
          Logger.warning(
            "TinctureRegistry: cannot read #{Enum.join(manifest_segs, "/")}: #{inspect(reason)}"
          )

          []
      end
    else
      []
    end
  end

  # Layout: ["components", athanor_id, "tinctures", publisher, name, version, "cyfr-manifest.json"]
  # `_bundle` is the seed source, never an athanor.
  defp tincture_path?(["components", "_bundle" | _]), do: false
  defp tincture_path?(["components", _athanor, @tincture_type_plural | _]), do: true
  defp tincture_path?(_), do: false

  # Manifest-segments OR a scope (Context/map) → athanor_id. Path segments
  # carry the athanor between "components" and "tinctures"; scopes carry it as
  # a field. Nothing is normalized: an absent athanor lists nothing.
  defp extract_athanor_id(["components", athanor_id, @tincture_type_plural | _]), do: athanor_id
  defp extract_athanor_id(%{athanor_id: athanor_id}), do: athanor_id
  defp extract_athanor_id(%{"athanor_id" => athanor_id}), do: athanor_id
  defp extract_athanor_id(_), do: nil

  # Launch constraint: tinctures can't carry raster image assets until
  # CSAM hash matching (PhotoDNA) is live. Vector (.svg) is allowed.
  @blocked_image_extensions ~w(.png .jpg .jpeg .gif .webp)

  defp parse_manifest(ctx, manifest_segs, raw, athanor_id) do
    with {:ok, manifest} <- Jason.decode(raw),
         true <- manifest["type"] == "tincture",
         true <- is_binary(manifest["name"]) do
      version_segs = Enum.drop(manifest_segs, -1)
      tincture_block = manifest["tincture"] || %{}
      publisher = Compendium.ComponentPath.normalize_publisher(manifest["publisher"])
      name = manifest["name"]
      version = manifest["version"] || "0.1.0"

      entry = tincture_block["entry"] || "index.html"
      icon = tincture_block["icon"] || "palette"
      window = tincture_block["window"] || %{}
      tagline = tincture_block["tagline"]

      # Convention auto-discovery via Arca.exists? (works for both Local and
      # S3). Manifest-declared media still wins for non-standard layouts.
      media_block = tincture_block["media"] || %{}
      discovered = Cyfr.TinctureHelpers.discover_media_via_arca(ctx, version_segs)

      media_icon = media_block["icon"] || discovered.icon

      media_previews =
        case media_block["previews"] do
          list when is_list(list) -> Enum.filter(list, &is_binary/1)
          _ -> discovered.previews
        end

      case blocked_image_refs(media_icon, media_previews) do
        [] ->
          [
            %{
              name: name,
              publisher: publisher,
              version: version,
              athanor_id: athanor_id,
              # Filled once the athanor is resolved (attach_athanor_segment/2).
              athanor_segment: nil,
              entry_url: nil,
              title: manifest["description"] || name,
              tagline: tagline,
              icon: icon,
              media_icon: media_icon,
              media_previews: media_previews,
              entry: entry,
              window: window,
              segments: version_segs,
              manifest: manifest
            }
          ]

        refs ->
          Logger.warning(
            "TinctureRegistry: skipping tincture at #{Enum.join(manifest_segs, "/")} — raster " <>
              "image assets are blocked until CSAM hash matching ships. Offending refs: " <>
              Enum.join(refs, ", ") <>
              ". Use SVG or remove the media entries to unblock."
          )

          []
      end
    else
      {:error, %Jason.DecodeError{} = err} ->
        Logger.warning(
          "TinctureRegistry: invalid JSON in #{Enum.join(manifest_segs, "/")}: #{Exception.message(err)}"
        )

        []

      false ->
        case Jason.decode(raw) do
          {:ok, manifest} ->
            if manifest["type"] == "tincture" and not is_binary(manifest["name"]) do
              Logger.warning(
                "TinctureRegistry: tincture manifest missing 'name' field: #{Enum.join(manifest_segs, "/")}"
              )
            end

          _ ->
            :ok
        end

        []
    end
  end

  defp blocked_image_refs(media_icon, media_previews) do
    candidates = [media_icon | List.wrap(media_previews)]

    candidates
    |> Enum.filter(&is_binary/1)
    |> Enum.filter(&blocked_image?/1)
  end

  defp blocked_image?(path) when is_binary(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in @blocked_image_extensions
  end

  defp blocked_image?(_), do: false

  # When multiple versions of the same tincture exist, keep only the latest.
  defp pick_latest_versions(tinctures) do
    tinctures
    |> Enum.group_by(fn t -> {t.athanor_id, t.publisher, t.name} end)
    |> Enum.map(fn {_key, versions} ->
      Enum.max_by(versions, fn t -> version_sort_key(t.version) end)
    end)
  end

  defp version_sort_key(version) do
    version
    |> String.split(".")
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {n, _} -> n
        :error -> 0
      end
    end)
  end
end
