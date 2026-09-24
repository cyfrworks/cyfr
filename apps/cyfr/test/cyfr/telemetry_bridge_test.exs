# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.TelemetryBridgeTest do
  @moduledoc """
  The one place a telemetry event becomes a bus message.

  The bridge attaches exactly the catalog's `:bridge` roster, turns each
  event into its one payload from the metadata fields the payload names,
  drops and counts a tenant event that names no athanor, forwards no
  arbitrary error term, and is never detached by a publish that fails.
  """
  use ExUnit.Case, async: false

  alias Cyfr.Bus

  alias Cyfr.Bus.{
    ApiKeys,
    AthanorArchived,
    Build,
    CallerInvalidated,
    Components,
    Execution,
    Membership,
    Notify,
    PolicyDecision,
    Request,
    ScheduleRun,
    Session,
    Tinctures,
    VaultEntryChanged,
    Webhooks
  }

  alias Cyfr.Telemetry.Catalog

  @athanor "ath_bridge"
  @actor Prima.Actor.in_athanor(@athanor)
  @user "user_bridge"

  # Every bridged event: the metadata it is emitted with, the topic its
  # message lands on and the message it must be.
  defp cases do
    tenant = %{athanor_id: @athanor}

    [
      {[:cyfr, :opus, :execute, :start], Map.put(tenant, :execution_id, "e1"),
       Bus.executions(@actor), {Execution, %{kind: :started, execution_id: "e1"}}},
      {[:cyfr, :opus, :execute, :stop], Map.merge(tenant, %{execution_id: "e1", duration_ms: 3}),
       Bus.executions(@actor), {Execution, %{kind: :completed, duration_ms: 3}}},
      {[:cyfr, :opus, :execute, :exception], Map.merge(tenant, %{error: "boom"}),
       Bus.executions(@actor), {Execution, %{kind: :failed, error: "boom"}}},
      {[:cyfr, :emissary, :request], Map.put(tenant, :method, "tools/call"), Bus.requests(@actor),
       {Request, %{kind: :logged, method: "tools/call"}}},
      {[:cyfr, :sanctum, :policy, :decision], Map.put(tenant, :decision, "denied"),
       Bus.enforcement(@actor), {PolicyDecision, %{kind: :changed, decision: "denied"}}},
      {[:cyfr, :locus, :build, :start], Map.put(tenant, :build_id, "b1"), Bus.builds(@actor),
       {Build, %{kind: :started, build_id: "b1"}}},
      {[:cyfr, :locus, :build, :progress], Map.put(tenant, :phase, :compiling),
       Bus.builds(@actor), {Build, %{kind: :progress, phase: :compiling}}},
      {[:cyfr, :locus, :build, :stop], Map.put(tenant, :status, :ok), Bus.builds(@actor),
       {Build, %{kind: :stopped, status: :ok}}},
      {[:cyfr, :schedules, :fired], Map.put(tenant, :schedule_id, "s1"),
       Bus.schedule_runs(@actor), {ScheduleRun, %{kind: :fired, schedule_id: "s1"}}},
      {[:cyfr, :schedules, :failed], Map.put(tenant, :schedule_id, "s1"),
       Bus.schedule_runs(@actor), {ScheduleRun, %{kind: :failed, schedule_id: "s1"}}},
      {[:cyfr, :compendium, :component, :install], Map.put(tenant, :name, "c"),
       Bus.components(@actor), {Components, %{kind: :installed, name: "c"}}},
      {[:cyfr, :compendium, :component, :remove], Map.put(tenant, :name, "c"),
       Bus.components(@actor), {Components, %{kind: :removed, name: "c"}}},
      {[:cyfr, :compendium, :component, :push], tenant, Bus.components(@actor),
       {Components, %{kind: :pushed}}},
      {[:cyfr, :emissary, :tincture, :invoke, :start], Map.put(tenant, :request_id, "r1"),
       Bus.tinctures(@actor), {Tinctures, %{kind: :invoke_started, request_id: "r1"}}},
      {[:cyfr, :emissary, :tincture, :invoke, :stop], Map.put(tenant, :status, :error),
       Bus.tinctures(@actor), {Tinctures, %{kind: :invoke_stopped, status: :error}}},
      {[:cyfr, :sanctum, :notify], Map.merge(tenant, %{kind: :member_changed, payload: %{}}),
       Bus.notify(@actor), {Notify, %{athanor_id: @athanor, kind: :member_changed}}},
      {[:cyfr, :sanctum, :caller, :invalidated], %{hash: "key_1"},
       Bus.caller_invalidated_global(), {CallerInvalidated, %{session_key: "key_1"}}},
      {[:cyfr, :sanctum, :session, :created], %{}, Bus.sessions(), {Session, %{kind: :created}}},
      {[:cyfr, :sanctum, :sessions, :revoked], %{user_id: @user}, Bus.sessions(),
       {Session, %{kind: :revoked, user_id: @user}}},
      {[:cyfr, :sanctum, :membership, :changed],
       %{user_id: @user, athanor_id: @athanor, change: :joined}, Bus.memberships(@user),
       {Membership, %{user_id: @user, change: :joined}}},
      {[:cyfr, :sanctum, :vault, :entry_changed],
       Map.merge(tenant, %{entry_id: "v1", verb: :rotate, meta: %{name: "k"}}),
       Bus.vault_changed(@actor),
       {VaultEntryChanged, %{kind: :rotate, entry_id: "v1", name: "k"}}},
      {[:cyfr, :sanctum, :athanor, :archived], tenant, Bus.athanor_archived_global(),
       {AthanorArchived, %{athanor_id: @athanor}}},
      {[:cyfr, :sanctum, :api_keys, :changed], tenant, Bus.api_keys(@actor),
       {ApiKeys, %{kind: :changed}}},
      {[:cyfr, :sanctum, :webhooks, :changed], tenant, Bus.webhooks(@actor),
       {Webhooks, %{kind: :changed}}}
    ]
  end

  defp listen(topic) do
    case topic do
      "tenant:" <> _ -> :ok = Bus.subscribe(@actor, topic)
      _global -> :ok = Bus.subscribe_global(topic)
    end
  end

  # The struct a case names, carrying the fields it names.
  defp matches?(%module{} = heard, {module, fields}),
    do: Enum.all?(fields, fn {key, value} -> Map.get(heard, key) == value end)

  defp matches?(_heard, _expected), do: false

  defp count_drops(test) do
    handler = "bridge-dropped-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:cyfr, :bus, :bridge_dropped],
      fn _event, measurements, metadata, _config ->
        send(test, {:dropped, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  describe "the attachment" do
    test "is exactly the catalog's :bridge roster, one handler each" do
      assert Cyfr.TelemetryBridge.events() == Catalog.consumed_by(:bridge)

      for event <- Catalog.consumed_by(:bridge) do
        ids = event |> :telemetry.list_handlers() |> Enum.map(& &1.id)

        assert Enum.count(ids, &(&1 == Cyfr.TelemetryBridge.handler_id(event))) == 1,
               "#{inspect(event)} is not attached once"
      end
    end

    test "every roster event has its message here, and nothing else does" do
      assert cases() |> Enum.map(&elem(&1, 0)) |> Enum.sort() == Catalog.consumed_by(:bridge)
    end
  end

  describe "one struct per event" do
    test "each event lands on its topic as its payload" do
      for {event, metadata, topic, expected} <- cases() do
        listen(topic)
        :telemetry.execute(event, %{count: 1}, metadata)

        assert_receive heard, 1_000
        assert matches?(heard, expected), "#{inspect(event)} bridged as #{inspect(heard)}"

        # Anything else the same event put on this topic.
        flush()
      end
    end

    test "a root's completion and failure reach the tray; a child's do not" do
      listen(Bus.notify(@actor))

      :telemetry.execute([:cyfr, :opus, :execute, :stop], %{}, %{
        athanor_id: @athanor,
        execution_id: "root",
        reference: "reagent:local.x:1.0.0"
      })

      assert_receive %Notify{kind: :execution_finished, payload: %{execution_id: "root"}}

      :telemetry.execute([:cyfr, :opus, :execute, :exception], %{}, %{
        athanor_id: @athanor,
        execution_id: "child",
        parent_execution_id: "root"
      })

      refute_receive %Notify{}, 100
    end

    test "a vault change reaches the athanor's topic and the global one" do
      listen(Bus.vault_changed(@actor))
      listen(Bus.vault_changed_global())

      :telemetry.execute([:cyfr, :sanctum, :vault, :entry_changed], %{}, %{
        athanor_id: @athanor,
        entry_id: "v2",
        verb: :rename,
        meta: %{name: "new", old_name: "old"}
      })

      assert_receive %VaultEntryChanged{kind: :rename, old_name: "old"}
      assert_receive %VaultEntryChanged{kind: :rename, old_name: "old"}
    end

    test "a notify naming no athanor is the operators'" do
      listen(Bus.platform_notify())

      :telemetry.execute([:cyfr, :sanctum, :notify], %{}, %{
        athanor_id: nil,
        kind: :allowlist_changed,
        payload: %{}
      })

      assert_receive %Notify{athanor_id: :platform, kind: :allowlist_changed}
    end

    test "a cancel reaches the executions topic as a cancel, and the tray not at all" do
      listen(Bus.executions(@actor))
      listen(Bus.notify(@actor))

      record = %Crucible.Record{
        id: "exec_cancelled",
        athanor_id: @athanor,
        user_id: @user,
        reference: "reagent:local.x:1.0.0",
        component_type: :reagent,
        status: :cancelled,
        duration_ms: 7
      }

      :ok = Crucible.Telemetry.execute_cancelled(record, "system")

      assert_receive %Execution{
        kind: :cancelled,
        execution_id: "exec_cancelled",
        error: "cancelled"
      }

      refute_receive %Notify{}, 100
    end
  end

  describe "what the bridge does not forward" do
    test "a tenant event that names no athanor is dropped and counted" do
      count_drops(self())
      listen(Bus.executions(@actor))

      :telemetry.execute([:cyfr, :opus, :execute, :start], %{}, %{execution_id: "nowhere"})

      assert_receive {:dropped, %{count: 1}, %{event: [:cyfr, :opus, :execute, :start]}}
      refute_receive %Execution{}, 100
    end

    test "an arbitrary error term reaches no payload" do
      listen(Bus.schedule_runs(@actor))
      listen(Bus.notify(@actor))
      listen(Bus.executions(@actor))
      secret = {:shutdown, %{token: "sk-live-bridge"}}

      :telemetry.execute([:cyfr, :schedules, :failed], %{}, %{
        athanor_id: @athanor,
        schedule_id: "s_err",
        reason: secret
      })

      assert_receive %ScheduleRun{kind: :failed, reason: "error"}
      assert_receive %Notify{kind: :schedule_failed, payload: %{reason: "error"}}

      :telemetry.execute([:cyfr, :opus, :execute, :exception], %{}, %{
        athanor_id: @athanor,
        execution_id: "e_err",
        parent_execution_id: "p",
        error: secret
      })

      assert_receive %Execution{kind: :failed, error: "error"}
    end

    test "metadata a payload does not name is not carried" do
      listen(Bus.requests(@actor))

      :telemetry.execute([:cyfr, :emissary, :request], %{}, %{
        athanor_id: @athanor,
        method: "tools/call",
        authorization: "Bearer sk-live"
      })

      assert_receive %Request{} = heard
      refute inspect(heard) =~ "sk-live"
    end
  end

  describe "resilience" do
    test "a publish that raises never detaches the handler, and the next event still arrives" do
      listen(Bus.notify(@actor))

      # A kind the tray does not have: the payload refuses it mid-publish.
      :telemetry.execute([:cyfr, :sanctum, :notify], %{}, %{
        athanor_id: @athanor,
        kind: :not_a_kind,
        payload: %{}
      })

      # A payload that is not a map: a function clause that does not match.
      :telemetry.execute([:cyfr, :sanctum, :notify], %{}, %{
        athanor_id: @athanor,
        kind: :member_changed,
        payload: :not_a_map
      })

      handler = Cyfr.TelemetryBridge.handler_id([:cyfr, :sanctum, :notify])
      ids = [:cyfr, :sanctum, :notify] |> :telemetry.list_handlers() |> Enum.map(& &1.id)
      assert handler in ids

      :telemetry.execute([:cyfr, :sanctum, :notify], %{}, %{
        athanor_id: @athanor,
        kind: :member_changed,
        payload: %{}
      })

      assert_receive %Notify{kind: :member_changed}
    end

    test "metadata with a malformed athanor is dropped, not raised" do
      assert :ok =
               Cyfr.TelemetryBridge.handle_event(
                 [:cyfr, :sanctum, :api_keys, :changed],
                 %{},
                 %{athanor_id: 42},
                 nil
               )
    end

    test "an unexpected message is survived" do
      assert {:noreply, %{}} = Cyfr.TelemetryBridge.handle_info(:unexpected, %{})
    end
  end

  describe "a close whose row write did not land" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
      :ok
    end

    test "announces nothing" do
      ctx = Sanctum.TestContext.local()
      actor = Sanctum.Context.actor(ctx)
      :ok = Bus.subscribe(actor, Bus.executions(actor))
      {:ok, grant} = Sanctum.ExecutionStanding.capture(ctx)

      # Admitted nowhere: the terminal write has no running row to close.
      record =
        Crucible.Record.new(ctx, "reagent:local.never-admitted:0.1.0", %{},
          component_type: :reagent,
          grant: grant
        )

      close = %Crucible.Close{
        ctx: ctx,
        record: record,
        limits: Prima.Authority.zero_limits(),
        started: true
      }

      Crucible.Close.complete(close, [], %{"ok" => true}, %{})
      Crucible.Close.fail(close, [], "it failed")

      id = record.id
      refute_receive %Execution{execution_id: ^id}, 200
    end
  end

  defp flush do
    receive do
      _ -> flush()
    after
      50 -> :ok
    end
  end
end
