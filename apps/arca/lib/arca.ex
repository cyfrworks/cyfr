defmodule Arca do
  @moduledoc """
  Unified storage layer for CYFR.

  Provides a consistent interface for file/artifact storage that works
  with local filesystem (Community) or cloud storage (Managed/Enterprise).

  All operations require a `Sanctum.Context` to enable per-user isolation
  and multi-tenant-ready architecture.

  ## Path Scoping

  Paths are automatically scoped based on the first segment:

  - **Global paths**: `mcp_logs`, `cache` → stored at root level
  - **User paths**: everything else → stored under `users/{user_id}/`

  ## Usage

      ctx = Sanctum.Context.local()

      # User-scoped storage (auto-prefixed with users/{user_id}/)
      :ok = Arca.put(ctx, ["executions", "exec_123", "started.json"], json)
      {:ok, content} = Arca.get(ctx, ["executions", "exec_123", "started.json"])

      # Global storage (no user prefix)
      :ok = Arca.put(ctx, ["mcp_logs", "req_123.json"], json)
      :ok = Arca.put(ctx, ["cache", "oci", "sha256_abc"], wasm_binary)

      # Append-only storage (for audit logs)
      :ok = Arca.append(ctx, ["audit", "2025-01-15.jsonl"], log_line <> "\\n")

      # JSON convenience functions
      :ok = Arca.put_json(ctx, ["executions", "exec_123", "started.json"], %{...})
      {:ok, map} = Arca.get_json(ctx, ["executions", "exec_123", "started.json"])

  ## Retention

  See `Arca.Retention` for managing data retention policies. Retention
  settings can also be managed via the MCP `storage` tool with `action: "retention"`.

  ## Configuration

      config :arca,
        storage_adapter: Arca.Adapters.Local,
        base_path: "./data"

      # Retention defaults
      config :arca, Arca.Retention,
        executions: 10,
        builds: 10,
        audit_days: 30

  """

  alias Sanctum.Context

  @doc """
  Read content from storage.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Arca.put(ctx, ["test", "file.txt"], "hello")
      :ok
      iex> Arca.get(ctx, ["test", "file.txt"])
      {:ok, "hello"}

  """
  def get(%Context{} = ctx, path), do: adapter().get(ctx, path)

  @doc """
  Read and decode JSON content from storage.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Arca.put_json(ctx, ["test", "data.json"], %{"key" => "value"})
      :ok
      iex> Arca.get_json(ctx, ["test", "data.json"])
      {:ok, %{"key" => "value"}}

  """
  def get_json(%Context{} = ctx, path) do
    case get(ctx, path) do
      {:ok, content} -> Jason.decode(content)
      {:error, _} = error -> error
    end
  end

  @doc """
  Write content to storage (overwrites existing).

  Creates parent directories automatically.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Arca.put(ctx, ["deep", "nested", "path", "file.txt"], "content")
      :ok

  """
  def put(%Context{} = ctx, path, content), do: adapter().put(ctx, path, content)

  @doc """
  Encode and write JSON content to storage.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Arca.put_json(ctx, ["test", "data.json"], %{"key" => "value"})
      :ok

  """
  def put_json(%Context{} = ctx, path, data) do
    case Jason.encode(data) do
      {:ok, json} -> put(ctx, path, json)
      {:error, _} = error -> error
    end
  end

  @doc """
  Append content to storage (for append-only logs).

  Creates parent directories automatically. Content is appended to the
  end of the file without overwriting existing content.

  Useful for audit logs stored as JSONL (JSON Lines) format.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Arca.append(ctx, ["audit", "2025-01-15.jsonl"], ~s|{"event":"login"}\\n|)
      :ok
      iex> Arca.append(ctx, ["audit", "2025-01-15.jsonl"], ~s|{"event":"logout"}\\n|)
      :ok

  """
  def append(%Context{} = ctx, path, content), do: adapter().append(ctx, path, content)

  @doc """
  Encode and append JSON content as a line to storage (JSONL format).

  Automatically adds a newline after the JSON.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Arca.append_json(ctx, ["audit", "2025-01-15.jsonl"], %{"event" => "login"})
      :ok

  """
  def append_json(%Context{} = ctx, path, data) do
    case Jason.encode(data) do
      {:ok, json} -> append(ctx, path, json <> "\n")
      {:error, _} = error -> error
    end
  end

  @doc """
  Delete content from storage.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Arca.put(ctx, ["test", "file.txt"], "hello")
      :ok
      iex> Arca.delete(ctx, ["test", "file.txt"])
      :ok
      iex> Arca.get(ctx, ["test", "file.txt"])
      {:error, :not_found}

  """
  def delete(%Context{} = ctx, path), do: adapter().delete(ctx, path)

  @doc """
  List contents at path.

  Returns empty list if path doesn't exist.
  Note: Order of results is not guaranteed.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Arca.put(ctx, ["listdir", "a.txt"], "a")
      :ok
      iex> Arca.put(ctx, ["listdir", "b.txt"], "b")
      :ok
      iex> {:ok, files} = Arca.list(ctx, ["listdir"])
      iex> Enum.sort(files)
      ["a.txt", "b.txt"]

  """
  def list(%Context{} = ctx, path), do: adapter().list(ctx, path)

  @doc """
  Check if path exists.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Arca.exists?(ctx, ["nonexistent"])
      false

  """
  def exists?(%Context{} = ctx, path), do: adapter().exists?(ctx, path)

  @doc """
  Recursively delete a directory tree at path.

  ## Examples

      iex> ctx = Sanctum.Context.local()
      iex> Arca.put(ctx, ["builds", "build_1", "started.json"], "{}")
      :ok
      iex> Arca.delete_tree(ctx, ["builds", "build_1"])
      :ok

  """
  def delete_tree(%Context{} = ctx, path), do: adapter().delete_tree(ctx, path)

  defp adapter do
    Application.get_env(:arca, :storage_adapter, Arca.Adapters.Local)
  end
end
