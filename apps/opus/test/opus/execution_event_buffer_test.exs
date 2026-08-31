# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ExecutionEventBufferTest do
  use ExUnit.Case, async: false

  alias Opus.ExecutionEventBuffer

  # Producers must route events under the execution's own athanor — consumers
  # (AQUA LiveView, SSE replay) subscribe and replay with the record's
  # athanor, so a misrouted event is invisible to them.

  test "the record's athanor routes the broadcast and the replay buffer" do
    exec_id = "exec_evt_tenant_#{System.unique_integer([:positive])}"
    record = %{id: exec_id, athanor_id: "ath_evt_x"}

    ExecutionEventBuffer.subscribe(exec_id, record)

    :ok =
      ExecutionEventBuffer.push_terminal(exec_id, "complete", %{status: "completed"}, 1, record)

    ExecutionEventBuffer.flush(exec_id)

    assert_receive {:execution_event, %{type: "complete", execution_id: ^exec_id}}

    # Replay under the record's athanor sees the event; another athanor's key
    # does not.
    assert [%{type: "complete"}] = ExecutionEventBuffer.since(exec_id, 0, "ath_evt_x")
    assert [] = ExecutionEventBuffer.since(exec_id, 0, "ath_other")
  end

  test "a Sanctum.Context routes identically to record coordinates" do
    exec_id = "exec_evt_ctx_#{System.unique_integer([:positive])}"
    ctx = %Sanctum.Context{athanor_id: "ath_evt_x"}
    record = %{id: exec_id, athanor_id: "ath_evt_x"}

    ExecutionEventBuffer.subscribe(exec_id, ctx)

    :ok = ExecutionEventBuffer.push(exec_id, %{"kind" => "text_delta"}, 1, record)
    ExecutionEventBuffer.flush(exec_id)

    assert_receive {:execution_event, %{type: "emit", execution_id: ^exec_id}}
  end

  test "an athanor-less producer is dropped, never routed into a default tenant" do
    exec_id = "exec_evt_none_#{System.unique_integer([:positive])}"
    ctx = %Sanctum.Context{athanor_id: "ath_evt_x"}

    ExecutionEventBuffer.subscribe(exec_id, ctx)

    :ok = ExecutionEventBuffer.push_terminal(exec_id, "error", %{error: "boom"}, 1, nil)
    ExecutionEventBuffer.flush(exec_id)

    refute_receive {:execution_event, %{type: "error", execution_id: ^exec_id}}, 100
    assert [] = ExecutionEventBuffer.since(exec_id, 0, "ath_evt_x")
  end

  test "replay and topic refuse a missing athanor" do
    exec_id = "exec_evt_nil_#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, fn -> ExecutionEventBuffer.since(exec_id, 0, nil) end
    assert_raise ArgumentError, fn -> ExecutionEventBuffer.topic(exec_id, %{}) end
  end

  # A buffer stops after two minutes idle and merges its events into the
  # cache, whose TTL is ten. A long execution that goes quiet and then emits
  # again restarts the process — which used to begin with an empty list and
  # put that one new event over the whole history, so a client reconnecting
  # with Last-Event-ID replayed a run that appeared to start in the middle.
  test "a buffer that restarts resumes the history instead of erasing it" do
    exec_id = "exec_evt_restart_#{System.unique_integer([:positive])}"
    record = %{id: exec_id, athanor_id: "ath_evt_x"}

    :ok = ExecutionEventBuffer.push(exec_id, %{"kind" => "text_delta", "n" => 1}, 1, record)
    :ok = ExecutionEventBuffer.push(exec_id, %{"kind" => "text_delta", "n" => 2}, 2, record)
    ExecutionEventBuffer.flush(exec_id)

    assert length(ExecutionEventBuffer.since(exec_id, 0, "ath_evt_x")) == 2

    # Exactly what the idle timeout does: a normal stop, terminate/2 merging
    # into the cache, and the registry entry gone.
    [{pid, _}] = Registry.lookup(Opus.ExecutionEventBuffer.Registry, exec_id)
    ref = Process.monitor(pid)
    send(pid, :timeout)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

    # And it STAYS stopped. The child spec is :transient for this reason —
    # a DynamicSupervisor restarts a :permanent child even on a :normal
    # exit, so the idle timeout reaped nothing and every execution ever run
    # kept a process for the life of the node.
    assert Enum.any?(1..200, fn _ ->
             Registry.lookup(Opus.ExecutionEventBuffer.Registry, exec_id) == [] or
               (Process.sleep(10) && false)
           end),
           "the idle-stopped buffer was restarted — the timeout reaps nothing"

    # The next event restarts the buffer.
    :ok = ExecutionEventBuffer.push(exec_id, %{"kind" => "text_delta", "n" => 3}, 3, record)
    ExecutionEventBuffer.flush(exec_id)

    replayed = ExecutionEventBuffer.since(exec_id, 0, "ath_evt_x")

    assert length(replayed) == 3,
           "the restarted buffer replayed #{length(replayed)} event(s) — the history before " <>
             "the idle gap was overwritten"
  end

  # Stop a live buffer the way the idle timeout does, and wait until the
  # Registry entry is actually gone — the entry is cleaned asynchronously
  # after the DOWN, and a push in that window would cast into the dead pid.
  defp idle_stop_buffer(exec_id) do
    [{pid, _}] = Registry.lookup(Opus.ExecutionEventBuffer.Registry, exec_id)
    ref = Process.monitor(pid)
    send(pid, :timeout)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

    assert Enum.any?(1..200, fn _ ->
             Registry.lookup(Opus.ExecutionEventBuffer.Registry, exec_id) == [] or
               (Process.sleep(10) && false)
           end),
           "the idle-stopped buffer's registry entry never cleared"
  end

  describe "Sequence — one numbering per stream" do
    alias Opus.ExecutionEventBuffer.Sequence

    # Emit sequences used to come from an `:atomics` ref created once per
    # formula execution, while emits are addressed to the ROOT execution id.
    # A formula and the nested formula it invoked therefore both counted
    # 1, 2, 3… into the same buffer, and `since/3` — which replays events with
    # `sequence > last_sequence` — silently dropped the overlap on reconnect.

    test "every emitter under one root shares the numbering" do
      root = "exec_seq_shared_#{System.unique_integer([:positive])}"

      # Two producers, as an outer formula and the formula it nests would be.
      outer = for _ <- 1..3, do: Sequence.next(root)
      inner = for _ <- 1..3, do: Sequence.next(root)

      assert outer == [1, 2, 3]
      assert inner == [4, 5, 6]
      assert Enum.uniq(outer ++ inner) == outer ++ inner
    end

    test "separate streams number independently" do
      a = "exec_seq_a_#{System.unique_integer([:positive])}"
      b = "exec_seq_b_#{System.unique_integer([:positive])}"

      assert Sequence.next(a) == 1
      assert Sequence.next(b) == 1
      assert Sequence.next(a) == 2
    end

    test "a replay window never sees a repeated sequence for one stream" do
      root = "exec_seq_replay_#{System.unique_integer([:positive])}"
      record = %{id: root, athanor_id: "ath_seq"}

      # Interleaved, the way a parent and its nested child actually emit.
      for i <- 1..6 do
        seq = Sequence.next(root)
        :ok = ExecutionEventBuffer.push(root, %{"i" => i}, seq, record)
      end

      ExecutionEventBuffer.flush(root)

      sequences =
        root
        |> ExecutionEventBuffer.since(0, "ath_seq")
        |> Enum.map(& &1.sequence)

      assert length(sequences) == 6
      assert Enum.uniq(sequences) == sequences

      # Resuming from any point returns exactly the rest — the property the
      # duplicate numbering broke.
      assert length(ExecutionEventBuffer.since(root, 3, "ath_seq")) == 3
    end

    test "forget/1 lets a finished stream's counter go" do
      root = "exec_seq_forget_#{System.unique_integer([:positive])}"

      assert Sequence.next(root) == 1
      assert :ok = Sequence.forget(root)
      assert Sequence.next(root) == 1
    end

    # The counter used to be forgotten when the buffer process died — but the
    # buffer idle-stops after two minutes while the replay cache lives ten and
    # the execution up to thirty. An execution that idled and emitted again
    # restarted at 1 under sequences already in the window, and a client
    # resuming with a pre-idle Last-Event-ID silently lost every post-idle
    # event. The terminal push is what retires the counter now.
    test "an idle-stop does not reset the numbering inside a live replay window" do
      root = "exec_seq_idle_#{System.unique_integer([:positive])}"
      record = %{id: root, athanor_id: "ath_seq"}

      for i <- 1..3 do
        seq = Sequence.next(root)
        :ok = ExecutionEventBuffer.push(root, %{"i" => i}, seq, record)
      end

      ExecutionEventBuffer.flush(root)

      idle_stop_buffer(root)

      # The execution is still running: the next emit continues the stream.
      seq = Sequence.next(root)

      assert seq == 4,
             "the idle-stop reset the counter — a resuming client would lose this event"

      :ok = ExecutionEventBuffer.push(root, %{"i" => 4}, seq, record)
      ExecutionEventBuffer.flush(root)

      # A client that saw 1..3 before the gap resumes and gets the rest.
      assert [%{sequence: 4}] = ExecutionEventBuffer.since(root, 3, "ath_seq")

      # The terminal push retires the counter; only then may the id restart.
      term_seq = Sequence.next(root)
      :ok = ExecutionEventBuffer.push_terminal(root, "complete", %{}, term_seq, record)
      ExecutionEventBuffer.flush(root)
      assert Sequence.next(root) == 1
    end

    test "reseed/2 floors a counter and never lowers it" do
      root = "exec_seq_reseed_#{System.unique_integer([:positive])}"

      assert :ok = Sequence.reseed(root, 7)
      assert Sequence.next(root) == 8

      assert :ok = Sequence.reseed(root, 3)
      assert Sequence.next(root) == 9
    end

    test "a buffer resuming from cache floors a restarted counter" do
      # If the counter table itself restarts mid-run (the ExecutionTree came
      # back) while the cache survives, the first post-restart emit is minted
      # before the buffer process exists to floor anything — that one event
      # is misnumbered — but the buffer's init reseeds from the cached
      # high-water mark so the stream continues from there.
      root = "exec_seq_treerestart_#{System.unique_integer([:positive])}"
      record = %{id: root, athanor_id: "ath_seq"}

      for i <- 1..3 do
        seq = Sequence.next(root)
        :ok = ExecutionEventBuffer.push(root, %{"i" => i}, seq, record)
      end

      ExecutionEventBuffer.flush(root)

      idle_stop_buffer(root)

      # Simulate the counter table having restarted mid-run.
      Sequence.forget(root)

      misnumbered = Sequence.next(root)
      :ok = ExecutionEventBuffer.push(root, %{"i" => "post-restart"}, misnumbered, record)
      ExecutionEventBuffer.flush(root)

      assert Sequence.next(root) == 4,
             "the buffer's init did not floor the counter from the cached events"
    end
  end
end
