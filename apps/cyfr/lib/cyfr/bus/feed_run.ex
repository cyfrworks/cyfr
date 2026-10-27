# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.FeedRun do
  @moduledoc """
  A feed fired, or could not run or ran and failed, on
  `Cyfr.Bus.feed_runs/1`: the console's activity of a feed's run, apart
  from the schedules' firings (`Cyfr.Bus.ScheduleRun`) and from the
  accepted results a canvas reads (`Cyfr.Bus.FeedPublished`). `binding`
  is the feed's binding id. `reason` is a refusal: its class and
  sentence.
  """

  alias Cyfr.Bus.Payload

  @kinds [:fired, :failed]
  @fields [:binding, :occurrence_id, :execution_id, :reason]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind | @fields]

  @type kind :: :fired | :failed

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          binding: String.t() | nil,
          occurrence_id: String.t() | nil,
          execution_id: String.t() | nil,
          reason: %{class: Prima.Refusal.class(), message: String.t()} | nil
        }

  @doc "The closed union of what this payload says happened."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The payload for `actor`'s athanor. A kind outside `kinds/0` or a field
  this struct does not declare raises.
  `reason` is a refusal's class and sentence (`%{class, message}`).
  """
  @spec new(Prima.Actor.t(), kind(), map() | keyword()) :: t()
  def new(%Prima.Actor{} = actor, kind, fields \\ %{}) do
    fields = fields |> Map.new() |> Payload.refusals([:reason])

    Payload.build(__MODULE__, @fields, fields, %{
      athanor_id: Payload.athanor!(actor),
      kind: Payload.kind!(__MODULE__, kind, @kinds)
    })
  end
end
