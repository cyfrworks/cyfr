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
  reader. The table exists from `init/1` on (readers never crash) and is
  EMPTY until the first scan completes — the scan runs in
  `handle_continue`, so a slow object-store walk never blocks supervisor
  startup; `reload/1` calls queue behind it.
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
  def list_tinctures(server \\ __MODULE__, %Context{athanor_id: athanor_id}) do
    case athanor_id do
      id when is_binary(id) and id != "" ->
        server
        |> :ets.match_object({{id, :_, :_}, :_})
        |> Enum.map(fn {_key, tincture} -> tincture end)

      _unresolved ->
        []
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

  Registering a tincture is a single-tenant act, but it used to rescan the
  whole roster: every active athanor walked and every manifest re-read,
  inside one `handle_call` on a global singleton — O(athanors × tinctures)
  object-store round trips for one athanor's write, with every other
  athanor's registration queued behind it. The prune is scoped to the same
  athanor, so a tincture removed elsewhere is still dropped by its own
  reload (or by the next full `reload/1`).
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

    {:ok, %{table: table}, {:continue, :initial_scan}}
  end

  @impl true
  def handle_continue(:initial_scan, state) do
    count = store_tinctures(state.table, scan_tinctures())
    Logger.info("[TinctureRegistry] loaded #{count} tincture(s)")
    {:noreply, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    count = store_tinctures(state.table, scan_tinctures())
    Logger.info("[TinctureRegistry] reloaded #{count} tincture(s)")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:reload_athanor, athanor_id}, _from, state) do
    count =
      case Sanctum.Tenancy.Athanors.get(athanor_id) do
        {:ok, %{status: "active"} = athanor} ->
          store_athanor_tinctures(state.table, athanor_id, scan_one(athanor))

        # Archived, gone, or unreadable: it contributes nothing, and its rows
        # go with it. `scan_tinctures/0` reaches the same end by not
        # enumerating it.
        _ ->
          store_athanor_tinctures(state.table, athanor_id, [])
      end

    Logger.info("[TinctureRegistry] reloaded #{count} tincture(s) for #{athanor_id}")
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
    old_keys = :ets.select(table, [{{:"$1", :_}, [], [:"$1"]}])
    replace(table, old_keys, tinctures)
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
    Sanctum.Tenancy.Athanors.list_active()
    |> Enum.flat_map(&scan_athanor/1)
    |> pick_latest_versions()
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
           ctx,
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
    entry_url = Cyfr.TinctureHelpers.tincture_path(segment, tincture.publisher, tincture.name)
    %{tincture | athanor_segment: segment, entry_url: entry_url}
  end

  defp read_and_parse(ctx, manifest_segs, athanor_id) do
    # Only consider manifests under tinctures/ — components/ also contains
    # catalysts/reagents/formulas which we ignore here. The seed bundle is
    # not an athanor and carries no route.
    if tincture_path?(manifest_segs) do
      case Arca.get(ctx, manifest_segs) do
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

      entry_result = Cyfr.TinctureHelpers.entry_of(manifest)
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

      # The same reading publish and serve use. Indexing a tincture whose
      # entry the serve side will refuse lists something that 404s on the
      # first click — and says nothing about why.
      case {entry_result, blocked_image_refs(media_icon, media_previews)} do
        {{:error, message}, _} ->
          Logger.warning(
            "[TinctureRegistry] skipping tincture at #{Enum.join(manifest_segs, "/")} — #{message}"
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

  defp blocked_image?(path) when is_binary(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in @blocked_image_extensions
  end

  defp blocked_image?(_), do: false

  # When multiple versions of the same tincture exist, keep only the latest.
  #
  # `Compendium.Semver` is the one comparator. The split-on-"." key this
  # replaced ran `Integer.parse/1` over each part, so "1.0.0-rc1" reduced to
  # [1, 0, 0] — indistinguishable from "1.0.0". `Enum.max_by/2` returns the
  # FIRST maximal element, so which of the two the tincture router served at
  # /t/{athanor}/{publisher}/{name} came down to the order the storage walk
  # happened to return, and the console could disagree with the router about
  # what "latest" meant.
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
