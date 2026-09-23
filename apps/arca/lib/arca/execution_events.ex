# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionEvents do
  @moduledoc """
  The `execution_events` rows: an execution's durable lifecycle and step
  outcomes, numbered from the execution's own counter.

  A durable event's `seq` comes from `executions.event_seq`, incremented
  inside the writer's transaction; the row update serializes allocation
  per execution on both adapters, so publication after commit is in seq
  order. Ephemeral deltas never take a durable number: they ride a
  sub-sequence under the last durable seq and are never replayed.
  Token deltas are not written here.

  Every function that names an athanor takes the `Cyfr.Actor` first and
  matches it in its head; an actor whose athanor is nil or the empty
  string is refused before any query, as `{:error, :no_athanor}` from an
  entry point and as a raise from `append!/4`, which runs inside a
  caller's transaction.
  """

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.ExecutionEvent

  @terminal ~w(execution.completed execution.failed execution.cancelled execution.lapsed execution.result_lost)

  @doc "The lifecycle types that end an execution's stream."
  @spec terminal_types() :: [String.t()]
  def terminal_types, do: @terminal

  @doc """
  Append one durable event to `execution_id` inside the caller's
  transaction and answer the row. `opts`: `:turn_id`, `:step_id`,
  `:data` (a map, stored as JSON). Raises when the execution is not the
  athanor's.
  """
  @spec append!(Cyfr.Actor.t(), String.t(), String.t(), keyword()) :: ExecutionEvent.t()
  def append!(actor, execution_id, type, opts \\ [])

  # arca:db-raise-ok inside the caller's transaction
  def append!(%Cyfr.Actor{athanor_id: athanor_id}, execution_id, type, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(type) do
    {count, _} =
      from(e in Arca.Schemas.Execution,
        where: e.id == ^execution_id and e.athanor_id == ^athanor_id
      )
      |> Arca.Repo.update_all(inc: [event_seq: 1])

    if count != 1, do: Arca.Repo.rollback({:execution_not_found, execution_id})

    seq =
      Arca.Repo.one!(
        from(e in Arca.Schemas.Execution,
          where: e.id == ^execution_id and e.athanor_id == ^athanor_id,
          select: e.event_seq
        )
      )

    Arca.Repo.insert!(%ExecutionEvent{
      id: Cyfr.UUID7.generate_id("evt"),
      athanor_id: athanor_id,
      execution_id: execution_id,
      turn_id: Keyword.get(opts, :turn_id),
      step_id: Keyword.get(opts, :step_id),
      seq: seq,
      type: type,
      data: encode(Keyword.get(opts, :data)),
      inserted_at: DateTime.utc_now()
    })
  end

  def append!(%Cyfr.Actor{}, _execution_id, _type, _opts),
    do: Arca.QueryHelpers.no_athanor!("Arca.ExecutionEvents.append!/4")

  @doc "Entry-point form of `append!/4`."
  @spec append(Cyfr.Actor.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def append(actor, execution_id, type, opts \\ [])

  def append(%Cyfr.Actor{athanor_id: athanor_id} = actor, execution_id, type, opts)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionEvents.append", fn ->
      Arca.Repo.transaction(fn -> append!(actor, execution_id, type, opts) end)
    end)
    |> Arca.Data.project()
  end

  def append(%Cyfr.Actor{}, _execution_id, _type, _opts), do: {:error, :no_athanor}

  @doc "The events of an execution after `after_seq`, in order, at most `limit`."
  @spec since(Cyfr.Actor.t(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def since(actor, execution_id, after_seq, limit \\ 500)

  def since(%Cyfr.Actor{athanor_id: athanor_id}, execution_id, after_seq, limit)
      when is_binary(athanor_id) and athanor_id != "" and is_integer(after_seq) do
    Arca.Repo.Errors.with_db_rescue("Arca.ExecutionEvents.since", fn ->
      {:ok,
       Arca.Repo.all(
         from(v in ExecutionEvent,
           where: v.athanor_id == ^athanor_id and v.execution_id == ^execution_id,
           where: v.seq > ^after_seq,
           order_by: [asc: v.seq],
           limit: ^limit
         )
       )}
    end)
    |> Arca.Data.project()
  end

  def since(%Cyfr.Actor{}, _execution_id, _after_seq, _limit), do: {:error, :no_athanor}

  @doc "The decoded `data` of an event row, or an empty map."
  @spec data(map()) :: map()
  def data(%{data: nil}), do: %{}

  def data(%{data: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp encode(nil), do: nil
  defp encode(map) when is_map(map), do: Jason.encode!(map)
end
