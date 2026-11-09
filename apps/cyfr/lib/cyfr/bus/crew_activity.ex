# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.CrewActivity do
  @moduledoc """
  A crew member's job began or ended, on the athanor's
  `Cyfr.Bus.crew_activity/1`, for the stream a canvas reads
  (`activity.changes`): the job's `id` (its turn, the key a reader
  holds it by, since one member may hold several jobs at once), the
  `member` (the crew agent's name), who
  `asked_by` (a display name, or the agent that asked), its `title` (a
  short line the asker gave it, or nil), `since` when the
  member took it, and its `status` (named so because the sanitizer
  reads a bare `state` as an OAuth secret). `ended` is a job that left the
  member's open work. Never the task's text or a person's id.
  """

  alias Cyfr.Bus.Payload

  @kinds [:started, :ended]
  @fields [:id, :member, :asked_by, :title, :since, :status]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind | @fields]

  @type kind :: :started | :ended

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          kind: kind(),
          id: String.t() | nil,
          member: String.t() | nil,
          asked_by: String.t() | nil,
          title: String.t() | nil,
          since: DateTime.t() | nil,
          status: String.t() | nil
        }

  @doc "The closed union: a job is open, or it ended."
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
end
