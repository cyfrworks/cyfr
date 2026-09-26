# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua do
  @moduledoc """
  The agent-orchestration domain: threads, turns, and the action
  plane an agent speaks through.

  - `Aqua.Runner` — one process per thread; every send is admitted
    and accepted through it, and it owns the turns' lifecycle.
  - `Aqua.Loop` — one turn, run by the process that holds its root: the
    model rounds, the dispatch, the cards, the clones (`Aqua.Loop.Turn`,
    `Aqua.Loop.Binding`, `Aqua.Loop.Request`, `Aqua.Loop.Planner`,
    `Aqua.Loop.Policy`, `Aqua.Loop.Clone`).
  - `Aqua.Tape` — the one persistence port of the runner and the loop.
  - `Aqua.Approvals` — a card decided once, from its own rows;
    `Aqua.Standing` — what may stand for later calls; `Aqua.Launch` — an
    approved launch run as its approver.
  - `Aqua.Agent` — the agent a turn is addressed to, as the
    approvals re-authorise a card against it.
  - `Aqua.Prompt` — the one composer of the system prompt, from the
    resolved agent and the turn's pinned authority.
  - `Aqua.ToolGrants` — standing approvals as rows, composed over the
    agent's declared `tool_policy`.
  - `Aqua.Hands` — the pseudo-tools that run on the bundled catalysts, and
    the console intents (`Aqua.Intents`).
  - `Aqua.AgentConfig` — the soul's and the roles' definitions and prompts;
    `Aqua.Roster` — who may be addressed.
  - `Aqua.Models` — what a model can do, the model listing and whether
    each soul's model has a key; `Aqua.ConsentStatus` — whether what the
    estate consented to still covers its sources.
  - `Aqua.ScheduleNotes` — a schedule's outcome kept as a note when the
    schedule asked for it.
  - `Aqua.Aloud` — the one deliberate copy: your own lines, said into an
    estate you belong to.
  - `Aqua.Notes` — what somebody chose to keep out of a thread: the
    estate's pinned page and its filed pile, surviving the tape.
  - `Aqua.RoomExcerpt` — what the person has open beside the thread, read
    for the turn as quoted material.
  - `Aqua.Attachments` — chat attachment refs and blobs.
  - `Aqua.Ops` — the single seam to `Emissary.MCP.*`
    (`Aqua.ToolSeamTest` keeps it the only one).

  This is domain, not console: it drives `PrismWeb`'s chat through PubSub
  broadcasts and rows, and never names the console back (pinned by
  `Cyfr.Boundaries`).

  The functions below are the domain's door for callers outside it.
  """

  use Boundary,
    deps: [Compendium, Crucible, Grimoire, Cyfr, Sanctum, Arca],
    exports: [
      Supervisor,
      Text
    ],
    check: [aliases: true]

  alias Aqua.{ApprovalScope, Attachments, ConsentStatus, Kinds, Models, Notes}
  alias Sanctum.Context

  @doc "The model listing the console's pickers show. See `Aqua.Models.catalogue/1`."
  @spec models(Context.t()) :: {:ok, map()} | {:error, :forbidden | :unavailable}
  defdelegate models(ctx), to: Models, as: :catalogue

  @doc "What one model can do, read from its catalyst. See `Aqua.Models.capabilities/5`."
  @spec model_capabilities(Context.t(), String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, Prima.Model.capabilities()} | {:error, term()}
  defdelegate model_capabilities(ctx, resolved_ref, model, binding_digest, opts),
    to: Models,
    as: :capabilities

  @doc "Whether each soul's model has a key. See `Aqua.Models.model_status/2`."
  @spec model_status(Context.t() | nil, [map()]) :: %{String.t() => {atom(), String.t()}}
  defdelegate model_status(ctx, agents), to: Models

  @doc "Whether the soul's consent still covers its source. See `Aqua.ConsentStatus.state/2`."
  @spec consent_state(Context.t()) ::
          {:ok, ConsentStatus.state()} | {:error, ConsentStatus.refusal()}
  def consent_state(%Context{} = ctx), do: ConsentStatus.state(ctx, Prima.AgentRef.soul_ref())

  @doc "Whether the consent of `ref` still covers its source. See `Aqua.ConsentStatus.state/2`."
  @spec consent_state(Context.t(), String.t()) ::
          {:ok, ConsentStatus.state()} | {:error, ConsentStatus.refusal()}
  defdelegate consent_state(ctx, ref), to: ConsentStatus, as: :state

  @doc "Every local source whose consent no longer answers. See `Aqua.ConsentStatus.stale_refs/1`."
  @spec stale_consent_refs(Context.t()) ::
          {:ok, [{String.t(), :stale | {:drifted, [String.t()]}}]}
          | {:error, ConsentStatus.refusal()}
  defdelegate stale_consent_refs(ctx), to: ConsentStatus, as: :stale_refs

  @doc "The approval scope a string or atom names, `:once` otherwise (`Aqua.ApprovalScope.parse/1`)."
  @spec parse_approval_scope(term()) :: ApprovalScope.t()
  defdelegate parse_approval_scope(scope), to: ApprovalScope, as: :parse

  @doc "An approval scope's wire string (`Aqua.ApprovalScope.to_string/1`)."
  @spec approval_scope_string(ApprovalScope.t()) :: String.t()
  defdelegate approval_scope_string(scope), to: ApprovalScope, as: :to_string

  @doc "The storage path of one message attachment's blob (`Aqua.Attachments.blob_path/3`)."
  @spec attachment_blob_path(String.t(), String.t(), Attachments.ref()) ::
          {:ok, [String.t()]} | :error
  defdelegate attachment_blob_path(thread_id, message_id, ref), to: Attachments, as: :blob_path

  @doc "The attachment refs a message row carries (`Aqua.Attachments.refs_of/1`)."
  @spec attachment_refs(Aqua.Tape.row()) :: [Attachments.ref()]
  defdelegate attachment_refs(message), to: Attachments, as: :refs_of

  @doc "An attachment name with its control characters removed (`Aqua.Attachments.strip_controls/1`)."
  @spec strip_attachment_name(String.t()) :: String.t()
  defdelegate strip_attachment_name(name), to: Attachments, as: :strip_controls

  @doc "The per-message attachment bounds (`Aqua.Attachments.limits/0`)."
  @spec attachment_limits() :: %{max_files: pos_integer(), max_file_bytes: pos_integer()}
  defdelegate attachment_limits(), to: Attachments, as: :limits

  @doc "Remove a message's stored attachments (`Aqua.Attachments.discard/4`)."
  @spec discard_attachments(Context.t(), String.t(), String.t(), [Attachments.ref()]) :: :ok
  defdelegate discard_attachments(ctx, thread_id, message_id, refs),
    to: Attachments,
    as: :discard

  @doc "Store a message's attachments, all or none (`Aqua.Attachments.store/4`)."
  @spec store_attachments(Context.t(), String.t(), String.t(), [Attachments.file()]) ::
          {:ok, [Attachments.ref()]}
          | {:error,
             :too_many_attachments
             | :attachment_too_large
             | :storage_full
             | :storage_unverifiable
             | :storage_error}
  defdelegate store_attachments(ctx, thread_id, message_id, files),
    to: Attachments,
    as: :store

  @doc "What the assistant classifies `tool.action` as, or nil (`Aqua.Kinds.kind_for/2`)."
  @spec tool_kind(String.t(), String.t()) :: atom() | nil
  defdelegate tool_kind(tool, action), to: Kinds, as: :kind_for

  @doc "Whether `tool.action` may ever run without a card (`Aqua.Kinds.auto_permitted?/2`)."
  @spec auto_permitted?(String.t(), String.t()) :: boolean()
  defdelegate auto_permitted?(tool, action), to: Kinds

  @doc "The virtual tools with each action's kind (`Aqua.Hands.list_for_panel/0`)."
  @spec virtual_tool_catalog() :: [{String.t(), [{String.t(), atom()}]}]
  defdelegate virtual_tool_catalog(), to: Aqua.Hands, as: :list_for_panel

  @doc "The most bytes the estate's pinned page holds (`Aqua.Notes.pin_max_bytes/0`)."
  @spec pin_max_bytes() :: pos_integer()
  defdelegate pin_max_bytes(), to: Notes

  @doc "The sentence for what a notes write answered, or nil (`Aqua.Notes.describe/1`)."
  @spec describe_note_result(term()) :: String.t() | nil
  defdelegate describe_note_result(result), to: Notes, as: :describe

  @doc "The estate's pinned page (`Aqua.Notes.pinned_page/1`)."
  @spec pinned_note_page(Context.t()) :: {:ok, String.t()} | {:error, :not_found}
  defdelegate pinned_note_page(ctx), to: Notes, as: :pinned_page

  @doc "Whether a note name is the pinned page (`Aqua.Notes.pinned?/1`)."
  @spec note_pinned?(String.t()) :: boolean()
  defdelegate note_pinned?(name), to: Notes, as: :pinned?

  @doc "Who in the estate may be addressed (`Aqua.Roster.roster/1`)."
  @spec roster(Context.t()) :: [map()]
  defdelegate roster(ctx), to: Aqua.Roster

  @doc "A thread's runner state as viewers see it (`Aqua.Runner.state/2`)."
  @spec thread_state(String.t(), String.t()) :: map() | {:error, term()}
  defdelegate thread_state(thread_id, athanor_id), to: Aqua.Runner, as: :state

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

  @doc "The room open beside a thread, read as quoted material (`Aqua.RoomExcerpt.read/2`)."
  @spec room_excerpt(Context.t(), Aqua.RoomExcerpt.room()) :: {:ok, String.t()} | {:error, term()}
  defdelegate room_excerpt(ctx, room), to: Aqua.RoomExcerpt, as: :read
end
