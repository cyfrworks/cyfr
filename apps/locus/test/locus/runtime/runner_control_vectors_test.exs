# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.RunnerControlVectorsTest do
  @moduledoc """
  The service's end of the runner control channel against its shared
  vectors (`tests/fixtures/runner_control.json`, which the runner's crate
  plays as the runner, `apps/locus/runner/tests/vectors.rs`): the
  service's handle (`Locus.Runtime.RunnerProcess`) hears every valid line
  the runner sends, forwards every valid event to the forwarder of its
  runner's events and none to its owner, refuses a line the service sends
  echoed back to it and every invalid line, events among them, with the
  fixture's reason, a protocol failure that retires the runner, and holds a line to
  the fixture's `max_line_bytes`: a partial line of exactly that many
  bytes waits for its newline, one byte more is refused.
  """

  use ExUnit.Case, async: true

  alias Locus.Runtime.RunnerProcess
  alias Locus.Runtime.Test.ScriptedKeeper
  alias Prima.RunnerControl

  # Read as this module compiles, so a checkout without the file fails
  # here, naming it, rather than running without the vectors.
  @vectors Path.expand("../../../../../tests/fixtures/runner_control.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  @max_line_bytes @vectors["max_line_bytes"]

  defp line(%{"line" => line}), do: line

  defp line(%{"repeated_line" => %{"prefix" => p, "repeat" => r, "times" => n, "suffix" => s}}),
    do: p <> String.duplicate(r, n) <> s

  defp valid(sender), do: Enum.filter(@vectors["valid"], &(&1["sender"] == sender))

  defp reason(%{"reason" => reason, "field" => field}),
    do: {String.to_existing_atom(reason), field}

  defp reason(%{"reason" => reason}), do: String.to_existing_atom(reason)

  # A vector's message as the codec reads it: atom keys throughout, the
  # keys' `call` and `seal` as their bytes.
  defp message(%{"type" => type} = fields) do
    fields
    |> atom_keys()
    |> Map.put(:type, String.to_existing_atom(type))
    |> Map.update(:keys, nil, fn keys ->
      keys
      |> Map.update!(:call, &Base.decode16!(&1, case: :lower))
      |> Map.update!(:seal, &Base.decode16!(&1, case: :lower))
    end)
    |> Map.reject(fn {_name, value} -> is_nil(value) end)
  end

  defp atom_keys(%{} = map),
    do: Map.new(map, fn {name, value} -> {String.to_existing_atom(name), atom_keys(value)} end)

  defp atom_keys(value), do: value

  test "the vectors hold lines of both directions and the bound both ends read" do
    assert valid("service") != [] and valid("runner") != []
    assert @vectors["invalid"] != []
    assert @max_line_bytes == RunnerControl.max_line_bytes()
  end

  describe "the service's handle" do
    setup do
      keeper = ScriptedKeeper.start!(__MODULE__.Keeper)

      spec = %{
        runner: "run_vectors",
        argv: ["runner"],
        env: %{"KEEPER" => Atom.to_string(keeper)}
      }

      # The test stands in for the forwarder of the runner's events too, so
      # what the handle forwards and what it tells its owner are told apart.
      handle =
        start_supervised!(
          {RunnerProcess,
           id: "run_vectors", keeper: ScriptedKeeper, spec: spec, owner: self(), events: self()}
        )

      assert_receive {RunnerProcess, ^handle, :ready}, 5_000
      [spawn] = ScriptedKeeper.spawns(keeper)
      {:ok, handle: handle, spawn: spawn}
    end

    test "hears every line the runner sends", %{handle: handle, spawn: spawn} do
      for vector <- valid("runner") do
        :ok = ScriptedKeeper.write(spawn, line(vector) <> "\n")
        message = message(vector["message"])
        assert_receive {RunnerProcess, ^handle, {:message, ^message}}, 5_000
      end
    end

    test "refuses a line the service sends, echoed back to it", %{handle: handle, spawn: spawn} do
      for vector <- valid("service") do
        type = String.to_existing_atom(vector["message"]["type"])
        :ok = ScriptedKeeper.write(spawn, line(vector) <> "\n")

        assert_receive {RunnerProcess, ^handle,
                        {:error, {:protocol, {:not_a_runner_frame, ^type}}}},
                       5_000
      end
    end

    test "refuses every invalid line with its reason", %{handle: handle, spawn: spawn} do
      for vector <- @vectors["invalid"] do
        reason = reason(vector)
        :ok = ScriptedKeeper.write(spawn, line(vector) <> "\n")
        assert_receive {RunnerProcess, ^handle, {:error, {:protocol, ^reason}}}, 5_000
      end
    end

    test "forwards every valid event to the forwarder of its runner's events, and tells its " <>
           "owner none",
         %{handle: handle, spawn: spawn} do
      events = @vectors["events"]["valid"] ++ @vectors["events"]["cut"]
      assert events != []

      for vector <- events do
        :ok = ScriptedKeeper.write(spawn, vector["line"])
        {:ok, event} = RunnerControl.decode(vector["line"])
        assert_receive {:"$gen_cast", {:event, ^event}}, 5_000
      end

      refute_received {RunnerProcess, ^handle, {:message, _event}}
    end

    test "refuses every invalid event line with its reason, a protocol failure as any line " <>
           "that is not a frame, and forwards none of it",
         %{handle: handle, spawn: spawn} do
      for vector <- @vectors["events"]["invalid"] do
        reason = reason(vector["refusal"])
        :ok = ScriptedKeeper.write(spawn, line(vector) <> "\n")
        assert_receive {RunnerProcess, ^handle, {:error, {:protocol, ^reason}}}, 5_000, vector["why"]
      end

      refute_received {:"$gen_cast", {:event, _event}}
    end

    test "holds a partial line to the fixture's bound", %{handle: handle, spawn: spawn} do
      :ok = ScriptedKeeper.write(spawn, :binary.copy("x", @max_line_bytes))
      refute_receive {RunnerProcess, ^handle, {:error, _}}, 100

      :ok = ScriptedKeeper.write(spawn, "x")
      assert_receive {RunnerProcess, ^handle, {:error, {:protocol, :oversize_line}}}, 5_000
    end
  end
end
