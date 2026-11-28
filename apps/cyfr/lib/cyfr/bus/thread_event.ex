# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.ThreadEvent do
  @moduledoc """
  One thing a thread's live view must hear, on `Cyfr.Bus.thread/2`,
  published by the tape (`Aqua.Tape`) and its runner.

  `data` is plain data by kind:

    * `:message` — a tape row as a plain map, after its write committed;
    * `:request`, `:reply` — the same for a request to a crew member and
      a reply answering one, each told apart so a view can file it under
      what it answers;
    * `:turn_started` — the turn's id;
    * `:turn_finished` — nil;
    * `:turn_starting` — the id of the person whose turn is starting;
    * `:turn_paused` — `%{turn_id:, reason:}`;
    * `:turn_fence` — `%{turn_id:, fence:}`, the running loop's fence;
    * `:queued` — how many turns wait;
    * `:restart_prompt` — `%{text:, user_id:}`;
    * `:consent_required` — `%{ref:, user_id:}`, and for a launch naming
      an account its app's profile does not bind, `account: %{name:,
      need:}` beside them: the account's name and the app's credential
      need it is for, nil for the one need or one no binding tells; and
      `message_id:`, the message of the turn that asked, which ended on
      it, so a retry sends that message again; a person's turn refused for
      Aqua's grant names its message so too;
    * `:intents` — `%{intents:, user_id:}`;
    * `:usage` — what the thread's latest turn used, as its steps count
      it (`Aqua.Tape.usage/2`): `%{input:, output:, models:, accounting:}`,
      the models it ran and whether all of it was counted (`:complete`),
      some (`:partial`) or none (`:unavailable`); a thread with no turn
      yet tells `%{input: 0, output: 0}`;
    * `:tool_activity` — the running turn's list of calls, `%{turn_id:,
      fence:, entries:}`, whole each time it changes (`Aqua.Loop.Stream`);
    * `:delta`, `:delta_abandoned` — a chat step's streamed text and
      its withdrawal (`Aqua.Loop.Stream`);
    * `:error` — a sentence for the person.
  """

  alias Cyfr.Bus.Payload

  @kinds [
    :message,
    :request,
    :reply,
    :turn_finished,
    :turn_starting,
    :turn_started,
    :turn_paused,
    :turn_fence,
    :queued,
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
          | :request
          | :reply
          | :turn_finished
          | :turn_starting
          | :turn_started
          | :turn_paused
          | :turn_fence
          | :queued
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
  @spec new(Prima.Actor.t(), String.t(), kind(), term()) :: t()
  def new(%Prima.Actor{} = actor, thread_id, kind, data \\ nil) when is_binary(thread_id) do
    %__MODULE__{
      athanor_id: Payload.athanor!(actor),
      thread_id: thread_id,
      kind: Payload.kind!(__MODULE__, kind, @kinds),
      data: data
    }
  end
end
