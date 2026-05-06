defmodule Prism.TinctureRegistry do
  @moduledoc """
  Registry for tincture components.

  Scans `components/tinctures/` for cyfr-manifest.json files with
  `"type": "tincture"` and provides lookup APIs for the shell and
  public tincture controllers.

  Replaces the legacy `Prism.AppRegistry`.
  """

  use GenServer

  require Logger

  # -- Public API --

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "List all tinctures visible in the given scope."
  @spec list_tinctures(map()) :: [map()]
  def list_tinctures(scope \\ %{}) do
    GenServer.call(__MODULE__, {:list_tinctures, scope})
  end

  @doc "Get a single tincture by publisher and name."
  @spec get_tincture(map(), String.t(), String.t()) :: map() | nil
  def get_tincture(scope \\ %{}, publisher, tincture_name) do
    GenServer.call(__MODULE__, {:get_tincture, scope, publisher, tincture_name})
  end

  @doc "Rescan the filesystem for tinctures."
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  # -- GenServer Callbacks --

  @impl true
  def init(_opts) do
    tinctures = scan_tinctures()
    Logger.info("TinctureRegistry: loaded #{length(tinctures)} tincture(s)")
    {:ok, %{tinctures: tinctures}}
  end

  @impl true
  def handle_call({:list_tinctures, scope}, _from, state) do
    org_id = extract_org_id(scope)
    result = Enum.filter(state.tinctures, fn t -> t.org_id == org_id end)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_tincture, scope, publisher, name}, _from, state) do
    org_id = extract_org_id(scope)

    result =
      Enum.find(state.tinctures, fn t ->
        t.publisher == publisher and t.name == name and t.org_id == org_id
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call(:reload, _from, _state) do
    tinctures = scan_tinctures()
    Logger.info("TinctureRegistry: reloaded #{length(tinctures)} tincture(s)")
    {:reply, :ok, %{tinctures: tinctures}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("#{__MODULE__}: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # -- Scanning --

  # Derive tincture subdirectory name from ComponentPath (single source of truth)
  @tincture_type_plural "tinctures"

  # Scanning runs through Arca (`list_recursive` + `get`) so the registry
  # populates identically on Local FS (Core) and S3 (Arx). The scanner uses
  # a synthetic system context with `:storage_read` permission only — it's a
  # read-only walk of the global `components/` prefix.
  defp scan_tinctures do
    ctx = scan_context()

    case Arca.list_recursive(ctx, ["components"]) do
      {:ok, leaves} ->
        leaves
        |> Enum.filter(fn segs -> List.last(segs) == "cyfr-manifest.json" end)
        |> Enum.flat_map(fn manifest_segs -> read_and_parse(ctx, manifest_segs) end)
        |> pick_latest_versions()

      {:error, reason} ->
        Logger.warning("TinctureRegistry: cannot list components/: #{inspect(reason)}")
        []
    end
  end

  defp scan_context do
    Sanctum.Context.build(
      user_id: "_system_scan",
      permissions: [:storage_read],
      scope: :platform,
      auth_method: :scheduled,
      authenticated: true
    )
  end

  defp read_and_parse(ctx, manifest_segs) do
    org_id = extract_org_id(manifest_segs)

    # Only consider manifests under tinctures/ — components/ also contains
    # catalysts/reagents/formulas which we ignore here.
    if tincture_path?(manifest_segs) do
      case Arca.get(ctx, manifest_segs) do
        {:ok, raw} ->
          parse_manifest(ctx, manifest_segs, raw, org_id)

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

  # Core layout: ["components", "tinctures", publisher, name, version, "cyfr-manifest.json"]
  # Arx layout:  ["components", org_id, "tinctures", publisher, name, version, "cyfr-manifest.json"]
  defp tincture_path?(["components", @tincture_type_plural | _]), do: true
  defp tincture_path?(["components", _org_id, @tincture_type_plural | _]), do: true
  defp tincture_path?(_), do: false

  # Manifest-segments → org_id: Core layout has empty string, Arx layout has
  # the org_id sandwiched between "components" and "tinctures".
  defp extract_org_id(["components", @tincture_type_plural | _]), do: ""
  defp extract_org_id(["components", org_id, @tincture_type_plural | _]), do: org_id
  # Scope map → org_id: used by `list_tinctures(scope)` filtering.
  defp extract_org_id(%{org_id: org_id}) when is_binary(org_id), do: org_id
  defp extract_org_id(%{"org_id" => org_id}) when is_binary(org_id), do: org_id
  defp extract_org_id(_), do: ""

  # Launch constraint: tinctures can't carry raster image assets until
  # CSAM hash matching (PhotoDNA) is live. Vector (.svg) is allowed.
  @blocked_image_extensions ~w(.png .jpg .jpeg .gif .webp)

  defp parse_manifest(ctx, manifest_segs, raw, org_id) do
    with {:ok, manifest} <- Jason.decode(raw),
         true <- manifest["type"] == "tincture",
         true <- is_binary(manifest["name"]) do
      version_segs = Enum.drop(manifest_segs, -1)
      tincture_block = manifest["tincture"] || %{}
      publisher = manifest["publisher"] || "local"
      name = manifest["name"]
      version = manifest["version"] || "0.1.0"

      entry = tincture_block["entry"] || "index.html"
      entry_url = Cyfr.TinctureHelpers.entry_url(publisher, name, entry)
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
              org_id: org_id,
              title: manifest["description"] || name,
              tagline: tagline,
              icon: icon,
              media_icon: media_icon,
              media_previews: media_previews,
              entry: entry,
              entry_url: entry_url,
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
    |> Enum.group_by(fn t -> {t.org_id, t.publisher, t.name} end)
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
