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

  defp scan_tinctures do
    components_path = components_path()
    tinctures_base = Path.join(components_path, @tincture_type_plural)

    if File.dir?(tinctures_base) do
      scan_core_tinctures(tinctures_base) ++ scan_arx_tinctures(components_path)
    else
      []
    end
  end

  # Core mode: components/tinctures/{publisher}/{name}/{version}/cyfr-manifest.json
  defp scan_core_tinctures(tinctures_base) do
    pattern = Path.join([tinctures_base, "**", "cyfr-manifest.json"])

    pattern
    |> Path.wildcard()
    |> Enum.flat_map(fn path -> parse_manifest(path, "") end)
    |> pick_latest_versions()
  end

  # Arx mode: components/{org_id}/tinctures/{publisher}/{name}/{version}/cyfr-manifest.json
  defp scan_arx_tinctures(components_path) do
    case Application.get_env(:cyfr, :edition, :core) do
      :arx ->
        case File.ls(components_path) do
          {:ok, entries} -> entries
          {:error, reason} ->
            Logger.warning("TinctureRegistry: cannot list #{components_path}: #{inspect(reason)}")
            []
        end
        |> Enum.filter(fn entry ->
          dir = Path.join(components_path, entry)
          File.dir?(dir) and entry not in Compendium.ComponentPath.type_plurals() and
            File.dir?(Path.join([dir, @tincture_type_plural]))
        end)
        |> Enum.flat_map(fn org_id ->
          pattern =
            Path.join([components_path, org_id, @tincture_type_plural, "**", "cyfr-manifest.json"])

          pattern
          |> Path.wildcard()
          |> Enum.flat_map(fn path -> parse_manifest(path, org_id) end)
        end)
        |> pick_latest_versions()

      _ ->
        []
    end
  end

  defp parse_manifest(manifest_path, org_id) do
    with {:ok, raw} <- File.read(manifest_path),
         {:ok, manifest} <- Jason.decode(raw),
         true <- manifest["type"] == "tincture",
         true <- is_binary(manifest["name"]) do
      version_dir = Path.dirname(manifest_path)
      tincture_block = manifest["tincture"] || %{}
      publisher = manifest["publisher"] || "local"
      name = manifest["name"]
      version = manifest["version"] || "0.1.0"

      entry = tincture_block["entry"] || "index.html"
      entry_url = Cyfr.TinctureHelpers.entry_url(publisher, name, entry)
      icon = tincture_block["icon"] || "palette"
      window = tincture_block["window"] || %{}
      tagline = tincture_block["tagline"]

      # Convention auto-discovery: if the manifest doesn't declare media,
      # fall back to fixed paths under `public/media/`. Manifest still wins
      # as an explicit override for non-standard layouts.
      media_block = tincture_block["media"] || %{}
      discovered = Cyfr.TinctureHelpers.discover_media(version_dir)

      media_icon = media_block["icon"] || discovered.icon

      media_previews =
        case media_block["previews"] do
          list when is_list(list) -> Enum.filter(list, &is_binary/1)
          _ -> discovered.previews
        end

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
          dir: version_dir,
          manifest: manifest
        }
      ]
    else
      {:error, %Jason.DecodeError{} = err} ->
        Logger.warning(
          "TinctureRegistry: invalid JSON in #{manifest_path}: #{Exception.message(err)}"
        )

        []

      {:error, reason} ->
        Logger.warning("TinctureRegistry: cannot read #{manifest_path}: #{inspect(reason)}")
        []

      false ->
        # Warn if manifest declares tincture type but is missing required name field
        with {:ok, raw} <- File.read(manifest_path),
             {:ok, manifest} <- Jason.decode(raw) do
          if manifest["type"] == "tincture" and not is_binary(manifest["name"]) do
            Logger.warning("TinctureRegistry: tincture manifest missing 'name' field: #{manifest_path}")
          end
        end

        []
    end
  end

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

  defp extract_org_id(%{org_id: org_id}) when is_binary(org_id), do: org_id
  defp extract_org_id(%{"org_id" => org_id}) when is_binary(org_id), do: org_id
  defp extract_org_id(_), do: ""

  defp components_path do
    Arca.Adapters.Local.components_path()
  end
end
