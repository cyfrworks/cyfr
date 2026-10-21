# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Gate.DecisionsTest do
  @moduledoc """
  What is recorded, and what a record that cannot be written costs: the
  roster of calls that are not recorded, the loss event for an append or
  a completion that did not land — a store that cannot answer, or every
  writer of the node busy — and an answer of `:ok` either way, with the
  operation's own result unchanged and nothing run again. And who reads
  the record back: the caller's athanor's decisions under its own
  context, never another athanor's or the host's.
  """
  use ExUnit.Case, async: false

  alias Sanctum.{Catalog, Decisions}
  alias Prima.{Decision, UUID7}

  @root Path.expand("../../../../..", __DIR__)

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

  describe "the calls the audit leaves out (Sanctum.Catalog.recorded?/2)" do
    test "discovery and the audit's own reads are not recorded" do
      for action <- ~w(list get correlate stats) do
        refute Catalog.recorded?("mcp_log", action)
      end

      for action <- ~w(get list payload) do
        refute Catalog.recorded?("record", action)
      end

      for action <- ~w(list get correlate list_global get_global) do
        refute Catalog.recorded?("decision", action)
      end

      refute Catalog.recorded?("tools", "list")
      refute Catalog.recorded?("system", "status")
    end

    # The shell reads the caller's own inbox on every navigation and every
    # offer message; what the person does with an offer is theirs to see.
    test "the shell's read of the caller's own offers is not recorded; acting on one is" do
      refute Catalog.recorded?("file", "offers")

      for action <- ~w(offer accept decline withdraw list read write delete) do
        assert Catalog.recorded?("file", action), "file.#{action} is not recorded"
      end
    end

    test "the unrecorded calls are the table's reads declared recorded: false, and no others" do
      unrecorded =
        for {_name, {_module, tool}} <- Catalog.operations(),
            %Prima.Operation{recorded: false} = operation <- tool.operations,
            do: {operation.tool, operation.action, operation.kind}

      assert Enum.all?(unrecorded, fn {_tool, _action, kind} -> kind == :read end)

      assert unrecorded
             |> Enum.map(fn {tool, action, _} -> "#{tool}.#{action}" end)
             |> Enum.sort() ==
               ~w(decision.correlate decision.get decision.get_global decision.list
                  decision.list_global file.offers mcp_log.correlate mcp_log.get
                  mcp_log.list mcp_log.stats record.get record.list record.payload system.status
                  tools.list)
    end

    test "every other call is recorded, discovery tools' other actions among them" do
      assert Catalog.recorded?("tools", "call")
      assert Catalog.recorded?("system", "notify")
      assert Catalog.recorded?("execution", "run")
      assert Catalog.recorded?("policy_log", "list")
      assert Catalog.recorded?("storage", "read")
      assert Catalog.recorded?("notion:create_page", nil)
      assert Catalog.recorded?("unknown", 42)
    end

    test "the gate neither appends nor emits an unrecorded call" do
      ctx = Sanctum.TestContext.local()
      admitted = attach([:cyfr, :sanctum, :decision, :admitted])
      request_id = UUID7.request_id()

      assert {:ok, _} =
               Sanctum.Gate.call_external("system", %{ctx | request_id: request_id}, %{
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
        Sanctum.Decisions.refused(ctx, :invalid_bearer,
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
      assert decision.reason == Sanctum.Refusals.render(:invalid_bearer)
      assert :ok = Prima.Decision.validate(decision)

      # Under no context: no actor, a null tenant, and an entry's own id kept.
      bare = Sanctum.Decisions.refused(nil, :lost, plane: :in_chain, call_id: "call_kept")
      assert bare.call_id == "call_kept"
      assert is_nil(bare.athanor_id) and is_nil(bare.user_id)

      assert_raise ArgumentError, fn ->
        Sanctum.Decisions.refused(nil, :lost, plane: :in_chain, call_id: "req_wrong")
      end
    end

    test "a refused call's tags hold only names the table knows" do
      refused = attach([:cyfr, :sanctum, :decision, :refused])
      ctx = Sanctum.TestContext.local()

      # A tool nobody declared, and an action its tool did not: a guest's
      # own names never become a metric series.
      Sanctum.Decisions.emit(
        Sanctum.Decisions.refused(ctx, :not_found, plane: :external, tool: "x-#{ctx.user_id}")
      )

      assert_received {^refused, %{count: 1}, %{tool: "unknown", action: "", refusal_class: _}}

      Sanctum.Decisions.emit(
        Sanctum.Decisions.refused(ctx, :invalid_params,
          plane: :external,
          tool: "system",
          action: "explode"
        )
      )

      assert_received {^refused, %{count: 1}, %{tool: "system", action: "unknown"}}

      Sanctum.Decisions.emit(
        Sanctum.Decisions.refused(ctx, :invalid_bearer,
          plane: :external,
          tool: "system",
          action: "status"
        )
      )

      assert_received {^refused, %{count: 1}, %{tool: "system", action: "status"}}

      # The row keeps the name as sent: the tag is the only thing bounded.
      assert Sanctum.Decisions.refused(ctx, :not_found, plane: :external, tool: "nope").tool ==
               "nope"
    end
  end

  describe "the loss path" do
    @tag capture_log: true
    test "an append whose store cannot answer is :ok, emitted and counted as lost" do
      ctx = Sanctum.TestContext.local()
      admitted = attach([:cyfr, :sanctum, :decision, :admitted])
      lost = attach([:cyfr, :sanctum, :decision, :lost])
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
      admitted = attach([:cyfr, :sanctum, :decision, :admitted])
      lost = attach([:cyfr, :sanctum, :decision, :lost])
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
      answered = Sanctum.Gate.call_external("retention", ctx, args)
      lost = attach([:cyfr, :sanctum, :decision, :lost])

      held = hold_every_writer()

      try do
        assert Sanctum.Gate.call_external("retention", ctx, args) == answered
      after
        release_writers(held)
      end

      assert_received {^lost, %{count: 1}, %{stage: :append, kind: :capacity}}
      assert_received {^lost, %{count: 1}, %{stage: :finish, kind: :capacity}}
      refute_received {^lost, _, _}
    end

    test "a completion under no admission is :ok and counted as lost" do
      ctx = Sanctum.TestContext.local()
      lost = attach([:cyfr, :sanctum, :decision, :lost])

      assert :ok =
               Decisions.close(ctx, UUID7.generate_id("call"), %{
                 result: {:error, :unavailable},
                 duration_ms: 3
               })

      assert_received {^lost, %{count: 1}, %{stage: :finish, kind: :not_found}}
    end

    test "a decision the log refuses to take is :ok, counted as lost and logged by shape" do
      ctx = Sanctum.TestContext.local()
      lost = attach([:cyfr, :sanctum, :decision, :lost])

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

  # One decision appended under `ctx`'s actor, or under none for the
  # host's row, made under `request_id`, with `fields` over an admitted
  # default.
  defp appended!(ctx, request_id, fields \\ []) do
    decision =
      Decision.new(
        Keyword.merge(
          [
            call_id: UUID7.generate_id("call"),
            request_id: request_id,
            user_id: ctx && ctx.user_id,
            athanor_id: ctx && ctx.athanor_id,
            plane: :external,
            tool: "storage",
            action: "get",
            inserted_at: DateTime.utc_now(),
            admission: :admitted
          ],
          fields
        )
      )

    :ok = Arca.DecisionLog.append(ctx && Sanctum.Context.actor(ctx), decision)
    decision
  end

  describe "reading the record" do
    setup do
      ctx = Sanctum.TestContext.local()
      {_ath_a, other} = Sanctum.TestContext.two_contexts()
      request_id = UUID7.request_id()

      own = appended!(ctx, request_id)
      foreign = appended!(other, request_id)
      host = appended!(nil, request_id, admission: :refused, refusal_class: :unauthenticated)

      {:ok,
       ctx: ctx, other: other, request_id: request_id, own: own, foreign: foreign, host: host}
    end

    test "list/2 and correlate/2 answer the caller's athanor's decisions, never another's or the host's",
         %{ctx: ctx, other: other, request_id: request_id, own: own, foreign: foreign} do
      assert {:ok, [listed]} = Decisions.list(ctx, request_id: request_id)
      assert listed.call_id == own.call_id

      # An option naming another athanor names nothing: the read is the
      # context's actor's.
      assert {:ok, [^listed]} =
               Decisions.list(ctx, request_id: request_id, athanor_id: other.athanor_id)

      assert {:ok, [correlated]} = Decisions.correlate(ctx, request_id)
      assert correlated.call_id == own.call_id

      # The other athanor reads its own, and only its own.
      assert {:ok, [theirs]} = Decisions.correlate(other, request_id)
      assert theirs.call_id == foreign.call_id
    end

    test "a context with no athanor reads nothing, a platform administrator's included",
         %{ctx: ctx, request_id: request_id} do
      for reader <- [
            Sanctum.TestContext.platform(platform_admin: true),
            Sanctum.system_context(),
            %{ctx | athanor_id: nil}
          ] do
        assert {:error, :no_athanor} = Decisions.list(reader, request_id: request_id)
        assert {:error, :no_athanor} = Decisions.correlate(reader, request_id)
      end
    end
  end

  describe "completion" do
    test "an execution's close never records a decision's completion" do
      # The gate records the call's completion when the call returns; an
      # asynchronous run's attempt closes its own row and nothing else.
      source = File.read!(Path.join(@root, "apps/cyfr/lib/opus/close.ex"))

      for name <- ["DecisionLog", "Decisions", "finish("] do
        refute source =~ name, "Opus.Close names #{name}"
      end
    end
  end
end
