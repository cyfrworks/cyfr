# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.HarnessTest do
  @moduledoc """
  The harness boundary (`Aqua.Harness`) holds for a harness that is not a
  program: the loop takes every answer `open/1` may give.
  """

  use ExUnit.Case, async: true

  alias Aqua.Loop.State

  # A harness of nothing: it answers as it is told and holds no session.
  defmodule Stand do
    @moduledoc false
    @behaviour Aqua.Harness

    @impl true
    def open(%{answer: answer}), do: answer
    @impl true
    def input(_handle, _posts), do: :ok
    @impl true
    def answer(_handle, _results), do: :ok
    @impl true
    def stop(_handle), do: :ok
    @impl true
    def facts, do: %{child_of_root?: false, supersedes?: true}
  end

  setup do
    turn_id = "trn_stand_#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.register(Aqua.RunnerRegistry, {:turn, turn_id}, nil)
    %{state: %State{turn: %{id: turn_id}}, turn_id: turn_id}
  end

  test "a harness that opens at once is held where Stop finds it, with the facts it gives",
       %{state: state, turn_id: turn_id} do
    handle = spawn(fn -> receive(do: (:stop -> :ok)) end)
    facts = Stand.facts()

    assert {:ok, %State{harness: {Stand, ^handle}, facts: ^facts}} =
             Aqua.Loop.take_open(state, Stand, Stand.open(%{answer: {:ok, handle, facts}}))

    assert [{_loop, {Stand, ^handle}}] = Registry.lookup(Aqua.RunnerRegistry, {:turn, turn_id})
    send(handle, :stop)
  end

  test "a harness that ends before it starts ends the turn with its reason", %{state: state} do
    finish = {:refused, {:harness, "Stand", :start_failed}}

    assert {:end, ^state, ^finish} =
             Aqua.Loop.take_open(state, Stand, Stand.open(%{answer: {:end, finish}}))
  end
end
