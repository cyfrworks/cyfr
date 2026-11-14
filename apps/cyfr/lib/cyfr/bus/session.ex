# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Session do
  @moduledoc """
  Session lifecycle, on the global `Cyfr.Bus.sessions/0`: a session was
  minted (no token travels; a subscriber adopts its own), or sessions of
  `user_id` were retired, every one or only some, and whatever holds a
  context of theirs revalidates it. A retirement says why (`reasons/0`):
  the person was denied, a device or key of theirs was removed, or a
  sign-in was ended by its holder; a page whose own session went tells
  its person that.
  """

  alias Cyfr.Bus.Payload

  @kinds [:created, :revoked]
  @reasons [:denied, :device_removed, :signed_out]

  @enforce_keys [:kind]
  defstruct [:kind, :user_id, :reason]

  @type kind :: :created | :revoked
  @type reason :: :denied | :device_removed | :signed_out
  @type t :: %__MODULE__{kind: kind(), user_id: String.t() | nil, reason: reason() | nil}

  @doc "The closed union of what happened to a session."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Why sessions were retired."
  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @doc "A session minted. Any other kind raises."
  @spec new(kind()) :: t()
  def new(kind), do: %__MODULE__{kind: Payload.kind!(__MODULE__, kind, [:created])}

  @doc "Sessions of `user_id` retired, for `reason`. A kind or reason outside the unions raises."
  @spec new(kind(), String.t(), reason()) :: t()
  def new(kind, user_id, reason) when is_binary(user_id),
    do: %__MODULE__{
      kind: Payload.kind!(__MODULE__, kind, [:revoked]),
      user_id: user_id,
      reason: Payload.kind!(__MODULE__, reason, @reasons)
    }
end
