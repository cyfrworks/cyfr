# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.BusTest do
  @moduledoc """
  The bus owns every topic: the tenant prefix and its refusals, the exact
  global roster, the page scope, the checks every publish and subscribe
  passes, and — by source scan — that nothing else in any `lib` tree
  reaches the PubSub server, spells a topic or sends a retired message.
  """
  use ExUnit.Case, async: false

  alias Cyfr.Bus
  alias Cyfr.Bus.{Execution, Notify, Progress, RoomInView, Session, Viewing}

  defp actor(athanor_id), do: Prima.Actor.in_athanor(athanor_id)

  @tenant_1 [
    :executions,
    :requests,
    :components,
    :builds,
    :schedule_runs,
    :tinctures,
    :enforcement,
    :webhooks,
    :api_keys,
    :mcp_servers,
    :schedules,
    :vault_changed,
    :notify
  ]

  @tenant_2 [execution_events: "exec_1", thread: "thr_1", progress: {:build, "b1"}]

  describe "the tenant prefix" do
    test "is tenant:<athanor_id>:, taken from the actor" do
      assert Bus.prefix(actor("ath_1")) == "tenant:ath_1:"
    end

    test "an actor with a nil or empty athanor raises rather than routing somewhere" do
      for athanor <- [nil, ""] do
        assert_raise ArgumentError, fn -> Bus.prefix(%Prima.Actor{athanor_id: athanor}) end

        for fun <- @tenant_1 do
          assert_raise ArgumentError, fn ->
            apply(Bus, fun, [%Prima.Actor{athanor_id: athanor}])
          end
        end
      end
    end

    test "anything but an actor raises" do
      for other <- [nil, "ath_1", %{athanor_id: "ath_1"}] do
        assert_raise ArgumentError, fn -> Bus.prefix(other) end
      end
    end

    test "every tenant topic carries it, and two athanors never share one" do
      for fun <- @tenant_1 do
        topic = apply(Bus, fun, [actor("ath_1")])
        assert String.starts_with?(topic, "tenant:ath_1:"), "#{fun}/1 is not tenant-prefixed"
        refute topic == apply(Bus, fun, [actor("ath_2")])
      end

      for {fun, subject} <- @tenant_2 do
        topic = apply(Bus, fun, [actor("ath_1"), subject])
        assert String.starts_with?(topic, "tenant:ath_1:"), "#{fun}/2 is not tenant-prefixed"
      end
    end

    test "every name is distinct" do
      names = Enum.map(@tenant_1, &apply(Bus, &1, [actor("ath_1")]))
      assert length(Enum.uniq(names)) == length(names)
    end

    test "a request's progress and a subject's are different topics" do
      a = actor("ath_1")
      refute Bus.progress(a, {:build, "x"}) == Bus.progress(a, {:request, "x"})
      refute Bus.progress(a, {:build, "x"}) == Bus.progress(a, {:pull, "x"})
      assert_raise FunctionClauseError, fn -> apply(Bus, :progress, [a, {:other, "x"}]) end
    end
  end

  describe "the global topics" do
    test "carry no tenant prefix" do
      for topic <- [
            Bus.vault_changed_global(),
            Bus.athanor_archived_global(),
            Bus.caller_invalidated_global(),
            Bus.sessions(),
            Bus.memberships("user_1"),
            Bus.platform_notify(),
            Bus.health_check(7),
            Bus.schedule_completions()
          ] do
        refute String.starts_with?(topic, "tenant:"), "#{topic} should be global"
      end
    end

    test "global/0 lists exactly the unscoped topics, each with its reason" do
      assert Enum.map(Bus.global(), &elem(&1, 0)) == [
               "sanctum:vault_changed",
               "sanctum:athanor_archived",
               "sanctum:caller_invalidated",
               "sanctum:sessions",
               "sanctum:memberships:<user_id>",
               "platform:notify",
               "health_check:<nonce>",
               "cyfr:schedule_completions"
             ]

      for {_topic, reason} <- Bus.global(), do: assert(is_binary(reason) and reason != "")
    end

    test "only a global topic passes the global doors" do
      assert :ok = Bus.subscribe_global(Bus.sessions())
      assert :ok = Bus.unsubscribe_global(Bus.sessions())

      assert_raise ArgumentError, fn -> Bus.subscribe_global(Bus.executions(actor("ath_1"))) end
      assert_raise ArgumentError, fn -> Bus.subscribe_global("sanctum:other") end

      assert_raise ArgumentError, fn ->
        Bus.broadcast_global(Bus.executions(actor("ath_1")), Session.new(:created))
      end

      # A global topic carries its own struct and no other.
      assert_raise ArgumentError, fn ->
        Bus.broadcast_global(Bus.sessions(), Notify.platform(:allowlist_changed))
      end
    end

    test "the standing announcements are one subscription, and one undo" do
      :ok = Bus.subscribe_standing("user_standing")

      subscribed = Registry.keys(Cyfr.PubSub, self())

      for topic <- [
            Bus.sessions(),
            Bus.caller_invalidated_global(),
            Bus.athanor_archived_global(),
            Bus.memberships("user_standing")
          ] do
        assert topic in subscribed
      end

      :ok = Bus.unsubscribe_standing("user_standing")
      assert Registry.keys(Cyfr.PubSub, self()) == []

      # A caller with no person hears the three that are not keyed by one.
      :ok = Bus.subscribe_standing(nil)
      assert length(Registry.keys(Cyfr.PubSub, self())) == 3
      :ok = Bus.unsubscribe_standing(nil)
    end
  end

  describe "the page topics" do
    test "stay on this node and carry their own structs" do
      topic = Bus.page_viewing(self())
      assert :ok = Bus.subscribe_page(topic)
      assert :ok = Bus.broadcast_page(topic, Viewing.new("ath_1"))
      assert_receive %Viewing{athanor_id: "ath_1"}

      assert_raise ArgumentError, fn -> Bus.broadcast_page(topic, RoomInView.new(nil)) end
      assert_raise ArgumentError, fn -> Bus.subscribe_page(Bus.sessions()) end

      room = Bus.room_feed("phx-1")
      :ok = Bus.subscribe_page(room)
      :ok = Bus.broadcast_page(room, RoomInView.new(%{"thread_id" => "t"}))
      assert_receive %RoomInView{room: %{"thread_id" => "t"}}
    end
  end

  describe "a tenant publish" do
    setup do
      test = self()
      handler = "bus-refused-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:cyfr, :bus, :publish_refused],
        fn _event, measurements, metadata, _config ->
          send(test, {:refused, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "reaches the tenant's subscribers when topic, actor and payload agree" do
      a = actor("ath_pub")
      :ok = Bus.subscribe(a, Bus.executions(a))
      assert :ok = Bus.broadcast(a, Bus.executions(a), Execution.new(a, :started))
      assert_receive %Execution{athanor_id: "ath_pub", kind: :started}
    end

    test "is refused and counted when the topic is another tenant's" do
      a = actor("ath_a")
      b = actor("ath_b")
      :ok = Bus.subscribe(b, Bus.executions(b))

      assert {:error, :cross_tenant} =
               Bus.broadcast(a, Bus.executions(b), Execution.new(a, :started))

      assert_receive {:refused, %{count: 1},
                      %{athanor_id: "ath_a", payload: Execution, topic_key: :executions}}

      refute_receive %Execution{}, 100
    end

    test "is refused when the payload names another tenant" do
      a = actor("ath_a")
      b = actor("ath_b")
      :ok = Bus.subscribe(a, Bus.executions(a))

      assert {:error, :cross_tenant} =
               Bus.broadcast(a, Bus.executions(a), Execution.new(b, :started))

      assert_receive {:refused, %{count: 1}, %{payload: Execution}}
      refute_receive %Execution{}, 100
    end

    test "is refused when the payload is not the topic's struct" do
      a = actor("ath_a")

      assert {:error, :cross_tenant} =
               Bus.broadcast(a, Bus.executions(a), Notify.new(a, :member_changed))

      assert_receive {:refused, _, %{payload: Notify, topic_key: :executions}}
    end

    test "is refused for an actor that names no athanor" do
      assert {:error, :cross_tenant} =
               Bus.broadcast(
                 %Prima.Actor{athanor_id: nil},
                 Bus.executions(actor("ath_a")),
                 Execution.new(actor("ath_a"), :started)
               )
    end

    test "of progress reaches the subject's topic and its request's" do
      a = actor("ath_progress_pub")
      :ok = Bus.subscribe(a, Bus.progress(a, {:pull, "p1"}))
      :ok = Bus.subscribe(a, Bus.progress(a, {:request, "req_1"}))

      step = Progress.new(a, {:pull, "p1"}, request_id: "req_1", phase: :pulling)
      assert :ok = Bus.broadcast_progress(a, step)

      assert_receive %Progress{subject: {:pull, "p1"}}
      assert_receive %Progress{subject: {:pull, "p1"}}
    end
  end

  describe "a tenant subscribe" do
    test "to another tenant's topic is refused" do
      assert {:error, :cross_tenant} =
               Bus.subscribe(actor("ath_a"), Bus.executions(actor("ath_b")))

      assert {:error, :cross_tenant} = Bus.subscribe(actor("ath_a"), Bus.sessions())
      assert {:error, :cross_tenant} = Bus.subscribe(actor("ath_a"), "tenant:ath_a:not_a_topic")
      assert Registry.keys(Cyfr.PubSub, self()) == []
    end
  end

  describe "a bounded reason" do
    test "keeps an atom, cuts a string to 200 bytes on a character boundary, and names anything else" do
      assert Bus.bounded_reason(:timeout) == :timeout
      assert Bus.bounded_reason(nil) == nil
      assert Bus.bounded_reason("short") == "short"

      cut = Bus.bounded_reason(String.duplicate("é", 150))
      assert byte_size(cut) <= 200 and String.valid?(cut)

      for other <- [{:error, %{token: "sk"}}, %{a: 1}, [1], 42, self()] do
        assert Bus.bounded_reason(other) == "error"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The tree
  # ---------------------------------------------------------------------------

  defp root, do: Path.expand("../../../..", __DIR__)

  # The bus's own file and its bounded dispatcher are the one place the
  # PubSub server is named and a topic is spelled; the boundary catalog
  # names every namespace it rosters and is read by its own scans.
  @owners ["apps/cyfr/lib/cyfr/bus.ex", "apps/cyfr/lib/cyfr/bus/bounded_dispatcher.ex"] ++
            Cyfr.Boundaries.scan_exclusions()

  @topic_literals ~w("tenant: "sanctum:vault "sanctum:athanor "sanctum:caller "sanctum:sessions
                     "sanctum:memberships "platform:notify "health_check: "room_feed:
                     "topbar:viewing "page: "bus: "thread: "execution:events "progress:
                     "cyfr:schedule_completions)

  @retired [
    "{:execution_started,",
    "{:execution_completed,",
    "{:execution_failed,",
    "{:policy_decision,",
    "{:build_started,",
    "{:build_progress,",
    "{:build_stopped,",
    "{:schedule_fired,",
    "{:schedule_failed,",
    "{:component_installed,",
    "{:component_removed,",
    "{:component_pushed,",
    "{:tincture_invoke_started,",
    "{:tincture_invoke_stopped,",
    "{:tinctures_changed,",
    "{:vault_entry_changed,",
    "{:vault_entry_changed_global,",
    "{:athanor_archived_global,",
    "{:caller_invalidated,",
    "{:session_created,",
    "{:sessions_revoked,",
    "{:membership_changed,",
    "{:notify,",
    "{:register_progress,",
    "{:execution_event,",
    "{:thread,",
    "{:room_in_view,",
    "{:viewing,",
    "{:mcp_progress,",
    ":components_changed",
    ":schedules_updated",
    ":mcp_servers_changed",
    ":webhooks_changed",
    ":api_keys_changed"
  ]

  defp lib_lines do
    for lib <- Prima.Test.SourceTree.app_libs(root()),
        path <- Prima.Test.SourceTree.files!(Path.join([root(), lib, "**/*.ex"])),
        rel = Path.relative_to(path, root()),
        rel not in @owners,
        {line, n} <- Prima.Test.SourceTree.code_lines(path),
        do: {rel, n, line}
  end

  test "the scan reads every lib tree" do
    lines = lib_lines()
    assert length(lines) > 10_000
    assert Enum.any?(lines, fn {rel, _n, _line} -> String.starts_with?(rel, "apps/sanctum/") end)
    assert Enum.any?(lines, fn {rel, _n, _line} -> String.starts_with?(rel, "apps/arca/") end)
  end

  test "no lib tree but the bus names the PubSub server or calls it" do
    found =
      for {rel, n, line} <- lib_lines(),
          line =~ ~r/\bPhoenix\.PubSub\.|\bEmissary\.PubSub\b|\bCyfr\.PubSub\b/,
          # The one process start and the one server name the endpoint reads.
          rel != "apps/cyfr/lib/cyfr/application.ex",
          do: "#{rel}:#{n}: #{String.trim(line)}"

    assert found == []
  end

  test "no lib tree but the bus spells a topic" do
    found =
      for {rel, n, line} <- lib_lines(),
          Enum.any?(@topic_literals, &String.contains?(line, &1)),
          do: "#{rel}:#{n}: #{String.trim(line)}"

    assert found == []
  end

  test "no lib tree sends or matches a retired message shape" do
    found =
      for {rel, n, line} <- lib_lines(),
          Enum.any?(@retired, &String.contains?(line, &1)),
          do: "#{rel}:#{n}: #{String.trim(line)}"

    assert found == []
  end

  test "a planted reach, topic and retired shape are each found" do
    planted = ~S'''
    defmodule Planted do
      def a, do: Phoenix.PubSub.broadcast(Cyfr.PubSub, "tenant:x:bus:executions", :x)
      def b(msg), do: match?({:execution_started, _, _}, msg)
    end
    '''

    lines = Prima.Test.CodeLines.code_lines(planted)

    assert Enum.any?(lines, fn {line, _} -> line =~ ~r/\bPhoenix\.PubSub\./ end)
    assert Enum.any?(lines, fn {line, _} -> String.contains?(line, ~s("tenant:)) end)
    assert Enum.any?(lines, fn {line, _} -> Enum.any?(@retired, &String.contains?(line, &1)) end)
  end

  test "the retired helpers are gone" do
    refute Code.ensure_loaded?(Sanctum.PubSub)
    refute Code.ensure_loaded?(Prism.TelemetryBridge)
    refute function_exported?(Sanctum.Notify, :topic, 1)
    refute function_exported?(Sanctum.Notify, :platform_topic, 0)
    refute function_exported?(Sanctum.Session, :topic, 0)
    refute function_exported?(Sanctum.Tenancy.Members, :topic, 1)
    refute function_exported?(Emissary.MCP.Progress, :emit, 2)
    refute Code.ensure_loaded?(Emissary.MCP.Progress.Registry)
  end
end
