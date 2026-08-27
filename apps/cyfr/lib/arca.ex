# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca do
  @moduledoc """
  Unified storage layer for CYFR.

  Provides a consistent interface for file/artifact storage that works
  with the local filesystem or, when a non-default storage adapter is
  configured, an object-store backend.

  Two persistence planes share the `Arca` name and only tenancy besides:
  **blobs** go through this module (backed by `Arca.Storage` adapters),
  **rows** go through the Ecto modules (`Arca.*Storage`, `Arca.Execution`,
  `Arca.McpLog`, …) on `Arca.Repo`. Structured records want queries and
  uniqueness; WASM binaries, tincture trees and attachments want a
  filesystem or object store. Don't put "storage" in a new blob helper's
  name — the suffix is the row plane's.

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

  Mutating operations (`put/3`, `append/3`, `delete/2`) require a path at
  least two segments deep — the athanor root and the scope roots are
  directories, never objects, and a write there would wedge the tree
  (`{:error, :invalid_path}`). `delete_tree/2` is exempt: deleting a whole
  scope, or the whole tree (`[]`, the purge), is exactly its job.

  `Arca.Storage.physical_segments/2` is the one place the stored layout
  (`athanors/{athanor_id}/...` under a single root) is written down.

  See `Arca.Storage` for the full bypass-group policy, `@global_prefixes`
  list, `authorize_path/2` (the reserved-root gate) and `tenant_segments/1`
  (the canonical tenant-segment builder).

  ## Errors

  One rule decides tuple-vs-raise: **typed tuples** for conditions a
  caller can classify and act on, **raises** for host-side programmer
  error.

  Typed tuples, whoever the caller: `:not_found`; `:forbidden` (unknown or
  reserved root, from `authorize_path/2`); `:seed_read_only`;
  `:reserved_name` (the `.tmp.<n>` shape); `:invalid_path` (a mutation
  above depth 2); `:bundled` (deleting an unmaterialized seed unit);
  `{:materialize_failed, reason}` and `{:limit_reached,
  :athanor_storage_bytes, cap}` (copy-on-write materialization); plus the
  adapter vocabulary in `t:Arca.Storage.error/0`. `get_json/2` adds
  `%Jason.DecodeError{}`.

  Raises, reserved for programmer error: a malformed path (traversal or
  over-long segments — `ArgumentError` from `Cyfr.PathSafety`, at the
  adapter's single validation site) and an athanor-less context on a
  tenant path (`ArgumentError` from `Arca.Storage.tenant_segments/1`).
  Every untrusted-path ingress validates at its own boundary first
  (`Opus.StorageHandler`, the MCP resource read, attachment filenames);
  `exists?/2` alone is total over both path and context.

  ## Usage

      ctx = Sanctum.TestContext.local()

      # Tenant-scoped storage (auto-prefixed with {athanor_id}/)
      :ok = Arca.put(ctx, ["guest", "notes.txt"], content)
      {:ok, content} = Arca.get(ctx, ["guest", "notes.txt"])

      # Global storage (no tenant prefix)
      :ok = Arca.put(ctx, ["cache", "oci", "sha256_abc"], wasm_binary)

      # Append-only storage (JSONL-style logs)
      :ok = Arca.append(ctx, ["guest", "logs", "2025-01-15.jsonl"], log_line <> "\\n")

      # JSON convenience functions
      :ok = Arca.put_json(ctx, ["guest", "state.json"], %{...})
      {:ok, map} = Arca.get_json(ctx, ["guest", "state.json"])

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
  def get(%Context{} = ctx, path),
    do: guarded(ctx, normalize(path), fn p -> adapter(p).get(ctx, p) end)

  @doc """
  Read and decode JSON content from storage.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.put_json(ctx, ["guest", "data.json"], %{"key" => "value"})
      :ok
      iex> Arca.get_json(ctx, ["guest", "data.json"])
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
    do:
      mutating(ctx, normalize(path), {:create, byte_size(content)}, fn p ->
        adapter(p).put(ctx, p, content)
      end)

  @doc """
  Encode and write JSON content to storage.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.put_json(ctx, ["guest", "data.json"], %{"key" => "value"})
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
      mutating(ctx, normalize(path), {:create, byte_size(content)}, fn p ->
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
    do: mutating(ctx, normalize(path), :delete, fn p -> adapter(p).delete(ctx, p) end)

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
  # Names are the typed listing minus its kinds — one adapter callback, not
  # two spellings of the same walk.
  def list(%Context{} = ctx, path) do
    with {:ok, entries} <- list_typed(ctx, path) do
      {:ok, Enum.map(entries, fn {name, _kind} -> name end)}
    end
  end

  @doc """
  List the entries directly under a path, each tagged `:file` or `:dir`.

  The kind comes from the adapter, so a caller that needs it does not have to
  know which adapter is configured or how it lays paths out. A path that is
  itself a file answers `{:error, :enotdir}`.
  """
  def list_typed(%Context{} = ctx, path),
    do: guarded(ctx, normalize(path), fn p -> adapter(p).list_typed(ctx, p) end)

  @doc """
  Recursive file count and byte total under a path prefix.

  Returns `{:ok, %{files: n, bytes: n}}`. Quota enforcement reads this.
  """
  def usage(%Context{} = ctx, path),
    do: guarded(ctx, normalize(path), fn p -> adapter(p).usage(ctx, p) end)

  @doc """
  Check if path exists — FILES only: a directory answers `false` on every
  adapter (an object store has no directory objects, and Local matches
  it), so "is there a directory here" is `list_typed/2`'s question, never
  this one's.

  A total predicate: it never raises. A path this context may not touch,
  an unknown root, a malformed path (traversal segments, over-long
  names), and a context with no resolved athanor on a tenant path all
  answer `false` — invalid input is not a thing that exists. Every other
  facade function keeps raising on a malformed path or an athanor-less
  context: those reach it only through a host-side programmer error,
  which should fail loud.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.exists?(ctx, ["guest", "nonexistent"])
      false

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.exists?(ctx, ["guest", "..", "aqua"])
      false

  """
  def exists?(%Context{} = ctx, path) do
    path = normalize(path)

    with :ok <- Cyfr.PathSafety.validate_segments(path),
         :ok <- Arca.Storage.authorize_path(ctx, path),
         true <- tenant_ctx_ok?(ctx, path) do
      adapter(path).exists?(ctx, path)
    else
      _refused -> false
    end
  end

  # A tenant path a context cannot even name does not exist for it — the
  # totality contract extends to the context, not just the path. The gate
  # must run before the adapter hop, which raises for an athanor-less
  # context (`Arca.Storage.tenant_segments/1`).
  defp tenant_ctx_ok?(ctx, path),
    do: Arca.Storage.classify(path) != :tenant or Arca.Storage.athanor_ready?(ctx)

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
    do: mutating(ctx, normalize(path), :delete_tree, fn p -> adapter(p).delete_tree(ctx, p) end)

  @doc """
  Recursively list all leaf paths under a prefix.

  Returns full segment lists so callers can pass them straight to `get/2`.
  Order is unspecified.
  """
  def list_recursive(%Context{} = ctx, path),
    do: guarded(ctx, normalize(path), fn p -> adapter(p).list_recursive(ctx, p) end)

  @doc """
  Read a whole subtree as `{relative_path, binary}` pairs — the shared
  algorithm over the routed adapter's `list_recursive/2` + `get/2`
  (`Arca.Storage.read_subtree_via/4`), so the overlay's union emerges
  compositionally and every adapter answers a file path the same way
  (`{:error, :enotdir}`).

  Memory-bounded; for large single files use `serve_to_conn/4` instead.
  """
  def read_subtree(%Context{} = ctx, path),
    do:
      guarded(ctx, normalize(path), fn p -> Arca.Storage.read_subtree_via(adapter(p), ctx, p) end)

  @doc """
  Write a batch of `{path, content}` files, any overlay unit sentinel
  LAST — the one spelling of "a unit is complete only when whole" for
  every writer that lays a unit file-by-file (scaffold, the tincture
  store, fork, OCI pull). A path whose root has no unit grammar keeps the
  given order. Halts on the first error, so a failed batch never leaves a
  directory unit carrying its completion mark; success answers the paths
  in the order they were written. `Arca.Overlay` enforces the same
  discipline for its own seed copies (`materialize/2`).
  """
  @spec put_files(Context.t(), [{[String.t()] | String.t(), binary()}]) ::
          {:ok, [[String.t()]]} | {:error, term()}
  def put_files(%Context{} = ctx, files) when is_list(files) do
    {sentinel_files, plain} =
      Enum.split_with(files, fn {path, _content} -> sentinel_file?(normalize(path)) end)

    ordered = plain ++ sentinel_files

    Enum.reduce_while(ordered, :ok, fn {path, content}, :ok ->
      case put(ctx, path, content) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      :ok -> {:ok, Enum.map(ordered, fn {path, _content} -> normalize(path) end)}
      {:error, _} = error -> error
    end
  end

  defp sentinel_file?(path) do
    case Arca.Storage.locate(path) do
      {:dir, unit, sentinel} -> path == unit ++ [sentinel]
      _file_unit_or_outside -> false
    end
  end

  @doc """
  Copy a whole subtree from `src` to `dest` (segment prefix → segment prefix).

  Lists `src` via `list_recursive/2`, then streams each file with `get/2` +
  `put/3` under `dest`, preserving relative layout — one file in memory at a
  time. Adapter-agnostic (Local FS or object store). Content-only — the
  source is left untouched, so a *move* is a successful `copy_tree/3`
  followed by `delete_tree/2`. Returns `:ok` or the first `{:error, reason}`.

  `exclude: fn relative_segments -> boolean end` skips matching files before
  their content is ever read — how `Arca.Overlay.materialize/2` keeps build
  droppings (`target/`, `node_modules/`) out of athanor trees.
  `transform: fn relative_segments, content -> content end` rewrites a
  file's bytes between the read and the write — how `Compendium.Fork`
  re-stamps the manifest without holding the whole tree in memory.
  """
  def copy_tree(%Context{} = ctx, src, dest, opts \\ []) do
    exclude = Keyword.get(opts, :exclude, fn _relative -> false end)
    transform = Keyword.get(opts, :transform, fn _relative, content -> content end)
    src = normalize(src)
    dest = normalize(dest)

    with {:ok, leaves} <- list_recursive(ctx, src) do
      leaves
      |> Enum.map(&Enum.drop(&1, length(src)))
      |> Enum.reject(exclude)
      |> Enum.reduce_while(:ok, fn relative, :ok ->
        case get(ctx, src ++ relative) do
          {:ok, content} ->
            case put(ctx, dest ++ relative, transform.(relative, content)) do
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
  def serve_to_conn(conn, %Context{} = ctx, path, opts \\ []) do
    guarded(ctx, normalize(path), fn p -> adapter(p).serve_to_conn(conn, ctx, p, opts) end)
  end

  @doc """
  Reclaim stale atomic-write temp files, if the configured adapter has any
  to reclaim — `c:Arca.Storage.sweep_stale_tmp/1` is optional, and an
  adapter without in-flight artifacts (an object store) answers `{:ok, 0}`
  here without being asked.
  """
  @spec sweep_stale_tmp() :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep_stale_tmp do
    adapter = Application.get_env(:cyfr, :storage_adapter, Arca.Adapters.Local)

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :sweep_stale_tmp, 1) do
      adapter.sweep_stale_tmp(Arca.Storage.stale_tmp_max_age_seconds())
    else
      {:ok, 0}
    end
  end

  # One spelling per object: every PUBLIC entry point flattens multi-level
  # string segments (`"a/b"` → `["a", "b"]`, split artifacts dropped)
  # exactly once, before any gate — so the two adapters (one joins with
  # the filesystem, one joins into a key) can never disagree about which
  # object a path names, and every gate (depth, reserved names, overlay)
  # sees the real shape. `guarded/3`, `mutating/4` and the `bare_*`
  # helpers assume normalized input. `Cyfr.PathSafety` still refuses a
  # bare `""` at the adapter, for callers that reach one directly.
  defp normalize(segments) when is_list(segments) do
    Enum.flat_map(segments, fn
      segment when is_binary(segment) -> segment |> String.split("/") |> Enum.reject(&(&1 == ""))
      other -> [other]
    end)
  end

  # `put`/`append` may not name a `.tmp.N` segment at ANY level: that
  # suffix is the Local adapter's in-flight write marker, and Local hides
  # it from listings and the usage walk at every depth — a caller-chosen
  # tmp name (leaf or directory) would be a hidden, uncounted object the
  # sweeper cannot reclaim, and the S3 adapter would disagree about all
  # three. Archive ingresses store remote-controlled paths, so this gate
  # is also what keeps a hostile tarball from planting an invisible
  # subtree. Reserving the shape keeps it meaning exactly one thing.
  defp reserved_name?(path) do
    Enum.any?(path, &Arca.Storage.tmp_name?/1)
  end

  # Every entry point runs the reserved-root gate before touching the
  # adapter: the seed bundle and the global roots are the server's own, and
  # every tenant path takes its athanor from the context — there is no path
  # spelling that reaches another athanor's bytes.
  defp guarded(ctx, path, fun) do
    case Arca.Storage.authorize_path(ctx, path) do
      :ok -> fun.(path)
      {:error, :forbidden} = err -> err
    end
  end

  # Seed media is read-only at this seam, whatever the context: the overlay
  # materializer only ever reads seed and writes the athanor, so a
  # write here is always a bug — and letting one through would mutate the
  # tracked repo tree or the operator's mount. "Read in place" is an
  # invariant, not a convention.
  #
  # For everything else: a write anywhere in the athanor's tree changes
  # what the storage cap measures, and that total is cached because walking
  # the tree on every guest write is the cost the cap was written to avoid.
  # Accounting here rather than in each writer means a new writer cannot
  # forget — every mutation already passes through. Globals are not tenant
  # bytes and touch nothing.
  defp mutating(ctx, path, kind, fun) do
    cond do
      Arca.Storage.classify(path) == :seed ->
        {:error, :seed_read_only}

      # The reserved tenant roots (`meta/` — the overlay's origin marks)
      # mutate only under the overlay's own internal-write scope or a
      # system context: a member-level write there could forge a mark and
      # turn "reset to shipped" into deleting member work. Reads stay
      # ordinary tenant reads.
      List.first(path) in Arca.Storage.reserved_roots() and
          not (Arca.Overlay.internal_writes?() or ctx.auth_method == :system) ->
        {:error, :forbidden}

      # A put/append/delete at depth 0 or 1 names the athanor root or a
      # scope root — directories, never objects. On Local, a put there
      # would rename a regular file over where the tree root belongs,
      # permanently ENOTDIR-ing the tenant. `delete_tree` is exempt: the
      # whole tree (`[]` — the purge) and a whole scope are exactly what
      # it is for. Runs on the normalized path, so a multi-level string
      # segment (`"guest/notes.txt"`) counts as its real depth.
      kind != :delete_tree and length(path) < 2 ->
        {:error, :invalid_path}

      match?({:create, _}, kind) and reserved_name?(path) ->
        {:error, :reserved_name}

      true ->
        # Copy-on-write for the seed-overlaid roots happens inside the
        # `Arca.Overlay` decorator's own put/append/delete callbacks —
        # this seam only gates, dispatches and accounts.
        result = guarded(ctx, path, fun)
        account_usage(ctx, path, kind, result)
        result
    end
  end

  # Accounting is universal — every tenant write lands here — but the cap
  # itself is CHECKED only by the user-ingress writers, by design; see
  # `Sanctum.Tenancy.Caps.check_storage/2` for the policy and its roster.
  #
  # The cached athanor total stays O(1) per write: a successful put/append
  # BUMPS the cached bytes by what was written (an overwrite over-counts —
  # the safe direction — until the entry's own TTL walks the tree afresh;
  # `bump_existing` never extends a TTL). Deletes and failed writes drop
  # the entry instead, so reclaimed space is recomputed accurately and a
  # partial write can never be under-counted. Invalidating on every write
  # — the previous scheme — made each subsequent cap check re-walk the
  # whole tree: O(total files) per write under sustained writing.
  defp account_usage(%Context{athanor_id: athanor_id}, path, kind, result)
       when is_binary(athanor_id) and athanor_id != "" do
    if Arca.Storage.classify(path) == :tenant do
      whole = Arca.Cache.Keys.athanor_usage(athanor_id)
      scope = List.first(path)

      case {kind, result} do
        {{:create, bytes}, :ok} ->
          Arca.Cache.bump_existing(whole, bytes)

          # The per-scope pair backs the public quota. The file count bumps
          # unconditionally — an overwrite over-counts a file the same safe
          # direction the bytes over-count — and the TTL walks it true again.
          if scope do
            Arca.Cache.bump_existing(Arca.Cache.Keys.scope_usage_bytes(athanor_id, scope), bytes)
            Arca.Cache.bump_existing(Arca.Cache.Keys.scope_usage_files(athanor_id, scope), 1)
          end

        _delete_or_failed ->
          Arca.Cache.invalidate(whole)

          # Both scope counters go together: dropping only one would leave a
          # stale count that never recovers inside its TTL.
          if scope do
            Arca.Cache.invalidate(Arca.Cache.Keys.scope_usage_bytes(athanor_id, scope))
            Arca.Cache.invalidate(Arca.Cache.Keys.scope_usage_files(athanor_id, scope))
          end
      end
    end

    :ok
  end

  defp account_usage(_ctx, _path, _kind, _result), do: :ok

  # Seed media is server install media read straight from local disk
  # (the one seed tree, `:seed_path` — `Arca.Storage.seed_roots/0`), whatever
  # storage adapter is configured: an object-store deployment provisions
  # athanors from the shipped media without the bucket ever holding a copy.
  # Every other path goes through the `Arca.Overlay` decorator (union
  # reads, copy-on-write, the `:bundled` refusal — wrapping the configured
  # adapter), which delegates verbatim for paths outside the overlaid
  # roots — one routing decision instead of a per-root classification.
  defp adapter(["seed" | _]), do: Arca.Adapters.Local
  defp adapter(_path), do: Arca.Overlay
end
