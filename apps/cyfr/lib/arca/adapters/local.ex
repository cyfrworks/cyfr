# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Adapters.Local do
  @moduledoc """
  Local filesystem storage adapter for Arca.

  ## Path Scoping

  Paths are automatically scoped based on the first segment:

  - **Component paths**: `["components" | rest]` → `components_path/{rest}`
  - **AQUA paths**: `["aqua" | rest]` → `aqua_path/{rest}`
  - **Global paths**: `cache` → `data/cache/{path}`
  - **Tenant-scoped paths**: everything else →
    `data/{org_or_namespace}/{project_id}/{namespace}/{path}`

  Tenant segments are produced by `Arca.Storage.tenant_segments/1`. In
  single-tenant mode it substitutes the namespace for the missing `org_id`
  and defaults `project_id` to `"default"`, yielding `data/{ns}/default/{ns}/...`
  for a single-user instance. A tenant-scoped deployment fills the slots
  with the real `org_id` and `project_id` validated by the tenant policy.

  ## Directory Structure

      components/                        # Component artifacts (separate root)
      └── {type}s/{publisher}/{name}/{version}/
          ├── {type}.wasm
          ├── cyfr-manifest.json
          └── src/

      aqua/                              # AQUA agent prompts/manifest (separate root)

      data/
      ├── {env}.db                       # SQLite database (all structured data)
      ├── cache/                         # Global: immutable cached artifacts
      │   └── oci/{digest}/
      └── {org_or_namespace}/            # Tenant-scoped
          └── {project_id}/              #   "default" single-tenant; real id when tenant-scoped
              └── {namespace}/           #   personal slug minted via cyfr.run
                  ├── builds/            # Locus build lifecycle
                  │   └── {build_id}/
                  │       ├── started.json
                  │       ├── completed.json
                  │       └── build.log
                  ├── data/              # User data (agent conversations, etc.)
                  ├── config/            # User config (retention settings, etc.)
                  └── audit/             # Audit events (append-only JSONL, opt-in)
                      └── {date}.jsonl

  ## Structured Logs (SQLite only)

  MCP request logs, execution records, and policy consultation logs are stored
  exclusively in SQLite tables (`mcp_logs`, `executions`, `policy_logs`).
  They are NOT written to disk files.

  ## Configuration

      config :cyfr,
        storage_adapter: Arca.Adapters.Local,
        base_path: "./data",
        components_path: "./components"

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
  Build the full filesystem path, respecting component, global, and tenant-scoped paths.

  - `["components" | rest]` → `components_path/{rest}`
  - `["aqua" | rest]` → `aqua_path/{rest}`
  - `["cache" | rest]` → `base_path/cache/{rest}` (global, root-level)
  - everything else → `base_path/{org_or_ns}/{project}/{ns}/{rest}` (tenant-scoped)

  Tenant-scoped paths are derived from `Arca.Storage.tenant_segments/1`:
  `{org_id}/{project_id}/{namespace}/...`. In single-tenant mode the org
  slot falls back to the namespace (org_id nil → namespace) and
  `project_id` is `"default"`, giving `{namespace}/default/{namespace}/...`.
  """
  def build_path(%Context{} = ctx, segments) do
    Arca.Storage.validate_path!(segments)
    base = base_path()

    case segments do
      ["components" | rest] ->
        # Component path - routed to components_path.
        # Org-scoped paths: ["components", org_id, "catalysts", ...]
        # Flat (single-tenant) paths: ["components", "catalysts", ...]
        Path.join([components_path() | rest])

      ["aqua" | rest] ->
        # AQUA agent prompts/manifest — separate root, like components/.
        Path.join([aqua_path() | rest])

      [prefix | _rest] ->
        if prefix in Arca.Storage.global_prefixes() do
          # Global path - no tenant prefix (e.g. cache/)
          Path.join([base | segments])
        else
          # Tenant-scoped path: {org_or_ns}/{project}/{ns}/...
          Path.join([base | Arca.Storage.tenant_segments(ctx) ++ segments])
        end

      _ ->
        # Empty segments - tenant-scoped root
        Path.join([base | Arca.Storage.tenant_segments(ctx)])
    end
  end

  @doc "Get the expanded base path for storage."
  def base_path do
    Application.fetch_env!(:cyfr, :base_path)
    |> Path.expand()
  end

  @doc "Get the expanded components path for component storage."
  def components_path do
    Application.get_env(:cyfr, :components_path, "./components")
    |> Path.expand()
  end

  @doc "Get the expanded aqua path for AQUA agent prompts."
  def aqua_path do
    Application.get_env(:cyfr, :aqua_path, "./aqua")
    |> Path.expand()
  end
end