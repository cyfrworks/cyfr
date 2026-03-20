defmodule Arca.McpServerStorage do
  @moduledoc """
  SQLite storage operations for external MCP server configurations.

  Follows the same tenant-scoped patterns as `Arca.PolicyStorage` and
  `Arca.SecretStorage`. All queries are scoped via `where_tenant(ctx)`.

  ## Schema

  The `mcp_servers` table stores:
  - id: Unique server ID (UUID7)
  - name: Server name (e.g., "notion", "github")
  - url: MCP server endpoint URL
  - config_json: JSON text with headers, timeout_ms, etc.
  - enabled: Whether the server is active
  - org_id/project_id: Tenant scoping columns
  - inserted_at/updated_at: Timestamps
  """

  require Logger
  require Arca.Repo.Errors
  import Ecto.Query
  import Arca.QueryHelpers, only: [where_tenant: 2, normalize_org_id: 1]

  alias Sanctum.Context

  @doc """
  List all MCP server configs for the given tenant context.
  """
  @spec list(Context.t()) :: {:ok, [map()]} | {:error, term()}
  def list(%Context{} = ctx) do
    query =
      from(s in "mcp_servers",
        select: %{
          id: s.id,
          name: s.name,
          url: s.url,
          config_json: s.config_json,
          enabled: s.enabled,
          org_id: s.org_id,
          project_id: s.project_id,
          inserted_at: s.inserted_at,
          updated_at: s.updated_at
        },
        order_by: [asc: s.name]
      )
      |> where_tenant(ctx)

    rows =
      Arca.Repo.all(query)
      |> Enum.map(&decode_config/1)

    {:ok, rows}
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.McpServerStorage] Error in list: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Get a single MCP server config by name, scoped to the given tenant.
  """
  @spec get(Context.t(), String.t()) :: {:ok, map()} | {:error, :not_found | :database_error}
  def get(%Context{} = ctx, name) when is_binary(name) do
    query =
      from(s in "mcp_servers",
        where: s.name == ^name,
        limit: 1,
        select: %{
          id: s.id,
          name: s.name,
          url: s.url,
          config_json: s.config_json,
          enabled: s.enabled,
          org_id: s.org_id,
          project_id: s.project_id,
          inserted_at: s.inserted_at,
          updated_at: s.updated_at
        }
      )
      |> where_tenant(ctx)

    case Arca.Repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, decode_config(row)}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.McpServerStorage] Error in get(#{name}): #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Create or update an MCP server config, scoped to the given tenant.

  Attrs must include `:name` and `:url`. Optional: `:config_json`, `:enabled`.
  """
  @spec put(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  def put(%Context{} = ctx, attrs) when is_map(attrs) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    attrs =
      attrs
      |> Map.put_new(:id, Emissary.UUID7.generate())
      |> Map.put_new(:enabled, true)
      |> Map.put_new(:config_json, "{}")
      |> Map.put(:org_id, normalize_org_id(ctx.org_id))
      |> Map.put(:project_id, ctx.project_id || "default")
      |> Map.put_new(:inserted_at, now)
      |> Map.put(:updated_at, now)
      |> encode_config()

    Arca.Repo.insert_all(
      "mcp_servers",
      [attrs],
      on_conflict: {:replace, [:url, :config_json, :enabled, :updated_at]},
      conflict_target: [:name, :org_id, :project_id]
    )
    |> case do
      {n, _} when n in [0, 1] ->
        {:ok, decode_config(attrs)}

      error ->
        {:error, error}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.McpServerStorage] Error in put: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Delete an MCP server config by name, scoped to the given tenant.
  """
  @spec delete(Context.t(), String.t()) :: :ok | {:error, term()}
  def delete(%Context{} = ctx, name) when is_binary(name) do
    query =
      from(s in "mcp_servers", where: s.name == ^name)
      |> where_tenant(ctx)

    case Arca.Repo.delete_all(query) do
      {_count, _} -> :ok
      error -> {:error, error}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.McpServerStorage] Error in delete(#{name}): #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Update specific fields of a server config.
  """
  @spec update(Context.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update(%Context{} = ctx, name, updates) when is_binary(name) and is_map(updates) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    set =
      updates
      |> Map.take([:url, :config_json, :enabled])
      |> encode_config()
      |> Map.put(:updated_at, now)
      |> Enum.to_list()

    query =
      from(s in "mcp_servers", where: s.name == ^name)
      |> where_tenant(ctx)

    case Arca.Repo.update_all(query, set: set) do
      {0, _} -> {:error, :not_found}
      {_n, _} -> get(ctx, name)
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[Arca.McpServerStorage] Error in update(#{name}): #{Exception.message(e)}"
      )

      {:error, :database_error}
  end

  # Encode config map to JSON string if needed
  defp encode_config(%{config_json: config} = attrs) when is_map(config) do
    case Jason.encode(config) do
      {:ok, json} -> Map.put(attrs, :config_json, json)
      {:error, _} -> Map.put(attrs, :config_json, "{}")
    end
  end

  defp encode_config(attrs), do: attrs

  # Decode config_json from string to map, normalize SQLite booleans
  defp decode_config(row) do
    row
    |> normalize_enabled()
    |> decode_json()
  end

  defp decode_json(%{config_json: json} = row) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, config} -> Map.put(row, :config, config)
      {:error, _} -> Map.put(row, :config, %{})
    end
  end

  defp decode_json(row), do: Map.put(row, :config, %{})

  # SQLite returns booleans as integers or strings
  defp normalize_enabled(%{enabled: val} = row) do
    Map.put(row, :enabled, to_bool(val))
  end

  defp normalize_enabled(row), do: row

  defp to_bool(true), do: true
  defp to_bool(false), do: false
  defp to_bool(1), do: true
  defp to_bool(0), do: false
  defp to_bool("true"), do: true
  defp to_bool("false"), do: false
  defp to_bool(_), do: false
end
