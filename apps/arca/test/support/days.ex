# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.Days do
  @moduledoc """
  Daily threads for fixtures. A daily thread is one per date of an
  athanor (`Arca.ThreadStorage.daily/2`), so a fixture that needs a thread
  of its own names a date no other call in this run has named.
  """

  @doc "A date no other call of this function in this run has answered."
  @spec next() :: Date.t()
  def next, do: Date.add(~D[2000-01-01], System.unique_integer([:positive, :monotonic]))

  @doc "A daily thread of a date of its own in the actor's athanor."
  @spec thread(Prima.Actor.t()) :: {:ok, map()} | {:error, term()}
  def thread(%Prima.Actor{} = actor), do: Arca.ThreadStorage.daily(actor, next())
end
