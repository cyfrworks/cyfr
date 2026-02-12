defmodule Arca.Adapters.Local do
  @moduledoc """
  Local filesystem storage adapter for Arca.

  ## Path Scoping

  Paths are automatically scoped based on the first segment:

  - **Global paths**: `mcp_logs`, `cache` → `data/{path}`
  - **User paths**: everything else → `data/users/{user_id}/{path}`

  ## Directory Structure

      data/
      ├── cyfr.db                        # SQLite database (all structured data)
      ├── mcp_logs/                      # Global: Emissary MCP request logs
      │   └── {request_id}.json
      ├── cache/                         # Global: immutable cached artifacts
      │   └── oci/{digest}/
      └── users/{user_id}/               # User-scoped
          ├── executions/                # Opus execution lifecycle
          │   └── {execution_id}/
          │       ├── started.json
          │       ├── completed.json
          │       └── failed.json
          ├── builds/                    # Locus build lifecycle
          │   └── {build_id}/
          │       ├── started.json
          │       ├── completed.json
          │       └── build.log
          ├── policy_logs/               # Sanctum policy consultations
          │   └── {request_id}.json
          ├── component_logs/            # Compendium operations
          │   └── {request_id}.json
          └── audit/                     # Sanctum security events
              └── {date}.jsonl           # Append-only

  ## Configuration

      config :arca,
        storage_adapter: Arca.Adapters.Local,
        base_path: "./data"

  """

  @behaviour Arca.Storage

  alias Sanctum.Context

  @impl true
  def get(%Context{} = ctx, path) do
    full_path = build_path(ctx, path)

    case File.read(full_path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
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
  Build the full filesystem path, respecting global vs user-scoped paths.

  Global paths (mcp_logs, cache) are stored at the root.
  User paths are stored under `users/{user_id}/`.
  """
  def build_path(%Context{user_id: user_id}, segments) do
    base = base_path()

    case segments do
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
    Application.fetch_env!(:arca, :base_path)
    |> Path.expand()
  end
end
