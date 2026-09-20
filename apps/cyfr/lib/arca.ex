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
  above depth 2); `:bundled` (deleting a shipped copy);
  `{:materialize_failed, reason}` (copying a shipped unit into the athanor);
  `{:limit_reached, :athanor_storage_bytes, cap}` and
  `:storage_unverifiable` (any capped tenant create — the write gate
  checks by default, see `put/4`'s `cap:` option); plus the adapter
  vocabulary in `t:Arca.Storage.error/0`. `get_json/2` adds
  `:invalid_json` (`Cyfr.Json`'s spelling — the one this repo uses for a
  corrupt stored value).

  Raises, reserved for programmer error: a malformed path (traversal or
  over-long segments — `ArgumentError` from `Cyfr.PathSafety`, at the
  adapter's single validation site) and an athanor-less context on a
  tenant path (`ArgumentError` from `Arca.Storage.tenant_segments/1`).
  Every untrusted-path ingress validates at its own boundary first
  (`Cyfr.Execution.GuestStorage`, the MCP resource read, attachment filenames);
  `exists?/2` alone is total over both path and context.

  ## Usage

      ctx = Sanctum.TestContext.local()

      # Tenant-scoped storage (auto-prefixed with {athanor_id}/)
      :ok = Arca.put(ctx, ["data", "notes.txt"], content)
      {:ok, content} = Arca.get(ctx, ["data", "notes.txt"])

      # Global storage (no tenant prefix)
      :ok = Arca.put(ctx, ["cache", "oci", "sha256_abc"], wasm_binary)

      # Append-only storage (JSONL-style logs)
      :ok = Arca.append(ctx, ["data", "logs", "2025-01-15.jsonl"], log_line <> "\\n")

      # JSON convenience functions
      :ok = Arca.put_json(ctx, ["data", "state.json"], %{...})
      {:ok, map} = Arca.get_json(ctx, ["data", "state.json"])

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
      iex> Arca.put(ctx, ["data", "file.txt"], "hello")
      :ok
      iex> Arca.get(ctx, ["data", "file.txt"])
      {:ok, "hello"}
  """
  @spec get(Context.t(), Arca.Storage.path()) :: {:ok, binary()} | {:error, term()}
  def get(%Context{} = ctx, path),
    do: guarded(ctx, normalize(path), fn p -> adapter(p).get(ctx, p) end)

  @doc """
  Read content together with the precondition a conditional replace of it
  must carry (`c:Arca.Storage.get_for_update/2`) — `get/2` for a caller
  that will write back what it read, and the read half of
  `Arca.Overlay.update/3`'s compare-and-set. The precondition is the
  adapter's own: carry it to `put_if_match/5` unread.
  """
  @spec get_for_update(Context.t(), Arca.Storage.path()) ::
          {:ok, binary(), Arca.Storage.precondition()} | {:error, term()}
  def get_for_update(%Context{} = ctx, path),
    do: guarded(ctx, normalize(path), fn p -> adapter(p).get_for_update(ctx, p) end)

  @doc """
  Read and decode JSON content from storage.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.put_json(ctx, ["data", "data.json"], %{"key" => "value"})
      :ok
      iex> Arca.get_json(ctx, ["data", "data.json"])
      {:ok, %{"key" => "value"}}
  """
  @spec get_json(Context.t(), Arca.Storage.path()) :: {:ok, term()} | {:error, term()}
  def get_json(%Context{} = ctx, path) do
    with {:ok, content} <- get(ctx, path) do
      # Normalize storage JSON errors through Cyfr.Json.decode/1.
      Cyfr.Json.decode(content)
    end
  end

  @doc """
  Write content to storage (overwrites existing).

  Creates parent directories automatically.

  ## Options

    * `cap:` — `:checked` (default) or `:exempt`. A tenant-scoped write
      is checked against the athanor's storage cap
      (`Sanctum.Tenancy.Caps.check_storage/2`) before a byte moves,
      refusing with `{:error, {:limit_reached, :athanor_storage_bytes,
      cap}}` or `{:error, :storage_unverifiable}`. The default is the
      protective posture — a new writer that states nothing is capped —
      and `:exempt` is a visible, deliberate statement at the few
      uncapped-by-design writers (`grep 'cap: :exempt'` is that roster).
      Global and seed paths carry no tenant bytes and ignore the option;
      `Arca.Overlay`'s internal writes were already checked at unit level
      by `commit_unit/4` and skip it.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.put(ctx, ["data", "nested", "path", "file.txt"], "content")
      :ok
  """
  @spec put(Context.t(), Arca.Storage.path(), binary(), keyword()) :: :ok | {:error, term()}
  def put(%Context{} = ctx, path, content, opts \\ []),
    do:
      mutating(ctx, normalize(path), {:create, byte_size(content)}, opts, fn p ->
        adapter(p).put(ctx, p, content)
      end)

  @doc """
  Write content only while the object still holds the version
  `precondition` names (`c:Arca.Storage.put_if_match/4`) — `put/4` for a
  caller that read the object first (`get_for_update/2`) and must not
  overwrite a writer that landed in between.

  The same gate `put/4` passes: path authorization, the storage cap
  (`cap:`, `:checked` by default) and usage accounting.
  `{:error, :precondition_failed}` when the object moved since the read
  and `{:error, :missing}` when nothing is at `path`; in both cases
  nothing is written.
  """
  @spec put_if_match(
          Context.t(),
          Arca.Storage.path(),
          binary(),
          Arca.Storage.precondition(),
          keyword()
        ) :: :ok | {:error, :precondition_failed | :missing | term()}
  def put_if_match(%Context{} = ctx, path, content, precondition, opts \\ []),
    do:
      mutating(ctx, normalize(path), {:create, byte_size(content)}, opts, fn p ->
        # The new precondition is the adapter's answer to this write; a
        # caller that needs it reads for update again, so the accounting
        # this gate does sees the one shape every other write answers.
        case adapter(p).put_if_match(ctx, p, content, precondition) do
          {:ok, _next_precondition} -> :ok
          {:error, _} = error -> error
        end
      end)

  @doc """
  Encode and write JSON content to storage.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.put_json(ctx, ["data", "data.json"], %{"key" => "value"})
      :ok
  """
  @spec put_json(Context.t(), Arca.Storage.path(), term(), keyword()) :: :ok | {:error, term()}
  def put_json(%Context{} = ctx, path, data, opts \\ []) do
    # `Cyfr.Json` on both sides of the round-trip: `get_json/2` speaks its
    # `:invalid_json`, so the write side speaks its `:unencodable` too —
    # not a `%Jason.EncodeError{}` escaping into the caller's error tuple.
    case Cyfr.Json.encode(data) do
      {:ok, json} -> put(ctx, path, json, opts)
      {:error, :unencodable} -> {:error, :unencodable}
    end
  end

  @doc """
  Append content to storage (for append-only logs).

  Creates parent directories automatically. Content is appended to the
  end of the file without overwriting existing content.

  Useful for logs stored as JSONL (JSON Lines) format.

  On the S3 adapter, append is a read-modify-write with last-writer-wins:
  concurrent appends to one key can lose lines (the adapter documents the
  race). Concurrent JSONL streams that must not lose lines belong on
  per-writer keys.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.append(ctx, ["data", "logs", "2025-01-15.jsonl"], ~s|{"event":"login"}\\n|)
      :ok
      iex> Arca.append(ctx, ["data", "logs", "2025-01-15.jsonl"], ~s|{"event":"logout"}\\n|)
      :ok
  """
  @spec append(Context.t(), Arca.Storage.path(), binary(), keyword()) :: :ok | {:error, term()}
  def append(%Context{} = ctx, path, content, opts \\ []),
    do:
      mutating(ctx, normalize(path), {:create, byte_size(content)}, opts, fn p ->
        adapter(p).append(ctx, p, content)
      end)

  @doc """
  Delete content from storage.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.put(ctx, ["data", "file.txt"], "hello")
      :ok
      iex> Arca.delete(ctx, ["data", "file.txt"])
      :ok
      iex> Arca.get(ctx, ["data", "file.txt"])
      {:error, :not_found}
  """
  @spec delete(Context.t(), Arca.Storage.path()) :: :ok | {:error, term()}
  def delete(%Context{} = ctx, path),
    do: mutating(ctx, normalize(path), :delete, [], fn p -> adapter(p).delete(ctx, p) end)

  @doc """
  List contents at path.

  Returns empty list if path doesn't exist.
  Note: Order of results is not guaranteed.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.put(ctx, ["data", "listdir", "a.txt"], "a")
      :ok
      iex> Arca.put(ctx, ["data", "listdir", "b.txt"], "b")
      :ok
      iex> {:ok, files} = Arca.list(ctx, ["data", "listdir"])
      iex> Enum.sort(files)
      ["a.txt", "b.txt"]
  """
  # Names are the typed listing minus its kinds — one adapter callback, not
  # two spellings of the same walk.
  @spec list(Context.t(), Arca.Storage.path()) :: {:ok, [String.t()]} | {:error, term()}
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
  @spec list_typed(Context.t(), Arca.Storage.path()) ::
          {:ok, [{String.t(), :file | :dir}]} | {:error, term()}
  def list_typed(%Context{} = ctx, path),
    do: guarded(ctx, normalize(path), fn p -> adapter(p).list_typed(ctx, p) end)

  @doc """
  Recursive file count and byte total under a path prefix.

  Returns `{:ok, %{files: n, bytes: n}}`. Quota enforcement reads this.
  """
  @spec usage(Context.t(), Arca.Storage.path()) ::
          {:ok, %{files: non_neg_integer(), bytes: non_neg_integer()}} | {:error, term()}
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
      iex> Arca.exists?(ctx, ["data", "nonexistent"])
      false

      iex> ctx = Sanctum.TestContext.local()
      iex> Arca.exists?(ctx, ["data", "..", "aqua"])
      false
  """
  @spec exists?(Context.t(), Arca.Storage.path()) :: boolean()
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
      iex> Arca.put(ctx, ["threads", "thread_1", "msg_1.json"], "{}")
      :ok
      iex> Arca.delete_tree(ctx, ["threads", "thread_1"])
      :ok
  """
  @spec delete_tree(Context.t(), Arca.Storage.path()) :: :ok | {:error, term()}
  def delete_tree(%Context{} = ctx, path),
    do:
      mutating(ctx, normalize(path), :delete_tree, [], fn p -> adapter(p).delete_tree(ctx, p) end)

  @doc """
  Recursively list all leaf paths under a prefix.

  Returns full segment lists so callers can pass them straight to `get/2`.
  Order is unspecified.
  """
  @spec list_recursive(Context.t(), Arca.Storage.path()) ::
          {:ok, [Arca.Storage.path()]} | {:error, term()}
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
  @spec read_subtree(Context.t(), Arca.Storage.path()) ::
          {:ok, [{Arca.Storage.path(), binary()}]} | {:error, term()}
  def read_subtree(%Context{} = ctx, path),
    do:
      guarded(ctx, normalize(path), fn p -> Arca.Storage.read_subtree_via(adapter(p), ctx, p) end)

  @doc """
  Copy a whole subtree from `src` to `dest` (segment prefix → segment prefix).

  Lists `src` via `list_recursive/2`, then streams each file with `get/2` +
  `put/3` under `dest`, preserving relative layout — one file in memory at a
  time. Adapter-agnostic (Local FS or object store). Content-only — the
  source is left untouched, so a *move* is a successful `copy_tree/3`
  followed by `delete_tree/2`. Returns `{:ok, copied_relatives}` in copy
  order, or the first `{:error, reason}`.

  NO rollback: a mid-copy failure leaves the files already copied in
  place. Unit-shaped copies get atomicity by going through
  `Arca.Overlay.commit_unit/4` (clean-slate + sentinel-last + rollback);
  a direct caller owns its own compensation.

  `exclude: fn relative_segments -> boolean end` skips matching files before
  their content is ever read — how `Arca.Overlay.materialize/2` keeps build
  droppings (`target/`, `node_modules/`) out of athanor trees.
  `transform: fn relative_segments, content -> content end` rewrites a
  file's bytes between the read and the write — how `Compendium.Fork`
  re-stamps the manifest without holding the whole tree in memory.
  `cap:` is threaded through to each `put/4` (default `:checked`, like
  any other write).
  """
  @spec copy_tree(Context.t(), Arca.Storage.path(), Arca.Storage.path(), keyword()) ::
          {:ok, [Arca.Storage.path()]} | {:error, term()}
  def copy_tree(%Context{} = ctx, src, dest, opts \\ []) do
    exclude = Keyword.get(opts, :exclude, fn _relative -> false end)
    transform = Keyword.get(opts, :transform, fn _relative, content -> content end)
    src = normalize(src)
    dest = normalize(dest)

    with {:ok, leaves} <- list_recursive(ctx, src) do
      leaves
      |> Enum.map(&Enum.drop(&1, length(src)))
      |> Enum.reject(exclude)
      |> Enum.reduce_while({:ok, []}, fn relative, {:ok, acc} ->
        case get(ctx, src ++ relative) do
          {:ok, content} ->
            case put(
                   ctx,
                   dest ++ relative,
                   transform.(relative, content),
                   Keyword.take(opts, [:cap])
                 ) do
              :ok -> {:cont, {:ok, [relative | acc]}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          # File vanished between list and read — skip; concurrent delete is
          # unusual but not an error condition for a tree copy.
          {:error, :not_found} ->
            {:cont, {:ok, acc}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, copied} -> {:ok, Enum.reverse(copied)}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Replace the directory tree at `path` with `files` —
  `{relative_path, content}` pairs, `content` as bytes or a zero-arity
  function answering `{:ok, bytes}` or `{:error, reason}`, resolved one
  file at a time.

  A reader sees the tree that was at `path` until the new one is whole,
  then the new one: the adapter stages the files where no reader looks and
  swaps them in (`c:Arca.Storage.replace_tree/3`, which states each
  adapter's exact guarantee). A failure before the swap answers its error
  and leaves the tree at `path` as it was. An adapter that cannot hide a
  partial tree refuses with `{:error, :atomic_replace_unsupported}` and
  writes nothing. Inside a unit the replacement holds the unit's lock
  (`Arca.Overlay`), so writes to the unit wait for it; elsewhere a write
  under `path` made during the replacement can land in the tree it retires.

  `cap:` (required) — `{:checked, bytes}` checks `bytes`, the replacement's
  size, against the athanor's storage cap before anything is staged;
  `:exempt` states an uncapped call site. `{:error, :reserved_name}` when
  `path` or a relative path names the `.tmp.<n>` shape, and
  `{:error, :invalid_path}` for an empty relative path, besides the
  refusals every write answers. A replacement drops the cached usage
  counters, so the next cap check measures the tree afresh.
  """
  @spec replace_tree(
          Context.t(),
          Arca.Storage.path(),
          [Arca.Storage.tree_file()],
          keyword()
        ) :: :ok | {:error, term()}
  def replace_tree(%Context{} = ctx, path, files, opts) when is_list(files) do
    path = normalize(path)
    files = Enum.map(files, fn {rel, content} when is_list(rel) -> {normalize(rel), content} end)

    cond do
      Enum.any?(files, &match?({[], _content}, &1)) ->
        {:error, :invalid_path}

      reserved_name?(path) or Enum.any?(files, fn {rel, _content} -> reserved_name?(rel) end) ->
        {:error, :reserved_name}

      true ->
        mutating(ctx, path, :replace_tree, opts, fn p ->
          adapter(p).replace_tree(ctx, p, files)
        end)
    end
  end

  @doc """
  Make a directory exist at a tenant path, holding nothing — every folder
  of a fresh estate from the first day (`ensure_roots/1`). Not a write of
  bytes: nothing is capped or counted, and the reserved roots are not
  refused — a directory carries no bytes a row could name. Refused like
  any path outside the tenant roster; seed media stays read-only.
  """
  @spec ensure_dir(Context.t(), Arca.Storage.path()) :: :ok | {:error, term()}
  def ensure_dir(%Context{} = ctx, path) do
    path = normalize(path)

    cond do
      Arca.Storage.classify(path) != :tenant -> {:error, :forbidden}
      path == [] -> {:error, :invalid_path}
      true -> guarded(ctx, path, fn p -> adapter(p).ensure_dir(ctx, p) end)
    end
  end

  @doc """
  Make every tenant root of the context's athanor exist — the folder
  structure a person browses, laid at provisioning and healed at boot.
  """
  @spec ensure_roots(Context.t()) :: :ok | {:error, term()}
  def ensure_roots(%Context{} = ctx) do
    Enum.reduce_while(Arca.Storage.tenant_roots(), :ok, fn root, :ok ->
      case ensure_dir(ctx, [root]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {root, reason}}}
      end
    end)
  end

  @doc """
  Stream a stored object to a `Plug.Conn`.

  Caller owns Content-Type, CSP, and caching headers; the adapter handles
  the body transfer. Returns `{:ok, conn}` or `{:error, term()}`.
  """
  @spec serve_to_conn(Plug.Conn.t(), Context.t(), Arca.Storage.path(), keyword()) ::
          {:ok, Plug.Conn.t()} | {:error, term()}
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
    adapter = Arca.Storage.configured_adapter()

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

  # Seed media is read-only at this seam, whatever the context: a shipped
  # copy is read from the seed and written into the athanor, so a write
  # here is always a bug — and letting one through would mutate the
  # tracked repo tree or the operator's mount.
  #
  # For everything else: a write anywhere in the athanor's tree changes
  # what the storage cap measures, and that total is cached because walking
  # the tree on every guest write is the cost the cap was written to avoid.
  # Accounting here rather than in each writer means a new writer cannot
  # forget — every mutation already passes through. Globals are not tenant
  # bytes and touch nothing.
  defp mutating(ctx, path, kind, opts, fun) do
    cond do
      Arca.Storage.classify(path) == :seed ->
        {:error, :seed_read_only}

      # Reserved tenant roots mutate only within `with_internal_writes/1`:
      # the bytes a payload row names by digest are the store's to write.
      # Reads use ordinary tenant access checks.
      List.first(path) in Arca.Storage.reserved_roots() and
          not Arca.Overlay.internal_writes?() ->
        {:error, :forbidden}

      # A put/append/delete at depth 0 or 1 names the athanor root or a
      # scope root — directories, never objects. On Local, a put there
      # would rename a regular file over where the tree root belongs,
      # permanently ENOTDIR-ing the tenant. `delete_tree` is exempt: the
      # whole tree (`[]` — the purge) and a whole scope are exactly what
      # it is for. Runs on the normalized path, so a multi-level string
      # segment (`"data/notes.txt"`) counts as its real depth.
      kind != :delete_tree and length(path) < 2 ->
        {:error, :invalid_path}

      match?({:create, _}, kind) and reserved_name?(path) ->
        {:error, :reserved_name}

      true ->
        # The unit lock and the `:bundled` refusal of the seeded roots
        # live inside the `Arca.Overlay` decorator's own callbacks — this
        # seam only gates, checks, dispatches and accounts.
        # Accounting is universal — every tenant write lands here, so a
        # new writer cannot forget — and the cap check rides the same
        # chokepoint (`check_cap/4` below): checked by default, exempt
        # only where a call site says so. `Arca.Usage` owns the cache
        # discipline, `Sanctum.Tenancy.Caps.check_storage/2` the policy.
        with :ok <- check_cap(ctx, path, kind, opts) do
          result = guarded(ctx, path, fun)
          Arca.Usage.account(ctx, path, kind, result)
          result
        end
    end
  end

  # The storage-cap gate: every tenant-scoped create is checked unless its
  # call site states `cap: :exempt` — the same visible-policy shape as
  # `Arca.Overlay.commit_unit/4`, with the default on the protective side
  # so a writer that states nothing is capped. Deletes reclaim space and
  # carry no policy; globals are not tenant bytes; the overlay's internal
  # writes were checked at unit level by `commit_unit/4` (its cap is a
  # required argument) and must not be re-checked per file.
  defp check_cap(ctx, path, {:create, bytes}, opts) do
    if Arca.Storage.classify(path) == :tenant and not Arca.Overlay.internal_writes?() do
      case Keyword.get(opts, :cap, :checked) do
        :checked ->
          Sanctum.Tenancy.Caps.check_storage(ctx, bytes)

        :exempt ->
          :ok

        other ->
          raise ArgumentError, "cap: must be :checked or :exempt, got #{inspect(other)}"
      end
    else
      :ok
    end
  end

  # A replacement states its size with its policy, since its contents may
  # not be resolved until it is staged.
  defp check_cap(ctx, path, :replace_tree, opts) do
    case Keyword.fetch!(opts, :cap) do
      {:checked, bytes} when is_integer(bytes) and bytes >= 0 ->
        if Arca.Storage.classify(path) == :tenant and not Arca.Overlay.internal_writes?(),
          do: Sanctum.Tenancy.Caps.check_storage(ctx, bytes),
          else: :ok

      :exempt ->
        :ok

      other ->
        raise ArgumentError, "cap: must be {:checked, bytes} or :exempt, got #{inspect(other)}"
    end
  end

  defp check_cap(_ctx, _path, _kind, _opts), do: :ok

  # Seed media is server install media read straight from local disk
  # (the one seed tree, `:seed_path` — `Arca.Storage.seed_roots/0`), whatever
  # storage adapter is configured: an object-store deployment provisions
  # athanors from the shipped media without the bucket ever holding a copy.
  # Every other path goes through the `Arca.Overlay` decorator (the unit
  # lock, the `:bundled` refusal — wrapping the configured adapter),
  # which delegates verbatim for paths outside the overlaid
  # roots — one routing decision instead of a per-root classification.
  defp adapter(["seed" | _]), do: Arca.Adapters.Local
  defp adapter(_path), do: Arca.Overlay
end
