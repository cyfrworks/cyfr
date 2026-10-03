# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ProgressTest do
  @moduledoc """
  Progress belongs to a request, not to a connection.

  A step is a `Cyfr.Bus.Progress` on its request's topic; the connection
  that streams the request's response binds the client's token to the
  request and renders each step it hears. A step of another request renders
  nothing, a backed-up listener has progress dropped and counted rather
  than queued, and once the request ends nothing more reaches it.
  """
  use ExUnit.Case, async: false

  alias Cyfr.Bus.{BoundedDispatcher, Progress}

  @actor Prima.Actor.in_athanor("ath_progress")

  defp step(request_id, phase, subject \\ {:build, "b1"}),
    do: Progress.new(@actor, subject, request_id: request_id, phase: phase, message: "m")

  defp listen!(request_id, token) do
    :ok = Emissary.MCP.Progress.listen(request_id, token)
    :ok = Cyfr.Bus.subscribe(@actor, Cyfr.Bus.progress(@actor, {:request, request_id}))
  end

  defp stop!(request_id) do
    :ok = Cyfr.Bus.unsubscribe(@actor, Cyfr.Bus.progress(@actor, {:request, request_id}))
    Emissary.MCP.Progress.forget(request_id)
  end

  test "a listener hears its own request's progress, stamped with the client's token" do
    listen!("req_own", "opaque-token-42")
    on_exit(fn -> Emissary.MCP.Progress.forget("req_own") end)

    :ok = Cyfr.Bus.broadcast_progress(@actor, step("req_own", :compiling))

    assert_receive %Progress{request_id: "req_own"} = heard
    assert {:ok, notification} = Emissary.MCP.Progress.notification(heard)
    assert notification["method"] == "notifications/progress"
    assert notification["params"]["phase"] == :compiling
    assert notification["params"]["build_id"] == "b1"
    assert notification["params"]["progressToken"] == "opaque-token-42"
  end

  # The key a client has always read a subject by is kept per kind.
  test "each subject renders under its own id key" do
    listen!("req_keys", "tok")

    for {kind, key} <- [build: "build_id", register: "register_id", pull: "progress_id"] do
      assert {:ok, %{"params" => params}} =
               Emissary.MCP.Progress.notification(step("req_keys", :x, {kind, "id_1"}))

      assert params[key] == "id_1"
    end

    stop!("req_keys")
  end

  # Two concurrent calls by one caller share a session: a channel keyed on
  # anything wider than the request would hand each the other's progress.
  test "a request never hears or renders another request's progress" do
    listen!("req_a", "tok-a")

    :ok = Cyfr.Bus.broadcast_progress(@actor, step("req_b", :not_for_us))
    refute_receive %Progress{}, 100
    assert Emissary.MCP.Progress.notification(step("req_b", :not_for_us)) == :ignore

    stop!("req_a")
  end

  test "once the request ends nothing more reaches it" do
    listen!("req_done", "tok")
    stop!("req_done")

    :ok = Cyfr.Bus.broadcast_progress(@actor, step("req_done", :late))
    refute_receive %Progress{}, 100
    assert Emissary.MCP.Progress.notification(step("req_done", :late)) == :ignore
  end

  # Progress is a courtesy. A client that did not ask for it, or that hung
  # up, must not turn into a failure in the code doing the actual work.
  test "publishing with no listener is a silent success" do
    assert Cyfr.Bus.broadcast_progress(@actor, step("req_nobody", :unheard)) == :ok
  end

  test "a step without a request is published on its subject alone" do
    :ok = Cyfr.Bus.subscribe(@actor, Cyfr.Bus.progress(@actor, {:build, "b1"}))
    :ok = Cyfr.Bus.broadcast_progress(@actor, step(nil, :solo))
    assert_receive %Progress{request_id: nil, phase: :solo}
    assert Emissary.MCP.Progress.notification(step(nil, :solo)) == :ignore
  end

  describe "a listener that cannot keep up" do
    setup do
      test = self()
      handler = "progress-dropped-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:cyfr, :mcp, :progress, :dropped],
        fn _event, measurements, metadata, _config ->
          send(test, {:dropped, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "has progress dropped and counted, never queued past the bound" do
      bound = BoundedDispatcher.max_pending_messages()
      test = self()

      # A connection stalled on its socket: subscribed, and reading nothing.
      stalled =
        spawn_link(fn ->
          :ok =
            Cyfr.Bus.subscribe(@actor, Cyfr.Bus.progress(@actor, {:request, "req_stalled"}))

          send(test, :subscribed)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :subscribed
      for n <- 1..bound, do: send(stalled, {:backlog, n})

      :ok = Cyfr.Bus.broadcast_progress(@actor, step("req_stalled", :dropped_one))

      assert_receive {:dropped, %{count: 1}, %{request_id: "req_stalled"}}
      assert {:message_queue_len, ^bound} = Process.info(stalled, :message_queue_len)
      send(stalled, :stop)
    end
  end
end
