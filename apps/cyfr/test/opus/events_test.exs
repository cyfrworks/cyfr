# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.EventsTest do
  use ExUnit.Case, async: false

  alias Opus.Events
  alias Opus.Events.Sequence
  alias Cyfr.Test.{AttemptFixtures, ScriptedWorker}

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    :ok
  end

  # An execution row, so durable events have a counter to take numbers from.
  defp execution!(athanor_id) do
    {:ok, %{execution: execution}} =
      Arca.Execution.admit(
        %{
          id: Prima.UUID7.execution_id(),
          reference: "reagent:local.evt:0.1.0",
          user_id: "usr_evt",
          athanor_id: athanor_id,
          component_type: "reagent",
          origin: :programmatic
        },
        Cyfr.Test.AttemptFixtures.standing(athanor_id)
      )

    execution
  end

  defp durable!(record, type, data) do
    {:ok, row} =
      Arca.ExecutionEvents.append(Prima.Actor.in_athanor(record.athanor_id), record.id, type,
        data: data
      )

    :ok = Events.publish(record.id, record, type, row.seq, data)
    row.seq
  end

  # Producers must route events under the execution's own athanor — consumers
  # (AQUA LiveView, SSE replay) subscribe and replay with the record's
  # athanor, so a misrouted event is invisible to them.

  test "the record's athanor routes the broadcast and the replay", %{} do
    record = execution!("ath_evt_x")
    Events.subscribe(record.id, record)

    seq = durable!(record, "execution.completed", %{"status" => "completed"})

    id = record.id
    assert_receive %Cyfr.Bus.ExecutionEvent{type: "execution.completed", execution_id: ^id}

    # Replay under the record's athanor sees the events; another athanor's
    # key does not.
    assert [%{type: "execution.started"}, %{type: "execution.completed", durable: ^seq}] =
             Events.since(record.id, {0, 0}, "ath_evt_x")

    assert [] = Events.since(record.id, {0, 0}, "ath_other")
  end

  test "a Sanctum.Context routes identically to record coordinates" do
    record = execution!("ath_evt_x")
    ctx = %Sanctum.Context{athanor_id: "ath_evt_x"}
    Events.subscribe(record.id, ctx)

    assert {:ok, "1.1"} =
             Events.push(record.id, %{"kind" => "text_delta"}, record, origin: "host")

    id = record.id
    assert_receive %Cyfr.Bus.ExecutionEvent{type: "emit", execution_id: ^id, sequence: "1.1"}
  end

  test "an athanor-less producer is dropped, never routed into a default tenant" do
    record = execution!("ath_evt_x")
    Events.subscribe(record.id, record)

    assert {:error, :missing_athanor} =
             Events.push(record.id, %{"kind" => "text_delta"}, nil, origin: "host")

    assert {:error, :missing_athanor} =
             Events.publish(record.id, nil, "execution.failed", 9, %{})

    id = record.id
    refute_receive %Cyfr.Bus.ExecutionEvent{execution_id: ^id}, 100
  end

  test "replay and subscription refuse a missing athanor" do
    exec_id = "exec_evt_nil_#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, fn -> Events.since(exec_id, {0, 0}, nil) end
    # A context whose athanor is unresolved: the platform's own.
    assert_raise ArgumentError, fn -> Events.subscribe(exec_id, Sanctum.Context.internal()) end
  end

  describe "numbering — durable rows and the deltas under them" do
    test "deltas ride the last durable event and restart at .1 after each new one" do
      record = execution!("ath_evt_x")

      assert {:ok, "1.1"} = Events.push(record.id, %{"i" => 1}, record, origin: "host")
      assert {:ok, "1.2"} = Events.push(record.id, %{"i" => 2}, record, origin: "host")

      two = durable!(record, "step.closed", %{"step" => "s1"})
      assert two == 2
      assert {:ok, "2.1"} = Events.push(record.id, %{"i" => 3}, record, origin: "host")

      # A publication for an older prefix, arriving late, does not touch the
      # counter of the prefix already emitted under.
      :ok = Events.publish(record.id, record, "step.closed", 1, %{"late" => true})
      assert {:ok, "2.2"} = Events.push(record.id, %{"i" => 4}, record, origin: "host")

      # Replay from a cursor: the rows after it in order, each with the
      # deltas under it; from the tip, only the deltas not yet seen.
      ids = fn cursor ->
        record.id
        |> Events.since(cursor, "ath_evt_x")
        |> Enum.map(& &1.sequence)
      end

      assert ids.({0, 0}) == ["1", "1.1", "1.2", "2", "2.1", "2.2"]
      assert ids.({1, 1}) == ["1.2", "2", "2.1", "2.2"]
      assert ids.({1, 2}) == ["2", "2.1", "2.2"]
      assert ids.({2, 1}) == ["2.2"]
      assert ids.({2, 2}) == []
    end

    test "every emitter under one root shares the numbering, and streams are independent" do
      a = execution!("ath_evt_x")
      b = execution!("ath_evt_x")

      outer = for _ <- 1..3, do: Sequence.next(a.id, 1)
      inner = for _ <- 1..3, do: Sequence.next(a.id, 1)
      assert outer == [1, 2, 3]
      assert inner == [4, 5, 6]

      assert Sequence.next(b.id, 1) == 1
      assert Sequence.next(a.id, 2) == 1
    end

    test "a terminal publication retires every prefix of the stream" do
      record = execution!("ath_evt_x")
      assert Sequence.next(record.id, 1) == 1
      assert Sequence.next(record.id, 1) == 2

      seq = durable!(record, "execution.completed", %{"status" => "completed"})
      assert seq == 2
      assert Sequence.next(record.id, 1) == 1
    end

    test "a floor raises a counter that is below it and never lowers one" do
      exec_id = "exec_evt_floor_#{System.unique_integer([:positive])}"
      assert Sequence.next(exec_id, 1) == 1

      assert :ok = Sequence.reseed(exec_id, 1, 5)
      assert Sequence.next(exec_id, 1) == 6

      assert :ok = Sequence.reseed(exec_id, 1, 3)
      assert Sequence.next(exec_id, 1) == 7

      assert :ok = Sequence.reseed(exec_id, 2, 4)
      assert Sequence.next(exec_id, 2) == 5
      Sequence.forget(exec_id)
    end
  end

  describe "the counter table" do
    # The table belongs to an always-started child of `Opus.Tree`; with it
    # absent a delta has no number, and numbering raises rather than
    # answering one from outside the stream's counter. Retiring a finished
    # stream's counters runs after its row committed, on the way to what
    # its end cleans up, and an absent table holds none to retire.
    @tag :capture_log
    test "numbering raises while the table is absent, and retiring answers :ok" do
      without_sequence(fn ->
        exec_id = "exec_evt_seq_#{System.unique_integer([:positive])}"
        assert_raise ArgumentError, fn -> Sequence.next(exec_id, 1) end
        assert_raise ArgumentError, fn -> Sequence.reseed(exec_id, 1, 3) end
        assert :ok = Sequence.forget(exec_id)
      end)

      assert Sequence.next("exec_evt_seq_back", 1) == 1
    end

    # Readers retire in a loop until the table is gone, while its owner is
    # stopped, so in some round one has found the table and deletes from
    # it as it goes.
    @tag :capture_log
    test "retiring answers :ok while the table's owner exits under it" do
      on_exit(&restart_sequence/0)
      test = self()

      for _round <- 1..5 do
        :ok = restart_sequence()

        readers =
          for _reader <- 1..max(System.schedulers_online(), 4),
              do: spawn_monitor(fn -> retire_until_gone(test) end)

        for {reader, _ref} <- readers, do: assert_receive({:retiring, ^reader}, 5_000)
        :ok = Supervisor.terminate_child(Opus.Tree, Sequence)

        for {reader, ref} <- readers do
          assert_receive {:DOWN, ^ref, :process, ^reader, reason}, 5_000
          assert reason == :normal
        end
      end

      restart_sequence()
    end

    # The parent's runner attached and was handed the run, so its stop is
    # the kill its worker service is sent.
    @tag :capture_log
    test "a cancel while the table is absent still fails the run's children and kills its runner" do
      start_supervised!({ScriptedWorker, ref: "reagent:local.unscripted", script: []})
      ctx = Sanctum.TestContext.local(:api)

      parent =
        AttemptFixtures.attached!(
          ctx: ctx,
          component_type: :formula,
          worker: ScriptedWorker.endpoint()
        )

      :ok = Opus.Attempt.hand_over(parent.pid)
      child = child!(parent)

      without_sequence(fn ->
        assert {:ok, %{cancelled: true}} = Opus.cancel(ctx, parent.execution_id)
      end)

      message = "Parent execution (#{parent.execution_id}) terminated"
      assert %{status: "cancelled"} = Arca.Repo.get!(Arca.Schemas.Execution, parent.execution_id)

      assert %{status: "failed", error_message: ^message} =
               Arca.Repo.get!(Arca.Schemas.Execution, child.id)

      assert parent.execution_id in ScriptedWorker.kills()
    end
  end

  # A running child of `parent`'s run, admitted under the parent's stamp.
  defp child!(parent) do
    {:ok, %{execution: child}} =
      Arca.Execution.admit(
        %{
          id: Prima.UUID7.execution_id(),
          reference: "reagent:local.evt-child:0.1.0",
          user_id: parent.ctx.user_id,
          athanor_id: parent.athanor_id,
          component_type: "reagent",
          parent_execution_id: parent.execution_id,
          root_execution_id: parent.execution_id
        },
        grant: parent.grant,
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    child
  end

  defp retire_until_gone(test) do
    :ok = Sequence.forget("exec_evt_retiring")
    send(test, {:retiring, self()})
    retiring()
  end

  defp retiring do
    :ok = Sequence.forget("exec_evt_retiring")
    if :ets.whereis(Sequence) != :undefined, do: retiring(), else: :ok
  end

  # Run `fun` with the counter table's owner stopped, and start it again.
  defp without_sequence(fun) do
    on_exit(&restart_sequence/0)
    :ok = Supervisor.terminate_child(Opus.Tree, Sequence)

    try do
      fun.()
    after
      restart_sequence()
    end
  end

  defp restart_sequence do
    case Supervisor.restart_child(Opus.Tree, Sequence) do
      {:ok, _pid} -> :ok
      {:error, :running} -> :ok
    end
  end

  # An idle buffer restart must restore cached events for Last-Event-ID
  # replay, and keep numbering where it was.
  test "a buffer that restarts resumes the history and the numbering" do
    record = execution!("ath_evt_x")

    assert {:ok, "1.1"} = Events.push(record.id, %{"n" => 1}, record, origin: "host")
    assert {:ok, "1.2"} = Events.push(record.id, %{"n" => 2}, record, origin: "host")

    idle_stop_buffer(record.id)

    # Simulate the counter table having restarted mid-run.
    Sequence.forget(record.id)

    # The next emit restarts the buffer, which floors the counter from
    # what the cache saw, and the stream continues.
    assert {:ok, "1.3"} = Events.push(record.id, %{"n" => 3}, record, origin: "host")

    assert ["1.1", "1.2", "1.3"] =
             record.id
             |> Events.since({1, 0}, "ath_evt_x")
             |> Enum.map(& &1.sequence)
  end

  # The counter outlives the buffer: the restarted buffer's floor is the
  # number the counter already holds.
  test "a buffer that stops on its idle timeout resumes the numbering its counter kept" do
    record = execution!("ath_evt_x")

    assert {:ok, "1.1"} = Events.push(record.id, %{"n" => 1}, record, origin: "host")
    assert {:ok, "1.2"} = Events.push(record.id, %{"n" => 2}, record, origin: "host")

    idle_stop_buffer(record.id)

    assert {:ok, "1.3"} = Events.push(record.id, %{"n" => 3}, record, origin: "host")

    assert ["1.1", "1.2", "1.3"] =
             record.id
             |> Events.since({1, 0}, "ath_evt_x")
             |> Enum.map(& &1.sequence)
  end

  describe "the replay window" do
    test "a delta whose buffer stopped after writing it, before answering, is replayed once" do
      record = execution!("ath_evt_x")
      assert {:ok, "1.1"} = Events.push(record.id, %{"n" => 1}, record, origin: "host")
      [{buffer, _}] = Registry.lookup(Opus.Events.Registry, record.id)
      key = Arca.Cache.Keys.exec_events(Prima.Actor.in_athanor("ath_evt_x"), record.id)

      # The buffer writes the next delta into its window, as its own write
      # does, and stops before it answers: the push asks again, of a fresh
      # buffer that restores that window.
      :ok =
        :sys.install(
          buffer,
          {fn
             _armed, {:in, {:"$gen_call", _from, {:buffer, event}}}, _name ->
               {:ok, window} = Arca.Cache.get(key)
               :ok = Arca.Cache.put(key, window ++ [event], :timer.minutes(10))
               Process.exit(self(), :shutdown)
               Process.sleep(:infinity)

             armed, _event, _name ->
               armed
           end, :armed}
        )

      ref = Process.monitor(buffer)
      assert {:ok, "1.2"} = Events.push(record.id, %{"n" => 2}, record, origin: "host")
      assert_receive {:DOWN, ^ref, :process, ^buffer, :shutdown}, 5_000

      assert ["1.1", "1.2"] =
               record.id
               |> Events.since({1, 0}, "ath_evt_x")
               |> Enum.map(& &1.sequence)
    end

    @tag :capture_log
    test "a delta whose window cannot be written is refused and never broadcast; a durable event is still broadcast" do
      record = execution!("ath_evt_x")
      id = record.id
      Events.subscribe(record.id, record)
      assert {:ok, "1.1"} = Events.push(record.id, %{"n" => 1}, record, origin: "host")
      assert_receive %Cyfr.Bus.ExecutionEvent{type: "emit", execution_id: ^id, sequence: "1.1"}

      without_cache(fn ->
        assert {:error, :unavailable} =
                 Events.push(record.id, %{"n" => 2}, record, origin: "host")

        refute_receive %Cyfr.Bus.ExecutionEvent{type: "emit", execution_id: ^id}, 100

        # Its row is its replay, and the deltas after it are numbered
        # under it.
        assert durable!(record, "step.closed", %{"step" => "s1"}) == 2
        assert_receive %Cyfr.Bus.ExecutionEvent{type: "step.closed", execution_id: ^id}
      end)

      # The buffer writes its window again once the cache is back, and the
      # refused delta is not in it.
      assert {:ok, "2.1"} = Events.push(record.id, %{"n" => 3}, record, origin: "host")

      assert ["1.1", "2", "2.1"] =
               record.id
               |> Events.since({1, 0}, "ath_evt_x")
               |> Enum.map(& &1.sequence)
    end
  end

  # Run `fun` with the cache's table gone: the table goes with its one
  # owner, `Arca.Cache.Sweeper`, and with the owner stopped no write brings
  # it back.
  defp without_cache(fun) do
    on_exit(&restart_cache/0)
    :ok = Supervisor.terminate_child(Arca.Supervisor, Arca.Cache.Sweeper)

    try do
      fun.()
    after
      restart_cache()
    end
  end

  defp restart_cache do
    case Supervisor.restart_child(Arca.Supervisor, Arca.Cache.Sweeper) do
      {:ok, _pid} -> :ok
      {:error, :running} -> :ok
    end
  end

  # Stop a live buffer the way the idle timeout does, and wait until the
  # Registry entry is cleared — the entry is cleaned asynchronously after
  # the DOWN.
  defp idle_stop_buffer(exec_id) do
    [{pid, _}] = Registry.lookup(Opus.Events.Registry, exec_id)
    ref = Process.monitor(pid)
    send(pid, :timeout)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

    assert Enum.any?(1..200, fn _ ->
             Registry.lookup(Opus.Events.Registry, exec_id) == [] or
               (Process.sleep(10) && false)
           end),
           "the idle-stopped buffer's registry entry never cleared"
  end
end
