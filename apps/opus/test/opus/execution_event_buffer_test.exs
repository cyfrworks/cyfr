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
end
