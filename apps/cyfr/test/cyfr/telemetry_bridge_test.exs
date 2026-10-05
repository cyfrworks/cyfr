# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.TelemetryBridgeTest do
  @moduledoc """
  The one place a telemetry event becomes a bus message.

  The bridge attaches exactly the catalog's `:bridge` roster, turns each
  event into its one payload from the metadata fields the payload names,
  drops and counts a tenant event that names no athanor, forwards no
  arbitrary error term — a reason is its class and public sentence — and
  is never detached by a publish that fails.
  """
  use ExUnit.Case, async: false

  alias Cyfr.Bus

  alias Cyfr.Bus.{
    ApiKeys,
    AthanorArchived,
    Build,
    CallerInvalidated,
    Components,
    Confirmation,
    Execution,
    FileOffer,
    InstanceEntryChanged,
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
  # A confirmation as the stream names it, and the secret its asker alone holds.
  @ref "cnr_RwUmgDNh5ufeCSEze6Mgzs_TKyc4u-HLi4RFA8i9XZ4"
  @secret "cnf_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

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
       Bus.executions(@actor),
       {Execution, %{kind: :failed, error: %{class: :internal, message: "boom"}}}},
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
      {[:cyfr, :crucible, :tincture, :invoke, :start], Map.put(tenant, :request_id, "r1"),
       Bus.tinctures(@actor), {Tinctures, %{kind: :invoke_started, request_id: "r1"}}},
      {[:cyfr, :crucible, :tincture, :invoke, :stop], Map.put(tenant, :status, :error),
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
    ] ++ confirmation_cases(tenant) ++ instance_entry_cases() ++ file_offer_cases()
  end

  # Sending a copy: each transition, a receipt that landed and one the
  # sweep failed, heard on the recipient's own topic as the offer, its
  # kind, its sender and the filename.
  defp file_offer_cases do
    for kind <- ~w(offered accepted declined withdrawn expired failed landed)a do
      {[:cyfr, :arca, :file_offer, kind],
       %{
         offer_id: "ofr_1",
         kind: kind,
         sender_user_id: "usr_sender",
         recipient_user_id: @user,
         filename: "q3.csv"
       }, Bus.file_offers(@user),
       {FileOffer,
        %{kind: kind, offer_id: "ofr_1", from_user_id: "usr_sender", filename: "q3.csv"}}}
    end
  end

  # An instance entry's durable changes, each on the one global topic as
  # its entry id and kind, whatever else the emitter attached.
  defp instance_entry_cases do
    for kind <- InstanceEntryChanged.kinds() do
      {[:cyfr, :sanctum, :instance_entry, kind], %{entry_id: "ine_1", kind: kind, user_id: @user},
       Bus.instance_entries(), {InstanceEntryChanged, %{kind: kind, entry_id: "ine_1"}}}
    end
  end

  # A pending confirmation's life, each on its person's own topic, carrying
  # the ref, operation and expiry and nothing else the emitter attached:
  # never a secret id.
  defp confirmation_cases(tenant) do
    expires_at = ~U[2026-09-30 12:05:00Z]

    metadata =
      Map.merge(tenant, %{
        user_id: @user,
        ref: @ref,
        id: @secret,
        operation: "vault.create",
        expires_at: expires_at,
        arguments: %{"fields" => %{"API_KEY" => "sk-never-bridged"}}
      })

    for kind <- [:opened, :confirmed, :consumed, :cancelled, :voided, :expired] do
      {[:cyfr, :sanctum, :confirmation, kind], metadata, Bus.confirmations(@actor, @user),
       {Confirmation,
        %{
          kind: kind,
          ref: @ref,
          operation: "vault.create",
          expires_at: expires_at
        }}}
    end
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

  # A listener of its own on the global `topic`, which hands the test what
  # it hears tagged with the topic, so a test hearing several knows which
  # one a message came by.
  defp relay(topic) do
    test = self()

    pid =
      spawn(fn ->
        :ok = Bus.subscribe_global(topic)
        send(test, {:relaying, topic})
        relay_loop(test, topic)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:relaying, ^topic}
  end

  defp relay_loop(test, topic) do
    receive do
      message ->
        send(test, {:heard, topic, message})
        relay_loop(test, topic)
    end
  end

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

    test "an instance entry's change carries its id and kind and nothing else" do
      listen(Bus.instance_entries())

      :telemetry.execute([:cyfr, :sanctum, :instance_entry, :policy], %{count: 1}, %{
        entry_id: "ine_policy",
        kind: :policy,
        user_id: @user,
        component_policy: "any",
        binding_digest: "sha256:digest",
        nodes: ["catalyst:local.openai:1.4.0"],
        fields: %{"API_KEY" => "sk-instance-never-bridged"}
      })

      assert_receive %InstanceEntryChanged{} = heard

      assert Map.from_struct(heard) == %{kind: :policy, entry_id: "ine_policy"}
      refute inspect(heard) =~ "sk-instance"
      refute inspect(heard) =~ @user
      refute inspect(heard) =~ "sha256"

      # Published once, on the one global topic.
      refute_receive %InstanceEntryChanged{}, 100
    end

    test "an instance entry event naming no entry, or another kind, is dropped and counted" do
      count_drops(self())
      listen(Bus.instance_entries())
      event = [:cyfr, :sanctum, :instance_entry, :caps]

      for metadata <- [%{kind: :caps}, %{entry_id: "", kind: :caps}, %{entry_id: "i", kind: :x}] do
        :telemetry.execute(event, %{count: 1}, metadata)
        assert_receive {:dropped, %{count: 1}, %{event: ^event}}
      end

      refute_receive %InstanceEntryChanged{}, 100
    end

    test "an offer's transition reaches both its people, and a receipt that failed or landed " <>
           "its recipient alone" do
      people = ["usr_sender", "usr_recipient", "usr_other"]
      for person <- people, do: relay(Bus.file_offers(person))

      metadata = %{
        offer_id: "ofr_both",
        sender_user_id: "usr_sender",
        recipient_user_id: "usr_recipient",
        filename: "q3.csv",
        digest: "sha256:never-bridged",
        content: "the bytes, never bridged"
      }

      expected = fn kind ->
        %{offer_id: "ofr_both", kind: kind, from_user_id: "usr_sender", filename: "q3.csv"}
      end

      for kind <- [:offered, :accepted, :declined, :withdrawn, :expired] do
        :telemetry.execute(
          [:cyfr, :arca, :file_offer, kind],
          %{system_time: 1},
          Map.put(metadata, :kind, kind)
        )

        for person <- ["usr_sender", "usr_recipient"] do
          topic = Bus.file_offers(person)
          assert_receive {:heard, ^topic, heard}
          assert Map.from_struct(heard) == expected.(kind), "#{kind} on #{person}'s topic"
        end

        refute_receive {:heard, _topic, _message}, 50
      end

      # The sender's offer is already accepted; the receipt is the recipient's.
      recipient = Bus.file_offers("usr_recipient")

      for kind <- [:failed, :landed] do
        :telemetry.execute(
          [:cyfr, :arca, :file_offer, kind],
          %{system_time: 1},
          Map.put(metadata, :kind, kind)
        )

        assert_receive {:heard, ^recipient, heard}
        assert Map.from_struct(heard) == expected.(kind)
        refute_receive {:heard, _topic, _message}, 100
      end
    end

    test "a file offer event naming no person, or another kind, is dropped and counted" do
      count_drops(self())
      relay(Bus.file_offers("usr_recipient"))
      event = [:cyfr, :arca, :file_offer, :offered]

      complete = %{
        offer_id: "ofr_drop",
        kind: :offered,
        sender_user_id: "usr_sender",
        recipient_user_id: "usr_recipient",
        filename: "a.txt"
      }

      for metadata <- [
            Map.delete(complete, :sender_user_id),
            %{complete | recipient_user_id: ""},
            %{complete | kind: :failed}
          ] do
        :telemetry.execute(event, %{system_time: 1}, metadata)
        assert_receive {:dropped, %{count: 1}, %{event: ^event}}
      end

      refute_receive {:heard, _topic, _message}, 100
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
        error: %{class: :internal, message: "cancelled"}
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

    test "an arbitrary error term reaches no payload, only its class and the fixed sentence" do
      listen(Bus.schedule_runs(@actor))
      listen(Bus.notify(@actor))
      listen(Bus.executions(@actor))
      secret = {:shutdown, %{token: "sk-live-bridge"}}

      :telemetry.execute([:cyfr, :schedules, :failed], %{}, %{
        athanor_id: @athanor,
        schedule_id: "s_err",
        reason: secret
      })

      unconfirmed = %{class: :internal, message: "The outcome could not be confirmed."}
      assert_receive %ScheduleRun{kind: :failed, reason: ^unconfirmed}
      assert_receive %Notify{kind: :schedule_failed, payload: %{reason: ^unconfirmed}}

      :telemetry.execute([:cyfr, :opus, :execute, :exception], %{}, %{
        athanor_id: @athanor,
        execution_id: "e_err",
        parent_execution_id: "p",
        error: secret
      })

      assert_receive %Execution{kind: :failed, error: ^unconfirmed}
    end

    test "an authorization reason is classed by its own vocabulary" do
      listen(Bus.schedule_runs(@actor))

      :telemetry.execute([:cyfr, :schedules, :failed], %{}, %{
        athanor_id: @athanor,
        schedule_id: "s_denied",
        reason: {:missing_permission, :execute}
      })

      message = Sanctum.Unauthorized.message({:missing_permission, :execute})
      assert_receive %ScheduleRun{kind: :failed, reason: %{class: :forbidden, message: ^message}}
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

    test "a confirmation reaches its own person alone, with no argument and no preview" do
      listen(Bus.confirmations(@actor, @user))
      listen(Bus.confirmations(@actor, "user_other"))

      :telemetry.execute([:cyfr, :sanctum, :confirmation, :opened], %{count: 1}, %{
        athanor_id: @athanor,
        user_id: @user,
        ref: @ref,
        id: @secret,
        operation: "vault.create",
        expires_at: ~U[2026-09-30 12:05:00Z],
        arguments: %{"fields" => %{"API_KEY" => "sk-confirmed"}},
        preview: %{"resource" => "production-key"}
      })

      assert_receive %Confirmation{kind: :opened, ref: @ref} = heard
      refute inspect(heard) =~ "sk-confirmed"
      refute inspect(heard) =~ "production-key"
      refute inspect(heard) =~ @secret
      refute Map.has_key?(heard, :id)

      # Published once, on the person's own topic: another member hears nothing.
      refute_receive %Confirmation{}, 100
    end

    test "Sanctum's announcement of a confirmation is what the bridge carries, kind by kind" do
      listen(Bus.confirmations(@actor, @user))
      expires_at = ~U[2026-09-30 12:05:00Z]
      fields = %{ref: @ref, operation: "vault.create", expires_at: expires_at}

      for kind <- Cyfr.Bus.Confirmation.kinds() do
        :ok = Sanctum.Telemetry.confirmation(kind, @athanor, @user, fields)

        assert_receive %Confirmation{
          kind: ^kind,
          athanor_id: @athanor,
          ref: @ref,
          operation: "vault.create",
          expires_at: ^expires_at
        }
      end

      assert_raise FunctionClauseError, fn ->
        Sanctum.Telemetry.confirmation(:approved, @athanor, @user, fields)
      end
    end

    test "a confirmation naming no person is dropped and counted" do
      count_drops(self())

      :telemetry.execute([:cyfr, :sanctum, :confirmation, :opened], %{count: 1}, %{
        athanor_id: @athanor,
        ref: @ref
      })

      assert_receive {:dropped, %{count: 1}, %{event: [:cyfr, :sanctum, :confirmation, :opened]}}
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
    setup tags do
      Cyfr.Test.Sandbox.setup!(tags)
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
