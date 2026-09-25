# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.RunnerControlVectorsTest do
  @moduledoc """
  Both ends of the runner control channel against its shared vectors
  (`tests/fixtures/runner_control.json`): the runner (`Opus.Runner`) acts
  on every valid line the service sends and the service's handle
  (`Opus.RunnerProcess`) hears every valid line the runner sends; each
  refuses a line of the other direction echoed back to it and every
  invalid line with the fixture's reason; and each holds a line to the
  fixture's `max_line_bytes`: a partial line of exactly that many bytes
  waits for its newline, one byte more is refused.
  """

  # The runner's refusals are log lines, captured from its process.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Opus.RunnerProcess
  alias Opus.Test.ScriptedKeeper
  alias Prima.RunnerControl

  # Read as this module compiles, so a checkout without the file fails
  # here, naming it, rather than running without the vectors.
  @vectors Path.expand("../../../../tests/fixtures/runner_control.json", __DIR__)
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

  describe "the runner" do
    setup do
      test = self()
      port = make_ref()
      name = :"runner_vectors_#{System.unique_integer([:positive])}"

      runner =
        start_supervised!(
          {Opus.Runner,
           settings: %{
             runner_id: "run_vectors",
             service_id: "wrk_not_the_assignments",
             boot: "boot_not_the_assignments",
             host_url: "http://127.0.0.1:9",
             control_fd: nil,
             watchdog_grace_ms: 500
           },
           port: port,
           supervisor: :"#{name}_attempts",
           name: name,
           halt: fn reason -> send(test, {:halted, reason}) end,
           stop: fn status -> send(test, {:stopped, status}) end}
        )

      {:ok, runner: runner, port: port}
    end

    # Hands the runner `data` as its control port would, and waits until
    # it has read it.
    defp feed(%{runner: runner, port: port}, data) do
      send(runner, {port, {:data, data}})
      :sys.get_state(runner)
    end

    test "acts on every line the service sends", ctx do
      for vector <- valid("service") do
        log = capture_log(fn -> feed(ctx, line(vector) <> "\n") end)
        refute log =~ "not a frame", vector["why"]
        refute log =~ "the service sent a", vector["why"]

        # An assign reaches the assignment's reading, which refuses one
        # issued to another service; a cancel for no child is ignored.
        case vector["message"]["type"] do
          "assign" -> assert_received {:halted, :malformed_assign}
          "cancel_child" -> refute_received {:halted, _}
        end
      end
    end

    test "refuses a line the runner sends, echoed back to it", ctx do
      for vector <- valid("runner") do
        type = vector["message"]["type"]
        log = capture_log(fn -> feed(ctx, line(vector) <> "\n") end)
        assert log =~ "the service sent a #{type} frame; ignored", vector["why"]
      end

      refute_received {:halted, _}
    end

    test "refuses every invalid line with its reason", ctx do
      for vector <- @vectors["invalid"] do
        log = capture_log(fn -> feed(ctx, line(vector) <> "\n") end)
        assert log =~ "not a frame: #{inspect(reason(vector))}", vector["why"]
      end

      refute_received {:halted, _}
    end

    test "holds a partial line to the fixture's bound", ctx do
      feed(ctx, :binary.copy("x", @max_line_bytes))
      refute_received {:halted, _}

      capture_log(fn -> feed(ctx, "x") end)
      assert_received {:halted, :oversize_line}
    end
  end

  describe "the service's handle" do
    setup do
      keeper = ScriptedKeeper.start!()

      spec = %{
        runner: "run_vectors",
        argv: ["runner"],
        env: %{"KEEPER" => Atom.to_string(keeper)}
      }

      handle =
        start_supervised!(
          {RunnerProcess, id: "run_vectors", keeper: ScriptedKeeper, spec: spec, owner: self()}
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

    test "holds a partial line to the fixture's bound", %{handle: handle, spawn: spawn} do
      :ok = ScriptedKeeper.write(spawn, :binary.copy("x", @max_line_bytes))
      refute_receive {RunnerProcess, ^handle, {:error, _}}, 100

      :ok = ScriptedKeeper.write(spawn, "x")
      assert_receive {RunnerProcess, ^handle, {:error, {:protocol, :oversize_line}}}, 5_000
    end
  end
end
