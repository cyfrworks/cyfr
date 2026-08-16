# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.FakeAquaTurn do
  @moduledoc """
  A stand-in for the engine half of `Prism.AquaTurn` — what
  `Prism.ConversationRunner` calls to start, follow, cancel and act on a
  turn. Every call is reported to the listener process (`listen/0`), and
  the test drives the turn by sending execution events to the runner it
  subscribed from. Nothing here touches Opus.

  Set `config :cyfr, :aqua_turn, Prism.FakeAquaTurn` (per test, restored on
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

  def start(ctx, input) do
    eid = "exec_fake_" <> Integer.to_string(System.unique_integer([:positive]))
    report({:fake_start, eid, ctx, input})
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

  def run_approved(proposal, ctx) do
    report({:fake_run_approved, proposal, ctx})
    {:ok, %{"status" => "ok", "id" => "wh_fake"}}
  end

  @doc false
  def listener, do: @listener
end
