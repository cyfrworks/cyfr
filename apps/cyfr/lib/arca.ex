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

  Every path is tenant-relative — the athanor always comes from the
  context. Scoping keys on the first segment:

  - `["components" | rest]` → the context's athanor's component artifacts
    (`Compendium.ComponentPath` builds the shape)
  - `["seed", root | rest]` → seed media (the component bundle, the AQUA
    template — `Arca.Storage.seed_roots/0`), read in place from local disk
    whatever storage adapter is configured — and read-only at this seam
  - `["cache" | rest]`, `["system" | rest]` → global (no tenant prefix)
  - the other tenant scopes (`Arca.Storage.tenant_roots/0`) → verbatim
    under the context's athanor (`namespace` is identity-only and not
    part of the path)
  - anything else → `{:error, :forbidden}`; an unknown root is refused,
    never minted as a new subtree

  `Arca.Storage.physical_segments/2` is the one place the stored layout
  (`athanors/{athanor_id}/...` under a single root) is written down.

  See `Arca.Storage` for the full bypass-group policy, `@global_prefixes`
  list, `authorize_path/2` (the reserved-root gate) and `tenant_segments/1`
  (the canonical tenant-segment builder).

  ## Usage

      ctx = Sanctum.TestContext.local()

      # Tenant-scoped storage (auto-prefixed with {athanor_id}/)
      :ok = Arca.put(ctx, ["builds", "build_1.json"], json)
      {:ok, content} = Arca.get(ctx, ["builds", "build_1.json"])

      # Global storage (no tenant prefix)
      :ok = Arca.put(ctx, ["cache", "oci", "sha256_abc"], wasm_binary)

      # Append-only storage (JSONL-style logs)
      :ok = Arca.append(ctx, ["guest", "logs", "2025-01-15.jsonl"], log_line <> "\\n")

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

      # Retention overrides (defaults live in Cyfr.Retention)
      config :cyfr, Cyfr.Retention,
        executions: 10_000,
        builds: 100

  """

  alias Sanctum.Context

  @doc """
  Read content from storage.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.put(ctx, ["guest", "file.txt"], "hello")
      :ok
      iex> Arca.get(ctx, ["guest", "file.txt"])
      {:ok, "hello"}

  """
  def get(%Context{} = ctx, path), do: guarded(ctx, path, fn p -> adapter(p).get(ctx, p) end)

  @doc """
  Read and decode JSON content from storage.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.put_json(ctx, ["config", "data.json"], %{"key" => "value"})
      :ok
      iex> Arca.get_json(ctx, ["config", "data.json"])
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
      iex> Arca.put(ctx, ["guest", "nested", "path", "file.txt"], "content")
      :ok

  """
  def put(%Context{} = ctx, path, content),
    do: mutating(ctx, path, {:create, byte_size(content)}, fn p -> adapter(p).put(ctx, p, content) end)

  @doc """
  Encode and write JSON content to storage.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.put_json(ctx, ["config", "data.json"], %{"key" => "value"})
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

  Useful for logs stored as JSONL (JSON Lines) format.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.append(ctx, ["guest", "logs", "2025-01-15.jsonl"], ~s|{"event":"login"}\\n|)
      :ok
      iex> Arca.append(ctx, ["guest", "logs", "2025-01-15.jsonl"], ~s|{"event":"logout"}\\n|)
      :ok

  """
  def append(%Context{} = ctx, path, content),
    do:
      mutating(ctx, path, {:create, byte_size(content)}, fn p ->
        adapter(p).append(ctx, p, content)
      end)

  @doc """
  Delete content from storage.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.put(ctx, ["guest", "file.txt"], "hello")
      :ok
      iex> Arca.delete(ctx, ["guest", "file.txt"])
      :ok
      iex> Arca.get(ctx, ["guest", "file.txt"])
      {:error, :not_found}

  """
  def delete(%Context{} = ctx, path),
    do: mutating(ctx, path, :delete, fn p -> adapter(p).delete(ctx, p) end)

  @doc """
  List contents at path.

  Returns empty list if path doesn't exist.
  Note: Order of results is not guaranteed.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.put(ctx, ["guest", "listdir", "a.txt"], "a")
      :ok
      iex> Arca.put(ctx, ["guest", "listdir", "b.txt"], "b")
      :ok
      iex> {:ok, files} = Arca.list(ctx, ["guest", "listdir"])
      iex> Enum.sort(files)
      ["a.txt", "b.txt"]

  """
  def list(%Context{} = ctx, path),
    do: guarded(ctx, path, fn p -> adapter(p).list(ctx, p) end)

  @doc """
  List the entries directly under a path, each tagged `:file` or `:dir`.

  The kind comes from the adapter, so a caller that needs it does not have to
  know which adapter is configured or how it lays paths out. A path that is
  itself a file answers `{:error, :enotdir}`.
  """
  def list_typed(%Context{} = ctx, path),
    do: guarded(ctx, path, fn p -> adapter(p).list_typed(ctx, p) end)

  @doc """
  Recursive file count and byte total under a path prefix.

  Returns `{:ok, %{files: n, bytes: n}}`. Quota enforcement reads this.
  """
  def usage(%Context{} = ctx, path),
    do: guarded(ctx, path, fn p -> adapter(p).usage(ctx, p) end)

  @doc """
  Check if path exists.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.exists?(ctx, ["guest", "nonexistent"])
      false

  """
  def exists?(%Context{} = ctx, path) do
    path = normalize(path)

    case Arca.Storage.authorize_path(ctx, path) do
      :ok -> adapter(path).exists?(ctx, path)
      {:error, :forbidden} -> false
    end
  end

  @doc """
  Recursively delete a directory tree at path.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.put(ctx, ["conversations", "conv_1", "msg_1.json"], "{}")
      :ok
      iex> Arca.delete_tree(ctx, ["conversations", "conv_1"])
      :ok

  """
  def delete_tree(%Context{} = ctx, path),
    do: mutating(ctx, path, :delete, fn p -> adapter(p).delete_tree(ctx, p) end)

  @doc """
  Recursively list all leaf paths under a prefix.

  Returns full segment lists so callers can pass them straight to `get/2`.
  Order is unspecified.
  """
  def list_recursive(%Context{} = ctx, path),
    do: guarded(ctx, path, fn p -> adapter(p).list_recursive(ctx, p) end)

  @doc """
  Read a whole subtree as `{relative_path, binary}` pairs.

  Memory-bounded; for large single files use `serve_to_conn/4` instead.
  """
  def read_subtree(%Context{} = ctx, path),
    do: guarded(ctx, path, fn p -> adapter(p).read_subtree(ctx, p) end)

  @doc """
  Copy a whole subtree from `src` to `dest` (segment prefix → segment prefix).

  Lists `src` via `list_recursive/2`, then streams each file with `get/2` +
  `put/3` under `dest`, preserving relative layout — one file in memory at a
  time. Adapter-agnostic (Local FS or object store). Content-only — the
  source is left untouched, so a *move* is a successful `copy_tree/3`
  followed by `delete_tree/2`. Returns `:ok` or the first `{:error, reason}`.

  `exclude: fn relative_segments -> boolean end` skips matching files before
  their content is ever read — how the seeder keeps build droppings
  (`target/`, `node_modules/`) out of athanor trees.
  """
  def copy_tree(%Context{} = ctx, src, dest, opts \\ []) do
    exclude = Keyword.get(opts, :exclude, fn _relative -> false end)
    src = normalize(src)
    dest = normalize(dest)

    with {:ok, leaves} <- list_recursive(ctx, src) do
      leaves
      |> Enum.map(&Enum.drop(&1, length(src)))
      |> Enum.reject(exclude)
      |> Enum.reduce_while(:ok, fn relative, :ok ->
        case get(ctx, src ++ relative) do
          {:ok, content} ->
            case put(ctx, dest ++ relative, content) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          # File vanished between list and read — skip; concurrent delete is
          # unusual but not an error condition for a tree copy.
          {:error, :not_found} ->
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, reason}}
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
    do: guarded(ctx, path, fn p -> adapter(p).serve_to_conn(conn, ctx, p, opts) end)

  # One spelling per object: every entry point flattens multi-level string
  # segments (`"a/b"` → `["a", "b"]`, split artifacts dropped) before the
  # gate, so the two adapters — one joins with the filesystem, one joins
  # into a key — can never disagree about which object a path names.
  # `Cyfr.PathSafety` still refuses a bare `""` at the adapter, for callers
  # that reach one directly.
  defp normalize(segments) when is_list(segments) do
    Enum.flat_map(segments, fn
      segment when is_binary(segment) -> segment |> String.split("/") |> Enum.reject(&(&1 == ""))
      other -> [other]
    end)
  end

  # `put`/`append` may not name a `.tmp.N` file: that suffix is the Local
  # adapter's in-flight write marker, invisible to listings and to the
  # usage walk — a caller-chosen tmp name would be a hidden, uncounted,
  # sweeper-reaped object (and the S3 adapter would disagree about all
  # three). Reserving the pattern keeps it meaning exactly one thing.
  defp reserved_name?(path) do
    case List.last(path) do
      nil -> false
      name -> name =~ ~r/\.tmp\.\d+$/
    end
  end

  # Every entry point runs the reserved-root gate before touching the
  # adapter: the seed bundle and the global roots are the server's own, and
  # every tenant path takes its athanor from the context — there is no path
  # spelling that reaches another athanor's bytes.
  defp guarded(ctx, path, fun) do
    path = normalize(path)

    case Arca.Storage.authorize_path(ctx, path) do
      :ok -> fun.(path)
      {:error, :forbidden} = err -> err
    end
  end

  # Seed media is read-only at this seam, whatever the context: the seeder
  # and the AQUA template only ever read seed and write the athanor, so a
  # write here is always a bug — and letting one through would mutate the
  # tracked repo tree or the operator's mount. "Read in place" is an
  # invariant, not a convention.
  #
  # For everything else: a write anywhere in the athanor's tree changes
  # what the storage cap measures, and that total is cached because walking
  # the tree on every guest write is the cost the cap was written to avoid.
  # Invalidating here rather than in each writer means a new writer cannot
  # forget — every mutation already passes through. Unconditional: a failed
  # write may still have left bytes behind. Globals are not tenant bytes
  # and invalidate nothing.
  defp mutating(ctx, path, kind, fun) do
    path = normalize(path)

    cond do
      Arca.Storage.classify(path) == :seed ->
        {:error, :seed_read_only}

      match?({:create, _}, kind) and reserved_name?(path) ->
        {:error, :reserved_name}

      true ->
        result = guarded(ctx, path, fun)
        invalidate_athanor_usage(ctx, path)
        result
    end
  end

  defp invalidate_athanor_usage(%Context{athanor_id: athanor_id}, path)
       when is_binary(athanor_id) and athanor_id != "" do
    if Arca.Storage.classify(path) == :tenant,
      do: Arca.Cache.invalidate(Arca.Cache.Keys.athanor_usage(athanor_id)),
      else: :ok
  end

  defp invalidate_athanor_usage(_ctx, _path), do: :ok

  # Seed media is server install media read straight from local disk
  # (the one seed tree, `:seed_path` — `Arca.Storage.seed_roots/0`), whatever
  # storage adapter is configured: an object-store deployment provisions
  # athanors from the shipped media without the bucket ever holding a copy.
  # Everything else goes to the configured adapter.
  defp adapter(["seed" | _]), do: Arca.Adapters.Local
  defp adapter(_path), do: Application.get_env(:cyfr, :storage_adapter, Arca.Adapters.Local)
end
