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
    Confirmation,
    Execution,
    ExecutionEvent,
    FeedPublished,
    FeedRun,
    FileOffer,
    FrameCredential,
    LayoutPublished,
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
    SettingsChanged,
    ShareChanged,
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
      ScheduleRun.new(@actor, :failed,
        schedule_id: "s",
        occurrence_id: "o",
        scheduled_for: ~U[2026-10-27 09:00:00Z],
        reason: "no slot"
      ),
      FeedRun.new(@actor, :fired, binding: "feed_1", occurrence_id: "o", execution_id: "e"),
      Tinctures.new(@actor, :invoke_stopped, tincture_ref: "tincture:local.t", status: :ok),
      PolicyDecision.new(@actor, :changed, event_type: "rate_limit", decision: "denied"),
      Webhooks.new(@actor, :changed),
      ApiKeys.new(@actor, :changed),
      McpServers.new(@actor, :changed),
      Schedules.new(@actor, :removed,
        schedule_id: "s",
        name: "nightly",
        reference: "reagent:local.x",
        cron_expression: "0 3 * * *",
        status: "paused",
        next_run_at: ~U[2026-10-28 03:00:00Z],
        last_run_at: nil,
        run_count: 2,
        error_count: 1
      ),
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
      LayoutPublished.new(@actor, "usr_1", 4),
      FeedPublished.new(@actor, feed_envelope()),
      Confirmation.new(@actor, :opened,
        ref: "cnr_RwUmgDNh5ufeCSEze6Mgzs_TKyc4u-HLi4RFA8i9XZ4",
        operation: "vault.create",
        expires_at: ~U[2026-09-30 12:05:00Z]
      ),
      Session.new(:revoked, "u"),
      SettingsChanged.new(:changed, setting: "log_level", revision: 3, op: :put, value: "debug"),
      Membership.new(:changed, "u", "ath_payload", :joined),
      CallerInvalidated.new(:crypto.hash(:sha256, "session")),
      AthanorArchived.new("ath_payload"),
      ShareChanged.new(:revoked, "shr_payload"),
      FileOffer.new(:offered, "ofr_payload", "usr_sender", "q3.csv"),
      FrameCredential.new(:revoked, "usr_payload", "fcr_payload"),
      Notify.new(@actor, :approval_pending, %{thread_id: "t", approval_id: "a"}),
      Ping.new(1),
      Viewing.new("ath_payload"),
      RoomInView.new(%{"athanor_id" => "ath_payload", "thread_id" => "t", "title" => "x"}),
      ScheduleCompleted.new(@actor)
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
              :subscribe_standing,
              :unsubscribe_standing,
              # Lookups over the roster a stream grant is checked and
              # resolved through, not topics.
              :topic?,
              :grantable?,
              :granted_topic
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

    test "a person's confirmations are heard through their stream alone" do
      row = Enum.find(Bus.topics(), &(&1.key == :confirmations))
      assert row.consumers == ["stream:confirmation.changes"]
      assert row.reason =~ "kind"
    end
  end

  describe "the tree agrees with the roster" do
    test "a consumer that is a stream is a declared stream riding the topic" do
      for row <- Bus.topics(), "stream:" <> name <- row.consumers do
        assert {:ok, stream} = Prima.Provider.fetch_stream(Sanctum.Catalog.streams(), name),
               "#{row.key} names the stream #{name}, which no provider declares"

        assert stream.topic == row.key, "#{name} rides #{inspect(stream.topic)}, not #{row.key}"
      end
    end

    test "every consumer names the topic's struct, and every producer builds it" do
      found =
        for row <- Bus.topics(),
            {role, names} <- [consumers: row.consumers, producers: row.producers],
            name <- names,
            # A stream's grant holder hears the topic through the stream
            # delivery, which matches the roster's struct for the topic.
            not String.starts_with?(name, "stream:"),
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
            fn -> ExecutionEvent.new(@actor, :durable, %{delta: 1}) end,
            fn -> ShareChanged.new(:policy, "shr_1") end,
            fn -> ShareChanged.new(:revoked, "") end,
            fn -> ShareChanged.new(:revoked, nil) end,
            fn -> FileOffer.new(:lost, "ofr_1", "usr_1", "a.txt") end,
            fn -> FileOffer.new(:offered, "", "usr_1", "a.txt") end,
            fn -> FileOffer.new(:offered, "ofr_1", nil, "a.txt") end,
            fn -> FileOffer.new(:offered, "ofr_1", "usr_1", nil) end
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
              FeedRun.new(@actor, :failed, reason: secret),
              Tinctures.new(@actor, :invoke_stopped, error: secret)
            ] do
          field =
            if is_struct(payload, ScheduleRun) or is_struct(payload, FeedRun),
              do: :reason,
              else: :error

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
      for change <- [:joined, :left, :athanor_changed, :platform_granted] do
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
            :layouts -> Bus.layouts(other, "usr_1")
            :confirmations -> Bus.confirmations(other, "usr_1")
            _ -> apply(Bus, key, [other])
          end

        assert {:error, :cross_tenant} = Bus.broadcast(@actor, topic, sample),
               "#{key} took #{inspect(module)} from another tenant"
      end
    end
  end

  describe "a share's change" do
    test "is its share id and kind, and nothing a page could read a share from" do
      fields = ShareChanged.new(:caps, "shr_1") |> Map.from_struct() |> Map.keys()
      assert Enum.sort(fields) == [:kind, :share_id]

      # The kinds are the one list the emitter and the catalog read.
      assert ShareChanged.kinds() == Prima.ShareKinds.all()

      assert Enum.sort(ShareChanged.kinds()) ==
               Enum.sort(~w(created audience caps rebound rotated revoked)a)

      for kind <- Prima.ShareKinds.all() do
        assert %ShareChanged{kind: ^kind, share_id: "shr_1"} = ShareChanged.new(kind, "shr_1")
      end

      row = Enum.find(Bus.topics(), &(&1.key == :shares))

      assert {row.scope, row.template, row.struct, row.producers, row.consumers} ==
               {:global, "sanctum:shares", ShareChanged, ["Cyfr.TelemetryBridge"],
                ["PrismWeb.VaultLive"]}

      assert Bus.shares() == "sanctum:shares"
      assert row.reason =~ "recipients live in other athanors"
      assert row.reason =~ "under its own context"
    end
  end

  describe "a feed's publication" do
    test "is the envelope's seven fields, and nothing of the binding's arguments or reference" do
      published = FeedPublished.new(@actor, feed_envelope())
      fields = published |> Map.from_struct() |> Map.keys() |> Enum.sort()

      assert fields ==
               Enum.sort(~w(athanor_id kind binding feed revision at result label actions)a)

      assert FeedPublished.kinds() == [:published]

      assert %FeedPublished{kind: :published, feed: "btc", revision: 3, result: %{"price" => 1}} =
               published

      # An envelope missing one of its fields builds nothing, and the
      # refusal names none of the envelope's values.
      for broken <- [Map.delete(feed_envelope(), "result"), %{"result" => "SECRET"}, nil] do
        error = assert_raise ArgumentError, fn -> FeedPublished.new(@actor, broken) end
        refute error.message =~ "SECRET"
        refute error.message =~ "btc"
        refute error.message =~ "price"
      end

      row = Enum.find(Bus.topics(), &(&1.key == :feeds))

      assert {row.scope, row.template, row.struct, row.producers, row.consumers} ==
               {:tenant, "tenant:<athanor_id>:bus:feeds", FeedPublished,
                ["Opus.Feeds", "Opus.Schedules.Scheduler"],
                ["stream:feed.results", "PrismWeb.SchedulesLive"]}

      assert "stream:runs.changes" in Enum.find(Bus.topics(), &(&1.key == :executions)).consumers
    end
  end

  describe "a schedule's payloads" do
    test "a schedule row is its id and the nine columns a canvas reads, and nothing private" do
      fields = Schedules.new(@actor, :changed) |> Map.from_struct() |> Map.keys() |> Enum.sort()

      assert fields ==
               Enum.sort(
                 ~w(athanor_id kind schedule_id name reference cron_expression status next_run_at last_run_at run_count error_count)a
               )

      assert Schedules.kinds() == [:changed, :removed]

      for private <- [:input, :metadata, :profile_id, :resolved_reference, :user_id, :feed_spec] do
        assert_raise ArgumentError, fn -> Schedules.new(@actor, :changed, [{private, "x"}]) end
      end

      row = Enum.find(Bus.topics(), &(&1.key == :schedules))

      assert {row.scope, row.template, row.struct, row.producers, row.consumers} ==
               {:tenant, "tenant:<athanor_id>:bus:schedules", Schedules,
                ["Opus.Schedules.Changes", "Compendium.Cascade"],
                ["PrismWeb.SchedulesLive", "stream:schedules.changes"]}
    end

    test "a schedule's run names its occurrence and due time; a feed's run rides its own topic" do
      fields = ScheduleRun.new(@actor, :fired) |> Map.from_struct() |> Map.keys() |> Enum.sort()

      assert fields ==
               Enum.sort(
                 ~w(athanor_id kind schedule_id occurrence_id execution_id scheduled_for reason)a
               )

      assert ScheduleRun.kinds() == [:fired, :failed]

      for private <- [:reference, :request_id, :user_id, :input, :output] do
        assert_raise ArgumentError, fn -> ScheduleRun.new(@actor, :fired, [{private, "x"}]) end
      end

      runs = Enum.find(Bus.topics(), &(&1.key == :schedule_runs))

      assert {runs.producers, runs.consumers} ==
               {["Cyfr.TelemetryBridge"],
                ["PrismWeb.ActivitiesLive", "PrismWeb.TopbarLive", "stream:schedule_runs.changes"]}

      feeds = Enum.find(Bus.topics(), &(&1.key == :feed_runs))

      assert {feeds.scope, feeds.template, feeds.struct, feeds.producers, feeds.consumers} ==
               {:tenant, "tenant:<athanor_id>:bus:feed_runs", FeedRun, ["Cyfr.TelemetryBridge"],
                ["PrismWeb.ActivitiesLive", "PrismWeb.TopbarLive"]}

      refute Enum.any?(feeds.consumers, &String.starts_with?(&1, "stream:"))
    end
  end

  describe "a file offer's notice" do
    test "is the offer, its kind, its sender and a filename, and nothing of the file" do
      fields =
        FileOffer.new(:failed, "ofr_1", "usr_s", "a.txt") |> Map.from_struct() |> Map.keys()

      assert Enum.sort(fields) == [:filename, :from_user_id, :kind, :offer_id]

      assert Enum.sort(FileOffer.kinds()) ==
               Enum.sort(~w(offered accepted declined withdrawn expired failed landed)a)

      assert %FileOffer{kind: :landed, filename: "a.txt"} =
               FileOffer.new(:landed, "ofr_1", "usr_s", "a.txt")

      row = Enum.find(Bus.topics(), &(&1.key == :file_offers))

      assert {row.scope, row.template, row.struct, row.producers, row.consumers} ==
               {:global, "arca:file_offers:<user_id>", FileOffer, ["Cyfr.TelemetryBridge"],
                ["PrismWeb.FilesLive", "PrismWeb.TopbarLive"]}
    end

    test "rides each person's own topic" do
      assert Bus.file_offers("usr_1") == "arca:file_offers:usr_1"
      refute Bus.file_offers("usr_1") == Bus.file_offers("usr_2")

      for nobody <- ["", nil] do
        assert_raise FunctionClauseError, fn -> apply(Bus, :file_offers, [nobody]) end
      end
    end
  end

  # ---------------------------------------------------------------------------

  # An accepted result's envelope, as `Prima.Feed.envelope/5` builds it.
  defp feed_envelope do
    %{
      "binding" => "feed_01926f4e-8c1a-7b3d-9e2f-1a2b3c4d5e6f",
      "feed" => "btc",
      "revision" => 3,
      "at" => "2026-10-09T00:00:00Z",
      "result" => %{"price" => 1},
      "label" => "Bitcoin",
      "actions" => [%{"name" => "refresh", "label" => "Refresh"}]
    }
  end

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
    module =
      try do
        Module.safe_concat([name])
      rescue
        ArgumentError -> flunk("#{name} is rostered and does not exist")
      end

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
