# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.PageCall do
  @moduledoc """
  A page in Aqua's browser called CYFR, or a call it made ended
  unanswered, on the global `Cyfr.Bus.page_calls/0`, published by the
  person's browser (`Opus.Browser`) and heard by `Aqua.PageCalls`.

  `call` is one call the browser holds paused: the window it came from
  (`thread_id`), the request the browser named it by, its `op`
  (`invoke` or `action`), its body's bytes and the put the calling
  document belongs to, the putting turn and the tincture reference it
  put, nil for a page that is no tincture. `ended` names a request the browser no longer holds: the
  driver gave it up, the browser's session ended, the browser stopped or
  the process that held it died. A request is answered once, through
  `Opus.Browser.answer/5`.

  The body is the page's own bytes: no inspect of this struct shows it.
  """

  alias Cyfr.Bus.Payload

  @kinds [:call, :ended]
  @ended [:user_id, :thread_id, :request]
  @call @ended ++ [:op, :body, :put]

  @derive {Inspect, except: [:body]}
  @enforce_keys [:kind, :athanor_id, :user_id, :thread_id, :request]
  defstruct [:kind, :athanor_id, :user_id, :thread_id, :request, :op, :body, :put]

  @type kind :: :call | :ended

  @type t :: %__MODULE__{
          kind: kind(),
          athanor_id: String.t(),
          user_id: String.t(),
          thread_id: String.t(),
          request: String.t(),
          op: String.t() | nil,
          body: binary() | nil,
          put: %{turn_id: String.t(), tincture: String.t() | nil} | nil
        }

  @doc "The closed union: a page's call, or the end of one unanswered."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The payload for `actor`'s athanor. A kind outside `kinds/0`, a field
  this struct does not declare, or a field of a call on an end, raises.
  """
  @spec new(Prima.Actor.t(), kind(), map() | keyword()) :: t()
  def new(%Prima.Actor{} = actor, kind, fields) do
    kind = Payload.kind!(__MODULE__, kind, @kinds)

    Payload.build(__MODULE__, if(kind == :call, do: @call, else: @ended), fields, %{
      kind: kind,
      athanor_id: Payload.athanor!(actor)
    })
  end
end
