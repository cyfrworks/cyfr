# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.CallerInvalidated do
  @moduledoc """
  An established-caller memo is no longer good anywhere in the cell, on
  the global `Cyfr.Bus.caller_invalidated_global/0`. `session_key` is the
  session row's key — the SHA-256 the sessions table is addressed by —
  never the token itself.
  """

  alias Cyfr.Bus.Payload

  @kinds [:invalidated]

  @enforce_keys [:kind, :session_key]
  defstruct [:kind, :session_key]

  @type kind :: :invalidated
  @type t :: %__MODULE__{kind: kind(), session_key: binary()}

  @doc "The closed union: the memo was invalidated."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The invalidation of `session_key`'s memos."
  @spec new(binary()) :: t()
  def new(session_key) when is_binary(session_key),
    do: %__MODULE__{
      kind: Payload.kind!(__MODULE__, :invalidated, @kinds),
      session_key: session_key
    }
end
