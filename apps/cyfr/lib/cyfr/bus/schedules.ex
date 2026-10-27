# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Schedules do
  @moduledoc """
  A schedule row of the athanor as a committed write left it, on
  `Cyfr.Bus.schedules/1`: `changed` after a create, an edit, a pause, a
  resume, a cursor move, an occurrence's start and its run's end;
  `removed` once, after its delete, carrying the row as it was. A feed's
  row is never announced here. Distinct from `Cyfr.Bus.ScheduleRun`,
  which carries firings.

  A publisher builds the payload from the stored row (`row_fields/1`) and
  reads and broadcasts it under the schedule's one lock (`serialized/2`),
  so the announcements of one schedule made on a node leave in the order
  of their reads and none carries an older row after a newer one. The
  lock orders nothing between two members.
  """

  alias Cyfr.Bus.Payload

  @kinds [:changed, :removed]
  @fields [
    :schedule_id,
    :name,
    :reference,
    :cron_expression,
    :status,
    :next_run_at,
    :last_run_at,
    :run_count,
    :error_count
  ]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind | @fields]

  @type kind :: :changed | :removed

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          schedule_id: String.t() | nil,
          name: String.t() | nil,
          reference: String.t() | nil,
          cron_expression: String.t() | nil,
          status: String.t() | nil,
          next_run_at: DateTime.t() | nil,
          last_run_at: DateTime.t() | nil,
          run_count: non_neg_integer() | nil,
          error_count: non_neg_integer() | nil
        }

  @doc "The closed union of what this payload says happened."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The payload for `actor`'s athanor. A kind outside `kinds/0` or a field
  this struct does not declare raises.
  """
  @spec new(Prima.Actor.t(), kind(), map() | keyword()) :: t()
  def new(%Prima.Actor{} = actor, kind, fields \\ %{}) do
    Payload.build(__MODULE__, @fields, fields, %{
      athanor_id: Payload.athanor!(actor),
      kind: Payload.kind!(__MODULE__, kind, @kinds)
    })
  end

  @doc """
  The fields of a stored schedule row (`Arca.CronSchedule`): its id and
  the columns above, never its input, metadata, profile, pinned reference,
  maker or feed columns.
  """
  @spec row_fields(map()) :: keyword()
  def row_fields(%{id: id} = row) do
    [schedule_id: id] ++ Enum.map(@fields -- [:schedule_id], &{&1, Map.fetch!(row, &1)})
  end

  @doc """
  `fun` run under the lock every publisher of `schedule_id`'s payload
  reads its row and broadcasts under, on this node.
  """
  @spec serialized(String.t(), (-> term())) :: term()
  def serialized(schedule_id, fun) when is_binary(schedule_id) and is_function(fun, 0),
    do: :global.trans({{__MODULE__, schedule_id}, self()}, fun, [node()])
end
