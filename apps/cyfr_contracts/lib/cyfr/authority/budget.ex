# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Authority.Budget do
  @moduledoc """
  The root-keyed invoke budget: how many spawns a root's tree may have in
  flight at once.

  An Authority names its budget by *identity* — `%Budget{id, cap}` — and
  the count lives wherever that id is charged. The struct is plain data:
  it crosses the wire, and a copy is the same budget.
  """

  import Bitwise, only: [<<<: 2]

  @type t :: %__MODULE__{id: String.t(), cap: non_neg_integer()}
  @enforce_keys [:id, :cap]
  defstruct [:id, :cap]

  @doc """
  A budget of `cap` slots. A fresh id counts from nothing in flight; a
  given `id` names an existing reservation, so a rebuilt authority
  charges the one its turn was admitted with.
  """
  @spec new(non_neg_integer(), String.t() | nil) :: t()
  def new(cap, id \\ nil) when is_integer(cap) and cap >= 0 do
    %__MODULE__{id: id || unique_id(), cap: cap}
  end

  defp unique_id do
    "bgt_" <>
      Base.url_encode64(
        <<System.unique_integer([:positive, :monotonic])::64, :rand.uniform(1 <<< 32)::32>>,
        padding: false
      )
  end
end
