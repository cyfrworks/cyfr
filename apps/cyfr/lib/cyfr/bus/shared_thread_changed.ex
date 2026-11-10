# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.SharedThreadChanged do
  @moduledoc """
  A shared thread one person sits in, or sat in until this change, moved,
  on that person's own `Cyfr.Bus.shared_threads/1` topic: `:changed` for
  its title, status or people, `:posted` for a message, `:read` when the
  person's own read mark moved. It carries the thread's id and nothing of
  what changed; a page that shows the thread reads it again under the
  person's seat (`Sanctum.SharedThreads`).
  """

  alias Cyfr.Bus.Payload

  @kinds [:changed, :posted, :read]

  @enforce_keys [:kind, :user_id, :thread_id]
  defstruct [:kind, :user_id, :thread_id]

  @type kind :: :changed | :posted | :read

  @type t :: %__MODULE__{kind: kind(), user_id: String.t(), thread_id: String.t()}

  @doc "The closed union of what happened to a thread."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "A change of `thread_id`, told to `user_id`. A kind outside `kinds/0` raises."
  @spec new(kind(), String.t(), String.t()) :: t()
  def new(kind, user_id, thread_id) when is_binary(user_id) and is_binary(thread_id) do
    %__MODULE__{
      kind: Payload.kind!(__MODULE__, kind, @kinds),
      user_id: user_id,
      thread_id: thread_id
    }
  end
end
