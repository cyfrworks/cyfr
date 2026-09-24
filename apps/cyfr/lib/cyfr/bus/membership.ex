# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Membership do
  @moduledoc """
  One person's seat in one athanor changed, on the global
  `Cyfr.Bus.memberships/1` topic keyed by the person: which estates they
  may now reach. `change` is one of a closed set (`changes/0`); anything
  else raises, as a kind outside `kinds/0` does.
  """

  alias Cyfr.Bus.Payload

  @kinds [:changed]
  @changes [:joined, :left, :athanor_changed, :platform_granted]

  @enforce_keys [:kind, :user_id]
  defstruct [:kind, :user_id, :athanor_id, :change]

  @type kind :: :changed

  @type t :: %__MODULE__{
          kind: kind(),
          user_id: String.t(),
          athanor_id: String.t() | nil,
          change: change()
        }

  @type change :: :joined | :left | :athanor_changed | :platform_granted

  @doc "The closed union of what happened to a seat."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The closed set of seat changes."
  @spec changes() :: [change()]
  def changes, do: @changes

  @doc """
  A seat change for `user_id`. A kind outside `kinds/0` or a change
  outside `changes/0` raises.
  """
  @spec new(kind(), String.t(), String.t() | nil, change()) :: t()
  def new(kind, user_id, athanor_id, change) when is_binary(user_id) do
    %__MODULE__{
      kind: Payload.kind!(__MODULE__, kind, @kinds),
      user_id: user_id,
      athanor_id: athanor_id,
      change: change!(change)
    }
  end

  defp change!(change) do
    if change in @changes do
      change
    else
      raise ArgumentError,
            "#{inspect(__MODULE__)} has no change #{inspect(change)}; " <>
              "its changes are #{inspect(@changes)}"
    end
  end
end
