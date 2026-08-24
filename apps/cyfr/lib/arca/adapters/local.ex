# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Adapters.Local do
  @moduledoc """
  Local filesystem storage adapter for Arca.

  ## Path Scoping

  The logical→physical mapping is `Arca.Storage.physical_segments/2` — the
  one place the layout is written down. This adapter joins its output under
  `:base_path`; the seed bundle (`["components", "_bundle" | rest]`) is the
  sole exception, read in place from `:bundle_path`.

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
          └── data/
              ├── builds/                # Locus build lifecycle
              │   └── {build_id}/
              │       ├── started.json
              │       ├── completed.json
              │       └── build.log
              ├── data/                  # Athanor data (agent conversations, etc.)
              ├── config/                # Athanor config (retention settings, etc.)
              └── audit/                 # Audit events (append-only JSONL, opt-in)
                  └── {date}.jsonl

  ## Structured Logs (database only)

  MCP request logs, execution records, and policy consultation logs are stored
  exclusively in database tables (`mcp_logs`, `executions`, `policy_logs`).
  They are NOT written to disk files.

  ## Configuration

      config :cyfr,
        storage_adapter: Arca.Adapters.Local,
        base_path: "./data",
        bundle_path: "./components/_bundle"

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
        # entitled to make one — which is the point of the callback.
        {:ok, Enum.map(names, &{&1, kind(Path.join(full_path, &1))})}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp kind(path), do: if(File.dir?(path), do: :dir, else: :file)

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
            {:ok, %File.Stat{size: size}} -> acc + size
            {:error, _} -> acc
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

    if File.regular?(full_path) do
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
          if File.dir?(full), do: walk_files(full), else: [full]
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Build the full filesystem path for logical segments.

  The seed bundle (`["components", "_bundle" | rest]`) is read in place from
  `:bundle_path`; every other path joins `Arca.Storage.physical_segments/2`
  under `:base_path`. Component access is pinned per athanor by
  `Arca.Storage.authorize_path/2` before any adapter call.
  """
  def build_path(%Context{} = ctx, segments) do
    Arca.Storage.validate_path!(segments)

    case segments do
      ["components", "_bundle" | rest] ->
        Path.join([bundle_path() | rest])

      _ ->
        Path.join([base_path() | Arca.Storage.physical_segments(ctx, segments)])
    end
  end

  @doc "Get the expanded base path for storage."
  def base_path do
    Application.fetch_env!(:cyfr, :base_path)
    |> Path.expand()
  end

  @doc "Get the expanded seed-bundle source path."
  def bundle_path do
    Application.fetch_env!(:cyfr, :bundle_path)
    |> Path.expand()
  end
end
