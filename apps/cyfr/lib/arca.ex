# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca do
  @moduledoc """
  Unified storage layer for CYFR.

  Provides a consistent interface for file/artifact storage that works
  with the local filesystem or, when a non-default storage adapter is
  configured, an object-store backend.

  All operations require a `Sanctum.Context` to enable per-user isolation
  and a tenant-scoping-ready architecture.

  ## Path Scoping

  Paths are automatically scoped based on the first segment:

  - `["components" | rest]` → component artifacts root (`:components_path`);
    `Compendium.ComponentPath` puts the tenant inside the segments, so the
    on-disk layout is `components/{athanor_id}/{type}s/...`
  - `["cache" | rest]`, `["system" | rest]` → global (no tenant prefix), under `:base_path`
  - everything else → tenant-scoped under `{athanor_id}/...`
    (`namespace` is identity-only and not part of the path)

  See `Arca.Storage` for the full bypass-group policy, `@global_prefixes`
  list, `authorize_path/2` (the component-tree pin) and `tenant_segments/1`
  (the canonical tenant-segment builder).

  ## Usage

      ctx = Sanctum.TestContext.local()

      # Tenant-scoped storage (auto-prefixed with {athanor_id}/)
      :ok = Arca.put(ctx, ["builds", "build_1", "started.json"], json)
      {:ok, content} = Arca.get(ctx, ["builds", "build_1", "started.json"])

      # Global storage (no tenant prefix)
      :ok = Arca.put(ctx, ["cache", "oci", "sha256_abc"], wasm_binary)

      # Append-only storage (for audit logs)
      :ok = Arca.append(ctx, ["audit", "2025-01-15.jsonl"], log_line <> "\\n")

      # JSON convenience functions
      :ok = Arca.put_json(ctx, ["config", "settings.json"], %{...})
      {:ok, map} = Arca.get_json(ctx, ["config", "settings.json"])

  ## Retention

  See `Cyfr.Retention` for managing data retention policies. Retention
  settings can also be managed via the MCP `retention` tool.

  ## Configuration

      config :cyfr,
        storage_adapter: Arca.Adapters.Local,
        base_path: "./data"

      # Retention defaults
      config :cyfr, Cyfr.Retention,
        executions: 10,
        builds: 10

  """

  alias Sanctum.Context

  @doc """
  Read content from storage.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.put(ctx, ["test", "file.txt"], "hello")
      :ok
      iex> Arca.get(ctx, ["test", "file.txt"])
      {:ok, "hello"}

  """
  def get(%Context{} = ctx, path), do: guarded(ctx, path, fn -> adapter(path).get(ctx, path) end)

  @doc """
  Read and decode JSON content from storage.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
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

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.put(ctx, ["deep", "nested", "path", "file.txt"], "content")
      :ok

  """
  def put(%Context{} = ctx, path, content),
    do: mutating(ctx, path, fn -> adapter(path).put(ctx, path, content) end)

  @doc """
  Encode and write JSON content to storage.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
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

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.append(ctx, ["audit", "2025-01-15.jsonl"], ~s|{"event":"login"}\\n|)
      :ok
      iex> Arca.append(ctx, ["audit", "2025-01-15.jsonl"], ~s|{"event":"logout"}\\n|)
      :ok

  """
  def append(%Context{} = ctx, path, content),
    do: guarded(ctx, path, fn -> adapter(path).append(ctx, path, content) end)

  @doc """
  Delete content from storage.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.put(ctx, ["test", "file.txt"], "hello")
      :ok
      iex> Arca.delete(ctx, ["test", "file.txt"])
      :ok
      iex> Arca.get(ctx, ["test", "file.txt"])
      {:error, :not_found}

  """
  def delete(%Context{} = ctx, path),
    do: mutating(ctx, path, fn -> adapter(path).delete(ctx, path) end)

  @doc """
  List contents at path.

  Returns empty list if path doesn't exist.
  Note: Order of results is not guaranteed.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.put(ctx, ["listdir", "a.txt"], "a")
      :ok
      iex> Arca.put(ctx, ["listdir", "b.txt"], "b")
      :ok
      iex> {:ok, files} = Arca.list(ctx, ["listdir"])
      iex> Enum.sort(files)
      ["a.txt", "b.txt"]

  """
  def list(%Context{} = ctx, path), do: guarded(ctx, path, fn -> adapter(path).list(ctx, path) end)

  @doc """
  List the entries directly under a path, each tagged `:file` or `:dir`.

  The kind comes from the adapter, so a caller that needs it does not have to
  know which adapter is configured or how it lays paths out. A path that is
  itself a file answers `{:error, :enotdir}`.
  """
  def list_typed(%Context{} = ctx, path),
    do: guarded(ctx, path, fn -> adapter(path).list_typed(ctx, path) end)

  @doc """
  Recursive file count and byte total under a path prefix.

  Returns `{:ok, %{files: n, bytes: n}}`. Quota enforcement reads this.
  """
  def usage(%Context{} = ctx, path), do: guarded(ctx, path, fn -> adapter(path).usage(ctx, path) end)

  @doc """
  Check if path exists.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.exists?(ctx, ["nonexistent"])
      false

  """
  def exists?(%Context{} = ctx, path) do
    case Arca.Storage.authorize_path(ctx, path) do
      :ok -> adapter(path).exists?(ctx, path)
      {:error, :forbidden} -> false
    end
  end

  @doc """
  Recursively delete a directory tree at path.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.put(ctx, ["builds", "build_1", "started.json"], "{}")
      :ok
      iex> Arca.delete_tree(ctx, ["builds", "build_1"])
      :ok

  """
  def delete_tree(%Context{} = ctx, path),
    do: mutating(ctx, path, fn -> adapter(path).delete_tree(ctx, path) end)

  @doc """
  Recursively list all leaf paths under a prefix.

  Returns full segment lists so callers can pass them straight to `get/2`.
  Order is unspecified.
  """
  def list_recursive(%Context{} = ctx, path),
    do: guarded(ctx, path, fn -> adapter(path).list_recursive(ctx, path) end)

  @doc """
  Read a whole subtree as `{relative_path, binary}` pairs.

  Memory-bounded; for large single files use `serve_to_conn/4` instead.
  """
  def read_subtree(%Context{} = ctx, path),
    do: guarded(ctx, path, fn -> adapter(path).read_subtree(ctx, path) end)

  @doc """
  Copy a whole subtree from `src` to `dest` (segment prefix → segment prefix).

  Reads `src` via `read_subtree/2` and `put/3`s each file under `dest`,
  preserving relative layout. Adapter-agnostic (Local FS or object store).
  Content-only — the source is left untouched, so a *move* is a successful
  `copy_tree/3` followed by `delete_tree/2`. Returns `:ok` or the first
  `{:error, reason}`.
  """
  def copy_tree(%Context{} = ctx, src, dest) do
    with {:ok, pairs} <- read_subtree(ctx, src) do
      Enum.reduce_while(pairs, :ok, fn {relative, content}, :ok ->
        case put(ctx, dest ++ relative, content) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  @doc """
  Stream a stored object to a `Plug.Conn`.

  Caller owns Content-Type, CSP, and caching headers; the adapter handles
  the body transfer. Returns `{:ok, conn}` or `{:error, term()}`.
  """
  def serve_to_conn(conn, %Context{} = ctx, path, opts \\ []),
    do: guarded(ctx, path, fn -> adapter(path).serve_to_conn(conn, ctx, path, opts) end)

  # Every entry point runs the component-path pin before touching the
  # adapter, so no adapter — and no future one — can hand one athanor
  # another athanor's bytes.
  defp guarded(ctx, path, fun) do
    case Arca.Storage.authorize_path(ctx, path) do
      :ok -> fun.()
      {:error, :forbidden} = err -> err
    end
  end

  # A write anywhere under `components/<athanor>` changes what the storage
  # cap measures, and that total is cached because walking the tree on every
  # guest write is the cost the cap was written to avoid. Invalidating here
  # rather than in each writer means a new writer cannot forget — every
  # mutation already passes through. Unconditional: a failed write may still
  # have left bytes behind.
  defp mutating(ctx, path, fun) do
    result = guarded(ctx, path, fun)
    invalidate_components_usage(path)
    result
  end

  defp invalidate_components_usage(["components", athanor_id | _]) when is_binary(athanor_id),
    do: Arca.Cache.invalidate(Arca.Cache.Keys.components_usage(athanor_id))

  defp invalidate_components_usage(_path), do: :ok

  # The seed bundle is server install media read straight from local disk
  # (`:cyfr, :bundle_path`), whatever storage adapter is configured — an
  # object-store deployment provisions athanors from the shipped bundle
  # without the bucket ever holding a copy. Everything else goes to the
  # configured adapter.
  defp adapter(["components", "_bundle" | _]), do: Arca.Adapters.Local
  defp adapter(_path), do: Application.get_env(:cyfr, :storage_adapter, Arca.Adapters.Local)
end
