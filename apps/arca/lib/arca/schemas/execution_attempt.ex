# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ExecutionAttempt do
  @moduledoc """
  One attempt at an execution: the fence every attempt-scoped write
  names. An execution's `current_attempt` points at the attempt that
  owns it; `fence` increases with each successor. `state` walks
  `running | paused` to `completed | failed | cancelled | lapsed`, and
  `outcome` records what a terminal attempt established:
  `ok | error | result_lost | cancelled | uncertain`. `claimed_by` names
  the runner that attached to the attempt (`Arca.ExecutionAttempts.claim/4`)
  and stays nil until then; a turn root is never claimed. `running_since`
  is set while the attempt runs and cleared when it pauses or ends, so
  running time is accounted once per interval. `athanor_generation` is
  the estate standing the attempt was admitted under
  (`Prima.ExecutionGrant`), inherited unchanged by a successor and never
  written after insert. Owned by the athanor.
  """

  use Ecto.Schema

  @primary_key {:attempt, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "execution_attempts" do
    field :athanor_id, :string
    field :athanor_generation, :integer
    field :execution_id, :string
    field :fence, :integer
    field :service_id, :string
    field :boot_id, :string
    field :claimed_by, :string
    field :lease_until, :utc_datetime_usec
    field :state, :string
    field :outcome, :string
    field :started_at, :utc_datetime_usec
    field :running_since, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
  end
end
