# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.InputSupplier do
  @moduledoc """
  A supplier of an invocation's further inputs (`Opus.Inputs`) of the
  test's own, holding the supplier's contract:

    * `next` answers the first input not yet marked, the same one again
      until it is marked, and records that it was offered to the asking
      attempt;
    * `sent` marks, once, only an input offered to that same attempt, and
      only while `Opus.Inputs.held!/1` holds inside the transaction that
      records the mark: a report from an attempt that no longer holds is
      refused, and nothing is marked;
    * every ask is recorded with the invocation it named, for a test to
      read (`asks/1`).

  `:mode` makes it misbehave instead: `:silent` never answers, and
  `{:answer, fun}` answers every `next` with `fun.(invocation)`, which runs
  in the supplier's own process.
  """

  use GenServer

  @doc "Start a supplier of `inputs` (wire maps, in order), linked to the caller."
  @spec start!([map()], keyword()) :: pid()
  def start!(inputs, opts \\ []) do
    {:ok, pid} = GenServer.start_link(__MODULE__, {inputs, Keyword.get(opts, :mode)})
    pid
  end

  @doc "Every ask the supplier was sent, in order: `{:next, invocation}` or `{:sent, invocation, id}`."
  @spec asks(pid()) :: [tuple()]
  def asks(pid), do: GenServer.call(pid, :asks)

  @doc "The ids marked, in the order they were marked."
  @spec marked(pid()) :: [String.t()]
  def marked(pid), do: GenServer.call(pid, :marked)

  @impl true
  def init({inputs, mode}),
    do: {:ok, %{inputs: inputs, mode: mode, offered: %{}, marked: [], asks: []}}

  @impl true
  def handle_call(:asks, _from, state), do: {:reply, Enum.reverse(state.asks), state}
  def handle_call(:marked, _from, state), do: {:reply, Enum.reverse(state.marked), state}

  @impl true
  def handle_info({Opus.Inputs, :next, invocation, reply_to}, state) do
    state = %{state | asks: [{:next, invocation} | state.asks]}

    case state.mode do
      :silent ->
        {:noreply, state}

      {:answer, fun} ->
        Opus.Inputs.reply(reply_to, fun.(invocation))
        {:noreply, state}

      nil ->
        case Enum.find(state.inputs, &(&1["id"] not in state.marked)) do
          nil ->
            Opus.Inputs.reply(reply_to, :none)
            {:noreply, state}

          input ->
            Opus.Inputs.reply(reply_to, {:ok, input})

            offered =
              Map.update(state.offered, invocation.attempt, [input["id"]], &[input["id"] | &1])

            {:noreply, %{state | offered: offered}}
        end
    end
  end

  def handle_info({Opus.Inputs, :sent, invocation, id, reply_to}, state) do
    state = %{state | asks: [{:sent, invocation, id} | state.asks]}

    cond do
      state.mode == :silent ->
        {:noreply, state}

      id not in Map.get(state.offered, invocation.attempt, []) ->
        Opus.Inputs.reply(reply_to, {:error, :not_offered})
        {:noreply, state}

      id in state.marked ->
        Opus.Inputs.reply(reply_to, :ok)
        {:noreply, state}

      true ->
        mark(state, invocation, id, reply_to)
    end
  end

  # The mark commits only while the invocation still holds its attempt,
  # checked in the transaction that would record it.
  defp mark(state, invocation, id, reply_to) do
    held =
      Arca.Repo.locking_transaction(fn ->
        if Opus.Inputs.held!(invocation), do: :held, else: Arca.Repo.rollback(:not_held)
      end)

    case held do
      {:ok, :held} ->
        Opus.Inputs.reply(reply_to, :ok)
        {:noreply, %{state | marked: [id | state.marked]}}

      {:error, reason} ->
        Opus.Inputs.reply(reply_to, {:error, reason})
        {:noreply, state}
    end
  end
end
