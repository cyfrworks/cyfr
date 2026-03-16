defmodule Arca.Adapters.Local do
  @moduledoc """
  Local filesystem storage adapter for Arca.

  ## Path Scoping

  Paths are automatically scoped based on the first segment:

  - **Component paths**: `["components" | rest]` → `components_path/{rest}`
  - **Global paths**: `cache` → `data/{path}`
  - **User paths**: everything else → `data/users/{user_id}/{path}`

  ## Directory Structure

      components/                        # Component artifacts (separate root)
      └── {type}s/{publisher}/{name}/{version}/
          ├── {type}.wasm
          ├── cyfr-manifest.json
          └── src/

      data/
      ├── {env}.db                       # SQLite database (all structured data)
      ├── cache/                         # Global: immutable cached artifacts
      │   └── oci/{digest}/
      └── users/{user_id}/               # User-scoped
          ├── builds/                    # Locus build lifecycle
          │   └── {build_id}/
          │       ├── started.json
          │       ├── completed.json
          │       └── build.log
          ├── data/                      # User data (agent conversations, etc.)
          ├── config/                    # User config (retention settings, etc.)
          └── audit/                     # Audit events (append-only JSONL, opt-in)
              └── {date}.jsonl

  ## Structured Logs (SQLite only)

  MCP request logs, execution records, and policy consultation logs are stored
  exclusively in SQLite tables (`mcp_logs`, `executions`, `policy_logs`).
  They are NOT written to disk files.

  ## Configuration

      config :cyfr,
        storage_adapter: Arca.Adapters.Local,
        base_path: "./data",
        components_path: "./components"

  """

  @behaviour Arca.Storage

  require Logger
  alias Sanctum.Context

  @impl true
  def get(%Context{} = ctx, path) do
    full_path = build_path(ctx, path)

    case File.read(full_path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        Logger.warning(
          "[Arca.Local.get] :enoent for full_path=#{full_path}, segments=#{inspect(path)}, exists?=#{File.exists?(full_path)}"
        )

        {:error, :not_found}

      {:error, reason} ->
        Logger.warning("[Arca.Local.get] error=#{inspect(reason)} for full_path=#{full_path}")
        {:error, reason}
    end
  end

  @impl true
  def put(%Context{} = ctx, path, content) do
    full_path = build_path(ctx, path)

    with :ok <- full_path |> Path.dirname() |> File.mkdir_p() do
      File.write(full_path, content)
    end
  end

  @impl true
  def append(%Context{} = ctx, path, content) do
    full_path = build_path(ctx, path)

    with :ok <- full_path |> Path.dirname() |> File.mkdir_p() do
      File.write(full_path, content, [:append])
    end
  end

  @impl true
  def delete(%Context{} = ctx, path) do
    full_path = build_path(ctx, path)

    case File.rm(full_path) do
      :ok -> :ok
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list(%Context{} = ctx, path) do
    full_path = build_path(ctx, path)

    case File.ls(full_path) do
      {:ok, files} -> {:ok, files}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def exists?(%Context{} = ctx, path) do
    full_path = build_path(ctx, path)
    File.exists?(full_path)
  end

  @impl true
  def delete_tree(%Context{} = ctx, path) do
    full_path = build_path(ctx, path)

    case File.rm_rf(full_path) do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, reason}
    end
  end

  @doc """
  Build the full filesystem path, respecting component, global, and user-scoped paths.

  Component paths (`["components" | rest]`) are routed to `components_path`.
  Global paths (mcp_logs, cache) are stored at the root.
  User paths are stored under `users/{user_id}/`.
  """
  def build_path(%Context{user_id: user_id}, segments) do
    Arca.Storage.validate_path!(segments)
    base = base_path()

    case segments do
      ["components", "orgs", org_id | rest] ->
        # Org-scoped component path (Arx mode)
        Path.join([components_path(), "orgs", org_id | rest])

      ["components" | rest] ->
        # Component path - routed to components_path
        Path.join([components_path() | rest])

      [prefix | _rest] ->
        if prefix in Arca.Storage.global_prefixes() do
          # Global path - no user prefix
          Path.join([base | segments])
        else
          # User-scoped path
          Path.join([base, "users", user_id | segments])
        end

      _ ->
        # Empty segments - user-scoped root
        Path.join([base, "users", user_id])
    end
  end

  @doc """
  Get the expanded base path for storage.
  """
  def base_path do
    Application.fetch_env!(:cyfr, :base_path)
    |> Path.expand()
  end

  @doc """
  Get the expanded components path for component storage.
  """
  def components_path do
    Application.get_env(:cyfr, :components_path, "./components")
    |> Path.expand()
  end
end
