# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.ThreadEvent do
  @moduledoc """
  One thing a thread's live view must hear, on `Cyfr.Bus.thread/2`,
  published by the tape (`Aqua.Tape`) and its runner.

  `data` is plain data by kind:

    * `:message` — a tape row as a plain map, after its write committed;
    * `:turn_suspended`, `:turn_started` — the turn's id;
    * `:turn_finished` — nil;
    * `:turn_starting` — the id of the person whose turn is starting;
    * `:turn_paused` — `%{turn_id:, reason:}`;
    * `:turn_fence` — `%{turn_id:, fence:}`, the running loop's fence;
    * `:approval_resolved` — the resolution's ids and decision;
    * `:queued` — how many turns wait;
    * `:grants` — the thread's standing grants;
    * `:restart_prompt` — `%{text:, user_id:}`;
    * `:consent_required` — `%{ref:, user_id:}`;
    * `:intents` — `%{intents:, user_id:}`;
    * `:usage` — the turn's token totals;
    * `:tool_activity` — the running tool calls;
    * `:delta`, `:delta_abandoned` — a chat step's streamed text and
      its withdrawal (`Aqua.Loop.Stream`);
    * `:error` — a sentence for the person.
  """

  alias Cyfr.Bus.Payload

  @kinds [
    :message,
    :turn_suspended,
    :turn_finished,
    :turn_starting,
    :turn_started,
    :turn_paused,
    :turn_fence,
    :approval_resolved,
    :queued,
    :grants,
    :restart_prompt,
    :consent_required,
    :intents,
    :usage,
    :tool_activity,
    :delta,
    :delta_abandoned,
    :error
  ]

  @enforce_keys [:athanor_id, :thread_id, :kind]
  defstruct [:athanor_id, :thread_id, :kind, :data]

  @type kind ::
          :message
          | :turn_suspended
          | :turn_finished
          | :turn_starting
          | :turn_started
          | :turn_paused
          | :turn_fence
          | :approval_resolved
          | :queued
          | :grants
          | :restart_prompt
          | :consent_required
          | :intents
          | :usage
          | :tool_activity
          | :delta
          | :delta_abandoned
          | :error

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          thread_id: String.t(),
          kind: kind(),
          data: term()
        }

  @doc "The closed union of what a thread's live view hears."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  An event of `thread_id` in `actor`'s athanor. A kind outside `kinds/0`
  raises.
  """
  @spec new(Cyfr.Actor.t(), String.t(), kind(), term()) :: t()
  def new(%Cyfr.Actor{} = actor, thread_id, kind, data \\ nil) when is_binary(thread_id) do
    %__MODULE__{
      athanor_id: Payload.athanor!(actor),
      thread_id: thread_id,
      kind: Payload.kind!(__MODULE__, kind, @kinds),
      data: data
    }
  end
end
