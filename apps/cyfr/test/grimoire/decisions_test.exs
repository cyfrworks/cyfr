# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.DecisionsTest do
  @moduledoc """
  What is recorded, and what a record that cannot be written costs: the
  roster of calls that are not recorded, the loss event for an append or
  a completion that did not land — a store that cannot answer, or every
  writer of the node busy — and an answer of `:ok` either way, with the
  operation's own result unchanged and nothing run again.
  """
  use ExUnit.Case, async: false

  alias Grimoire.Decisions
  alias Prima.{Decision, UUID7}

  @root Path.expand("../../../..", __DIR__)

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
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

  # Run `fun` while the decision log's table is gone, which is what a store
  # that cannot answer is to its writer: the write raises, and the writer
  # answers the refusal it handles.
  defp without_decision_log(fun) do
    Arca.Repo.query!("ALTER TABLE decision_logs RENAME TO decision_logs_unavailable")

    try do
      fun.()
    after
      Arca.Repo.query!("ALTER TABLE decision_logs_unavailable RENAME TO decision_logs")
    end
  end

  # Every writer slot the node has, taken by an idle process of the case's
  # once the writers the case started before have ended, so a write past
  # them is refused at once whatever its store would say.
  defp hold_every_writer do
    await_idle_writers(1_000)
    hold_every_writer([])
  end

  defp hold_every_writer(held) do
    idle = fn -> receive do: (:done -> :ok) end

    case Task.Supervisor.start_child(Arca.DecisionLog.Writers, idle) do
      {:ok, pid} -> hold_every_writer([pid | held])
      {:error, :max_children} -> held
    end
  end

  defp await_idle_writers(0), do: flunk("the decision log's writers never went idle")

  defp await_idle_writers(tries) do
    if Arca.DecisionLog.writers() == 0 do
      :ok
    else
      Process.sleep(5)
      await_idle_writers(tries - 1)
    end
  end

  defp release_writers(held) do
    for pid <- held do
      ref = Process.monitor(pid)
      send(pid, :done)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
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

      for action <- ~w(list get correlate list_global get_global) do
        refute Decisions.recorded?("decision", action)
      end

      refute Decisions.recorded?("tools", "list")
      refute Decisions.recorded?("system", "status")
    end

    # The shell reads the caller's own inbox on every navigation and every
    # offer message; what the person does with an offer is theirs to see.
    test "the shell's read of the caller's own offers is not recorded; acting on one is" do
      refute Decisions.recorded?("file", "offers")

      for action <- ~w(offer accept decline withdraw list read write delete) do
        assert Decisions.recorded?("file", action), "file.#{action} is not recorded"
      end
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

  describe "refused/3 and what a tag carries" do
    test "a refusal before the gate is a refused decision with the reason's class and sentence" do
      ctx = Sanctum.TestContext.local()

      decision =
        Grimoire.Decisions.refused(ctx, :invalid_bearer,
          plane: :external,
          tool: "system",
          action: "status"
        )

      assert "call_" <> _ = decision.call_id
      assert decision.request_id == ctx.request_id
      assert decision.athanor_id == ctx.athanor_id
      assert decision.user_id == ctx.user_id
      assert decision.admission == :refused
      assert decision.refusal_class == :unauthenticated
      assert decision.reason == Grimoire.render(:invalid_bearer)
      assert :ok = Prima.Decision.validate(decision)

      # Under no context: no actor, a null tenant, and an entry's own id kept.
      bare = Grimoire.Decisions.refused(nil, :lost, plane: :in_chain, call_id: "call_kept")
      assert bare.call_id == "call_kept"
      assert is_nil(bare.athanor_id) and is_nil(bare.user_id)

      assert_raise ArgumentError, fn ->
        Grimoire.Decisions.refused(nil, :lost, plane: :in_chain, call_id: "req_wrong")
      end
    end

    test "a refused call's tags hold only names the table knows" do
      refused = attach([:cyfr, :grimoire, :decision, :refused])
      ctx = Sanctum.TestContext.local()

      # A tool nobody declared, and an action its tool did not: a guest's
      # own names never become a metric series.
      Grimoire.Decisions.emit(
        Grimoire.Decisions.refused(ctx, :not_found, plane: :external, tool: "x-#{ctx.user_id}")
      )

      assert_received {^refused, %{count: 1}, %{tool: "unknown", action: "", refusal_class: _}}

      Grimoire.Decisions.emit(
        Grimoire.Decisions.refused(ctx, :invalid_params,
          plane: :external,
          tool: "system",
          action: "explode"
        )
      )

      assert_received {^refused, %{count: 1}, %{tool: "system", action: "unknown"}}

      Grimoire.Decisions.emit(
        Grimoire.Decisions.refused(ctx, :invalid_bearer,
          plane: :external,
          tool: "system",
          action: "status"
        )
      )

      assert_received {^refused, %{count: 1}, %{tool: "system", action: "status"}}

      # The row keeps the name as sent: the tag is the only thing bounded.
      assert Grimoire.Decisions.refused(ctx, :not_found, plane: :external, tool: "nope").tool ==
               "nope"
    end
  end

  describe "the loss path" do
    @tag capture_log: true
    test "an append whose store cannot answer is :ok, emitted and counted as lost" do
      ctx = Sanctum.TestContext.local()
      admitted = attach([:cyfr, :grimoire, :decision, :admitted])
      lost = attach([:cyfr, :grimoire, :decision, :lost])
      decision = decision(ctx)

      without_decision_log(fn ->
        assert :ok = Decisions.open(ctx, decision, %{input: %{}})
      end)

      assert_received {^admitted, %{count: 1}, _}
      assert_received {^lost, %{count: 1}, %{stage: :append, kind: :unavailable}}
    end

    @tag capture_log: true
    test "a write past the writer cap is :ok, one capacity loss per write, never asked again" do
      ctx = Sanctum.TestContext.local()
      admitted = attach([:cyfr, :grimoire, :decision, :admitted])
      lost = attach([:cyfr, :grimoire, :decision, :lost])
      decision = decision(ctx)

      held = hold_every_writer()

      try do
        assert :ok = Decisions.open(ctx, decision, %{input: %{}})

        assert :ok =
                 Decisions.close(ctx, decision.call_id, %{result: {:ok, %{}}, duration_ms: 1})
      after
        release_writers(held)
      end

      assert_received {^admitted, %{count: 1}, _}
      assert_received {^lost, %{count: 1}, %{stage: :append, kind: :capacity}}
      assert_received {^lost, %{count: 1}, %{stage: :finish, kind: :capacity}}
      refute_received {^lost, _, _}

      assert {:error, :not_found} =
               Arca.DecisionLog.get(Sanctum.Context.actor(ctx), decision.call_id)
    end

    @tag capture_log: true
    test "a call the gate admits while every writer is busy answers as it would, run once" do
      ctx = Sanctum.TestContext.local()
      args = %{"action" => "get"}
      answered = Grimoire.call_external("retention", ctx, args)
      lost = attach([:cyfr, :grimoire, :decision, :lost])

      held = hold_every_writer()

      try do
        assert Grimoire.call_external("retention", ctx, args) == answered
      after
        release_writers(held)
      end

      assert_received {^lost, %{count: 1}, %{stage: :append, kind: :capacity}}
      assert_received {^lost, %{count: 1}, %{stage: :finish, kind: :capacity}}
      refute_received {^lost, _, _}
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
