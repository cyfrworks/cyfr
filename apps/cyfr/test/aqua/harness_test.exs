# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.HarnessTest do
  @moduledoc """
  The harness boundary (`Aqua.Harness`) holds for a harness that is not a
  program: the loop takes every answer `open/1` may give, at the turn's
  first open and again with its admitted start, and ends or goes on as the
  boundary says for each. A stand-in harness runs a program row's turn in
  the program's place (`Aqua.Harness.of/1`'s test seam), answering each
  open as the test tells it.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Aqua.Loop.State
  alias Aqua.Tape
  alias Arca.TurnStorage

  @title "Aqua"

  # A harness of nothing: each open answers as the test tells it, in the
  # loop's process, and its handle is a process of the test's.
  defmodule Stand do
    @moduledoc false
    @behaviour Aqua.Harness

    @impl true
    def open(%{answer: answer}), do: answer

    def open(work) do
      send(Aqua.HarnessTest, {:open, self(), work})

      receive do
        {:answer, answer} -> answer
      end
    end

    @impl true
    def moved(handle) do
      send(handle, :moved)
      :ok
    end

    @impl true
    def stop(handle) do
      monitor = Process.monitor(handle)
      send(handle, :stop)

      receive do
        {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
      end
    end

    @impl true
    def facts, do: %{supersedes?: true, own_tools?: false}
  end

  describe "the boundary's answers, said straight to it" do
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

  describe "a turn whose harness the engine does not know" do
    setup do
      user = test_user()
      own = Sanctum.Test.People.athanor!(user.user_id)
      {:ok, _} = Sanctum.TestContext.mark_provisioned(own)
      ctx = ready_athanor!(own.id, user.user_id)
      Cyfr.Test.Sandbox.stop_work_on_exit()
      Process.register(self(), __MODULE__)
      Prima.Test.Env.put_app_env(:cyfr, :program_harness, Stand)

      {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
      {:ok, ctx: ctx, thread: thread, row: brain_row!(ctx)}
    end

    test "ends done at its first open: the turn completes with no start",
         %{ctx: ctx, thread: thread, row: row} do
      turn = accept!(ctx, thread, row)
      loop = run(ctx, turn)
      answer!(nil, {:end, :done})

      assert :completed = Task.await(loop, 30_000)
      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, turn.id)
      assert start_step(ctx, turn) == nil
      assert lines(ctx, turn) == []
    end

    test "is refused at its first open: the turn fails in the reason's sentence",
         %{ctx: ctx, thread: thread, row: row} do
      turn = accept!(ctx, thread, row)
      loop = run(ctx, turn)
      answer!(nil, {:end, {:refused, {:harness, @title, :start_failed}}})

      line = "#{@title} could not start."
      assert {:failed, ^line} = Task.await(loop, 30_000)
      assert {:ok, %{status: "failed", error: ^line}} = Tape.turn(ctx, turn.id)
      assert lines(ctx, turn) == [line]
    end

    test "opens at its first open: held where Stop finds it, told once each time the loop " <>
           "is woken, and its end done completes the turn and stops it",
         %{ctx: ctx, thread: thread, row: row} do
      turn = accept!(ctx, thread, row)
      loop = run(ctx, turn)
      handle = handle!()
      answer!(nil, {:ok, handle, Stand.facts()})

      assert_receive {:handle, :moved}, 10_000
      assert [{_loop, {Stand, ^handle}}] = Registry.lookup(Aqua.RunnerRegistry, {:turn, turn.id})
      send(loop.pid, {:moved, turn.id})
      assert_receive {:handle, :moved}, 10_000
      refute_receive {:handle, :moved}, 500

      send(loop.pid, {Aqua.Harness, turn.id, {:end, :done}})
      assert :completed = Task.await(loop, 30_000)
      assert_received {:handle, :stop}
      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, turn.id)
    end

    test "opens with its admitted start once the engine decided it, which closes as started " <>
           "when it takes the work",
         %{ctx: ctx, thread: thread, row: row} do
      turn = accept!(ctx, thread, row)
      loop = run(ctx, turn)
      start = admitted!()
      handle = handle!()
      answer!(start, {:ok, handle, Stand.facts()})

      assert_receive {:handle, :moved}, 10_000
      send(loop.pid, {Aqua.Harness, turn.id, {:took, [{start.id, :started}]}})
      send(loop.pid, {Aqua.Harness, turn.id, {:end, :done}})

      assert :completed = Task.await(loop, 30_000)
      assert %{dispatch_state: "closed", outcome: "ok"} = start_step(ctx, turn)
      assert start_said(ctx, turn) == "#{@title} started"
    end

    test "ends done with its admitted start: the start closes as started and the turn completes",
         %{ctx: ctx, thread: thread, row: row} do
      turn = accept!(ctx, thread, row)
      loop = run(ctx, turn)
      start = admitted!()
      answer!(start, {:end, :done})

      assert :completed = Task.await(loop, 30_000)
      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, turn.id)
      assert %{dispatch_state: "closed", outcome: "ok"} = start_step(ctx, turn)
      assert start_said(ctx, turn) == "#{@title} started"
    end

    test "is refused with its admitted start: the start closes in the reason's sentence and " <>
           "the turn fails in it",
         %{ctx: ctx, thread: thread, row: row} do
      turn = accept!(ctx, thread, row)
      loop = run(ctx, turn)
      start = admitted!()
      answer!(start, {:end, {:refused, {:harness, @title, :start_failed}}})

      line = "#{@title} could not start."
      assert {:failed, ^line} = Task.await(loop, 30_000)
      assert {:ok, %{status: "failed", error: ^line}} = Tape.turn(ctx, turn.id)
      assert %{dispatch_state: "closed", error: ^line} = start_step(ctx, turn)
      assert lines(ctx, turn) == [line]
    end

    test "asks its admission again with the start it was given: the start was never taken, " <>
           "and the turn fails saying it did not start",
         %{ctx: ctx, thread: thread, row: row} do
      turn = accept!(ctx, thread, row)
      loop = run(ctx, turn)
      %{work: work} = start = admitted!()
      answer!(start, {:admit, start_proposal(%{work | admitted: nil})})

      line = Prima.Refusal.message({:harness, @title, {:start_failed, :unstarted}})
      assert {:failed, ^line} = Task.await(loop, 30_000)
      assert {:ok, %{status: "failed", error: ^line}} = Tape.turn(ctx, turn.id)
      refute_received {:open, _loop, _work}
    end
  end

  # The loop's open of the turn's harness, answered with `answer`: the first
  # open's (`start` nil) or the one with its admitted start.
  defp answer!(start, answer) do
    assert_receive {:open, loop, %{admitted: admitted}}, 10_000
    assert admitted == start_of(start)
    send(loop, {:answer, answer})
  end

  defp start_of(nil), do: nil
  defp start_of(%{step: step}), do: step

  # The first open asks the engine to admit the harness's start, which the
  # engine decides through the gate and opens again with, dispatched.
  defp admitted! do
    assert_receive {:open, loop, %{admitted: nil} = work}, 10_000
    send(loop, {:answer, {:admit, start_proposal(work)}})

    assert_receive {:open, ^loop, %{admitted: %{dispatch_state: "dispatched"} = step} = again},
                   10_000

    send(self(), {:open, loop, again})
    %{id: step.id, step: step, work: again}
  end

  # A handle that tells the test what the loop says to it, and ends on its
  # stop.
  defp handle! do
    test = self()

    spawn(fn ->
      Stream.repeatedly(fn ->
        receive do
          :stop ->
            send(test, {:handle, :stop})
            :stop

          said ->
            send(test, {:handle, said})
        end
      end)
      |> Enum.find(&(&1 == :stop))
    end)
  end

  # The host's start of the turn's program row, as the program's harness
  # proposes it (`Aqua.Harness.Program`).
  defp start_proposal(%{program: %{row: row, epoch: epoch}, turn: turn}) do
    args = %{"action" => "start", "program" => row, "epoch" => epoch}
    call = Aqua.Loop.Binding.resolve("program", args, tool_call_id: "start")
    recorded = Aqua.Loop.recorded("program", call)

    %{
      kind: recorded.step_kind,
      purpose: "brain",
      tool: "program",
      action: "start",
      recovery: "replay_safe",
      idempotency_key: Tape.admission_key(turn.id),
      call: %{
        kind: "tool_call",
        content: "program",
        payload: %{
          "tool_call_id" => "start",
          "name" => "program",
          "tool" => "program",
          "action" => "start",
          "arguments" => args,
          "kind" => recorded.kind
        }
      }
    }
  end

  defp run(ctx, turn), do: Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)

  defp accept!(ctx, thread, row) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "work on it"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    {:ok, turn} =
      TurnStorage.pin_program(Sanctum.Context.actor(ctx), turn.id, row.id, %{fence: turn.fence})

    turn
  end

  defp brain_row!(ctx) do
    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: "claude-code",
        transport: "program",
        mark: "driven",
        url: nil,
        home: "kept",
        memory_bytes: 1_073_741_824,
        config_json:
          Jason.encode!(%{
            "command" => "cyfr-claude-code npx -y @anthropic-ai/claude-code@2.1.323",
            "env" => %{}
          })
      })

    row
  end

  defp start_step(ctx, turn) do
    {:ok, steps} = Tape.steps(ctx, turn)
    Enum.find(steps, &(&1.idempotency_key == TurnStorage.admission_key(turn.id)))
  end

  # What the start's step says, its result row's words.
  defp start_said(ctx, turn) do
    %{result_message_id: id} = start_step(ctx, turn)
    {:ok, %{content: content}} = Tape.message(ctx, id)
    content
  end

  # The turn's own lines in its thread, the server's words.
  defp lines(ctx, turn) do
    from(m in Arca.Schemas.Message,
      where: m.athanor_id == ^ctx.athanor_id and m.turn_id == ^turn.id and m.kind == "system",
      order_by: [asc: m.seq],
      select: m.content
    )
    |> Arca.Repo.all()
  end
end
