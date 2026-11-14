# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Session do
  @moduledoc """
  Session lifecycle, on the global `Cyfr.Bus.sessions/0`: a session was
  minted (no token travels; a subscriber adopts its own), or sessions of
  `user_id` were retired, every one or only some, and whatever holds a
  context of theirs revalidates it. A retirement says why (`reasons/0`):
  the person was denied, a device or key of theirs was removed, or a
  sign-in was ended by its holder; and which sessions it retired, by
  their row keys (`session_keys`). A page whose own session is among them
  tells its person why; any other page that finds its session gone says
  only that it ended.
  """

  alias Cyfr.Bus.Payload

  @kinds [:created, :revoked]
  @reasons [:denied, :device_removed, :signed_out]

  @enforce_keys [:kind]
  defstruct [:kind, :user_id, :reason, session_keys: []]

  @type kind :: :created | :revoked
  @type reason :: :denied | :device_removed | :signed_out
  @type t :: %__MODULE__{
          kind: kind(),
          user_id: String.t() | nil,
          reason: reason() | nil,
          session_keys: [binary()]
        }

  @doc "The closed union of what happened to a session."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Why sessions were retired."
  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @doc "A session minted. Any other kind raises."
  @spec new(kind()) :: t()
  def new(kind), do: %__MODULE__{kind: Payload.kind!(__MODULE__, kind, [:created])}

  @doc """
  Sessions of `user_id`, by their row keys, retired for `reason`. A kind
  or reason outside the unions raises.
  """
  @spec new(kind(), String.t(), reason(), [binary()]) :: t()
  def new(kind, user_id, reason, session_keys)
      when is_binary(user_id) and is_list(session_keys),
      do: %__MODULE__{
        kind: Payload.kind!(__MODULE__, kind, [:revoked]),
        user_id: user_id,
        reason: Payload.kind!(__MODULE__, reason, @reasons),
        session_keys: session_keys
      }
end
