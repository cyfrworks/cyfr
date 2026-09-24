# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.EventsTest do
  use ExUnit.Case, async: false

  alias Crucible.Events
  alias Crucible.Events.Sequence

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
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
          component_type: "reagent"
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
    Events.flush(record.id)

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

    assert {:ok, "1.1"} = Events.push(record.id, %{"kind" => "text_delta"}, record)
    Events.flush(record.id)

    id = record.id
    assert_receive %Cyfr.Bus.ExecutionEvent{type: "emit", execution_id: ^id, sequence: "1.1"}
  end

  test "an athanor-less producer is dropped, never routed into a default tenant" do
    record = execution!("ath_evt_x")
    Events.subscribe(record.id, record)

    assert {:error, :missing_athanor} =
             Events.push(record.id, %{"kind" => "text_delta"}, nil)

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

      assert {:ok, "1.1"} = Events.push(record.id, %{"i" => 1}, record)
      assert {:ok, "1.2"} = Events.push(record.id, %{"i" => 2}, record)

      two = durable!(record, "step.closed", %{"step" => "s1"})
      assert two == 2
      assert {:ok, "2.1"} = Events.push(record.id, %{"i" => 3}, record)

      # A publication for an older prefix, arriving late, does not touch the
      # counter of the prefix already emitted under.
      :ok = Events.publish(record.id, record, "step.closed", 1, %{"late" => true})
      assert {:ok, "2.2"} = Events.push(record.id, %{"i" => 4}, record)
      Events.flush(record.id)

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
  end

  # An idle buffer restart must restore cached events for Last-Event-ID
  # replay, and keep numbering where it was.
  test "a buffer that restarts resumes the history and the numbering" do
    record = execution!("ath_evt_x")

    assert {:ok, "1.1"} = Events.push(record.id, %{"n" => 1}, record)
    assert {:ok, "1.2"} = Events.push(record.id, %{"n" => 2}, record)
    Events.flush(record.id)

    idle_stop_buffer(record.id)

    # Simulate the counter table having restarted mid-run.
    Sequence.forget(record.id)

    # The next emit restarts the buffer, which floors the counter from
    # what the cache saw, and the stream continues.
    assert {:ok, "1.3"} = Events.push(record.id, %{"n" => 3}, record)
    Events.flush(record.id)

    assert ["1.1", "1.2", "1.3"] =
             record.id
             |> Events.since({1, 0}, "ath_evt_x")
             |> Enum.map(& &1.sequence)
  end

  # Stop a live buffer the way the idle timeout does, and wait until the
  # Registry entry is actually gone — the entry is cleaned asynchronously
  # after the DOWN, and a push in that window would cast into the dead pid.
  defp idle_stop_buffer(exec_id) do
    [{pid, _}] = Registry.lookup(Crucible.Events.Registry, exec_id)
    ref = Process.monitor(pid)
    send(pid, :timeout)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

    assert Enum.any?(1..200, fn _ ->
             Registry.lookup(Crucible.Events.Registry, exec_id) == [] or
               (Process.sleep(10) && false)
           end),
           "the idle-stopped buffer's registry entry never cleared"
  end
end
