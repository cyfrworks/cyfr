# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.McpServerStorage do
  @moduledoc """
  Storage operations for external MCP server configurations.

  Follows the same tenant-scoped patterns as the other `Arca.*Storage`
  modules. All queries are scoped via `where_tenant(actor)`, except
  `fenced/1`, which reads named rows across athanors for the MCP bridge
  controller and matches each row to its athanor itself.

  ## Schema

  The `mcp_servers` table stores:
  - id: Unique server ID (UUID7)
  - name: Server name (e.g., "notion", "github")
  - transport: `"http"` or `"stdio"`
  - url: MCP server endpoint URL (http); nil for stdio
  - config_json: JSON text with headers, timeout_ms, backends, etc.
  - enabled: Whether the server is active
  - epoch: 1 on insert, one higher after every write to the row
  - created_by: the id of the person whose context created the row
  - athanor_id: the owning athanor
  - inserted_at/updated_at: Timestamps

  Every write that changes a row raises its epoch in the same statement,
  and the written row is answered as the database returned it.
  """

  import Ecto.Query
  import Arca.QueryHelpers, only: [where_tenant: 2]

  alias Arca.Schemas.Athanor
  alias Arca.Schemas.McpServer

  @doc """
  The decoded `config_json` of a stored row — headers, `timeout_ms`,
  `tool_patterns`, `backends`.

  `insert/2` stores the string verbatim; this is the other half of that, and
  the one place it is read. A row whose JSON is absent or malformed reads as
  an empty config rather than raising: the consent digest, the header
  resolver and the vault reconciler all have to agree about such a row, and
  they can only agree if they decode it the same way.
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
  @spec list(Cyfr.Actor.t()) :: {:ok, [McpServer.t()]} | {:error, term()}
  def list(%Cyfr.Actor{athanor_id: athanor_id} = actor)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.McpServerStorage.list", fn ->
      query =
        from(s in McpServer, order_by: [asc: s.name])
        |> where_tenant(actor)

      {:ok, Arca.Repo.all(query)}
    end)
  end

  def list(%Cyfr.Actor{}), do: {:error, :no_athanor}

  @doc """
  Get a single MCP server config by name, scoped to the given tenant.
  """
  @spec get(Cyfr.Actor.t(), String.t()) ::
          {:ok, McpServer.t()} | {:error, :no_athanor | :not_found | :database_error}
  def get(%Cyfr.Actor{athanor_id: athanor_id} = actor, name)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(name) do
    Arca.Repo.Errors.with_db_rescue("Arca.McpServerStorage.get", fn ->
      query =
        from(s in McpServer, where: s.name == ^name, limit: 1)
        |> where_tenant(actor)

      case Arca.Repo.one(query) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
  end

  def get(%Cyfr.Actor{}, _name), do: {:error, :no_athanor}

  @doc """
  Get a single MCP server config by its row id, scoped to the given tenant.
  """
  @spec get_by_id(Cyfr.Actor.t(), String.t()) ::
          {:ok, McpServer.t()} | {:error, :no_athanor | :not_found | :database_error}
  def get_by_id(%Cyfr.Actor{athanor_id: athanor_id} = actor, id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.McpServerStorage.get_by_id", fn ->
      query =
        from(s in McpServer, where: s.id == ^id, limit: 1)
        |> where_tenant(actor)

      case Arca.Repo.one(query) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
  end

  def get_by_id(%Cyfr.Actor{}, _id), do: {:error, :no_athanor}

  @doc """
  Create an MCP server config, scoped to the given tenant, at epoch 1, and
  answer the stored row. A name the athanor already uses is
  `{:error, :exists}` — a config changes through `update/4`.

  Attrs must include `:name`, and `:url` unless `:transport` is `"stdio"`
  (`"http"` when absent). `:config_json` is the raw JSON string (the caller
  serializes; Arca stores it verbatim). Optional: `:enabled`. The row's
  `created_by` is the context's user.
  """
  @spec insert(Cyfr.Actor.t(), map()) :: {:ok, McpServer.t()} | {:error, :no_athanor | term()}
  # arca:unscoped-ok the actor's athanor is stamped onto the row below before the write.
  def insert(%Cyfr.Actor{athanor_id: athanor_id, user_id: user_id} = actor, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(user_id) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.McpServerStorage.insert", fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      attrs =
        attrs
        |> Map.put_new(:id, Cyfr.UUID7.generate_id("mcp"))
        |> Map.put_new(:transport, "http")
        |> Map.put_new(:enabled, true)
        |> Map.put_new(:config_json, "{}")
        |> Map.put(:epoch, 1)
        |> Map.put(:created_by, user_id)
        |> then(&Arca.QueryHelpers.stamp_tenant!(actor, &1))
        |> Map.put_new(:inserted_at, now)
        |> Map.put(:updated_at, now)

      case Arca.Repo.insert_all(McpServer, [attrs],
             on_conflict: :nothing,
             conflict_target: [:athanor_id, :name],
             returning: true
           ) do
        {1, [server]} -> {:ok, server}
        {0, _} -> {:error, :exists}
      end
    end)
  end

  def insert(%Cyfr.Actor{}, attrs) when is_map(attrs), do: {:error, :no_athanor}

  @doc """
  Delete an MCP server config by name, scoped to the given tenant, and
  answer the row that was deleted.
  """
  @spec delete(Cyfr.Actor.t(), String.t()) ::
          {:ok, McpServer.t()} | {:error, :no_athanor | :not_found | :database_error}
  def delete(%Cyfr.Actor{athanor_id: athanor_id} = actor, name)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(name) do
    Arca.Repo.Errors.with_db_rescue("Arca.McpServerStorage.delete", fn ->
      query =
        from(s in McpServer, where: s.name == ^name, select: s)
        |> where_tenant(actor)

      case Arca.Repo.delete_all(query) do
        {1, [server]} -> {:ok, server}
        {0, _} -> {:error, :not_found}
      end
    end)
  end

  def delete(%Cyfr.Actor{}, _name), do: {:error, :no_athanor}

  @doc """
  Update fields of a server config (`:transport`, `:url`, `:config_json`,
  `:enabled`) and raise its epoch, in one statement.

  With `expected_epoch`, the write happens only while the row is still at
  that epoch; a row that moved on answers `{:error, :stale_epoch}`.
  """
  @spec update(Cyfr.Actor.t(), String.t(), map(), pos_integer() | nil) ::
          {:ok, McpServer.t()}
          | {:error, :no_athanor | :not_found | :stale_epoch | :database_error}
  def update(actor, name, updates, expected_epoch \\ nil)

  def update(%Cyfr.Actor{athanor_id: athanor_id} = actor, name, updates, expected_epoch)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(name) and is_map(updates) do
    Arca.Repo.Errors.with_db_rescue("Arca.McpServerStorage.update", fn ->
      set =
        updates
        |> Map.take([:transport, :url, :config_json, :enabled])
        |> Map.put(:updated_at, now())
        |> Enum.to_list()

      from(s in McpServer, where: s.name == ^name, select: s)
      |> where_tenant(actor)
      |> write_epoch(set, expected_epoch, fn -> get(actor, name) end)
    end)
  end

  def update(%Cyfr.Actor{}, _name, _updates, _expected_epoch), do: {:error, :no_athanor}

  @doc """
  Raise a row's epoch, found by id, with nothing else changed. With
  `expected_epoch`, only while the row is still at that epoch.
  """
  @spec bump_epoch(Cyfr.Actor.t(), String.t(), pos_integer() | nil) ::
          {:ok, McpServer.t()}
          | {:error, :no_athanor | :not_found | :stale_epoch | :database_error}
  def bump_epoch(actor, id, expected_epoch \\ nil)

  def bump_epoch(%Cyfr.Actor{athanor_id: athanor_id} = actor, id, expected_epoch)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.McpServerStorage.bump_epoch", fn ->
      from(s in McpServer, where: s.id == ^id, select: s)
      |> where_tenant(actor)
      |> write_epoch([updated_at: now()], expected_epoch, fn -> get_by_id(actor, id) end)
    end)
  end

  def bump_epoch(%Cyfr.Actor{}, _id, _expected_epoch), do: {:error, :no_athanor}

  @doc """
  The named rows, read in one statement with the status of each row's
  athanor, for the MCP bridge controller's fence: each `{athanor_id,
  server_id}` pair maps to the row when the row exists in that athanor,
  along with whether that athanor is active (not archived). A pair with no
  such row is absent from the map.
  """
  @spec fenced([{String.t(), String.t()}]) ::
          {:ok, %{{String.t(), String.t()} => %{row: McpServer.t(), athanor_active: boolean()}}}
          | {:error, :database_error}
  # arca:unscoped-ok each row read is matched to the athanor its pair names before it is answered.
  def fenced(pairs) when is_list(pairs) do
    Arca.Repo.Errors.with_db_rescue("Arca.McpServerStorage.fenced", fn ->
      ids = pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
      wanted = MapSet.new(pairs)

      rows =
        Arca.Repo.all(
          from(s in McpServer,
            left_join: a in Athanor,
            on: a.id == s.athanor_id,
            where: s.id in ^ids,
            select: {s, a.status}
          )
        )

      fenced =
        for {row, status} <- rows,
            MapSet.member?(wanted, {row.athanor_id, row.id}),
            into: %{},
            do: {{row.athanor_id, row.id}, %{row: row, athanor_active: status != "archived"}}

      {:ok, fenced}
    end)
  end

  # arca:unscoped-ok every caller hands in a query already scoped with where_tenant/2.
  defp write_epoch(query, set, expected_epoch, reread) do
    query = if expected_epoch, do: where(query, [s], s.epoch == ^expected_epoch), else: query

    case Arca.Repo.update_all(query, set: set, inc: [epoch: 1]) do
      {1, [server]} ->
        {:ok, server}

      {0, _} ->
        case expected_epoch && reread.() do
          {:ok, _moved_on} -> {:error, :stale_epoch}
          {:error, :database_error} = error -> error
          _ -> {:error, :not_found}
        end
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
