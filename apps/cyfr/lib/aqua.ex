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

  alias Aqua.{ConsentStatus, Models}
  alias Sanctum.Context

  @doc "The model listing the console's pickers show. See `Aqua.Models.catalogue/1`."
  @spec models(Context.t()) :: {:ok, map()} | {:error, :forbidden | :unavailable}
  defdelegate models(ctx), to: Models, as: :catalogue

  @doc "What one model can do, read from its catalyst. See `Aqua.Models.capabilities/5`."
  @spec model_capabilities(Context.t(), String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, Cyfr.Model.capabilities()} | {:error, term()}
  defdelegate model_capabilities(ctx, resolved_ref, model, binding_digest, opts),
    to: Models,
    as: :capabilities

  @doc "Whether each soul's model has a key. See `Aqua.Models.model_status/2`."
  @spec model_status(Context.t() | nil, [map()]) :: %{String.t() => {atom(), String.t()}}
  defdelegate model_status(ctx, agents), to: Models

  @doc "Whether the soul's consent still covers its source. See `Aqua.ConsentStatus.state/2`."
  @spec consent_state(Context.t()) ::
          {:ok, ConsentStatus.state()} | {:error, ConsentStatus.refusal()}
  def consent_state(%Context{} = ctx), do: ConsentStatus.state(ctx, Cyfr.AgentRef.soul_ref())

  @doc "Whether the consent of `ref` still covers its source. See `Aqua.ConsentStatus.state/2`."
  @spec consent_state(Context.t(), String.t()) ::
          {:ok, ConsentStatus.state()} | {:error, ConsentStatus.refusal()}
  defdelegate consent_state(ctx, ref), to: ConsentStatus, as: :state

  @doc "Every local source whose consent no longer answers. See `Aqua.ConsentStatus.stale_refs/1`."
  @spec stale_consent_refs(Context.t()) ::
          {:ok, [{String.t(), :stale | {:drifted, [String.t()]}}]}
          | {:error, ConsentStatus.refusal()}
  defdelegate stale_consent_refs(ctx), to: ConsentStatus, as: :stale_refs
end
