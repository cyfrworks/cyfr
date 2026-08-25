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

      data/                              # :base_path — the one runtime root
      ├── cyfr.db                        # SQLite database (all structured data)
      ├── cache/                         # Global: immutable cached artifacts
      │   └── oci/{digest}/
      ├── system/                        # Global: server-internal scratch
      └── athanors/{athanor_id}/         # Tenant-scoped
          ├── components/{type}s/{publisher}/{name}/{version}/
          │   ├── {type}.wasm
          │   ├── cyfr-manifest.json
          │   └── src/
          ├── aqua/                      # the athanor's AQUA agent definitions
          │   └── {build_id}.json
          ├── config/                    # Athanor config (retention settings, etc.)
          ├── conversations/             # chat attachment blobs
          └── guest/                     # guest (WASM) files — the guest's `data/` scope

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

          {:error, reason} ->
            Logger.warning("[Arca.Local.get] error=#{inspect(reason)} for full_path=#{full_path}")
            {:error, reason}
        end
    end
  end

  @impl true
  def put(%Context{} = ctx, path, content) do
    full_path = build_path(ctx, path)

    with :ok <- full_path |> Path.dirname() |> File.mkdir_p() do
      # Write-then-rename keeps the object atomic: a concurrent reader sees
      # either the old or the new content, never a torn file, and a crash
      # mid-write can't leave a partial artifact at the real path (matching
      # the all-or-nothing semantics of an S3 object PUT).
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
    with {:ok, entries} <- list_typed(ctx, path) do
      {:ok, Enum.map(entries, fn {name, _kind} -> name end)}
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
  defp tmp_name?(name), do: name =~ ~r/\.tmp\.\d+$/

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
    full_path = build_path(ctx, path)

    case File.rm_rf(full_path) do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, reason}
    end
  end

  @impl true
  def list_recursive(%Context{} = ctx, path) do
    Arca.Storage.validate_path!(path)
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
    Arca.Storage.validate_path!(path)
    full_path = build_path(ctx, path)

    if File.dir?(full_path) do
      leaves = walk_files(full_path)

      bytes =
        Enum.reduce(leaves, 0, fn leaf, acc ->
          case File.stat(leaf) do
            {:ok, %File.Stat{size: size}} ->
              acc + size

            {:error, reason} ->
              # Fail open (quota reads an unreadable file as empty), never
              # silently: an under-count here weakens the storage cap.
              Logger.warning("[Arca.Local.usage] stat #{inspect(reason)} for #{leaf}")
              acc
          end
        end)

      {:ok, %{files: length(leaves), bytes: bytes}}
    else
      {:ok, %{files: 0, bytes: 0}}
    end
  end

  @impl true
  def read_subtree(%Context{} = ctx, path) do
    with {:ok, leaf_segments} <- list_recursive(ctx, path) do
      pairs =
        Enum.reduce_while(leaf_segments, [], fn segs, acc ->
          case get(ctx, segs) do
            {:ok, content} ->
              relative = Enum.drop(segs, length(path))
              {:cont, [{relative, content} | acc]}

            {:error, :not_found} ->
              # File vanished between list and read — skip; concurrent delete is
              # unusual but not an error condition for a tree dump.
              {:cont, acc}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)

      case pairs do
        {:error, reason} -> {:error, reason}
        list -> {:ok, Enum.reverse(list)}
      end
    end
  end

  @impl true
  def serve_to_conn(conn, %Context{} = ctx, path, opts) do
    Arca.Storage.validate_path!(path)
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
        # Fail open (walks and quota read an unreadable directory as
        # empty), never silently: an under-count weakens the storage cap.
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
  Remove `put/3` temp files older than `max_age_seconds` (default one day) —
  orphans of crashed writes. Listings never surface them; this reclaims the
  bytes. Returns `{:ok, removed_count}`.
  """
  def sweep_stale_tmp(max_age_seconds \\ 86_400) do
    cutoff = System.os_time(:second) - max_age_seconds
    {:ok, sweep_tmp_dir(base_path(), cutoff)}
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

                _ ->
                  acc
              end

            lstat_type(full) == :directory ->
              acc + sweep_tmp_dir(full, cutoff)

            true ->
              acc
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
