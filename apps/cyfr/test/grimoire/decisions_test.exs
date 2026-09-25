# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.DecisionsTest do
  @moduledoc """
  What is recorded, and what a record that cannot be written costs: the
  roster of calls that are not recorded, the loss event for an append or
  a completion that did not land, and an answer of `:ok` either way.
  """
  use ExUnit.Case, async: false

  alias Grimoire.Decisions
  alias Prima.{Decision, UUID7}

  @root Path.expand("../../../..", __DIR__)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp attach(event) do
    ref = make_ref()
    test = self()

    :telemetry.attach(
      {__MODULE__, ref},
      event,
      fn _name, measurements, metadata, _ -> send(test, {ref, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  # Run `fun` in a process of its own while no process holds a sandbox
  # connection, then hand the test its own again.
  defp without_connection(fun) do
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, :manual)

    try do
      Task.async(fn ->
        Process.delete(:"$callers")
        fun.()
      end)
      |> Task.await()
    after
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    end
  end

  defp decision(ctx) do
    Decision.new(
      call_id: UUID7.generate_id("call"),
      request_id: UUID7.request_id(),
      user_id: ctx.user_id,
      athanor_id: ctx.athanor_id,
      plane: :external,
      tool: "storage",
      action: "get",
      inserted_at: DateTime.utc_now(),
      admission: :admitted
    )
  end

  describe "recorded?/2" do
    test "discovery and the audit's own reads are not recorded" do
      for action <- ~w(list get correlate fan_outs stats) do
        refute Decisions.recorded?("mcp_log", action)
      end

      for action <- ~w(get list payload) do
        refute Decisions.recorded?("record", action)
      end

      refute Decisions.recorded?("tools", "list")
      refute Decisions.recorded?("system", "status")
    end

    test "every other call is recorded, discovery tools' other actions among them" do
      assert Decisions.recorded?("tools", "call")
      assert Decisions.recorded?("system", "notify")
      assert Decisions.recorded?("execution", "run")
      assert Decisions.recorded?("policy_log", "list")
      assert Decisions.recorded?("storage", "read")
      assert Decisions.recorded?("notion:create_page", nil)
      assert Decisions.recorded?("unknown", 42)
    end

    test "the gate neither appends nor emits an unrecorded call" do
      ctx = Sanctum.TestContext.local()
      admitted = attach([:cyfr, :grimoire, :decision, :admitted])
      request_id = UUID7.request_id()

      assert {:ok, _} =
               Grimoire.call_external("system", %{ctx | request_id: request_id}, %{
                 "action" => "status"
               })

      refute_received {^admitted, _, _}

      assert {:ok, []} =
               Arca.DecisionLog.correlate(Sanctum.Context.actor(ctx), request_id)
    end
  end

  describe "the loss path" do
    @tag capture_log: true
    test "an append whose store cannot answer is :ok, emitted and counted as lost" do
      ctx = Sanctum.TestContext.local()
      admitted = attach([:cyfr, :grimoire, :decision, :admitted])
      lost = attach([:cyfr, :grimoire, :decision, :lost])
      decision = decision(ctx)

      # The connection is taken away: no process holds one, so the writer
      # has none to write with.
      without_connection(fn ->
        assert :ok = Decisions.open(ctx, decision, %{input: %{}})
      end)

      assert_received {^admitted, %{count: 1}, _}
      assert_received {^lost, %{count: 1}, %{stage: :append, kind: :unavailable}}
    end

    test "a completion under no admission is :ok and counted as lost" do
      ctx = Sanctum.TestContext.local()
      lost = attach([:cyfr, :grimoire, :decision, :lost])

      assert :ok =
               Decisions.close(ctx, UUID7.generate_id("call"), %{
                 result: {:error, :unavailable},
                 duration_ms: 3
               })

      assert_received {^lost, %{count: 1}, %{stage: :finish, kind: :not_found}}
    end

    test "a decision the log refuses to take is :ok, counted as lost and logged by shape" do
      ctx = Sanctum.TestContext.local()
      lost = attach([:cyfr, :grimoire, :decision, :lost])

      # Attribution is the actor's: a decision naming another tenant raises
      # in the log, and the raise is a loss, never the caller's crash.
      other = %{decision(ctx) | athanor_id: "ath_somebody_else"}

      log =
        ExUnit.CaptureLog.capture_log(fn -> assert :ok = Decisions.open(ctx, other) end)

      assert_received {^lost, %{count: 1}, %{stage: :append, kind: :unavailable}}

      # The exception's module and the stage, never its message: a message
      # can carry the values the log refused.
      assert log =~ "append raised ArgumentError"
      refute log =~ "ath_somebody_else"
      refute log =~ "is the actor's"
    end
  end

  describe "completion" do
    test "an execution's close never records a decision's completion" do
      # The gate records the call's completion when the call returns; an
      # asynchronous run's attempt closes its own row and nothing else.
      source = File.read!(Path.join(@root, "apps/cyfr/lib/crucible/close.ex"))

      for name <- ["DecisionLog", "Grimoire.Decisions", "close_decision", "finish("] do
        refute source =~ name, "Crucible.Close names #{name}"
      end
    end
  end
end
