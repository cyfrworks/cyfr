# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.FakeTurn do
  @moduledoc """
  A stand-in for the engine half of `Aqua.Turn` — what
  `Aqua.ConversationRunner` calls to start, follow, cancel and act on a
  turn. Every call is reported to the listener process (`listen/0`), and
  the test drives the turn by sending execution events to the runner it
  subscribed from. Nothing here touches Opus.

  Set `config :cyfr, :aqua_turn, Aqua.FakeTurn` (per test, restored on
  exit) before the runner under test starts.
  """

  @listener {:global, __MODULE__}

  @doc "Make the calling process the listener for the fake's reports."
  def listen do
    :global.re_register_name(__MODULE__, self())
    :ok
  end

  defp report(msg) do
    case :global.whereis_name(__MODULE__) do
      :undefined -> :ok
      pid -> send(pid, msg)
    end
  end

  @doc """
  The pinned profile a turn runs as. The fake answers a fixed one so the
  runner's three-step start (pin → compose → run) has something to thread;
  a test that cares which profile was pinned asserts on `:fake_start`.
  """
  def pin_profile(ctx) do
    report({:fake_pin_profile, ctx})
    {:ok, %{profile_id: fake_profile_id()}}
  end

  @doc "The profile id `pin_profile/1` answers."
  def fake_profile_id, do: "prof_fake"

  def start(ctx, input, profile_id) do
    eid = "exec_fake_" <> Integer.to_string(System.unique_integer([:positive]))
    report({:fake_start, eid, ctx, input, profile_id})
    {:ok, eid}
  end

  def engine_available?, do: true
  def subscribe(execution_id, _ctx), do: report({:fake_subscribe, execution_id, self()})
  def unsubscribe(execution_id, _ctx), do: report({:fake_unsubscribe, execution_id})

  def cancel(_ctx, execution_id) do
    report({:fake_cancel, execution_id})
    :ok
  end

  def cancel_for_restart(_ctx, execution_id, payload) do
    report({:fake_cancel_for_restart, execution_id, payload})
    :ok
  end

  def events_since(_execution_id, _athanor_id), do: []
  def running?(_ctx, _execution_id), do: false

  def run_approved(proposal, ctx, profile_id) do
    report({:fake_run_approved, proposal, ctx, profile_id})
    {:ok, %{"status" => "ok", "id" => "wh_fake"}}
  end

  @doc false
  def listener, do: @listener
end
