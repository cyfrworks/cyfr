# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.Days do
  @moduledoc """
  Daily threads for fixtures. A daily thread is one per date of an
  athanor (`Arca.ThreadStorage.daily/2`), so a fixture that needs a thread
  of its own names a date no other call in this run has named.
  """

  @doc """
  A date no other call of this function in this run has answered, counted
  from 1900 by this function alone, so a run would need some 46,000 of
  them to reach a date a test reads as today.
  """
  @spec next() :: Date.t()
  def next, do: Date.add(~D[1900-01-01], :atomics.add_get(counter(), 1, 1))

  defp counter do
    case :persistent_term.get({__MODULE__, :counter}, nil) do
      nil -> :global.trans({__MODULE__, self()}, &first_counter/0)
      counter -> counter
    end
  end

  defp first_counter do
    case :persistent_term.get({__MODULE__, :counter}, nil) do
      nil ->
        counter = :atomics.new(1, [])
        :persistent_term.put({__MODULE__, :counter}, counter)
        counter

      counter ->
        counter
    end
  end

  @doc "A daily thread of a date of its own in the actor's athanor."
  @spec thread(Prima.Actor.t()) :: {:ok, map()} | {:error, term()}
  def thread(%Prima.Actor{} = actor), do: Arca.ThreadStorage.daily(actor, next())
end
