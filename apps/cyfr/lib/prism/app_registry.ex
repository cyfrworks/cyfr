defmodule Prism.AppRegistry do
  @moduledoc """
  Registry for local iframe apps.

  Scans `data/apps/` for cyfr-manifest.json files and provides
  lookup APIs for the shell to discover installable apps.
  """

  use GenServer

  require Logger

  @default_apps_dir "data/apps"

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List all registered apps."
  def list_apps do
    GenServer.call(__MODULE__, :list_apps)
  end

  @doc "Get a single app by its id (e.g., \"hello\" or \"iframe_hello\")."
  def get_app(id) do
    GenServer.call(__MODULE__, {:get_app, id})
  end

  @doc "Rescan the filesystem for apps."
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  # -- GenServer Callbacks --

  @impl true
  def init(opts) do
    apps_dir = opts[:apps_dir] || apps_dir()
    apps = scan_apps(apps_dir)
    Logger.info("AppRegistry: loaded #{length(apps)} app(s) from #{apps_dir}")
    {:ok, %{apps_dir: apps_dir, apps: apps}}
  end

  @impl true
  def handle_call(:list_apps, _from, state) do
    {:reply, state.apps, state}
  end

  @impl true
  def handle_call({:get_app, id}, _from, state) do
    # Strip "iframe_" prefix if present
    name = String.replace_prefix(id, "iframe_", "")

    app = Enum.find(state.apps, fn a -> a.name == name || a.id == id end)
    {:reply, app, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    apps = scan_apps(state.apps_dir)
    Logger.info("AppRegistry: reloaded #{length(apps)} app(s)")
    {:reply, :ok, %{state | apps: apps}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("#{__MODULE__}: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # -- Scanning --

  defp scan_apps(apps_dir) do
    manifest_pattern = Path.join([apps_dir, "**", "cyfr-manifest.json"])

    manifest_pattern
    |> Path.wildcard()
    |> Enum.flat_map(&parse_manifest/1)
  end

  defp parse_manifest(manifest_path) do
    with {:ok, raw} <- File.read(manifest_path),
         {:ok, manifest} <- Jason.decode(raw),
         true <- manifest["type"] == "app",
         true <- is_binary(manifest["name"]) do
      app_dir = Path.dirname(manifest_path)
      app_config = manifest["app"] || %{}
      publisher = manifest["publisher"] || "local"
      name = manifest["name"]
      version = manifest["version"] || "1.0.0"

      entry = app_config["entry"] || "index.html"
      entry_url = "/apps/#{publisher}/#{name}/#{version}/#{entry}"

      [
        %{
          id: name,
          name: name,
          publisher: publisher,
          version: version,
          title: manifest["description"] || name,
          icon: app_config["icon"] || "cube",
          entry: entry,
          entry_url: entry_url,
          dir: app_dir,
          manifest: manifest
        }
      ]
    else
      {:error, %Jason.DecodeError{} = err} ->
        Logger.warning("AppRegistry: invalid JSON in #{manifest_path}: #{Exception.message(err)}")
        []

      {:error, reason} ->
        Logger.warning("AppRegistry: cannot read #{manifest_path}: #{inspect(reason)}")
        []

      false ->
        Logger.warning("AppRegistry: skipping #{manifest_path} (not type=app or missing name)")
        []
    end
  end

  defp apps_dir do
    Application.get_env(:cyfr, :apps_dir, @default_apps_dir)
  end
end
