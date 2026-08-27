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
    full_path = build_path(ctx, path)

    # No symlink guard needed here: the write lands at a temp name and
    # `File.rename/2` REPLACES a link at the target rather than following it.
    with :ok <- full_path |> Path.dirname() |> File.mkdir_p() do
      # Write-then-rename keeps the object atomic: a concurrent reader sees
      # either the old or the new content, never a torn file, and a crash
      # mid-write can't leave a partial artifact at the real path (matching
      # the all-or-nothing semantics of an S3 object PUT).
      #
      # Atomic against readers, NOT against power loss: nothing fsyncs the
      # file or its directory, so a crash can lose a write the caller saw
      # succeed (a committed row may briefly reference a vanished blob).
      # Accepted deliberately — every blob consumer tolerates a missing
      # blob, the row plane is SQLite-journaled, and a datasync per publish
      # tree was judged not worth its cost.
      tmp_path = "#{full_path}.tmp.#{System.unique_integer([:positive])}"

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
        with :ok <- full_path |> Path.dirname() |> File.mkdir_p() do
          File.write(full_path, content, [:append])
        end
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

  # A `put/3` in flight (or a crashed one): named `<file>.tmp.<n>` next to
  # its target. Never content — listings, walks and usage skip the pattern,
  # and `sweep_stale_tmp/1` reclaims orphans.
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
      leaves = walk_files(full_path)

      relative_segments =
        Enum.map(leaves, fn leaf ->
          rel = Path.relative_to(leaf, full_path)
          path ++ String.split(rel, "/", trim: true)
        end)

      {:ok, relative_segments}
    else
      {:ok, []}
    end
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
        {:error, reason} when reason != :enoent ->
          # A root that exists but cannot even be stat'd must not read as
          # empty — the cap would silently under-count.
          {:error, {:usage_walk, full_path, reason}}

        _missing_or_not_a_dir ->
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
  Remove `put/3` temp files older than `max_age_seconds` — orphans of
  crashed writes. Listings never surface them; this reclaims the bytes.
  Returns `{:ok, removed_count}`. `Arca.sweep_stale_tmp/0` is the one
  caller and supplies the age.
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
        Enum.reduce(entries, 0, fn entry, acc ->
          full = Path.join(dir, entry)

          cond do
            tmp_name?(entry) ->
              case File.lstat(full, time: :posix) do
                {:ok, %File.Stat{type: :regular, mtime: mtime}} when mtime < cutoff ->
                  if File.rm(full) == :ok, do: acc + 1, else: acc

                {:ok, %File.Stat{type: :directory, mtime: mtime}} when mtime < cutoff ->
                  # A tmp-named directory predates the facade reserving the
                  # shape on every segment; nothing can list it or count it,
                  # so reclaim the whole subtree once it has aged out.
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
