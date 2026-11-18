# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.McpServerStorage do
  @moduledoc """
  Storage operations for external MCP server configurations.

  Follows the same tenant-scoped patterns as the other `Arca.*Storage`
  modules. All queries are scoped via `where_tenant(actor)`, except
  `fenced/1`, which reads named rows across athanors for the backends
  controller and matches each row to its athanor itself.

  ## Schema

  The `mcp_servers` table stores:
  - id: Unique server ID (UUID7)
  - name: Server name (e.g., "notion", "github")
  - transport: `"http"` or `"program"`
  - mark: a program's `"mcp"` or `"driven"`; nil for http
  - url: MCP server endpoint URL (http); nil for a program
  - home, memory_bytes, home_max_bytes, hosts: a program's
    settings (`Arca.Schemas.McpServer`)
  - config_json: JSON text with headers (http), command and env (program),
    timeout_ms, etc.
  - enabled: Whether the server is active
  - epoch: 1 on insert, one higher after every write to the row
  - revision: 0 on insert, one higher after every write to the row — the
    counter a fenced publication compares (`Arca.FencedPublication`)
  - created_by: the id of the person whose context created the row
  - athanor_id: the owning athanor
  - inserted_at/updated_at: Timestamps

  Every write that changes a row raises its epoch and its revision in the
  same statement. `bump_epoch/3` is the one host-owned write, published
  under this member's live ownership of its slot and the revision it read
  (`Arca.FencedPublication`). The others (`insert/2`, `update/4`,
  `delete/3`) are a person's writes, made without the slot check, and
  answer the written row as the database returned it.

  `insert/2` counts the athanor's servers against the caller's cap and
  inserts in one locking transaction under the athanor's row lock.
  """

  import Ecto.Query
  import Arca.QueryHelpers, only: [where_tenant: 2]

  alias Arca.Schemas.Athanor
  alias Arca.Schemas.McpServer

  @typedoc "The row a write expects to find under its name: its id and epoch."
  @type expected :: %{id: String.t(), epoch: pos_integer()}

  # The brains' drivers, each a command's first word (`driver/1`).
  @drivers ~w(cyfr-claude-code cyfr-codex)

  # A program's settings, which `update/4` writes as named (nil clears one).
  @program_columns [
    :mark,
    :home,
    :memory_bytes,
    :home_max_bytes,
    :hosts
  ]

  @doc """
  The decoded `config_json` of a stored row — headers, `command`, `env`,
  `timeout_ms`, `tool_patterns`.

  `insert/2` stores the string verbatim; this is the other half of that, and
  the one place it is read. A row whose JSON is absent or malformed reads as
  an empty config rather than raising: the consent digest, the header
  resolver and the vault reconciler all have to agree about such a row, and
  they can only agree if they decode it the same way.
  """
  @spec config(map() | map()) :: map()
  def config(%{config_json: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = config} -> config
      _ -> %{}
    end
  end

  def config(_server), do: %{}

  @doc """
  The driver a program row's command names as its first word, one of the
  brains' drivers built into the box beside the harness each drives
  (`Dockerfile.locus`), or nil: a bare harness, another program, a tool
  server, no command. What a kept row's folder holds of a brain's
  sessions is laid out by that driver's harness, so the driver is fixed
  once the row names one (`update/4`).
  """
  @spec driver(map()) :: String.t() | nil
  def driver(%{transport: "program"} = row) do
    with %{"command" => command} when is_binary(command) <- config(row),
         [first | _args] when first in @drivers <- String.split(command) do
      first
    else
      _no_driver -> nil
    end
  end

  def driver(_row), do: nil

  @doc """
  List all MCP server configs for the given tenant context.
  """
  @spec list(Prima.Actor.t()) :: {:ok, [map()]} | {:error, term()}
  def list(%Prima.Actor{athanor_id: athanor_id} = actor)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.McpServerStorage.list", fn ->
      query =
        from(s in McpServer, order_by: [asc: s.name])
        |> where_tenant(actor)

      {:ok, Arca.Repo.all(query)}
    end)
    |> Arca.Data.project()
  end

  def list(%Prima.Actor{}), do: {:error, :no_athanor}

  @doc """
  Get a single MCP server config by name, scoped to the given tenant.
  """
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :no_athanor | :not_found | :database_error}
  def get(%Prima.Actor{athanor_id: athanor_id} = actor, name)
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
    |> Arca.Data.project()
  end

  def get(%Prima.Actor{}, _name), do: {:error, :no_athanor}

  @doc """
  Get a single MCP server config by its row id, scoped to the given tenant.
  """
  @spec get_by_id(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :no_athanor | :not_found | :database_error}
  def get_by_id(%Prima.Actor{athanor_id: athanor_id} = actor, id)
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
    |> Arca.Data.project()
  end

  def get_by_id(%Prima.Actor{}, _id), do: {:error, :no_athanor}

  @doc """
  Create an MCP server config, scoped to the given tenant, at epoch 1, and
  answer the stored row. A name the athanor already uses is
  `{:error, :exists}` — a config changes through `update/4`.

  Attrs must include `:name`, and `:url` unless `:transport` is
  `"program"` (`"http"` when absent), which names its `:mark`. `:config_json` is the raw JSON string (the caller
  serializes; Arca stores it verbatim). Optional: `:enabled`. The row's
  `created_by` is the context's user.

  Attrs must also include `:cap`, the most servers the athanor may hold,
  which the caller names (`Emissary.External.Provider`), and 0 no ceiling;
  it is not stored. One locking transaction locks the athanor's row,
  counts its servers and inserts, so creates racing for the last place
  leave one row in it. Refused with `:server_cap` at `cap`, `:not_found`
  when the athanor has no row, `:no_athanor` for an actor that names none,
  `{:validation, errors}` for a missing or malformed cap, and
  `:database_error`.
  """
  @spec insert(Prima.Actor.t(), map()) ::
          {:ok, map()}
          | {:error,
             :exists
             | :server_cap
             | :not_found
             | :no_athanor
             | :database_error
             | {:validation, %{atom() => [String.t()]}}}
  def insert(%Prima.Actor{athanor_id: athanor_id, user_id: user_id} = actor, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(user_id) and is_map(attrs) do
    with {:ok, cap} <- server_cap(Map.get(attrs, :cap)) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      row =
        attrs
        |> Map.delete(:cap)
        |> Map.put_new(:id, Prima.UUID7.generate_id("mcp"))
        |> Map.put_new(:transport, "http")
        |> Map.put_new(:enabled, true)
        |> Map.put_new(:config_json, "{}")
        |> Map.put(:epoch, 1)
        |> Map.put(:revision, 0)
        |> Map.put(:created_by, user_id)
        |> then(&Arca.QueryHelpers.stamp_tenant!(actor, &1))
        |> Map.put_new(:inserted_at, now)
        |> Map.put(:updated_at, now)

      Arca.Repo.Errors.with_db_rescue("Arca.McpServerStorage.insert", fn ->
        capped_insert(actor, row, cap)
      end)
      |> Arca.Data.project()
    end
  end

  def insert(%Prima.Actor{}, attrs) when is_map(attrs), do: {:error, :no_athanor}

  @doc """
  Delete an MCP server config by name, scoped to the given tenant, and
  answer the row that was deleted.

  In one transaction the row is locked, every profile whose head stands
  on it is blocked to ask again (`Arca.ConsentStorage.head_profiles_on_row/2`
  through `block_dependents/4`, the order a revision binding the row
  takes), every standing answer constrained to the row goes
  (`Arca.ToolGrantStorage.delete_on_program_row/2`), and then the row is
  deleted; a login need's bindings go with it (the baseline's cascade).

  With `expected` (`%{id, epoch}`, the row a person confirmed removing),
  the row under `name` must still be that row at that epoch, compared
  under its lock: another row made under the name, or the row written
  since, is `{:error, :stale_epoch}` and nothing is written.
  """
  @spec delete(Prima.Actor.t(), String.t(), expected() | nil) ::
          {:ok, map()} | {:error, :no_athanor | :not_found | :stale_epoch | :database_error}
  def delete(actor, name, expected \\ nil)

  def delete(%Prima.Actor{athanor_id: athanor_id} = actor, name, expected)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(name) do
    Arca.Repo.Errors.with_db_rescue("Arca.McpServerStorage.delete", fn ->
      Arca.Repo.locking_transaction(fn ->
        with %McpServer{id: id} = row <- locked(actor, name) || {:error, :not_found},
             :ok <- as_expected(row, expected),
             {:ok, _blocked} <-
               Arca.ConsentStorage.block_dependents(
                 actor,
                 {athanor_id, %{id: id, name: row.name}},
                 [],
                 Arca.StatusTransitions.blocked_profile_status()
               ),
             {:ok, _ended} <- Arca.ToolGrantStorage.delete_on_program_row(actor, id),
             {1, [server]} <-
               Arca.Repo.delete_all(
                 from(s in McpServer, where: s.id == ^id, select: s)
                 |> where_tenant(actor)
               ) do
          server
        else
          {:error, reason} -> Arca.Repo.rollback(reason)
        end
      end)
    end)
    |> Arca.Data.project()
  end

  def delete(%Prima.Actor{}, _name, _expected), do: {:error, :no_athanor}

  defp as_expected(_row, nil), do: :ok
  defp as_expected(%McpServer{id: id, epoch: epoch}, %{id: id, epoch: epoch}), do: :ok
  defp as_expected(_row, _expected), do: {:error, :stale_epoch}

  # Read under the row's lock, so every writer of a row is held to it.
  defp driver_kept(%McpServer{home: "kept"} = row, written) do
    kept = driver(row)

    if kept == nil or driver(Map.merge(row, written)) == kept,
      do: :ok,
      else: {:error, :driver_fixed}
  end

  defp driver_kept(_row, _written), do: :ok

  defp locked(actor, name) do
    from(s in McpServer, where: s.name == ^name)
    |> where_tenant(actor)
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.one()
  end

  @doc """
  Update fields of a server config (`:transport`, `:url`, `:config_json`,
  `:enabled` and the program columns, `@program_columns`) and raise its
  epoch, in one transaction under the row's lock. A write that changes
  anything but `enabled` also ends every standing answer constrained to
  the row (`Arca.ToolGrantStorage.delete_on_program_row/2`), as a
  profile's grant on it asks again when its definition's digest moves.

  With `expected` (`%{id, epoch}`, the row the caller read and a person
  confirmed changing), the write happens only while the row under `name`
  is still that row at that epoch, in the one statement: another row made
  under the name, or the row written since, answers
  `{:error, :stale_epoch}`.

  A kept row whose command names a driver (`driver/1`) keeps it: a write
  that names another driver or none, another transport among them, is
  `{:error, :driver_fixed}` and writes nothing, since the records the
  folder holds of the brain's sessions are that driver's harness's, which
  a removal owed for one of them asks that driver to remove
  (`Arca.ThreadStorage.forget_sessions/2`). A bare command that gains a
  driver, and a change after the driver's word, write as any other.
  """
  @spec update(Prima.Actor.t(), String.t(), map(), expected() | nil) ::
          {:ok, map()}
          | {:error, :no_athanor | :not_found | :stale_epoch | :driver_fixed | :database_error}
  def update(actor, name, updates, expected \\ nil)

  def update(%Prima.Actor{athanor_id: athanor_id} = actor, name, updates, expected)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(name) and is_map(updates) do
    Arca.Repo.Errors.with_db_rescue("Arca.McpServerStorage.update", fn ->
      written = Map.take(updates, [:transport, :url, :config_json, :enabled | @program_columns])
      set = written |> Map.put(:updated_at, now()) |> Enum.to_list()

      Arca.Repo.locking_transaction(fn ->
        with %McpServer{id: id} = row <- locked(actor, name) || {:error, :not_found},
             :ok <- as_expected(row, expected),
             :ok <- driver_kept(row, written),
             {1, [server]} <-
               Arca.Repo.update_all(
                 from(s in McpServer, where: s.id == ^id, select: s) |> where_tenant(actor),
                 set: set,
                 inc: [epoch: 1, revision: 1]
               ),
             {:ok, _ended} <- end_constrained(actor, row, written) do
          server
        else
          {:error, reason} -> Arca.Repo.rollback(reason)
        end
      end)
    end)
    |> Arca.Data.project()
  end

  def update(%Prima.Actor{}, _name, _updates, _expected), do: {:error, :no_athanor}

  # A row's definition moving ends every standing answer constrained to
  # it, as a profile's grant on it asks again when its digest moves:
  # whatever but `enabled` the write changes. Enabling or disabling keeps
  # them.
  defp end_constrained(actor, row, written) do
    moved? =
      Enum.any?(written, fn {column, value} ->
        column != :enabled and Map.get(row, column) != value
      end)

    if moved?, do: Arca.ToolGrantStorage.delete_on_program_row(actor, row.id), else: {:ok, 0}
  end

  @doc """
  Raise a row's epoch, found by id in the actor's athanor, with nothing
  else changed, and answer the row as the publication wrote it.

  A host-owned write: the row is read, and its raised epoch published
  under this member's slot (`Arca.ControlPlane.member_slot/0`) over the
  revision read (`Arca.FencedPublication.publish/3`). With
  `expected_epoch`, the row must also still be at that epoch; the
  revision compare-and-set carries that read to the publication.

    * `{:error, :stale_epoch}` — the row is not at `expected_epoch`.
    * `{:error, :stale}` — the row moved between the read and the
      publication (with no `expected_epoch`: nothing was raised by this
      call, and a caller that still needs the raise reads again).
    * `{:error, :not_owner}` — this member does not hold its slot, live;
      nothing is written.
    * `{:error, :budget}` — the publication outran its transaction budget.
  """
  @spec bump_epoch(Prima.Actor.t(), String.t(), pos_integer() | nil) ::
          {:ok, map()}
          | {:error,
             :no_athanor
             | :not_found
             | :stale_epoch
             | :stale
             | :not_owner
             | :budget
             | :database_error}
  def bump_epoch(actor, id, expected_epoch \\ nil)

  def bump_epoch(%Prima.Actor{athanor_id: athanor_id} = actor, id, expected_epoch)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) do
    with {:ok, slot} <- Arca.ControlPlane.member_slot(),
         {:ok, server} <- get_by_id(actor, id),
         :ok <- at_epoch(server, expected_epoch) do
      publish_epoch(actor, server, expected_epoch, slot)
    end
  end

  def bump_epoch(%Prima.Actor{}, _id, _expected_epoch), do: {:error, :no_athanor}

  defp at_epoch(_server, nil), do: :ok
  defp at_epoch(%{epoch: epoch}, epoch), do: :ok
  defp at_epoch(_server, _expected_epoch), do: {:error, :stale_epoch}

  # What the publication set, not a later read: a read after the commit
  # could answer a successor's row.
  defp publish_epoch(actor, server, expected_epoch, slot) do
    attrs = %{epoch: server.epoch + 1, updated_at: now()}

    change = %Arca.FencedPublication.Change{
      resource: {:row, McpServer, server.id},
      attrs: attrs
    }

    case Arca.FencedPublication.publish(change, server.revision, slot) do
      {:ok, revision} ->
        {:ok, server |> Map.merge(attrs) |> Map.put(:revision, revision)}

      {:error, :stale} when is_integer(expected_epoch) ->
        moved(actor, server.id)

      {:error, _} = refused ->
        refused
    end
  end

  # With an epoch expected, a row that moved is read again so the answer
  # says which: gone, or at another epoch.
  defp moved(actor, id) do
    case get_by_id(actor, id) do
      {:ok, _moved_on} -> {:error, :stale_epoch}
      {:error, _} = error -> error
    end
  end

  @doc """
  The named rows, read in one statement with the status of each row's
  athanor, for the backends controller's fence: each `{athanor_id,
  server_id}` pair maps to the row when the row exists in that athanor,
  along with whether that athanor is active (not archived). A pair with no
  such row is absent from the map.
  """
  @spec fenced([{String.t(), String.t()}]) ::
          {:ok, %{{String.t(), String.t()} => %{row: map(), athanor_active: boolean()}}}
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
    |> Arca.Data.project()
  end

  @doc """
  Where the rows `ids` stand, whatever athanor holds each, for the
  programs controller's sweep of the kept homes a box holds: each id that
  names a row maps to its athanor, whether it is a program with a kept
  home, and whether its athanor is archived. An id that names no row is
  absent. Nothing of a row's definition is read.
  """
  @spec standing([String.t()]) ::
          {:ok,
           %{
             String.t() => %{
               athanor_id: String.t(),
               kept: boolean(),
               athanor_archived: boolean()
             }
           }}
          | {:error, :database_error}
  # arca:unscoped-ok a box names its kept homes by row id alone, so the sweep reads each id's own athanor back and answers no definition.
  def standing(ids) when is_list(ids) do
    Arca.Repo.Errors.with_db_rescue("Arca.McpServerStorage.standing", fn ->
      rows =
        Arca.Repo.all(
          from(s in McpServer,
            left_join: a in Athanor,
            on: a.id == s.athanor_id,
            where: s.id in ^Enum.uniq(ids),
            select: {s.id, s.athanor_id, s.transport, s.home, a.status}
          )
        )

      {:ok,
       Map.new(rows, fn {id, athanor_id, transport, home, athanor_status} ->
         {id,
          %{
            athanor_id: athanor_id,
            kept: transport == "program" and home == "kept",
            athanor_archived: athanor_status == "archived"
          }}
       end)}
    end)
  end

  defp server_cap(cap) when is_integer(cap) and cap >= 0, do: {:ok, cap}
  defp server_cap(_cap), do: {:error, {:validation, %{cap: ["must be a non-negative integer"]}}}

  # One locking transaction: the athanor's row is locked before the count,
  # so creates in one athanor count and insert one at a time.
  defp capped_insert(actor, row, cap) do
    Arca.Repo.locking_transaction(fn ->
      with {:ok, _athanor} <- lock_athanor(actor),
           :ok <- below_cap(actor, cap),
           {:ok, server} <- insert_row(row) do
        server
      else
        {:error, reason} -> Arca.Repo.rollback(reason)
      end
    end)
  end

  defp lock_athanor(%Prima.Actor{athanor_id: athanor_id}) do
    case from(a in Athanor, where: a.id == ^athanor_id)
         |> Arca.QueryHelpers.for_update()
         |> Arca.Repo.one() do
      nil -> {:error, :not_found}
      athanor -> {:ok, athanor}
    end
  end

  # Every server row of the athanor, read under its row lock. A cap of 0
  # is no ceiling, the meaning the operator's setting gives it, and counts
  # nothing.
  defp below_cap(_actor, 0), do: :ok

  defp below_cap(actor, cap) do
    count =
      from(s in McpServer, select: count(s.id))
      |> where_tenant(actor)
      |> Arca.Repo.one()

    if (count || 0) < cap, do: :ok, else: {:error, :server_cap}
  end

  # arca:unscoped-ok insert/2 stamped the actor's athanor onto the row before the transaction.
  defp insert_row(row) do
    case Arca.Repo.insert_all(McpServer, [row],
           on_conflict: :nothing,
           conflict_target: [:athanor_id, :name],
           returning: true
         ) do
      {1, [server]} -> {:ok, server}
      {0, _} -> {:error, :exists}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
