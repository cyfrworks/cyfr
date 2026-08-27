# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.McpServerStorage do
  @moduledoc """
  Storage operations for external MCP server configurations.

  Follows the same tenant-scoped patterns as the other `Arca.*Storage`
  modules. All queries are scoped via `where_tenant(ctx)`.

  ## Schema

  The `mcp_servers` table stores:
  - id: Unique server ID (UUID7)
  - name: Server name (e.g., "notion", "github")
  - url: MCP server endpoint URL
  - config_json: JSON text with headers, timeout_ms, etc.
  - enabled: Whether the server is active
  - athanor_id: the owning athanor
  - inserted_at/updated_at: Timestamps
  """

  import Ecto.Query
  import Arca.QueryHelpers, only: [where_tenant: 2]

  alias Arca.Schemas.McpServer
  alias Sanctum.Context

  @doc """
  The decoded `config_json` of a stored row — headers, `timeout_ms`,
  `tool_patterns`.

  `put/2` stores the string verbatim; this is the other half of that, and the
  one place it is read. A row whose JSON is absent or malformed reads as an
  empty config rather than raising: the consent digest, the header resolver
  and the vault reconciler all have to agree about such a row, and they can
  only agree if they decode it the same way.
  """
  @spec config(McpServer.t() | map()) :: map()
  def config(%{config_json: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = config} -> config
      _ -> %{}
    end
  end

  def config(_server), do: %{}

  @doc """
  List all MCP server configs for the given tenant context.
  """
  @spec list(Context.t()) :: {:ok, [McpServer.t()]} | {:error, term()}
  def list(%Context{} = ctx) do
    Arca.Repo.Errors.with_db_rescue("Arca.McpServerStorage.list", fn ->
      query =
        from(s in McpServer, order_by: [asc: s.name])
        |> where_tenant(ctx)

      {:ok, Arca.Repo.all(query)}
    end)
  end

  @doc """
  Get a single MCP server config by name, scoped to the given tenant.
  """
  @spec get(Context.t(), String.t()) ::
          {:ok, McpServer.t()} | {:error, :not_found | :database_error}
  def get(%Context{} = ctx, name) when is_binary(name) do
    Arca.Repo.Errors.with_db_rescue("Arca.McpServerStorage.get", fn ->
      query =
        from(s in McpServer, where: s.name == ^name, limit: 1)
        |> where_tenant(ctx)

      case Arca.Repo.one(query) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
  end

  @doc """
  Create or update an MCP server config, scoped to the given tenant.

  Attrs must include `:name` and `:url`. `:config_json` is the raw JSON string
  (the caller serializes; Arca stores it verbatim). Optional: `:enabled`.
  """
  @spec put(Context.t(), map()) :: {:ok, McpServer.t()} | {:error, term()}
  def put(%Context{} = ctx, attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.McpServerStorage.put", fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      attrs =
        attrs
        |> Map.put_new(:id, Emissary.UUID7.generate())
        |> Map.put_new(:enabled, true)
        |> Map.put_new(:config_json, "{}")
        |> Map.put(:athanor_id, ctx.athanor_id)
        |> Map.put_new(:inserted_at, now)
        |> Map.put(:updated_at, now)

      Arca.Repo.insert_all(
        McpServer,
        [attrs],
        on_conflict: {:replace, [:url, :config_json, :enabled, :updated_at]},
        conflict_target: [:athanor_id, :name]
      )
      |> case do
        {n, _} when n in [0, 1] ->
          {:ok, struct(McpServer, attrs)}

        error ->
          {:error, error}
      end
    end)
  end

  @doc """
  Delete an MCP server config by name, scoped to the given tenant.
  """
  @spec delete(Context.t(), String.t()) :: :ok | {:error, term()}
  def delete(%Context{} = ctx, name) when is_binary(name) do
    Arca.Repo.Errors.with_db_rescue("Arca.McpServerStorage.delete", fn ->
      query =
        from(s in McpServer, where: s.name == ^name)
        |> where_tenant(ctx)

      case Arca.Repo.delete_all(query) do
        {_count, _} -> :ok
        error -> {:error, error}
      end
    end)
  end

  @doc """
  Update specific fields of a server config.
  """
  @spec update(Context.t(), String.t(), map()) ::
          {:ok, McpServer.t()} | {:error, term()}
  def update(%Context{} = ctx, name, updates) when is_binary(name) and is_map(updates) do
    Arca.Repo.Errors.with_db_rescue("Arca.McpServerStorage.update", fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      set =
        updates
        |> Map.take([:url, :config_json, :enabled])
        |> Map.put(:updated_at, now)
        |> Enum.to_list()

      query =
        from(s in McpServer, where: s.name == ^name)
        |> where_tenant(ctx)

      case Arca.Repo.update_all(query, set: set) do
        {0, _} -> {:error, :not_found}
        {_n, _} -> get(ctx, name)
      end
    end)
  end
end
