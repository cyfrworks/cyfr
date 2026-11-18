# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Message do
  @moduledoc """
  Ecto schema for the `messages` table (backs `Arca.ThreadStorage`).

  One row per thread entry, in `seq` order. `author` is a user id or one
  of the two reserved authors below (`agent_author/0`, `system_author/0`);
  `kind` is `text | approval | error | system`. An approval row carries the
  agent's proposal in `payload` and walks
  `pending → running → approved | declined | error`, with the decision in
  `resolution` and the person who made it in `resolved_by`.

  `sent_by` is who said it, `"person"` or an agent name, on every row: a
  turn's own rows carry its agent, so what anyone else wrote into a turn
  is told apart by it. A request to a crew member names it in `addressee`
  and is `pending` until a reply answers it: then `answered`, with the
  reply's id in `resolved_by`, or `expired` when the person stopped its
  room's work before an answer came. A reply names the request it answers in
  `reply_to`, its `outcome` (`outcomes/0`) and, in `addressee`, who the
  request came from; a notice is a reply row whose outcome is
  `needs_you`, which answers nothing.

  A workspace thread's rows: an `opening` is the first message of a
  workspace thread and each further ask sent there (its envelope in
  `payload`), waiting for its turn while it has none and no `status`:
  `expired` once the person stopped the thread's work before it started,
  `error` once its delivery was refused for good; a `pointer` the daily
  thread's post that points at a workspace thread opened or asked again,
  and a `report` the daily thread's post of a workspace thread's
  outcome. A pointer and a report
  name their workspace thread in `workspace_id`, by which they go with it
  when it is deleted, as the server's post of its wait on its person
  does: a `text` row sent by `system` on a daily thread, its payload's
  `waits_since` the wait it names (`Aqua.Nudge`).

  A `nudge` is the server's line to a quiet workspace thread's Aqua
  (`Aqua.Nudge`), sent by `system` and written in the server's voice:
  the ask to say where its work stands. It is no post: it counts as
  nothing unread and reopens nothing. It is answered once a model step of
  its turn carried it, and that step's id is its `resolved_by`; for a
  program brain, once the program's own end of its turn named the
  `input` step that delivered it.

  `carried_by` is the step that first carried a post to its brain: a
  program brain's `input` step (`Arca.TurnStorage.carry/3`). A post with
  none still waits; one carried is no steer and the turn reads it as
  history.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}
  # `tool_call`, `tool_result`, `compaction` and `turn_aborted` are the
  # turn's own rows: the loop writes them through `Aqua.Tape`. A
  # `page_call` is a call a page in Aqua's browser made, which the host
  # proposed as a step, and a `page_result` its answer: the turn's own
  # rows too, which no model's request carries (`Aqua.PageCalls`). A
  # `page_call`'s `resolved_at` is when its request ended unanswered
  # (`Arca.TurnStorage.end_call/4`).
  @kinds ~w(text approval error system tool_call tool_result compaction turn_aborted
             opening pointer report page_call page_result nudge)
  @statuses ~w(pending running approved declined error expired answered)

  @doc """
  A reply's or notice's `outcome` vocabulary, the `messages_outcome_known`
  check's: `Prima.OutboxRecord.reply_outcomes/0`, which a reply's outbox
  record carries.
  """
  @spec outcomes() :: [String.t()]
  def outcomes, do: Prima.OutboxRecord.reply_outcomes()

  # The two reserved authors are `Prima.Author`'s, where every side of a
  # thread reads them; the two heads below are this table's spelling.

  @doc "The `author` of a row the assistant wrote — `Prima.Author.agent/0`."
  @spec agent_author() :: String.t()
  defdelegate agent_author(), to: Prima.Author, as: :agent

  @doc """
  The `author` of a row written in the server's voice rather than the
  assistant's — `Prima.Author.system/0`.
  """
  @spec system_author() :: String.t()
  defdelegate system_author(), to: Prima.Author, as: :system

  schema "messages" do
    field :thread_id, :string
    field :athanor_id, :string
    field :seq, :integer
    field :author, :string
    field :kind, :string, default: "text"
    field :content, :string, default: ""
    field :payload, :string
    field :status, :string
    field :resolved_by, :string
    field :carried_by, :string
    field :resolved_at, :utc_datetime_usec
    field :resolution, :string
    field :execution_id, :string
    field :inserted_at, :utc_datetime_usec
    field :turn_id, :string
    field :approval_id, :string
    field :client_id, :string
    field :sent_by, :string
    field :addressee, :string
    field :reply_to, :string
    field :outcome, :string
    field :workspace_id, :string
  end

  @fields [
    :id,
    :thread_id,
    :athanor_id,
    :seq,
    :author,
    :kind,
    :content,
    :payload,
    :status,
    :resolved_by,
    :resolved_at,
    :resolution,
    :execution_id,
    :inserted_at,
    :turn_id,
    :approval_id,
    :client_id,
    :sent_by,
    :addressee,
    :reply_to,
    :outcome,
    :workspace_id
  ]

  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required([
      :id,
      :thread_id,
      :athanor_id,
      :seq,
      :author,
      :sent_by,
      :kind,
      :inserted_at
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:outcome, outcomes())
    |> unique_constraint([:thread_id, :seq])
    |> unique_constraint([:thread_id, :client_id])
    # The primary key, under the name each adapter reports it by.
    |> unique_constraint(:id, name: :messages_pkey)
    |> unique_constraint(:id, name: :messages_id_index)
  end
end
