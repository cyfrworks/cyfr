# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.BusPayloadTest do
  @moduledoc """
  Every topic carries exactly one payload struct, and every struct is the
  shape the roster says: a closed kind union its constructor enforces,
  plain values only — no schema, no context, no field the sanitizer would
  redact — and producers and consumers the tree actually has.
  """
  use ExUnit.Case, async: true

  alias Cyfr.Bus

  alias Cyfr.Bus.{
    ApiKeys,
    AthanorArchived,
    Build,
    CallerInvalidated,
    Components,
    Execution,
    ExecutionEvent,
    McpServers,
    Membership,
    Notify,
    Ping,
    PolicyDecision,
    Progress,
    Request,
    RoomInView,
    ScheduleCompleted,
    ScheduleRun,
    Schedules,
    Session,
    ThreadEvent,
    Tinctures,
    VaultEntryChanged,
    Viewing,
    Webhooks
  }

  @actor Prima.Actor.in_athanor("ath_payload")

  # One representative of every struct, built the way its producer builds it.
  defp samples do
    [
      Execution.new(@actor, :failed, execution_id: "e", error: "boom", component_type: :reagent),
      Request.new(@actor, :logged, request_id: "r", method: "tools/call", status: :success),
      Components.new(@actor, :installed, name: "c", version: "1.0.0", publisher: "local"),
      Build.new(@actor, :stopped, build_id: "b", status: :error, error: :timeout),
      ScheduleRun.new(@actor, :failed, schedule_id: "s", reason: "no slot"),
      Tinctures.new(@actor, :invoke_stopped, tincture_ref: "tincture:local.t", status: :ok),
      PolicyDecision.new(@actor, :changed, event_type: "rate_limit", decision: "denied"),
      Webhooks.new(@actor, :changed),
      ApiKeys.new(@actor, :changed),
      McpServers.new(@actor, :changed),
      Schedules.new(@actor, :changed, schedule_id: "s"),
      VaultEntryChanged.new(@actor, :rename, entry_id: "v", name: "new", old_name: "old"),
      Progress.new(@actor, {:pull, "p"}, request_id: "r", phase: :pulling, data: %{"n" => 1}),
      ExecutionEvent.new(@actor, :delta, %{
        type: "emit",
        execution_id: "e",
        sequence: "1.1",
        durable: 1,
        delta: 1,
        timestamp: "2026-09-24T00:00:00Z",
        data: %{"type" => "text.delta", "text" => "hi"},
        origin: "guest",
        node: "reagent:local.x"
      }),
      ThreadEvent.new(@actor, "thr", :message, %{id: "m", kind: "text", content: "hi"}),
      Session.new(:revoked, "u"),
      Membership.new(:changed, "u", "ath_payload", :joined),
      CallerInvalidated.new(:crypto.hash(:sha256, "session")),
      AthanorArchived.new("ath_payload"),
      Notify.new(@actor, :approval_pending, %{thread_id: "t", approval_id: "a"}),
      Ping.new(1),
      Viewing.new("ath_payload"),
      RoomInView.new(%{"athanor_id" => "ath_payload", "thread_id" => "t", "title" => "x"}),
      ScheduleCompleted.new(@actor, %{
        issuer_member: %{node: "a@host", owner: "boot_1", generation: 1},
        schedule_id: "s",
        execution_id: "e",
        occurrence_id: "o",
        completed_at: DateTime.utc_now(),
        keep_outcome: true,
        note_name: "n",
        output: %{"rows" => 42}
      })
    ]
  end

  defp structs, do: Bus.topics() |> Enum.map(& &1.struct) |> Enum.uniq()

  describe "the roster" do
    test "every struct the roster names has a representative here, and none is extra" do
      assert samples() |> Enum.map(& &1.__struct__) |> Enum.sort() == Enum.sort(structs())
    end

    test "each topic carries one struct, and a struct rides one topic but its global twin" do
      shared =
        Bus.topics()
        |> Enum.group_by(& &1.struct, & &1)
        |> Enum.filter(fn {_struct, rows} -> length(rows) > 1 end)
        |> Map.new(fn {struct, rows} -> {struct, rows |> Enum.map(& &1.scope) |> Enum.sort()} end)

      # The two announcements that are one fact said twice: to the athanor,
      # and to the server-wide reader that cannot know every athanor.
      assert shared == %{
               Notify => [:global, :tenant],
               VaultEntryChanged => [:global, :tenant]
             }

      keys = Enum.map(Bus.topics(), & &1.key)
      assert length(Enum.uniq(keys)) == length(keys)
    end

    test "every topic function is in the roster, and every roster key is a function" do
      exported =
        for {name, arity} <- Bus.__info__(:functions),
            arity in [0, 1, 2],
            name not in [
              :topics,
              :global,
              :prefix,
              :broadcast,
              :broadcast_global,
              :broadcast_page,
              :broadcast_progress,
              :subscribe,
              :unsubscribe,
              :subscribe_global,
              :unsubscribe_global,
              :subscribe_page,
              :unsubscribe_page,
              :subscribe_standing,
              :unsubscribe_standing
            ],
            uniq: true,
            do: name

      assert Enum.sort(exported) == Bus.topics() |> Enum.map(& &1.key) |> Enum.sort()
    end

    test "every topic has a scope, a template, a reason, producers and consumers" do
      for row <- Bus.topics() do
        assert row.scope in [:tenant, :global, :page]
        assert is_binary(row.template) and row.template != ""
        assert is_binary(row.reason) and row.reason != ""
        assert roster_gaps(row) == [], "#{row.key}: #{inspect(roster_gaps(row))}"
      end
    end

    test "a topic with no consumer, or no producer, is found" do
      row = %{key: :orphan, struct: Webhooks, producers: [], consumers: []}
      assert roster_gaps(row) == [:no_producer, :no_consumer]
    end

    test "the global rows are global/0, in order" do
      assert Bus.global() ==
               for(%{scope: :global} = row <- Bus.topics(), do: {row.template, row.reason})
    end
  end

  describe "the tree agrees with the roster" do
    test "every consumer names the topic's struct, and every producer builds it" do
      found =
        for row <- Bus.topics(),
            {role, names} <- [consumers: row.consumers, producers: row.producers],
            name <- names,
            source = source_of(name),
            not names?(source, row.struct, role),
            do:
              "#{name} is a #{role |> Atom.to_string() |> String.trim_trailing("s")} of " <>
                "#{row.key} and its source does not #{if role == :producers, do: "build", else: "name"} " <>
                inspect(row.struct)

      assert found == []
    end

    test "a module that never names the struct is reported" do
      refute names?("defmodule X do\n  def a, do: :ok\nend\n", Webhooks, :consumers)
      assert names?("def handle_info(%Cyfr.Bus.Webhooks{}, s), do: s", Webhooks, :consumers)
      assert names?("alias Cyfr.Bus\n%Bus.Webhooks{}", Webhooks, :consumers)
      assert names?("alias Cyfr.Bus.{Notify, Webhooks}\n%Webhooks{}", Webhooks, :consumers)

      assert names?(
               "alias Cyfr.Bus.Webhooks\nWebhooks.new(actor, :changed)",
               Webhooks,
               :producers
             )

      refute names?("alias Cyfr.Bus.Webhooks\n%Webhooks{}", Webhooks, :producers)
      refute names?("Webhooks.new(actor, :changed)", Webhooks, :producers)
    end
  end

  describe "every payload" do
    test "has a closed kind union, and its constructor refuses anything outside it" do
      for module <- structs() do
        kinds = module.kinds()
        assert is_list(kinds) and kinds != [] and Enum.all?(kinds, &is_atom/1)
      end

      for build <- [
            fn -> Execution.new(@actor, :exploded) end,
            fn -> Webhooks.new(@actor, :deleted) end,
            fn -> Notify.new(@actor, :not_a_kind) end,
            fn -> Notify.platform(:not_a_kind) end,
            fn -> Session.new(:minted) end,
            fn -> Membership.new(:left, "u", nil, :left) end,
            fn -> ThreadEvent.new(@actor, "t", :message_updated, %{}) end,
            fn -> Progress.new(@actor, {:request, "r"}) end,
            fn -> ExecutionEvent.new(@actor, :durable, %{delta: 1}) end
          ] do
        assert_raise ArgumentError, build
      end
    end

    test "a reason or an error is a refusal's class and public sentence, never a term" do
      secret = {:shutdown, %{token: "sk-live-payload"}}
      long = String.duplicate("é", 150)

      ExUnit.CaptureLog.capture_log(fn ->
        for payload <- [
              Execution.new(@actor, :failed, error: secret),
              Build.new(@actor, :stopped, error: secret),
              ScheduleRun.new(@actor, :failed, reason: secret),
              Tinctures.new(@actor, :invoke_stopped, error: secret)
            ] do
          field = if match?(%ScheduleRun{}, payload), do: :reason, else: :error

          assert Map.fetch!(payload, field) ==
                   %{class: :internal, message: "The outcome could not be confirmed."}
        end

        assert %Notify{payload: %{reason: %{class: :internal}}} =
                 Notify.new(@actor, :schedule_failed, %{reason: secret})
      end)

      assert Build.new(@actor, :stopped, error: :timeout).error ==
               %{class: :timeout, message: Prima.Refusal.message(:timeout)}

      # A refusal the bridge already classified keeps its class.
      refusal = %Prima.Refusal{class: :forbidden, reason: :x, message: "Not yours"}

      assert Execution.new(@actor, :failed, error: refusal).error ==
               %{class: :forbidden, message: "Not yours"}

      assert Execution.new(@actor, :completed).error == nil
      assert %{class: :internal, message: cut} = Execution.new(@actor, :failed, error: long).error
      assert byte_size(cut) <= 200 and String.valid?(cut)
    end

    test "a seat change is one of a closed set, and anything else raises" do
      for change <- Membership.changes() do
        assert %Membership{change: ^change} = Membership.new(:changed, "u", nil, change)
      end

      # Built at runtime, as the bridge builds it from telemetry metadata.
      for change <- ["joined", {:joined, "sk"}, :deleted] do
        assert_raise ArgumentError, fn ->
          apply(Membership, :new, [:changed, "u", nil, change])
        end
      end
    end

    test "a tenant payload refuses an actor that names no athanor, and a field it does not declare" do
      assert_raise ArgumentError, fn -> Execution.new(%Prima.Actor{}, :started) end
      assert_raise ArgumentError, fn -> Execution.new(@actor, :started, token: "sk") end
      assert_raise ArgumentError, fn -> Request.new(@actor, :logged, __meta__: :x) end
    end

    test "the tray's kinds are the identity domain's, exactly" do
      assert Notify.kinds() == Sanctum.Notify.kinds()
    end

    test "carries no schema, no context and no field the sanitizer would redact" do
      for module <- structs() do
        fields = module.__struct__() |> Map.from_struct() |> Map.keys()
        refute :__meta__ in fields, "#{inspect(module)} is a schema"

        for field <- fields do
          refute Prima.Sanitizer.sensitive_key?(field),
                 "#{inspect(module)}.#{field} is a field the sanitizer redacts"
        end
      end

      for sample <- samples() do
        refute carries?(sample, &match?(%Sanctum.Context{}, &1)),
               "#{inspect(sample.__struct__)} carries a context"

        refute carries?(sample, &(is_map(&1) and Map.has_key?(&1, :__meta__))),
               "#{inspect(sample.__struct__)} carries a schema"
      end
    end

    test "passes the sanitizer unchanged" do
      for sample <- samples() do
        assert Prima.Sanitizer.sanitize(sample) == sample,
               "#{inspect(sample.__struct__)} is changed by the sanitizer"
      end
    end

    test "names its tenant, from the actor it was built for" do
      for %{athanor_id: athanor_id} = sample <- samples(),
          sample.__struct__ not in [Membership, Viewing],
          do: assert(athanor_id in ["ath_payload", :platform])
    end

    test "a tenant topic refuses another tenant's payload" do
      other = Prima.Actor.in_athanor("ath_other")

      for %{scope: :tenant, key: key, struct: module} <- Bus.topics(),
          sample = Enum.find(samples(), &(&1.__struct__ == module)) do
        topic =
          case key do
            :progress -> Bus.progress(other, {:pull, "p"})
            :execution_events -> Bus.execution_events(other, "e")
            :thread -> Bus.thread(other, "thr")
            _ -> apply(Bus, key, [other])
          end

        assert {:error, :cross_tenant} = Bus.broadcast(@actor, topic, sample),
               "#{key} took #{inspect(module)} from another tenant"
      end
    end
  end

  describe "the schedule completion" do
    test "keeps output only when the schedule asked, encoded and capped" do
      base = %{schedule_id: "s", execution_id: "e", output: %{"a" => 1}}

      assert %{output: nil, truncated: false} =
               ScheduleCompleted.new(@actor, Map.put(base, :keep_outcome, false))

      assert %{output: ~s({"a":1})} =
               ScheduleCompleted.new(@actor, Map.put(base, :keep_outcome, true))

      long = String.duplicate("é", 40_000)

      assert %{output: cut, truncated: true} =
               ScheduleCompleted.new(
                 @actor,
                 %{base | output: long} |> Map.put(:keep_outcome, true)
               )

      assert byte_size(cut) <= ScheduleCompleted.max_output_bytes() and String.valid?(cut)
    end

    test "names its issuer the same way on both sides" do
      slot = %{node: "a", owner: "b", generation: 3, fence: 9, lease_until: DateTime.utc_now()}
      assert ScheduleCompleted.issuer({:ok, slot}) == %{node: "a", owner: "b", generation: 3}
      assert ScheduleCompleted.issuer(:none) == nil
    end
  end

  # ---------------------------------------------------------------------------

  defp roster_gaps(row) do
    Enum.reject(
      [
        if(row.producers == [], do: :no_producer),
        if(row.consumers == [], do: :no_consumer)
      ],
      &is_nil/1
    )
  end

  defp source_of(name) do
    module = Module.concat([name])
    assert Code.ensure_loaded?(module), "#{name} is rostered and does not exist"
    module.module_info(:compile)[:source] |> to_string() |> File.read!()
  end

  # A consumer names the struct in a pattern or a reference; a producer
  # calls its constructor. Either through the full name, `Bus.` under an
  # alias of the bus, or the bare name under an alias that names it.
  defp names?(source, struct, role) do
    short = struct |> Module.split() |> List.last()

    aliased? =
      source =~ ~r/alias Cyfr\.Bus\.\{[^}]*\b#{short}\b/s or source =~ "alias Cyfr.Bus.#{short}"

    bus_aliased? = source =~ ~r/alias Cyfr\.Bus\s*$/m

    spellings =
      ["Cyfr.Bus.#{short}"] ++
        if(bus_aliased?, do: ["Bus.#{short}"], else: []) ++
        if(aliased?, do: [short], else: [])

    case role do
      :consumers ->
        Enum.any?(spellings, &String.contains?(source, "%" <> &1 <> "{"))

      :producers ->
        Enum.any?(spellings, fn spelling ->
          String.contains?(source, spelling <> ".new(") or
            String.contains?(source, spelling <> ".platform(")
        end)
    end
  end

  defp carries?(term, found?) do
    found?.(term) or
      case term do
        %DateTime{} ->
          false

        %_{} = struct ->
          struct |> Map.from_struct() |> Map.values() |> Enum.any?(&carries?(&1, found?))

        %{} = map ->
          Enum.any?(map, fn {k, v} -> carries?(k, found?) or carries?(v, found?) end)

        list when is_list(list) ->
          Enum.any?(list, &carries?(&1, found?))

        tuple when is_tuple(tuple) ->
          tuple |> Tuple.to_list() |> Enum.any?(&carries?(&1, found?))

        _ ->
          false
      end
  end
end
