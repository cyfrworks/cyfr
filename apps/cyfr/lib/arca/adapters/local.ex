# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Adapters.Local do
  @moduledoc """
  Local filesystem storage adapter for Arca.

  ## Path Scoping

  The logical→physical mapping is `Arca.Storage.physical_segments/2` — the
  one place the layout is written down. This adapter joins its output under
  `:base_path`; seed media (`["seed", root | rest]`) is the sole exception,
  read in place from the one seed tree (`:seed_path`,
  `Arca.Storage.seed_roots/0`).

  ## Directory Structure

  The tree this adapter lays out is drawn once, in `Arca.Storage`'s
  moduledoc (the layout table's home) — this module only joins
  `physical_segments/2` under `:base_path`.

  ## Conditional writes

  The precondition this adapter mints is the SHA-256 of the object's bytes
  (`Cyfr.Digest.sha256_hex/1`, the digest `Arca.Storage.TestDouble` mints
  too). A create writes the bytes whole at a temporary name and hard-links
  them to the target: `link(2)` refuses with `EEXIST` when anything is at
  the target, so the existence check and the publication are one syscall
  and a reader never opens a partial file. A conditional replace re-reads
  the object, compares its digest and renames the new bytes over it.

  Every conditional write on one path runs under a lock on this node, so
  a replace's read and write cannot interleave with another conditional
  write's. The adapter is single-node by definition — one boot owns the
  volume — so the node-local lock is the whole serialization. A plain
  `put/3` or `append/3` is not under it: a key written conditionally is
  written conditionally by every writer.

  The one result vocabulary, shared with `Arca.Adapters.S3` for the same
  situations:

  | situation | `put_if_none_match/3` | `put_if_match/4` |
  |---|---|---|
  | nothing at the path | `{:ok, precondition}`, created | `{:error, :missing}`, nothing written |
  | an object there, precondition current | `{:error, :exists}`, untouched | `{:ok, precondition}`, replaced |
  | an object there, precondition stale | `{:error, :exists}`, untouched | `{:error, :precondition_failed}`, untouched |
  | the store cannot make the write conditional | `{:error, :unsupported}` | `{:error, :unsupported}` |
  | the store cannot say whether it applied the write | `{:error, :unknown}` (an object store; a filesystem call always answers) | same |
  | the store refuses or cannot be reached | `{:error, reason}` | `{:error, reason}` |

  Here `:unsupported` is a filesystem that cannot create a hard link (the
  create-once step). `list_prefix/2` answers every file under a directory
  as full segments, `[prefix]` for a prefix that is one file, and `[]` for
  nothing.

  ## Structured Logs (database only)

  MCP request logs, execution records, and policy consultation logs are stored
  exclusively in database tables (`mcp_logs`, `executions`, `policy_logs`).
  They are NOT written to disk files.

  ## Configuration

      config :cyfr,
        storage_adapter: Arca.Adapters.Local,
        base_path: "./data",
        seed_path: "./seed"
  """

  @behaviour Arca.Storage

  require Logger
  alias Sanctum.Context

  @impl true
  def get(%Context{} = ctx, path) do
    full_path = build_path(ctx, path)

    # `File.read` follows symlinks; nothing tenant-reachable can create one
    # (the tar ingests refuse them), so a link here is host tampering or a
    # bug — refuse rather than read bytes from outside the storage root.
    # The walks (`walk_files/1`) lstat for the same reason.
    case lstat_type(full_path) do
      :symlink ->
        Logger.warning("[Arca.Local.get] refusing symlink at #{full_path}")
        {:error, :symlink_denied}

      _ ->
        case File.read(full_path) do
          {:ok, content} ->
            {:ok, content}

          {:error, :enoent} ->
            # An expected miss (read-probe patterns everywhere) — debug, not
            # warning: a boot-time stamp probe must not read like a fault.
            Logger.debug("[Arca.Local.get] :enoent for #{full_path}")
            {:error, :not_found}

          {:error, :eisdir} ->
            # A directory is not a readable object on any adapter — S3 has
            # no key there and answers :not_found; so does Local.
            Logger.debug("[Arca.Local.get] :eisdir for #{full_path}")
            {:error, :not_found}

          {:error, reason} ->
            Logger.warning("[Arca.Local.get] error=#{inspect(reason)} for full_path=#{full_path}")
            {:error, reason}
        end
    end
  end

  @impl true
  def put(%Context{} = ctx, path, content) do
    refuse_seed_write!(path)
    write_via_rename(build_path(ctx, path), content)
  end

  # Write-then-rename is atomic for readers: they see complete old or new
  # content. Files and directories are not fsynced, so a power failure can
  # lose a write that returned success. No symlink guard needed: the write
  # lands at a temp name and `File.rename/2` REPLACES a link at the target
  # rather than following it.
  defp write_via_rename(full_path, content) do
    with :ok <- full_path |> Path.dirname() |> File.mkdir_p() do
      tmp_path = tmp_path(full_path)

      case File.write(tmp_path, content) do
        :ok ->
          case File.rename(tmp_path, full_path) do
            :ok ->
              :ok

            {:error, _} = error ->
              File.rm(tmp_path)
              error
          end

        {:error, _} = error ->
          File.rm(tmp_path)
          error
      end
    end
  end

  @impl true
  def append(%Context{} = ctx, path, content) do
    refuse_seed_write!(path)
    full_path = build_path(ctx, path)

    # `File.write [:append]` opens with O_APPEND and FOLLOWS a symlink —
    # unlike `put/3`, whose rename replaces the link. Refuse like `get/2`
    # does; this guards the final component (a symlinked parent directory
    # is the same residual `get/2` carries — only the walks lstat every
    # level). Checked before mkdir_p: lstat on a missing target is
    # `:undefined`, and a refused call should create no directories.
    case lstat_type(full_path) do
      :symlink ->
        Logger.warning("[Arca.Local.append] refusing symlink at #{full_path}")
        {:error, :symlink_denied}

      _ ->
        with :ok <- check_append_ceiling(full_path, content),
             :ok <- full_path |> Path.dirname() |> File.mkdir_p() do
          File.write(full_path, content, [:append])
        end
    end
  end

  # The same append ceiling the S3 adapter enforces, from the same
  # constant — one bound for both adapters, so the same guest program
  # cannot grow a file here that an object-store deployment would refuse
  # (`{:error, :object_too_large}` either way).
  defp check_append_ceiling(full_path, content) do
    existing =
      case File.stat(full_path) do
        {:ok, %{size: size}} -> size
        _ -> 0
      end

    if existing + byte_size(content) > Cyfr.Limits.default_max_response_size() do
      {:error, :object_too_large}
    else
      :ok
    end
  end

  @doc """
  Create the file at `path` only when nothing is there
  (`c:Arca.Storage.put_if_none_match/3`); the moduledoc states the
  mechanism and the result vocabulary.
  """
  @impl true
  def put_if_none_match(%Context{} = ctx, path, content) do
    refuse_seed_write!(path)
    full_path = build_path(ctx, path)
    bytes = IO.iodata_to_binary(content)

    serialized(full_path, fn ->
      with :ok <- full_path |> Path.dirname() |> File.mkdir_p() do
        tmp_path = tmp_path(full_path)

        result =
          with :ok <- File.write(tmp_path, bytes),
               :ok <- link_once(tmp_path, full_path) do
            {:ok, precondition(bytes)}
          end

        # The link, when it landed, holds the bytes; the temporary name is
        # done either way.
        File.rm(tmp_path)
        result
      end
    end)
  end

  # `link(2)`: the target comes to exist in the one syscall that also
  # refuses when it already does (a file, a directory, even a dangling
  # symlink). A filesystem without hard links cannot make the create
  # conditional, and the adapter refuses rather than falling back to a
  # write that could land second.
  defp link_once(tmp_path, full_path) do
    case :file.make_link(tmp_path, full_path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        {:error, :exists}

      {:error, reason} when reason in [:eperm, :enotsup, :eopnotsupp, :emlink] ->
        {:error, :unsupported}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Replace the file at `path` while its bytes still digest to
  `precondition` (`c:Arca.Storage.put_if_match/4`); the moduledoc states
  the mechanism and the result vocabulary.
  """
  @impl true
  def put_if_match(%Context{} = ctx, path, content, precondition) do
    refuse_seed_write!(path)
    full_path = build_path(ctx, path)
    bytes = IO.iodata_to_binary(content)

    serialized(full_path, fn ->
      case current_precondition(full_path) do
        {:ok, ^precondition} ->
          with :ok <- write_via_rename(full_path, bytes), do: {:ok, precondition(bytes)}

        {:ok, _changed} ->
          {:error, :precondition_failed}

        {:error, _} = error ->
          error
      end
    end)
  end

  # The precondition of what is at `full_path` now. A directory is not an
  # object (as `get/2` answers) and a symlink is refused as every read is.
  defp current_precondition(full_path) do
    case lstat_type(full_path) do
      :symlink ->
        Logger.warning("[Arca.Local.put_if_match] refusing symlink at #{full_path}")
        {:error, :symlink_denied}

      _ ->
        case File.read(full_path) do
          {:ok, current} -> {:ok, precondition(current)}
          {:error, :enoent} -> {:error, :missing}
          {:error, :eisdir} -> {:error, :missing}
          {:error, _} = error -> error
        end
    end
  end

  defp precondition(bytes), do: Cyfr.Digest.sha256_hex(bytes)

  # One conditional write (or tree swap) in flight per physical path on
  # this node: its check and its write cannot interleave with another's.
  # Node-local by design (the moduledoc says why). `:aborted` only with
  # `retries` of zero, when the lock is held.
  defp serialized(full_path, fun, retries \\ :infinity) do
    :global.trans({{__MODULE__, full_path}, self()}, fun, [node()], retries)
  end

  @doc """
  Every file at or below `prefix`, as full segments
  (`c:Arca.Storage.list_prefix/2`): the walk of a directory, `[prefix]`
  for a prefix that is one file, `[]` for nothing (or a symlink).
  """
  @impl true
  def list_prefix(%Context{} = ctx, prefix) do
    full_path = build_path(ctx, prefix)

    case lstat_type(full_path) do
      :directory -> {:ok, leaves_as_segments(full_path, prefix)}
      :regular -> {:ok, [prefix]}
      _ -> {:ok, []}
    end
  end

  @impl true
  def delete(%Context{} = ctx, path) do
    refuse_seed_write!(path)
    full_path = build_path(ctx, path)

    case File.rm(full_path) do
      :ok -> :ok
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def ensure_dir(%Context{} = ctx, path) do
    refuse_seed_write!(path)
    File.mkdir_p(build_path(ctx, path))
  end

  @impl true
  def list_typed(%Context{} = ctx, path) do
    full_path = build_path(ctx, path)

    case File.ls(full_path) do
      {:ok, names} ->
        # On a filesystem the kind is a stat, and the adapter is the only layer
        # entitled to make one — which is the point of the callback. Symlinks
        # are skipped like temp names: nothing legitimate creates them, and
        # reporting one would invite a follow-up read through it.
        {:ok,
         names
         |> Enum.reject(&tmp_name?/1)
         |> Enum.reject(&(lstat_type(Path.join(full_path, &1)) == :symlink))
         |> Enum.map(&{&1, kind(Path.join(full_path, &1))})}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp kind(path), do: if(File.dir?(path), do: :dir, else: :file)

  # A `put/3` in flight, or a `replace_tree/3`'s staged or retired tree
  # and its journal (or a crashed one's): named `<name>.tmp.<n>` next to
  # its target. Never content — listings, walks and usage skip the
  # pattern, and `sweep_stale_tmp/1` reclaims orphans.
  defp tmp_name?(name), do: Arca.Storage.tmp_name?(name)

  @impl true
  def exists?(%Context{} = ctx, path) do
    full_path = build_path(ctx, path)
    # Files only, matching the S3 adapter's HEAD probe: a directory "exists"
    # on a filesystem but has no object-store counterpart, and the two
    # adapters must answer the same question the same way. Directories are
    # asked about with `list_typed/2`. lstat, so a symlink is not a file —
    # the same rule `get/2` and the walks apply.
    lstat_type(full_path) == :regular
  end

  @impl true
  def delete_tree(%Context{} = ctx, path) do
    refuse_seed_write!(path)
    full_path = build_path(ctx, path)

    case File.rm_rf(full_path) do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, reason}
    end
  end

  @impl true
  def list_recursive(%Context{} = ctx, path) do
    full_path = build_path(ctx, path)

    if File.dir?(full_path) do
      {:ok, leaves_as_segments(full_path, path)}
    else
      {:ok, []}
    end
  end

  # Every regular leaf under the directory at `full_path`, as the logical
  # segments of `path` extended by each leaf's relative path.
  defp leaves_as_segments(full_path, path) do
    Enum.map(walk_files(full_path), fn leaf ->
      rel = Path.relative_to(leaf, full_path)
      path ++ String.split(rel, "/", trim: true)
    end)
  end

  @impl true
  def usage(%Context{} = ctx, path) do
    full_path = build_path(ctx, path)

    if File.dir?(full_path) do
      # Strict, unlike the listing walk: the storage cap rides this
      # number, and an unreadable subtree silently read as empty would
      # weaken it — the cap layer fails CLOSED on a usage error
      # (`Sanctum.Tenancy.Caps.check_storage/2`), so the error must reach
      # it. A missing root stays zero (nothing stored is honestly zero).
      case walk_files_sized(full_path) do
        {:ok, sized} ->
          {:ok,
           %{
             files: length(sized),
             bytes: Enum.reduce(sized, 0, fn {_leaf, size}, acc -> acc + size end)
           }}

        {:error, reason} ->
          Logger.warning("[Arca.Local.usage] walk failed: #{inspect(reason)}")
          {:error, reason}
      end
    else
      case File.lstat(full_path) do
        {:ok, %File.Stat{type: :regular, size: size}} ->
          {:ok, %{files: 1, bytes: size}}

        {:error, reason} when reason != :enoent ->
          # A root that exists but cannot even be stat'd must not read as
          # empty — the cap would silently under-count.
          {:error, {:usage_walk, full_path, reason}}

        _missing_or_not_a_file ->
          {:ok, %{files: 0, bytes: 0}}
      end
    end
  end

  # The usage walk: every regular leaf with its size, or the first error.
  # A leaf that vanishes between the listing and its lstat is skipped —
  # concurrent deletion is not an unreadable tree.
  defp walk_files_sized(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
          full = Path.join(dir, entry)

          if tmp_name?(entry) do
            {:cont, {:ok, acc}}
          else
            case File.lstat(full) do
              {:ok, %File.Stat{type: :directory}} ->
                case walk_files_sized(full) do
                  {:ok, sub} -> {:cont, {:ok, sub ++ acc}}
                  {:error, _} = error -> {:halt, error}
                end

              {:ok, %File.Stat{type: :regular, size: size}} ->
                {:cont, {:ok, [{full, size} | acc]}}

              {:ok, _symlink_or_special} ->
                {:cont, {:ok, acc}}

              {:error, :enoent} ->
                {:cont, {:ok, acc}}

              {:error, reason} ->
                {:halt, {:error, {:usage_walk, full, reason}}}
            end
          end
        end)

      {:error, reason} ->
        {:error, {:usage_walk, dir, reason}}
    end
  end

  @impl true
  def serve_to_conn(conn, %Context{} = ctx, path, opts) do
    full_path = build_path(ctx, path)
    status = Keyword.get(opts, :status, 200)

    # lstat, same rule as get/2: a symlink is not servable content.
    if lstat_type(full_path) == :regular do
      {:ok, Plug.Conn.send_file(conn, status, full_path)}
    else
      {:error, :not_found}
    end
  end

  @doc """
  Replace the directory tree at `path` with `files`
  (`c:Arca.Storage.replace_tree/3`).

  Every file is written under a staging directory beside `path`, named
  `<name>.staged.tmp.<n>` so listings, walks and usage skip it. The swap
  then runs under the path's lock (the one the conditional writes hold):
  a journal `<name>.swap.tmp.<n>` beside the trees records the staged
  and retired names, the tree at `path` is renamed to
  `<name>.retired.tmp.<n>`, the staged tree is renamed into its place, and
  the retired tree and the journal are removed. A reader opening a file
  under `path` reads the previous tree before the second rename and the
  new one after it; between the two renames, which follow one another
  directly, `path` holds nothing, and a reader that lists the tree and
  then opens its files across that moment can read files of both.

  A failure while staging removes the staging directory and leaves `path`
  as it was. A failure during the swap settles through the journal: the
  staged tree is installed if it can be, else the retired tree is put
  back, and the error is answered only when the previous tree stands. A
  crash between the steps leaves either the previous tree or the new one
  at `path` once `sweep_stale_tmp/1` has read the journal — the sweep
  installs a staged tree whose swap did not finish, or restores the
  retired one, then removes what is left — never neither: the trees a
  journal names are never reclaimed as orphans. Renames and the journal
  are not fsynced, as `put/3` is not.
  """
  @impl true
  def replace_tree(%Context{} = ctx, path, files) when is_list(files) do
    refuse_seed_write!(path)
    swap = swap_names(build_path(ctx, path))

    with :ok <- stage(ctx, path, swap.staged, files),
         :ok <- swap(swap) do
      :ok
    else
      {:error, _} = error ->
        File.rm_rf(swap.staged)
        error
    end
  end

  defp tmp_path(path), do: "#{path}.tmp.#{System.unique_integer([:positive])}"

  # The names of one replacement, all beside the live tree under the
  # `.tmp.<n>` shape with one number.
  defp swap_names(live) do
    n = System.unique_integer([:positive])

    %{
      live: live,
      staged: "#{live}.staged.tmp.#{n}",
      retired: "#{live}.retired.tmp.#{n}",
      journal: "#{live}.swap.tmp.#{n}"
    }
  end

  @journal_suffix ~r/\.swap\.tmp\.\d+$/

  defp journal_name?(name), do: name =~ @journal_suffix

  # A staged file lands at a fresh name no reader resolves, so it is
  # written in place rather than through `put/3`'s rename.
  defp stage(ctx, path, staged, files) do
    with :ok <- File.mkdir_p(staged) do
      Enum.reduce_while(files, :ok, fn {rel, content}, :ok ->
        # Validates `rel` and its containment exactly as a write would.
        _live_file = build_path(ctx, path ++ rel)
        target = Path.join([staged | rel])

        with {:ok, bytes} <- file_bytes(content),
             :ok <- File.mkdir_p(Path.dirname(target)),
             :ok <- File.write(target, bytes) do
          {:cont, :ok}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp file_bytes(bytes) when is_binary(bytes), do: {:ok, bytes}
  defp file_bytes(fun) when is_function(fun, 0), do: fun.()

  # The journal is written inside the lock, so a journal on disk with the
  # lock free belongs to a swap that crashed or whose cleanup failed —
  # what the sweep may settle without racing a swap in flight.
  defp swap(%{live: live} = names) do
    with :ok <- File.mkdir_p(Path.dirname(live)) do
      serialized(live, fn ->
        with :ok <- write_journal(names) do
          renamed =
            case File.rename(live, names.retired) do
              :ok -> File.rename(names.staged, live)
              {:error, :enoent} -> File.rename(names.staged, live)
              {:error, _} = error -> error
            end

          case {settle(names), renamed} do
            {:new, _} -> :ok
            {_old_or_none, {:error, _} = error} -> error
            {_old_or_none, :ok} -> {:error, :swap_unsettled}
          end
        end
      end)
    end
  end

  defp write_journal(%{live: live, staged: staged, retired: retired, journal: journal}) do
    File.write(
      journal,
      :erlang.term_to_binary(%{
        version: 1,
        live: Path.basename(live),
        staged: Path.basename(staged),
        retired: Path.basename(retired)
      })
    )
  end

  # The swap a journal records. Its names are siblings of the journal
  # under the journal's own number, so they are rebuilt from the journal's
  # file name and the record must agree: a journal that names anything
  # else directs no rename. One that cannot be read is an orphan the
  # sweep ages out like any temp file.
  defp read_journal(journal) do
    with [_, live, n] <- Regex.run(~r/^(.+)\.swap\.tmp\.(\d+)$/s, Path.basename(journal)),
         {:ok, bytes} <- File.read(journal),
         %{version: 1, live: ^live, staged: staged, retired: retired} <- decode_journal(bytes),
         true <- staged == "#{live}.staged.tmp.#{n}" and retired == "#{live}.retired.tmp.#{n}" do
      dir = Path.dirname(journal)

      {:ok,
       %{
         live: Path.join(dir, live),
         staged: Path.join(dir, staged),
         retired: Path.join(dir, retired),
         journal: journal
       }}
    else
      _ -> {:error, :corrupt_journal}
    end
  end

  defp decode_journal(bytes) do
    :erlang.binary_to_term(bytes, [:safe])
  rescue
    ArgumentError -> :corrupt
  end

  # Bring a journalled swap to rest, whichever step it stopped at, and
  # answer which tree stands at the live path: `:new` (the staged tree,
  # installed now or earlier), `:old` (the previous tree, never moved or
  # put back) or `:none` (nothing could be installed; the journal stays
  # for the next sweep). The journal goes only once nothing it names is
  # left to reclaim.
  defp settle(%{live: live, staged: staged, retired: retired, journal: journal} = names) do
    cond do
      File.exists?(live) and File.exists?(staged) ->
        # The swap never moved the staged tree: the previous tree stands.
        File.rm_rf(staged)
        finish_retirement(names, :old)

      File.exists?(live) ->
        finish_retirement(names, :new)

      File.exists?(staged) ->
        case File.rename(staged, live) do
          :ok -> finish_retirement(names, :new)
          {:error, _} -> restore_retired(names)
        end

      File.exists?(retired) ->
        restore_retired(names)

      true ->
        File.rm(journal)
        :none
    end
  end

  defp restore_retired(%{live: live, staged: staged, retired: retired} = names) do
    case File.rename(retired, live) do
      :ok ->
        File.rm_rf(staged)
        finish_retirement(names, :old)

      {:error, _} ->
        :none
    end
  end

  # The live tree stands; a retired tree that cannot be removed stays
  # hidden under its temporary name, journal and all, until the sweep
  # retries.
  defp finish_retirement(%{retired: retired, journal: journal}, standing) do
    case File.rm_rf(retired) do
      {:ok, _} ->
        File.rm(journal)
        standing

      {:error, reason, file} ->
        Logger.warning(
          "[Arca.Local.replace_tree] previous tree not removed (#{inspect(reason)} at #{file})"
        )

        standing
    end
  end

  defp walk_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full = Path.join(dir, entry)

          # lstat, not stat: a symlink inside a tree must not pull outside
          # bytes into walks, usage counts or tree copies (the same rule the
          # registry applies when storing extracted files).
          cond do
            tmp_name?(entry) -> []
            lstat_type(full) == :directory -> walk_files(full)
            lstat_type(full) == :regular -> [full]
            true -> []
          end
        end)

      {:error, reason} ->
        # Fail open, never silently: listings read an unreadable
        # directory as empty. The storage cap does NOT ride this walk —
        # `usage/2` has its own strict one that propagates the error.
        Logger.warning("[Arca.Local.walk] ls #{inspect(reason)} for #{dir}")
        []
    end
  end

  defp lstat_type(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: type}} -> type
      {:error, _} -> :undefined
    end
  end

  @doc """
  Settle every journalled tree swap and remove `put/3` temp files and
  staged or retired trees older than `max_age_seconds` — orphans of
  crashed writes. Listings never surface them; this reclaims the bytes.
  Returns `{:ok, removed_count}`, a settled journal counting once.
  `Arca.sweep_stale_tmp/0` is the one caller and supplies the age.

  A journal is settled whatever its age, under its path's lock and only
  when the lock is free (a swap in flight holds it), before the aged
  orphans in its directory are reclaimed — so the trees it names are
  installed or restored, never swept out from under it.
  """
  @impl true
  def sweep_stale_tmp(max_age_seconds) do
    cutoff = System.os_time(:second) - max_age_seconds

    # The volume holds more than Arca paths (`cyfr.db*`, the `mcp-bridge/`
    # sidecar tree — "another program's file" per `Arca.Storage`). `put/3`
    # lands tmp files only where Arca writes: under `athanors/` and the
    # global roots — so the sweep walks exactly those.
    removed =
      [Arca.Storage.tenant_physical_root() | Arca.Storage.global_prefixes()]
      |> Enum.map(&Path.join(base_path(), &1))
      |> Enum.filter(&File.dir?/1)
      |> Enum.reduce(0, &(&2 + sweep_tmp_dir(&1, cutoff)))

    {:ok, removed}
  end

  defp sweep_tmp_dir(dir, cutoff) do
    case File.ls(dir) do
      {:ok, entries} ->
        # Journals first: what a journal still standing names is its to
        # settle on a later sweep, whatever its age, and is kept from the
        # orphan pass; an unreadable journal protects nothing and ages out
        # as the orphan it is.
        {settled, kept} =
          entries
          |> Enum.filter(&journal_name?/1)
          |> Enum.reduce({0, []}, fn entry, {count, kept} ->
            case settle_journal(Path.join(dir, entry)) do
              :settled -> {count + 1, kept}
              {:standing, names} -> {count, [entry | names] ++ kept}
              :unreadable -> {count, kept}
            end
          end)

        Enum.reduce(entries -- kept, settled, fn entry, acc ->
          full = Path.join(dir, entry)

          cond do
            tmp_name?(entry) ->
              case File.lstat(full, time: :posix) do
                {:ok, %File.Stat{type: :regular, mtime: mtime}} when mtime < cutoff ->
                  if File.rm(full) == :ok, do: acc + 1, else: acc

                {:ok, %File.Stat{type: :directory, mtime: mtime}} when mtime < cutoff ->
                  # Reclaim the whole temporary subtree after it ages out.
                  case File.rm_rf(full) do
                    {:ok, _} -> acc + 1
                    {:error, _, _} -> acc
                  end

                _ ->
                  acc
              end

            true ->
              case lstat_type(full) do
                :directory ->
                  acc + sweep_tmp_dir(full, cutoff)

                :symlink ->
                  # No tenant-reachable code can create one, so a symlink
                  # under the storage root means host-level tampering or a
                  # bug — the per-operation guards refuse the final
                  # component, and this walk is the cheap detector for the
                  # rest of the chain.
                  Logger.warning("[Arca.Local.sweep] symlink under storage root: #{full}")
                  acc

                _ ->
                  acc
              end
          end
        end)

      {:error, _} ->
        0
    end
  end

  # One journal, settled if its swap's lock is free (a swap in flight
  # holds it) and it can be read. `{:standing, names}` when the journal is
  # still on disk afterwards, with the sibling names it goes on owning.
  defp settle_journal(journal) do
    case read_journal(journal) do
      {:ok, names} ->
        serialized(names.live, fn -> settle(names) end, 0)

        if File.exists?(journal),
          do: {:standing, [Path.basename(names.staged), Path.basename(names.retired)]},
          else: :settled

      {:error, :corrupt_journal} ->
        Logger.warning("[Arca.Local.sweep] unreadable swap journal: #{journal}")
        :unreadable
    end
  end

  @doc """
  Build the full filesystem path for logical segments.

  Seed media (`["seed", root | rest]`) is read in place from its configured
  directory (`Arca.Storage.seed_roots/0`); every other path joins
  `Arca.Storage.physical_segments/2` under `:base_path`. The reserved roots
  are gated by `Arca.Storage.authorize_path/2` before any adapter call.

  This is the adapter's one validation chokepoint: every callback reaches
  it before any I/O, so `Arca.Storage.validate_path!/1` runs exactly once
  per operation — never per callback on top.
  """
  def build_path(%Context{} = ctx, segments) do
    Arca.Storage.validate_path!(segments)

    {root, relative} =
      case segments do
        ["seed", seed_root | rest] ->
          {seed_root_path!(seed_root), rest}

        _ ->
          {base_path(), Arca.Storage.physical_segments(ctx, segments)}
      end

    path = Path.join([root | relative])

    # Belt over the denylist: whatever the validator and the layout produced,
    # the joined path must still live under its root.
    unless contained_in?(path, root) do
      raise ArgumentError, "storage path escapes its root: #{inspect(segments)}"
    end

    path
  end

  defp contained_in?(path, root) do
    expanded = Path.expand(path)
    expanded == root or String.starts_with?(expanded, root <> "/")
  end

  # One spelling for every adapter — `Arca.Storage.refuse_seed_write!/1`.
  defdelegate refuse_seed_write!(path), to: Arca.Storage

  defp seed_root_path!(seed_root) do
    if seed_root in Arca.Storage.seed_roots() do
      :cyfr
      |> Application.fetch_env!(:seed_path)
      |> Path.expand()
      |> Path.join(seed_root)
    else
      raise ArgumentError, "unknown seed root: #{inspect(seed_root)}"
    end
  end

  @doc "Get the expanded base path for storage."
  def base_path do
    Application.fetch_env!(:cyfr, :base_path)
    |> Path.expand()
  end
end
