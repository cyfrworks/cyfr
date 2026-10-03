# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Runner.RecoveryPolicy do
  @moduledoc """
  How many automatic recoveries a turn gets before it ends `uncertain`.

  The policy is the assistant's; the turn row enforces it. A turn stores
  the limit chosen here when it starts (`Aqua.Tape.start_turn/3`), or when
  an accepted turn is first claimed by a recovery (`Aqua.Tape.recover/2`),
  and every later recovery is counted against that stored limit in the
  transaction that spends it (`Arca.TurnStorage`), so a caller's update
  never widens it and a change here reaches new turns only.
  """

  @max_attempts 3

  @doc "The recoveries a new turn is allowed."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts
end
