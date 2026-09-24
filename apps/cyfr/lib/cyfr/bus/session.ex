# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Session do
  @moduledoc """
  Session lifecycle, on the global `Cyfr.Bus.sessions/0`: a session was
  minted (no token travels; a subscriber adopts its own), or every session
  of `user_id` was retired and their sockets must let go.
  """

  alias Cyfr.Bus.Payload

  @kinds [:created, :revoked]

  @enforce_keys [:kind]
  defstruct [:kind, :user_id]

  @type kind :: :created | :revoked
  @type t :: %__MODULE__{kind: kind(), user_id: String.t() | nil}

  @doc "The closed union of what happened to a session."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "A session announcement. A kind outside `kinds/0` raises."
  @spec new(kind(), String.t() | nil) :: t()
  def new(kind, user_id \\ nil) when is_nil(user_id) or is_binary(user_id),
    do: %__MODULE__{kind: Payload.kind!(__MODULE__, kind, @kinds), user_id: user_id}
end
