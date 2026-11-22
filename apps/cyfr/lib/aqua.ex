# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua do
  @moduledoc """
  The agent-orchestration domain: threads, turns, and the action
  plane an agent speaks through.

  - `Aqua.Runner` — one process per thread; every send is admitted
    and accepted through it, and it owns the turns' lifecycle.
  - `Aqua.Loop` — one turn, run by the process that holds its root: the
    model rounds, the dispatch, and each call decided (`Aqua.Loop.Turn`,
    `Aqua.Loop.Binding`, `Aqua.Loop.Request`, `Aqua.Loop.Planner`,
    `Aqua.Loop.Policy`).
  - `Aqua.Crew` — the crew index, the soul's hand-off to a crew member,
    worked in a child thread of the room, and the delivery of requests
    and replies.
  - `Aqua.Tape` — the one persistence port of the runner and the loop.
  - `Aqua.Launch` — the one dispatcher of a launch, run as a person.
  - `Aqua.Prompt` — the one composer of the system prompt, from the
    resolved agent and the turn's pinned authority.
  - `Aqua.Hands` — the pseudo-tools that run on the bundled catalysts, and
    the console intents (`Aqua.Intents`).
  - `Aqua.AgentConfig` — the soul's and the crew's definitions and their catalysts;
    `Aqua.Roster` — who may be addressed.
  - `Aqua.Models` — what a model can do, the model listing, an agent's
    brain options, whether each agent's brain is ready and what is known
    of its program; `Aqua.ConsentStatus` — whether what the
    athanor consented to still covers its sources.
  - `Aqua.ScheduleNotes` — a schedule's outcome kept as a note when the
    schedule asked for it; `Aqua.ScheduleTurns` — a schedule's line for
    Aqua, each fire a turn of the daily thread current when it fires.
  - `Aqua.Day` — the person's day, and the daily thread that holds it.
  - `Aqua.Providers.Workspace` — workspace threads, opened from a daily
    thread for one piece of work, which the soul works in turns of their
    own, reporting back to it; `Aqua.Steps` — what Aqua did in a thread, one
    sentence a step.
  - `Aqua.Aloud` — the one deliberate copy: your own lines, said into a
    shared thread you sit in.
  - `Aqua.Notes` — what somebody chose to keep out of a thread: the
    athanor's pinned page and its filed pile, surviving the tape.
  - `Aqua.RoomExcerpt` — what the person has open beside the thread, read
    for the turn as quoted material.
  - `Aqua.Attachments` — chat attachment refs and blobs.
  - `Aqua.Ops` — the single seam onto the gate's dispatch
    (`Aqua.ToolSeamTest` keeps it the only one).

  This is domain, not console: it drives `PrismWeb`'s chat through PubSub
  broadcasts and rows, and never names the console back (pinned by
  `Cyfr.Boundaries`).

  The functions below are the domain's door for callers outside it.
  """

  use Boundary,
    deps: [Compendium, Opus, Cyfr, Sanctum, Arca],
    exports: [
      Supervisor,
      Text
    ],
    check: [aliases: true]

  alias Aqua.{Attachments, ConsentStatus, Models, Notes}
  alias Sanctum.Context

  @doc "The model listing the console's pickers show. See `Aqua.Models.catalogue/1`."
  @spec models(Context.t()) :: {:ok, map()} | {:error, :forbidden | :unavailable}
  defdelegate models(ctx), to: Models, as: :catalogue

  @doc "One brain asked for its models. See `Aqua.Models.models/2`."
  @spec models(Context.t(), String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  defdelegate models(ctx, ref), to: Models

  @doc "Every brain the athanor can connect. See `Aqua.Models.providers/1`."
  @spec providers(Context.t()) :: {:ok, [Models.provider()]} | {:error, :forbidden | :unavailable}
  defdelegate providers(ctx), to: Models

  @doc "Whether each agent's brain is ready, by name. See `Aqua.Models.model_status/2`."
  @spec model_status(Context.t() | nil, [map()]) :: %{String.t() => {atom(), String.t()}}
  defdelegate model_status(ctx, agents), to: Models

  @doc "The options an agent's brain declares. See `Aqua.Models.brain_options/2`."
  @spec brain_options(Context.t(), map()) :: {:ok, [map()]} | {:error, term()}
  defdelegate brain_options(ctx, agent), to: Models

  @doc """
  The models, each with its efforts, and the access choices a program
  brain's program lists, by asking it. See `Aqua.Models.program_listing/2`.
  """
  @spec program_listing(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate program_listing(ctx, agent), to: Models

  @doc "What is known of an agent's program, never asking it. See `Aqua.Models.known_program/2`."
  @spec known_program(Context.t(), map()) :: %{
          account: :signed_in | :signed_out | nil,
          listing: map() | nil
        }
  defdelegate known_program(ctx, agent), to: Models

  @doc """
  The words a person reads for the permission `action` of `tool`: those
  its operation is declared with (`Prima.Operation`), as the system layer
  names a change, and for a virtual tool, which declares its family's
  title alone, that title and the action. Never the `tool.action` name.
  """
  @spec action_title(String.t(), String.t()) :: String.t()
  def action_title(tool, action) do
    with nil <- declared_words(tool, action),
         %{title: title} <- Sanctum.VirtualTools.table()[tool] do
      "#{title}: #{action}"
    else
      words when is_binary(words) -> words
      _undeclared -> "Another action"
    end
  end

  defp declared_words(tool, action) do
    case Sanctum.Catalog.operations() do
      %{^tool => {_module, %{operations: operations}}} ->
        Enum.find_value(operations, &(&1.action == action && &1.description))

      _not_in_the_table ->
        nil
    end
  end

  @doc "Every local source whose consent no longer answers. See `Aqua.ConsentStatus.stale_refs/1`."
  @spec stale_consent_refs(Context.t()) ::
          {:ok, [{String.t(), :stale | {:drifted, [String.t()]}}]}
          | {:error, ConsentStatus.refusal()}
  defdelegate stale_consent_refs(ctx), to: ConsentStatus, as: :stale_refs

  @doc "The storage path of one message attachment's blob (`Aqua.Attachments.blob_path/3`)."
  @spec attachment_blob_path(String.t(), String.t(), Attachments.ref()) ::
          {:ok, [String.t()]} | :error
  defdelegate attachment_blob_path(thread_id, message_id, ref), to: Attachments, as: :blob_path

  @doc """
  A message row's attachment refs, each whose bytes the person deleted
  marked removed (`Aqua.Attachments.as_kept/2`).
  """
  @spec attachments_as_kept(Sanctum.Context.t(), Aqua.Tape.row()) :: [Attachments.ref()]
  defdelegate attachments_as_kept(ctx, message), to: Attachments, as: :as_kept

  @doc "The attachment refs a message row carries (`Aqua.Attachments.refs_of/1`)."
  @spec attachment_refs(Aqua.Tape.row()) :: [Attachments.ref()]
  defdelegate attachment_refs(message), to: Attachments, as: :refs_of

  @doc "An attachment name with its control characters removed (`Aqua.Attachments.strip_controls/1`)."
  @spec strip_attachment_name(String.t()) :: String.t()
  defdelegate strip_attachment_name(name), to: Attachments, as: :strip_controls

  @doc "The per-message attachment bounds (`Aqua.Attachments.limits/0`)."
  @spec attachment_limits() :: %{max_files: pos_integer(), max_file_bytes: pos_integer()}
  defdelegate attachment_limits(), to: Attachments, as: :limits

  @doc "The virtual tools with each action's kind (`Aqua.Hands.list_for_panel/0`)."
  @spec virtual_tool_catalog() :: [{String.t(), [{String.t(), atom()}]}]
  defdelegate virtual_tool_catalog(), to: Aqua.Hands, as: :list_for_panel

  @doc "The most bytes the athanor's pinned page holds (`Aqua.Notes.pin_max_bytes/0`)."
  @spec pin_max_bytes() :: pos_integer()
  defdelegate pin_max_bytes(), to: Notes

  @doc "The sentence for what a notes write answered, or nil (`Aqua.Notes.describe/1`)."
  @spec describe_note_result(term()) :: String.t() | nil
  defdelegate describe_note_result(result), to: Notes, as: :describe

  @doc "The athanor's pinned page (`Aqua.Notes.pinned_page/1`)."
  @spec pinned_note_page(Context.t()) :: {:ok, String.t()} | {:error, :not_found}
  defdelegate pinned_note_page(ctx), to: Notes, as: :pinned_page

  @doc "Whether a note name is the pinned page (`Aqua.Notes.pinned?/1`)."
  @spec note_pinned?(String.t()) :: boolean()
  defdelegate note_pinned?(name), to: Notes, as: :pinned?

  @doc "Who in the athanor may be addressed (`Aqua.Roster.roster/1`)."
  @spec roster(Context.t()) :: [map()]
  defdelegate roster(ctx), to: Aqua.Roster

  @doc "A thread's runner state as viewers see it (`Aqua.Runner.state/2`)."
  @spec thread_state(String.t(), String.t()) :: map() | {:error, term()}
  defdelegate thread_state(thread_id, athanor_id), to: Aqua.Runner, as: :state

  @doc """
  Keep `zone`, the time zone the person's browser reported, as theirs when
  the day can be read in it and it differs from the stored one
  (`Aqua.Day.put_zone/2`).
  """
  @spec put_time_zone(String.t(), term()) :: :ok | {:error, term()}
  defdelegate put_time_zone(user_id, zone), to: Aqua.Day, as: :put_zone

  @doc """
  The date now in the person's own time zone (`Aqua.Day.today/1`): which
  daily thread is today's. A read, which makes no thread.
  """
  @spec today(Context.t()) :: Date.t()
  defdelegate today(ctx), to: Aqua.Day

  @doc """
  Move the person's read mark of `thread_id` to `seq`, forward only, while a
  view shows it, and announce the thread again to their list with its
  count (`Aqua.ThreadList`).
  """
  @spec mark_read(Context.t(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  defdelegate mark_read(ctx, thread_id, seq), to: Aqua.ThreadList

  @doc """
  The person's workspace threads a view lists, the latest activity
  first: each at work or waiting on them, and each whose work ended with
  posts they have not seen (`Aqua.Providers.Workspace.records/1`).
  """
  @spec workspaces(Context.t()) ::
          {:ok, [Aqua.Providers.Workspace.entry()]} | {:error, term()}
  defdelegate workspaces(ctx), to: Aqua.Providers.Workspace, as: :records

  @doc """
  One workspace thread as a view reads it, with the daily thread's post it
  was opened from (`Aqua.Providers.Workspace.record/2`).
  """
  @spec workspace(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate workspace(ctx, thread_id), to: Aqua.Providers.Workspace, as: :record

  @doc "What a person reads while their browser setting is off. See `Aqua.Providers.Browser.turned_off/0`."
  @spec browser_turned_off() :: String.t()
  defdelegate browser_turned_off(), to: Aqua.Providers.Browser, as: :turned_off

  @doc """
  A thread's steps across its turns, newest first, each a sentence of
  what Aqua did (`Aqua.Steps.steps/3`).
  """
  @spec steps(Context.t(), String.t(), keyword()) ::
          {:ok, [Aqua.Steps.step()]} | {:error, term()}
  defdelegate steps(ctx, thread_id, opts \\ []), to: Aqua.Steps

  @doc """
  Who is at work in a workspace thread now, one row an agent, each with
  the last thing it did and when (`Aqua.Steps.at_work/2`).
  """
  @spec at_work(Context.t(), String.t()) :: {:ok, [Aqua.Steps.at_work()]} | {:error, term()}
  defdelegate at_work(ctx, workspace_id), to: Aqua.Steps

  @doc "An empty stream of a running turn's answers (`Aqua.Loop.Stream.new/0`)."
  @spec stream_new() :: Aqua.Loop.Stream.t()
  defdelegate stream_new(), to: Aqua.Loop.Stream, as: :new

  @doc "A stream once a step's text row landed in place of its answer (`Aqua.Loop.Stream.landed/2`)."
  @spec stream_landed(Aqua.Loop.Stream.t(), Aqua.Tape.row()) :: Aqua.Loop.Stream.t()
  defdelegate stream_landed(stream, row), to: Aqua.Loop.Stream, as: :landed

  @doc "A stream moved to a newer turn fence (`Aqua.Loop.Stream.advance/2`)."
  @spec stream_advance(Aqua.Loop.Stream.t(), pos_integer()) :: Aqua.Loop.Stream.t()
  defdelegate stream_advance(stream, fence), to: Aqua.Loop.Stream, as: :advance

  @doc "A stream with an abandoned answer's entry dropped (`Aqua.Loop.Stream.abandoned/2`)."
  @spec stream_abandoned(Aqua.Loop.Stream.t(), map()) :: Aqua.Loop.Stream.t()
  defdelegate stream_abandoned(stream, marker), to: Aqua.Loop.Stream, as: :abandoned

  @doc "A stream with one delta applied (`Aqua.Loop.Stream.add/2`)."
  @spec stream_add(Aqua.Loop.Stream.t(), map()) :: Aqua.Loop.Stream.t()
  defdelegate stream_add(stream, delta), to: Aqua.Loop.Stream, as: :add

  @doc "The streamed answers a viewer shows (`Aqua.Loop.Stream.texts/1`)."
  @spec stream_texts(Aqua.Loop.Stream.t()) ::
          [%{step_id: String.t(), role: String.t() | nil, text: String.t()}]
  defdelegate stream_texts(stream), to: Aqua.Loop.Stream, as: :texts

  @doc "The shared thread open beside a thread, read as quoted material (`Aqua.RoomExcerpt.read/2`)."
  @spec room_excerpt(Context.t(), Aqua.RoomExcerpt.room()) :: {:ok, String.t()} | {:error, term()}
  defdelegate room_excerpt(ctx, room), to: Aqua.RoomExcerpt, as: :read
end
