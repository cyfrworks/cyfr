# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.TinctureRegistry do
  @moduledoc """
  Registry for tincture components.

  Scans every active athanor's `components/tinctures/` tree — each inside
  that athanor's own context — for
  cyfr-manifest.json files with `"type": "tincture"` and provides lookup APIs
  for the shell and public tincture controllers. Each row carries the
  athanor's route segment (`athanor_segment`) so callers can build public
  URLs without a lookup per render.

  Reads go straight to a protected ETS table owned by the GenServer, so
  lookups never queue behind a `reload/1` scan (which walks Arca and can be
  slow on an object-store backend). The table is named after the registered
  process name, so `server` must be that name (an atom), not a pid.

  A shell-plane UI cache, member-facing only: the public `/t/` route is
  served by `Sanctum.TinctureAccess`, not this table, so `list_tinctures/2`
  takes the member's `Sanctum.Context` like every other storage-derived
  reader. The table exists from `init/1` on (readers never crash) and
  populates LAZILY, one athanor at a time: the first `list_tinctures/2`
  for an athanor scans exactly that athanor (a `{:scanned, id}` marker
  row remembers it), so boot never walks every athanor's tree and a
  server with a thousand furnaces pays only for the ones whose shell is
  actually opened. `reload/1` remains the full rescan.

  The marker holds the epoch the component registry had acknowledged for
  the athanor's `components/` root when the scan began
  (`Compendium.ProjectionReconciler.acknowledged_epoch/3`). A read past
  the registry's barrier that finds the epoch moved rescans the athanor,
  so a tincture change reaches the table whether or not the domain's
  `%Cyfr.Bus.Tinctures{kind: :changed}` on the athanor's tinctures topic
  did.
  """

  use GenServer

  require Logger

  alias Sanctum.Context

  # -- Public API --

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  List the tinctures of the context's athanor. An unresolved athanor
  lists nothing.
  """
  @spec list_tinctures(atom(), Context.t()) :: [map()]
  def list_tinctures(server \\ __MODULE__, %Context{athanor_id: athanor_id} = ctx) do
    case athanor_id do
      id when is_binary(id) and id != "" ->
        ensure_scanned(server, id, current_epoch(ctx))

        server
        |> :ets.match_object({{id, :_, :_}, :_})
        |> Enum.map(fn {_key, tincture} -> tincture end)

      _unresolved ->
        []
    end
  end

  # First read for an athanor scans exactly that athanor, and so does a
  # read that finds the registry's acknowledged epoch moved since the scan.
  # A busy or restarting registry lists what the table already holds rather
  # than crashing the page, and so does an epoch that could not be read.
  defp ensure_scanned(server, athanor_id, epoch) do
    unless current?(:ets.lookup(server, {:scanned, athanor_id}), epoch) do
      GenServer.call(server, {:ensure_scanned, athanor_id, epoch}, 30_000)
    end

    :ok
  catch
    :exit, _ -> :ok
    :error, :badarg -> :ok
  end

  defp current?([{_marker, _scanned_at}], :unknown), do: true
  defp current?([{_marker, epoch}], epoch), do: true
  defp current?(_absent_or_moved, _epoch), do: false

  # Past the registry's barrier: a change the reader's own write made is
  # acknowledged before the epoch is read.
  defp current_epoch(ctx) do
    case Compendium.ProjectionReconciler.acknowledged_epoch(ctx, "components") do
      {:ok, epoch} -> epoch
      {:error, _} -> :unknown
    end
  end

  # The epoch a scan starts from, read without reconciling: this process
  # derives nothing, and a change made while it scans moves the epoch past
  # what the marker records.
  defp scan_epoch(athanor_id) do
    case Compendium.ProjectionReconciler.acknowledged_epoch(
           scan_context(athanor_id),
           "components",
           await: false
         ) do
      {:ok, epoch} -> epoch
      {:error, _} -> :unknown
    end
  end

  @doc """
  Rescan every active athanor. Boot and the seed sync use this; a change
  inside one athanor uses `reload_athanor/2`.
  """
  @spec reload(atom()) :: :ok
  def reload(server \\ __MODULE__) do
    # The scan is I/O-bound (Arca walk + per-manifest reads); the default 5s
    # call timeout is too tight on object-store backends.
    GenServer.call(server, :reload, 30_000)
  end

  @doc """
  Rescan one athanor's tinctures and replace exactly that athanor's rows.

  Reloads and prunes only the specified athanor's tinctures. Other
  athanors are refreshed by their own reload or a full `reload/1`.
  """
  @spec reload_athanor(atom(), String.t()) :: :ok
  def reload_athanor(server \\ __MODULE__, athanor_id) when is_binary(athanor_id) do
    GenServer.call(server, {:reload_athanor, athanor_id}, 30_000)
  end

  # -- GenServer Callbacks --

  @impl true
  def init(opts) do
    table =
      opts
      |> Keyword.get(:name, __MODULE__)
      |> :ets.new([:named_table, :protected, :set, read_concurrency: true])

    {:ok, %{table: table, watching: MapSet.new()}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    count = store_tinctures(state.table, scan_tinctures())
    Logger.info("[TinctureRegistry] reloaded #{count} tincture(s)")
    {:reply, :ok, watch_scanned(state)}
  end

  @impl true
  def handle_call({:ensure_scanned, athanor_id, epoch}, _from, state) do
    # Re-check under the serializing process: a second caller that queued
    # behind the first scan finds the marker and pays nothing.
    unless current?(:ets.lookup(state.table, {:scanned, athanor_id}), epoch) do
      scan_athanor_into(state.table, athanor_id, epoch)
    end

    {:reply, :ok, watch(state, athanor_id)}
  end

  @impl true
  def handle_call({:reload_athanor, athanor_id}, _from, state) do
    count = scan_athanor_into(state.table, athanor_id, scan_epoch(athanor_id))
    Logger.info("[TinctureRegistry] reloaded #{count} tincture(s) for #{athanor_id}")
    {:reply, :ok, watch(state, athanor_id)}
  end

  # Subscribed to each scanned athanor's tinctures topic, exactly once —
  # so a registry change lands here without the domain naming this module.
  defp watch(state, athanor_id) do
    if MapSet.member?(state.watching, athanor_id) do
      state
    else
      actor = Prima.Actor.in_athanor(athanor_id)
      :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.tinctures(actor))
      %{state | watching: MapSet.put(state.watching, athanor_id)}
    end
  end

  defp watch_scanned(state) do
    :ets.select(state.table, [{{{:scanned, :"$1"}, :_}, [], [:"$1"]}])
    |> Enum.reduce(state, &watch(&2, &1))
  end

  defp scan_athanor_into(table, athanor_id, epoch) do
    count =
      case Sanctum.Tenancy.Athanors.get(athanor_id) do
        {:ok, %{status: "active"} = athanor} ->
          store_athanor_tinctures(table, athanor_id, scan_one(athanor))

        # Archived, gone, or unreadable: it contributes nothing, and its rows
        # go with it. `scan_tinctures/0` reaches the same end by not
        # enumerating it.
        _ ->
          store_athanor_tinctures(table, athanor_id, [])
      end

    :ets.insert(table, {{:scanned, athanor_id}, epoch})
    count
  end

  # The domain announced a change (`Compendium.ProjectionReconciler`
  # broadcasts on the athanor's tinctures topic after a replacement that
  # touched a tincture); this cache follows. The topic's invocation kinds
  # are the console's activity feed, not this cache's business.
  @impl true
  def handle_info(%Cyfr.Bus.Tinctures{kind: :changed, athanor_id: athanor_id}, state) do
    scan_athanor_into(state.table, athanor_id, scan_epoch(athanor_id))
    {:noreply, state}
  end

  def handle_info(%Cyfr.Bus.Tinctures{}, state), do: {:noreply, state}

  @impl true
  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  # Insert the fresh rows first (a list insert is a single atomic ETS op),
  # then prune keys that vanished — readers never observe an empty table
  # mid-reload. Returns the fresh tincture count. The 3-tuple match keeps
  # {:scanned, id} marker rows out of the prune; the full scan then marks
  # every athanor it walked as scanned, at the epoch it began from.
  defp store_tinctures(table, {tinctures, epochs}) do
    old_keys =
      :ets.select(table, [{{{:"$1", :"$2", :"$3"}, :_}, [], [{{:"$1", :"$2", :"$3"}}]}])

    count = replace(table, old_keys, tinctures)

    for athanor_id <- Enum.uniq(Enum.map(tinctures, & &1.athanor_id)) do
      :ets.insert(table, {{:scanned, athanor_id}, Map.get(epochs, athanor_id, :unknown)})
    end

    count
  end

  # The same insert-then-prune, with the prune confined to one athanor's
  # keys so a single-tenant reload cannot delete another tenant's rows.
  defp store_athanor_tinctures(table, athanor_id, tinctures) do
    old_keys =
      :ets.select(table, [{{{athanor_id, :"$1", :"$2"}, :_}, [], [{{athanor_id, :"$1", :"$2"}}]}])

    replace(table, old_keys, tinctures)
  end

  defp replace(table, old_keys, tinctures) do
    rows = Enum.map(tinctures, &{{&1.athanor_id, &1.publisher, &1.name}, &1})
    fresh_keys = MapSet.new(rows, fn {key, _} -> key end)

    :ets.insert(table, rows)

    for key <- old_keys, not MapSet.member?(fresh_keys, key), do: :ets.delete(table, key)

    length(rows)
  end

  # -- Scanning --

  # Pinned at compile time from the SSOT.
  @tincture_type_plural Compendium.ComponentPath.type_plural("tincture")

  # Scanning runs through Arca (`list_recursive` + `get`) so the registry
  # populates identically on the Local FS adapter and any configured
  # object-store adapter. The walk is roster-driven: every active athanor
  # row, opened with its own internal context — paths are tenant-relative,
  # so there is no reaching across athanors from one context — and never a
  # whole-root filesystem walk, so nothing outside a registered athanor is
  # ever read and an archived athanor drops out by not being enumerated.
  defp scan_tinctures do
    athanors = Sanctum.Tenancy.Athanors.list_active()
    epochs = Map.new(athanors, &{&1.id, scan_epoch(&1.id)})

    tinctures =
      athanors
      |> Enum.flat_map(&scan_athanor/1)
      |> pick_latest_versions()

    {tinctures, epochs}
  end

  # One athanor's scan, version-picked the same way the full scan is — the
  # grouping in `pick_latest_versions/1` is keyed by athanor, so running it
  # over one athanor's rows gives that athanor exactly the rows it would
  # have got from the full walk.
  defp scan_one(athanor) do
    athanor
    |> scan_athanor()
    |> pick_latest_versions()
  end

  # One athanor's tinctures, each carrying its route segment. An unreadable
  # tree logs and contributes nothing — one bad athanor must not empty the
  # registry.
  defp scan_athanor(athanor) do
    ctx = scan_context(athanor.id)

    case Arca.list_recursive(
           Sanctum.Context.actor(ctx),
           Compendium.ComponentPath.base_prefix() ++ [@tincture_type_plural]
         ) do
      {:ok, leaves} ->
        segment = Sanctum.Tenancy.Athanors.route_slug(athanor)

        leaves
        |> Compendium.ComponentPath.manifest_leaves()
        |> Enum.flat_map(fn manifest_segs -> read_and_parse(ctx, manifest_segs, athanor.id) end)
        |> Enum.map(&put_segment(&1, segment))

      {:error, reason} ->
        Logger.warning(
          "[TinctureRegistry] cannot list #{athanor.id}/#{@tincture_type_plural}: #{inspect(reason)}"
        )

        []
    end
  end

  defp scan_context(athanor_id) do
    # Server-built roster scan (not cron), routed through the single
    # server-internal builder (auth_method: :system) and scoped to the one
    # athanor being scanned — its context is what names its tree.
    Sanctum.internal_context(
      user_id: "_system_scan",
      athanor_id: athanor_id,
      scope: :athanor,
      permissions: [:storage_read]
    )
  end

  defp put_segment(tincture, segment) do
    entry_url = Prima.TinctureUrl.path(segment, tincture.publisher, tincture.name)
    %{tincture | athanor_segment: segment, entry_url: entry_url}
  end

  defp read_and_parse(ctx, manifest_segs, athanor_id) do
    # Only consider manifests under tinctures/ — components/ also contains
    # catalysts/reagents/formulas which we ignore here. The seed bundle is
    # not an athanor and carries no route.
    if tincture_path?(manifest_segs) do
      case Arca.get(Sanctum.Context.actor(ctx), manifest_segs) do
        {:ok, raw} ->
          parse_manifest(ctx, manifest_segs, raw, athanor_id)

        {:error, reason} ->
          Logger.warning(
            "[TinctureRegistry] cannot read #{Enum.join(manifest_segs, "/")}: #{inspect(reason)}"
          )

          []
      end
    else
      []
    end
  end

  # A tincture manifest exactly at its version directory — the one parser
  # (`Compendium.ComponentPath.parse/1`) decides, so a manifest nested
  # BELOW a version dir is refused instead of indexed with the wrong
  # version segments. Tenant-relative; the athanor is the scanning
  # context's.
  defp tincture_path?(segs),
    do:
      match?({:ok, %{type: "tincture", rest: [_manifest]}}, Compendium.ComponentPath.parse(segs))

  defp parse_manifest(ctx, manifest_segs, raw, athanor_id) do
    with {:ok, manifest} <- Jason.decode(raw),
         true <- manifest["type"] == "tincture",
         true <- is_binary(manifest["name"]) do
      version_segs = Enum.drop(manifest_segs, -1)
      tincture_block = manifest["tincture"] || %{}
      publisher = Compendium.ComponentPath.normalize_publisher(manifest["publisher"])
      name = manifest["name"]
      version = manifest["version"] || "0.1.0"

      entry_result = Compendium.tincture_entry(manifest)
      icon = tincture_block["icon"] || "palette"
      window = tincture_block["window"] || %{}
      tagline = tincture_block["tagline"]

      # Convention auto-discovery via Arca.exists? (works for both Local and
      # S3). Manifest-declared media still wins for non-standard layouts.
      media_block = tincture_block["media"] || %{}
      discovered = Compendium.tincture_media(ctx, version_segs)

      media_icon = media_block["icon"] || discovered.icon

      media_previews =
        case media_block["previews"] do
          list when is_list(list) -> Enum.filter(list, &is_binary/1)
          _ -> discovered.previews
        end

      # The same reading publish and serve use. Indexing a tincture whose
      # entry the serve side will refuse lists something that 404s on the
      # first click — and says nothing about why.
      case {entry_result, blocked_image_refs(media_icon, media_previews)} do
        {{:error, refused}, _} ->
          Logger.warning(
            "[TinctureRegistry] skipping tincture at #{Enum.join(manifest_segs, "/")} — " <>
              "its entry is refused (#{refused})"
          )

          []

        {{:ok, entry}, []} ->
          [
            %{
              name: name,
              publisher: publisher,
              version: version,
              athanor_id: athanor_id,
              # Filled by the enumerating scan (scan_athanor/2).
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

        {_entry, refs} ->
          Logger.warning(
            "[TinctureRegistry] skipping tincture at #{Enum.join(manifest_segs, "/")} — raster " <>
              "image assets are blocked until CSAM hash matching ships. Offending refs: " <>
              Enum.join(refs, ", ") <>
              ". Use SVG or remove the media entries to unblock."
          )

          []
      end
    else
      {:error, %Jason.DecodeError{} = err} ->
        Logger.warning(
          "[TinctureRegistry] invalid JSON in #{Enum.join(manifest_segs, "/")}: #{Exception.message(err)}"
        )

        []

      false ->
        case Jason.decode(raw) do
          {:ok, manifest} ->
            if manifest["type"] == "tincture" and not is_binary(manifest["name"]) do
              Logger.warning(
                "[TinctureRegistry] tincture manifest missing 'name' field: #{Enum.join(manifest_segs, "/")}"
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

  # Launch constraint: tinctures can't SURFACE raster image assets in the
  # discovery slots until CSAM hash matching (PhotoDNA) is live. Vector
  # (.svg) is allowed. The roster is the component domain's rule map, read
  # where it is used, so the serve gate and the listing cannot drift.
  defp blocked_image?(path) when is_binary(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in Compendium.tincture_asset_rules().blocked_raster_extensions
  end

  defp blocked_image?(_), do: false

  # Select the latest tincture version using Compendium.Semver.
  defp pick_latest_versions(tinctures) do
    tinctures
    |> Enum.group_by(fn t -> {t.athanor_id, t.publisher, t.name} end)
    |> Enum.map(fn {_key, versions} ->
      versions
      |> Compendium.Semver.sort_desc_by(&(&1.version || "0.0.0"))
      |> hd()
    end)
  end
end
