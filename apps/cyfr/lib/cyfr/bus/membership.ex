# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Membership do
  @moduledoc """
  One person's seat in one athanor changed, on the global
  `Cyfr.Bus.memberships/1` topic keyed by the person: which estates they
  may now reach. `change` is bounded (`Cyfr.Bus.bounded_reason/1`).
  """

  alias Cyfr.Bus.Payload

  @kinds [:changed]

  @enforce_keys [:kind, :user_id]
  defstruct [:kind, :user_id, :athanor_id, :change]

  @type kind :: :changed

  @type t :: %__MODULE__{
          kind: kind(),
          user_id: String.t(),
          athanor_id: String.t() | nil,
          change: atom() | String.t() | nil
        }

  @doc "The closed union of what happened to a seat."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "A seat change for `user_id`. A kind outside `kinds/0` raises."
  @spec new(kind(), String.t(), String.t() | nil, term()) :: t()
  def new(kind, user_id, athanor_id, change) when is_binary(user_id) do
    %__MODULE__{
      kind: Payload.kind!(__MODULE__, kind, @kinds),
      user_id: user_id,
      athanor_id: athanor_id,
      change: Cyfr.Bus.bounded_reason(change)
    }
  end
end
