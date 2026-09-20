# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Doors do
  @moduledoc """
  The server allowlist rows (`Arca.Schemas.ServerAllowlistEntry`) — the
  door: who may sign in to this server at all.

  Rows only. Which entry admits whom, which of them an operator may write
  and what a refusal says are `Sanctum.Door`'s; this module reads and
  writes the table and says which of the three things happened — the row
  is there, the row is not there, or the store could not answer.

  ## The first argument

  Every facade here takes `%Cyfr.Actor{}` first, and matches `scope:
  :platform` in the head rather than an athanor id.

  A door entry carries no athanor and cannot: the door is asked **before**
  a session exists, so at admission time there is no tenant, no person and
  no credential to scope a read to. What a door row belongs to is the
  server, and the authority that reaches it is the platform scope.
  `Cyfr.Actor.system/0` carries it — that is how `Sanctum.Door` asks at
  sign-in, the server asking its own question on behalf of someone who is
  not yet anyone here. A platform admin's context projects the same scope
  (`Sanctum.Context.actor/1`), so the operator verbs that edit the door
  need no authority beyond the one their operation was already gated on,
  and an operator's write never has to borrow the server's own.

  An athanor-scoped actor — any ordinary caller — is refused with
  `{:error, :not_platform}` before any query, so a tenant's code cannot
  enumerate or edit who may sign in to the server it runs on. Anything
  that is not an actor at all — a `%Sanctum.Context{}`, a bare id — matches
  no head and raises.

  Nothing here reads an athanor, so no head guards one. The empty-string
  athanor that is an unresolved identity elsewhere has no meaning at this
  table, and an empty **entry id** is not one either: entry ids arrive from
  an operator over the wire, no row carries one, and `{:error, :not_found}`
  is the true answer rather than a sentinel standing in for a refusal.

  ## What crosses

  Plain maps with the row's ten fields, and typed errors. No schema
  struct and no changeset leaves this module: `{:error, :already_exists}`
  is a lost race for the unique `[kind, value]` pair, and
  `{:error, {:invalid, errors}}` carries a map of field to rendered
  messages rather than the changeset that produced them.
  """

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.ServerAllowlistEntry, as: Entry

  @columns [
    :id,
    :kind,
    :value,
    :effect,
    :status,
    :requested_by,
    :added_by,
    :note,
    :created_at,
    :updated_at
  ]

  @typedoc "One door row as it crosses the boundary."
  @type entry :: %{
          id: String.t(),
          kind: String.t(),
          value: String.t(),
          effect: String.t(),
          status: String.t(),
          requested_by: String.t() | nil,
          added_by: String.t() | nil,
          note: String.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @type refusal :: {:error, :not_platform | :database_error}

  @doc "The kinds a door row may name, as the rows themselves define them."
  @spec kinds() :: [String.t()]
  def kinds, do: Entry.kinds()

  @doc "Every entry, allowed and requested, newest first."
  @spec list(Cyfr.Actor.t()) :: {:ok, [entry()]} | refusal()
  def list(%Cyfr.Actor{scope: :platform}) do
    Arca.Repo.Errors.with_db_rescue("Arca.Doors.list", fn ->
      {:ok, Arca.Repo.all(from(e in Entry, order_by: [desc: e.created_at])) |> Enum.map(&row/1)}
    end)
  end

  def list(%Cyfr.Actor{}), do: {:error, :not_platform}

  @doc "The entries still waiting on an operator, oldest first."
  @spec requests(Cyfr.Actor.t()) :: {:ok, [entry()]} | refusal()
  def requests(%Cyfr.Actor{scope: :platform}) do
    Arca.Repo.Errors.with_db_rescue("Arca.Doors.requests", fn ->
      query = from(e in Entry, where: e.status == "requested", order_by: [asc: e.created_at])
      {:ok, Arca.Repo.all(query) |> Enum.map(&row/1)}
    end)
  end

  def requests(%Cyfr.Actor{}), do: {:error, :not_platform}

  @doc "One entry by id."
  @spec get(Cyfr.Actor.t(), String.t()) :: {:ok, entry()} | {:error, :not_found} | refusal()
  def get(%Cyfr.Actor{scope: :platform}, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Doors.get", fn ->
      case Arca.Repo.get(Entry, id) do
        nil -> {:error, :not_found}
        entry -> {:ok, row(entry)}
      end
    end)
  end

  def get(%Cyfr.Actor{}, id) when is_binary(id), do: {:error, :not_platform}

  @doc """
  The one entry for `kind` and `value`, the pair the unique index is on.

  `{:error, :not_found}` is "no such row" and `{:error, :database_error}`
  is "we could not look" — the door is where that difference decides who
  gets in, so the two are never collapsed here.
  """
  @spec find(Cyfr.Actor.t(), String.t(), String.t()) ::
          {:ok, entry()} | {:error, :not_found} | refusal()
  def find(%Cyfr.Actor{scope: :platform}, kind, value)
      when is_binary(kind) and is_binary(value) do
    Arca.Repo.Errors.with_db_rescue("Arca.Doors.find", fn ->
      case Arca.Repo.get_by(Entry, kind: kind, value: value) do
        nil -> {:error, :not_found}
        entry -> {:ok, row(entry)}
      end
    end)
  end

  def find(%Cyfr.Actor{}, kind, value) when is_binary(kind) and is_binary(value),
    do: {:error, :not_platform}

  @doc """
  Write a new entry, minting its id and both timestamps.

  `{:error, :already_exists}` when the `[kind, value]` pair is taken —
  the unique index is the arbiter of a race between two writers of the
  same entry, and the caller decides what to do with the row that landed.
  """
  @spec insert(Cyfr.Actor.t(), map()) ::
          {:ok, entry()} | {:error, :already_exists | {:invalid, map()}} | refusal()
  def insert(%Cyfr.Actor{scope: :platform}, attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.Doors.insert", fn ->
      now = DateTime.utc_now()

      %Entry{}
      |> Entry.changeset(
        attrs
        |> Map.take(@columns)
        |> Map.merge(%{id: Cyfr.UUID7.generate_id("door"), created_at: now, updated_at: now})
      )
      |> Arca.Repo.insert()
      |> written()
    end)
  end

  def insert(%Cyfr.Actor{}, attrs) when is_map(attrs), do: {:error, :not_platform}

  @doc """
  Change the entry `id` names, stamping `updated_at`.

  `{:error, :not_found}` when the row is gone — a caller that read it
  first and writes into the gap learns that it lost, rather than being
  answered with the row it remembered.
  """
  @spec update(Cyfr.Actor.t(), String.t(), map()) ::
          {:ok, entry()} | {:error, :not_found | :already_exists | {:invalid, map()}} | refusal()
  def update(%Cyfr.Actor{scope: :platform}, id, attrs) when is_binary(id) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.Doors.update", fn ->
      case Arca.Repo.get(Entry, id) do
        nil ->
          {:error, :not_found}

        entry ->
          entry
          |> Entry.changeset(
            attrs
            |> Map.take(@columns)
            |> Map.put(:updated_at, DateTime.utc_now())
          )
          |> Arca.Repo.update()
          |> written()
      end
    end)
  end

  def update(%Cyfr.Actor{}, id, attrs) when is_binary(id) and is_map(attrs),
    do: {:error, :not_platform}

  @doc "Delete the entry `id` names."
  @spec delete(Cyfr.Actor.t(), String.t()) :: :ok | {:error, :not_found} | refusal()
  def delete(%Cyfr.Actor{scope: :platform}, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Doors.delete", fn ->
      case Arca.Repo.delete_all(from(e in Entry, where: e.id == ^id)) do
        {0, _} -> {:error, :not_found}
        _ -> :ok
      end
    end)
  end

  def delete(%Cyfr.Actor{}, id) when is_binary(id), do: {:error, :not_platform}

  # ---- internal --------------------------------------------------------------

  defp written({:ok, entry}), do: {:ok, row(entry)}

  defp written({:error, %Ecto.Changeset{} = changeset}) do
    errors = Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

    if taken?(changeset), do: {:error, :already_exists}, else: {:error, {:invalid, errors}}
  end

  # The unique `[kind, value]` index reports on the first field of the pair.
  defp taken?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {field, {_message, meta}} ->
      field == :kind and meta[:constraint] == :unique
    end)
  end

  defp row(%Entry{} = entry), do: Map.take(entry, @columns)
end
