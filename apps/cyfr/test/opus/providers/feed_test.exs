# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Providers.FeedTest do
  @moduledoc """
  The `feed` tool through the gate, and the two streams it declares.

  A bind pins the installed version, copies the operation's declared
  result shape, authorizes the profile and refuses one whose grant does
  not admit the `schedule` origin; the assistant's ceiling always asks
  before it binds. A list answers bindings, shapes and actions, never
  arguments or values. A press runs under the binding's own profile: a
  `refresh` publishes its accepted result on the athanor's feeds topic
  once the accept committed, a `run` publishes nothing, and a binding id
  that is no longer live refuses, so a control drawn before a rebind
  never presses the new binding. A refused, stale or fenced-off result
  publishes nothing.

  Presses run with the scripted worker service: everything but the
  component is real.
  """

  # Takes a slot through `Arca.ControlPlane` (the process-wide standing
  # record) for the ownership cases, which restore it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.CronSchedule
  alias Opus.Feeds
  alias Opus.Providers.Feed
  alias Cyfr.Bus.FeedPublished
  alias Cyfr.Test.ScriptedWorker
  alias Prima.Test.AuthorityFixtures
  alias Sanctum.Test.ConsentFixtures

  @reference "catalyst:local.markets"
  @pinned "catalyst:local.markets:1.0.0"
  @profile_id "prof_feed_tool"
  @math_wasm_path Path.expand("../../support/test_wasm/math.wasm", __DIR__)

  @price %{
    "type" => "object",
    "fields" => %{"price" => %{"type" => "number"}},
    "required" => ["price"]
  }

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    test_path = Path.join(System.tmp_dir!(), "feed_tool_#{System.unique_integer([:positive])}")
    keys = [cyfr: :locus_runtime_workers, arca: :base_path]
    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)

    Application.put_env(
      :cyfr,
      :locus_runtime_workers,
      ScriptedWorker.workers(@reference, prev[{:cyfr, :locus_runtime_workers}])
    )

    Application.put_env(:arca, :base_path, test_path)
    ctx = Sanctum.TestContext.local(:prism)

    on_exit(fn ->
      Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id)
      File.rm_rf!(test_path)

      for {{app, key}, value} <- prev do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()
    Sanctum.TestContext.ready!(ctx.athanor_id)
    consented!(ctx, published!(ctx))
    {:ok, ctx: ctx, actor: Sanctum.Context.actor(ctx)}
  end

  # ---------------------------------------------------------------------------
  # The declaration
  # ---------------------------------------------------------------------------

  describe "the declaration" do
    test "four operations, with the operation table's kinds, planes and permissions" do
      [tool] = Feed.tools()
      assert tool.name == "feed"
      assert Feed.service() == "opus"

      ops = operations()
      assert Enum.sort(Map.keys(ops)) == ~w(bind list press remove)

      assert {ops["bind"].kind, ops["bind"].planes, ops["bind"].permission} ==
               {:external, [:external, :in_chain], :execute}

      assert {ops["list"].kind, ops["list"].planes, ops["list"].permission} ==
               {:read, [:external, :in_chain], nil}

      assert {ops["remove"].kind, ops["remove"].planes, ops["remove"].permission} ==
               {:write, [:external, :in_chain], :execute}

      assert {ops["press"].kind, ops["press"].planes, ops["press"].permission} ==
               {:execute, [:external], :execute}

      for {_action, op} <- ops do
        assert {op.consent, op.standing, op.resource} == {nil, nil, nil}
      end
    end

    test "each takes the arguments the table names, all required, JSON as a JSON value" do
      args = fn action -> Map.new(operations()[action].args, &{&1.name, &1}) end

      assert Enum.sort(Map.keys(args.("bind"))) ==
               ~w(actions args interval_minutes label name operation profile_id reference)

      assert args.("list") == %{}
      assert Map.keys(args.("remove")) == ["binding"]
      assert Enum.sort(Map.keys(args.("press"))) == ~w(action_name binding)

      for action <- ~w(bind remove press), {_name, arg} <- args.(action) do
        assert arg.required, "#{action}.#{arg.name} is required"
      end

      assert args.("bind")["args"].type == :json
      assert args.("bind")["actions"].type == :json
      assert args.("bind")["interval_minutes"].type == :integer

      for name <- ~w(name label reference profile_id operation),
          do: assert(args.("bind")[name].type == :string)
    end

    test "the provider is rostered after the schedules', and a press never runs from a chain" do
      providers = Application.fetch_env!(:sanctum, :tool_providers)

      assert Enum.find_index(providers, &(&1 == Feed)) ==
               Enum.find_index(providers, &(&1 == Opus.Schedules.Provider)) + 1

      assert {:ok, {Feed, _meta}} = Sanctum.Catalog.lookup("feed")

      for action <- ~w(bind list remove),
          do: assert(Sanctum.Catalog.chain_reachable?("feed", action))

      assert Sanctum.Catalog.in_chain_refused?("feed", "press")
    end

    test "the two streams a canvas reads, each with its shape, refresh and filter" do
      [results, runs] = Feed.streams()

      for stream <- [results, runs] do
        assert Prima.Provider.Stream.valid?(stream), stream.name
        assert stream.deadline_bound == 86_400
        assert {:ok, {Feed, ^stream}} = Sanctum.Catalog.lookup_stream(stream.name)
      end

      assert {results.name, results.topic, results.filter, results.refresh} ==
               {"feed.results", :feeds, "feed", {Feeds, :latest}}

      assert results.subject == ~S"\A[a-z0-9][a-z0-9-]{0,47}\z"
      assert results.projection == ~w(binding feed revision at result label actions)
      assert Enum.sort(results.shape["required"]) == Enum.sort(results.projection)

      assert {runs.name, runs.topic, runs.subject, runs.filter, runs.refresh} ==
               {"runs.changes", :executions, nil, nil, {Feed, :recent_runs}}

      assert runs.projection ==
               ~w(kind execution_id parent_execution_id reference component_type duration_ms error)

      assert runs.shape["fields"]["kind"]["values"] == ~w(started completed failed cancelled)
    end
  end

  # ---------------------------------------------------------------------------
  # bind
  # ---------------------------------------------------------------------------

  describe "bind" do
    test "pins the installed version, copies the declared result shape, and answers no arguments",
         %{ctx: ctx, actor: actor} do
      assert {:ok, answer} = call(ctx, bind_args("btc"))

      assert answer |> Map.keys() |> Enum.sort() ==
               ~w(actions binding feed interval_minutes label)a

      assert %{feed: "btc", label: "Feed btc", interval_minutes: 5} = answer

      assert answer.actions == [
               %{name: "refresh", label: "Refresh", kind: "refresh"},
               %{name: "buy", label: "Buy", kind: "run"}
             ]

      refute inspect(answer) =~ "SECRET"

      assert {:ok, row} = CronSchedule.get_feed(actor, answer.binding)

      assert {row.resolved_reference, row.profile_id, row.reference} ==
               {@pinned, @profile_id, @reference}

      {:ok, shape} = Prima.Canvas.Shape.validate(@price)
      assert {:ok, feeds} = Feeds.list(ctx)

      assert %{binding: %{result_shape: ^shape}} =
               Enum.find(feeds, &(&1.binding_id == answer.binding))
    end

    test "bind refuses a consent that does not admit schedule", %{ctx: ctx, actor: actor} do
      head = ConsentFixtures.regrant_origins!(ctx, @profile_id, [:interactive])

      assert %Prima.Refusal{class: :consent_required, reason: reason} =
               refused(call(ctx, bind_args("btc")))

      assert reason ==
               {:consent_required,
                %{profile_id: @profile_id, current_revision: head.revision, shape_diff: []}}

      assert {:ok, []} = CronSchedule.list_feeds(actor)
    end

    test "an in-chain bind is never admitted without an approval" do
      # External in kind: no policy makes it automatic, and no standing
      # allow is ever taken for it, so each in-chain bind waits on a
      # person's approval of that call.
      assert Aqua.Kinds.kind_for("feed", "bind") == :external
      refute Aqua.Kinds.auto_permitted?("feed", "bind")

      allow = %{scope: "athanor", effect: "allow", tool: "feed", action: "bind"}

      assert {:error, _not_standing} =
               Sanctum.ToolGrants.check_standing(allow, DateTime.utc_now())

      assert Aqua.ToolGrants.resolve(%{"feed.bind" => "auto"}, [])["feed.bind"] == "ask"
      assert Aqua.ToolGrants.resolve(%{"feed.*" => "auto"}, [allow])["feed.bind"] == "ask"
    end

    test "refuses an uninstalled reference, an operation with no declared result, and a binding " <>
           "its grammar refuses, binding nothing",
         %{ctx: ctx, actor: actor} do
      assert %Prima.Refusal{class: :not_found, message: missing} =
               refused(call(ctx, bind_args("btc", %{"reference" => "catalyst:local.nothere"})))

      assert missing == "Component not found: catalyst:local.nothere"

      assert %Prima.Refusal{class: :invalid_argument, message: undeclared} =
               refused(call(ctx, bind_args("btc", %{"operation" => "sell"})))

      assert undeclared == "sell declares no result shape"

      for {overrides, sentence} <- [
            {%{"interval_minutes" => 7}, "/interval_minutes: enum"},
            {%{"name" => "BTC"}, "/name: name"},
            {%{"args" => ["SECRET"]}, "/args: type"},
            {%{"actions" => [%{"name" => "x", "label" => "X", "kind" => "fly"}]},
             "/actions/0/kind: enum"},
            {%{"reference" => @pinned}, "/reference: reference"}
          ] do
        assert %Prima.Refusal{class: :invalid_argument, message: ^sentence} =
                 refused(call(ctx, bind_args("btc", overrides))),
               inspect(overrides)
      end

      assert {:ok, []} = CronSchedule.list_feeds(actor)
    end

    test "refuses a profile of another component, a name a live feed holds and one past the cap",
         %{ctx: ctx, actor: actor} do
      other = ConsentFixtures.bindable_profile(ctx, "catalyst:local.elsewhere")

      assert %Prima.Refusal{class: :invalid_argument, message: other_profile} =
               refused(call(ctx, bind_args("btc", %{"profile_id" => other})))

      assert other_profile == "profile binding refused: the profile belongs to another component"

      assert {:ok, _} = call(ctx, bind_args("btc"))

      assert %Prima.Refusal{class: :conflict, message: "a live feed is named btc"} =
               refused(call(ctx, bind_args("btc")))

      Cyfr.Test.Settings.put("max_feeds_per_athanor", 3)
      for i <- 2..3, do: {:ok, _} = call(ctx, bind_args("feed-#{i}"))

      assert %Prima.Refusal{class: :forbidden, reason: :feed_cap, message: capped} =
               refused(call(ctx, bind_args("feed-4")))

      assert capped ==
               "This athanor holds 3 live feeds, the most it may; " <>
                 "remove one to bind another (feed_cap)"

      assert {:ok, 3} = Arca.Test.CronSlots.occupied(actor, "feed")
    end

    test "the feed ceiling is the operator's setting: 1,000 unset, and 0 removes it",
         %{ctx: ctx, actor: actor} do
      assert {:ok, %{default: 1_000}} =
               Cyfr.Platform.Settings.Roster.fetch("max_feeds_per_athanor")

      assert {:ok, 1_000} = Arca.PlatformSettings.effective("max_feeds_per_athanor")

      Cyfr.Test.Settings.put("max_feeds_per_athanor", 1)
      assert {:ok, _} = call(ctx, bind_args("feed-1"))
      assert %Prima.Refusal{reason: :feed_cap} = refused(call(ctx, bind_args("feed-2")))

      Cyfr.Test.Settings.put("max_feeds_per_athanor", 0)
      for i <- 2..3, do: assert({:ok, _} = call(ctx, bind_args("feed-#{i}")))
      assert {:ok, 3} = Arca.Test.CronSlots.occupied(actor, "feed")
    end

    test "a feed ceiling the store cannot answer refuses the bind", %{ctx: ctx} do
      Cyfr.Test.Settings.expire("max_feeds_per_athanor")
      Cyfr.Test.Settings.break_store!()

      assert %Prima.Refusal{class: :unavailable} = refused(call(ctx, bind_args("btc")))
    end

    # A profile list or a head the store cannot answer, and a profile row
    # or a head stored damaged: each in the binding's own class and
    # sentence (`Sanctum.Consent.RegistrationBinding.refusal/1`), the class
    # the gate records, and nothing bound.
    @tag :capture_log
    test "a profile list the store cannot answer refuses unavailable", %{ctx: ctx, actor: actor} do
      Arca.Repo.query!("ALTER TABLE profiles RENAME TO profiles_unavailable")

      binding_refused!(
        ctx,
        :unavailable,
        "the component's profiles cannot be read right now — try again"
      )

      Arca.Repo.query!("ALTER TABLE profiles_unavailable RENAME TO profiles")
      assert {:ok, []} = CronSchedule.list_feeds(actor)
    end

    @tag :capture_log
    test "a head the store cannot answer refuses unavailable", %{ctx: ctx, actor: actor} do
      Arca.Repo.query!("ALTER TABLE consents RENAME TO consents_unavailable")

      binding_refused!(
        ctx,
        :unavailable,
        "the profile's consent cannot be read right now — try again"
      )

      Arca.Repo.query!("ALTER TABLE consents_unavailable RENAME TO consents")
      assert {:ok, []} = CronSchedule.list_feeds(actor)
    end

    test "a profile row stored damaged refuses corrupt", %{ctx: ctx, actor: actor} do
      {1, _} =
        Arca.Repo.update_all(
          from(p in Arca.Schemas.Profile,
            where: p.athanor_id == ^ctx.athanor_id and p.id == @profile_id
          ),
          set: [kind: "sideways"]
        )

      binding_refused!(
        ctx,
        :corrupt,
        "the profile is damaged and cannot be used — revoke profile #{@profile_id} and grant it again"
      )

      assert {:ok, []} = CronSchedule.list_feeds(actor)
    end

    test "a head stored damaged refuses corrupt", %{ctx: ctx, actor: actor} do
      :ok = ConsentFixtures.hand_edit_head!(ctx, @profile_id, scope: "sideways")

      binding_refused!(
        ctx,
        :corrupt,
        "the profile's consent is damaged and cannot be used — " <>
          "revoke profile #{@profile_id} and grant it again"
      )

      assert {:ok, []} = CronSchedule.list_feeds(actor)
    end

    test "refuses a member that lost its slot, creating nothing", %{ctx: ctx, actor: actor} do
      slot = claimant!()
      take_over!(slot)

      assert %Prima.Refusal{class: :not_owner} = refused(call(ctx, bind_args("btc")))
      assert {:ok, []} = CronSchedule.list_feeds(actor)
    end
  end

  # ---------------------------------------------------------------------------
  # list and remove
  # ---------------------------------------------------------------------------

  describe "list" do
    test "answers each live feed's binding, shape, actions and revision, never arguments or values",
         %{ctx: ctx, actor: actor} do
      {:ok, %{binding: btc}} = call(ctx, bind_args("btc"))
      {:ok, %{binding: eth}} = call(ctx, bind_args("eth"))
      {:ok, slot} = Arca.ControlPlane.member_slot()
      {:ok, 1} = CronSchedule.claim_feed_seq(actor, eth)
      {:ok, _envelope} = Feeds.accept(ctx, eth, 1, envelope(%{"price" => 9_876.5}), slot)

      assert {:ok, %{feeds: [first, second]}} = call(ctx, %{"action" => "list"})
      {:ok, shape} = Prima.Canvas.Shape.validate(@price)

      assert %{
               binding: ^btc,
               feed: "btc",
               label: "Feed btc",
               reference: @reference,
               operation: "quote",
               interval_minutes: 5,
               result_shape: ^shape,
               revision: 0,
               at: nil
             } = first

      assert %{binding: ^eth, feed: "eth", revision: 1, at: at} = second
      assert {:ok, _at, 0} = DateTime.from_iso8601(at)

      assert first.actions == [
               %{name: "refresh", label: "Refresh", kind: "refresh"},
               %{name: "buy", label: "Buy", kind: "run"}
             ]

      assert first |> Map.keys() |> Enum.sort() ==
               ~w(actions at binding feed interval_minutes label operation reference result_shape revision)a

      refute inspect([first, second]) =~ "SECRET"
      refute inspect([first, second]) =~ "9876.5"
    end
  end

  describe "remove" do
    test "removes a live feed, and refuses an id that is no live binding of the athanor", %{
      ctx: ctx,
      actor: actor
    } do
      {:ok, %{binding: id}} = call(ctx, bind_args("btc"))

      assert {:ok, %{removed: true, binding: ^id, feed: "btc"}} =
               call(ctx, %{"action" => "remove", "binding" => id})

      assert {:error, :not_found} = CronSchedule.get_feed(actor, id)

      assert %Prima.Refusal{class: :not_found, message: message} =
               refused(call(ctx, %{"action" => "remove", "binding" => id}))

      assert message == "Feed not found: #{id}"

      {:ok, %{binding: kept}} = call(ctx, bind_args("eth"))

      assert %Prima.Refusal{class: :not_found} =
               refused(call(foreign(ctx), %{"action" => "remove", "binding" => kept}))

      assert {:ok, %{status: "active"}} = CronSchedule.get_feed(actor, kept)
    end
  end

  # ---------------------------------------------------------------------------
  # press
  # ---------------------------------------------------------------------------

  describe "press" do
    test "a refresh press publishes through the fence", %{ctx: ctx, actor: actor} do
      script!([%{"price" => 7.5}])
      watch_feeds(actor)
      {:ok, %{binding: id}} = call(ctx, bind_args("btc"))

      assert {:ok, %{binding: ^id, action: "refresh", revision: 1}} = press(ctx, id, "refresh")

      assert_received %FeedPublished{binding: ^id, feed: "btc", revision: 1} = published
      assert published.result == %{"price" => 7.5}
      refute inspect(published) =~ "SECRET"

      assert {:ok, %{feed_fire_seq: 1, feed_result_seq: 1}} = CronSchedule.get_feed(actor, id)

      # The binding's operation and arguments ran, under its own profile and
      # pinned version.
      assert [%{input: input}] = ScriptedWorker.calls()
      assert input == %{"operation" => "quote", "params" => %{"symbol" => "SECRET-btc"}}
    end

    test "a run press publishes nothing", %{ctx: ctx, actor: actor} do
      script!([%{"ordered" => "SECRET-RECEIPT"}])
      watch_feeds(actor)
      {:ok, %{binding: id}} = call(ctx, bind_args("btc"))

      assert {:ok, answer} = press(ctx, id, "buy")

      assert %{binding: ^id, action: "buy", status: "completed", execution_id: "exec_" <> _} =
               answer

      refute inspect(answer) =~ "SECRET"

      assert [%{input: input}] = ScriptedWorker.calls()
      assert input == %{"operation" => "buy", "params" => %{"qty" => "SECRET-QTY"}}

      refute_received %FeedPublished{}

      assert {:ok, %{feed_fire_seq: 0, feed_result_seq: 0, feed_result: nil}} =
               CronSchedule.get_feed(actor, id)
    end

    test "after a rebind with different arguments, a press naming the old binding refuses", %{
      ctx: ctx,
      actor: actor
    } do
      script!([%{"price" => 1.0}])
      watch_feeds(actor)
      {:ok, %{binding: old}} = call(ctx, bind_args("btc"))
      {:ok, _} = call(ctx, %{"action" => "remove", "binding" => old})

      {:ok, %{binding: new}} =
        call(ctx, bind_args("btc", %{"args" => %{"symbol" => "SECRET-other"}}))

      refute new == old

      assert %Prima.Refusal{class: :not_found, message: message} =
               refused(press(ctx, old, "refresh"))

      assert message == "Feed not found: #{old}"
      assert ScriptedWorker.calls() == []
      refute_received %FeedPublished{}
      assert {:ok, %{feed_fire_seq: 0}} = CronSchedule.get_feed(actor, new)
    end

    test "refuses an unknown action and another athanor's binding, running nothing", %{ctx: ctx} do
      script!([%{"price" => 1.0}])
      {:ok, %{binding: id}} = call(ctx, bind_args("btc"))

      assert %Prima.Refusal{class: :not_found, message: "Action not found: sell"} =
               refused(press(ctx, id, "sell"))

      assert %Prima.Refusal{class: :not_found, message: message} =
               refused(press(foreign(ctx), id, "refresh"))

      assert message == "Feed not found: #{id}"
      assert ScriptedWorker.calls() == []
    end

    test "a failed run answers the run's own refusal and publishes nothing", %{
      ctx: ctx,
      actor: actor
    } do
      script!([{:error, "upstream gone"}])
      watch_feeds(actor)
      {:ok, %{binding: id}} = call(ctx, bind_args("btc"))

      assert %Prima.Refusal{message: message} = refused(press(ctx, id, "refresh"))
      refute message =~ "the result was refused"
      refute_received %FeedPublished{}
      assert {:ok, %{feed_result_seq: 0, feed_result: nil}} = CronSchedule.get_feed(actor, id)
    end
  end

  # ---------------------------------------------------------------------------
  # Publication
  # ---------------------------------------------------------------------------

  describe "publication" do
    test "an accepted result is broadcast after its commit", %{ctx: ctx, actor: actor} do
      script!([%{"price" => 3.25}])
      {:ok, %{binding: id}} = call(ctx, bind_args("btc"))
      test = self()

      # A subscriber that reads the row the moment it hears the event.
      spawn_link(fn ->
        :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.feeds(actor))
        send(test, :watching)

        receive do
          %FeedPublished{} = published ->
            {:ok, row} = CronSchedule.get_feed(actor, published.binding)
            send(test, {:heard, published, row})
        end
      end)

      assert_receive :watching
      assert {:ok, %{revision: 1}} = press(ctx, id, "refresh")

      assert_receive {:heard, %FeedPublished{binding: ^id, revision: 1} = published, row}, 5_000
      assert row.feed_result_seq == 1
      assert {:ok, published.result} == Prima.Json.decode(row.feed_result)
    end

    test "a refused result broadcasts nothing", %{ctx: ctx, actor: actor} do
      script!([%{"price" => "SECRET-high"}])
      watch_feeds(actor)
      {:ok, %{binding: id}} = call(ctx, bind_args("btc"))

      assert %Prima.Refusal{class: :invalid_argument, message: message} =
               refused(press(ctx, id, "refresh"))

      assert message ==
               ~s(the result was refused at "/price": ) <>
                 Prima.Feed.reasons()["type"]

      refute message =~ "SECRET"
      refute_received %FeedPublished{}

      assert {:ok, %{feed_fire_seq: 1, feed_result_seq: 0, feed_result: nil}} =
               CronSchedule.get_feed(actor, id)
    end

    test "an output that is no envelope is refused with the error reason's sentence", %{
      ctx: ctx
    } do
      script!([{:output, %{"status" => 503, "data" => %{"price" => 1}}}])
      {:ok, %{binding: id}} = call(ctx, bind_args("btc"))

      assert %Prima.Refusal{class: :invalid_argument, message: message} =
               refused(press(ctx, id, "refresh"))

      assert message ==
               ~s(the result was refused at "": the operation answered an error, or no envelope ) <>
                 "(status 503)"
    end

    test "another athanor's subscriber hears nothing", %{ctx: ctx, actor: actor} do
      script!([%{"price" => 2.0}])
      watch_feeds(actor)
      {:ok, %{binding: id}} = call(ctx, bind_args("btc"))
      other = Prima.Actor.in_athanor("ath_feed_other_#{System.unique_integer([:positive])}")
      test = self()

      stranger =
        spawn_link(fn ->
          :ok = Cyfr.Bus.subscribe(other, Cyfr.Bus.feeds(other))
          send(test, :watching)

          receive do
            :look -> send(test, {:held, Process.info(self(), :messages)})
          end
        end)

      assert_receive :watching
      assert {:ok, %{revision: 1}} = press(ctx, id, "refresh")
      assert_received %FeedPublished{binding: ^id}

      # The publish was sent from this process before it answered, so
      # anything it delivered elsewhere is queued before the look.
      send(stranger, :look)
      assert_receive {:held, {:messages, []}}
    end

    test "a stale press result broadcasts nothing", %{ctx: ctx, actor: actor} do
      script!([{:probe, self()}, %{"price" => 1.0}])
      watch_feeds(actor)
      {:ok, %{binding: id}} = call(ctx, bind_args("btc"))

      pressing = Task.async(fn -> press(ctx, id, "refresh") end)
      assert_receive {:scripted_probe, worker, _execution_id}, 10_000

      # A later claim's result is accepted while the press runs.
      {:ok, slot} = Arca.ControlPlane.member_slot()
      {:ok, 2} = CronSchedule.claim_feed_seq(actor, id)
      {:ok, _envelope} = Feeds.accept(ctx, id, 2, envelope(%{"price" => 2.0}), slot)

      send(worker, :continue)

      assert %Prima.Refusal{class: :conflict, message: message} =
               refused(Task.await(pressing, 10_000))

      assert message == "a newer result of feed btc was accepted"
      refute_received %FeedPublished{}
      assert {:ok, %{feed_result_seq: 2}} = CronSchedule.get_feed(actor, id)
    end

    test "a press whose feed is removed during the run refuses not_found and broadcasts nothing",
         %{ctx: ctx, actor: actor} do
      script!([{:probe, self()}, %{"price" => 1.0}])
      watch_feeds(actor)
      {:ok, %{binding: id}} = call(ctx, bind_args("btc"))

      pressing = Task.async(fn -> press(ctx, id, "refresh") end)
      assert_receive {:scripted_probe, worker, _execution_id}, 10_000

      assert {:ok, _removed} = CronSchedule.remove_feed(actor, id)
      send(worker, :continue)

      assert %Prima.Refusal{class: :not_found, message: message} =
               refused(Task.await(pressing, 10_000))

      assert message == "Feed not found: #{id}"
      refute_received %FeedPublished{}

      assert {:ok, %{status: "deleted", feed_result_seq: 0, feed_result: nil}} =
               CronSchedule.get_for_daemon(id)
    end

    test "a stale member's accepted-looking result broadcasts nothing", %{ctx: ctx, actor: actor} do
      slot = claimant!()
      script!([{:probe, self()}, %{"price" => 1.0}])
      watch_feeds(actor)
      {:ok, %{binding: id}} = call(ctx, bind_args("btc"))

      pressing = Task.async(fn -> press(ctx, id, "refresh") end)
      assert_receive {:scripted_probe, worker, _execution_id}, 10_000

      # Taken over while the run is in flight: the result is valid, and
      # only the acceptance's own fence refuses it.
      take_over!(slot)
      send(worker, :continue)

      assert %Prima.Refusal{class: :not_owner} = refused(Task.await(pressing, 10_000))
      refute_received %FeedPublished{}

      assert {:ok, %{feed_result_seq: 0, feed_result: nil}} =
               CronSchedule.get_feed(actor, id)
    end
  end

  # ---------------------------------------------------------------------------
  # The refreshes
  # ---------------------------------------------------------------------------

  describe "the refreshes" do
    test "a feed's is its last accepted envelope, by name, in its shape", %{
      ctx: ctx,
      actor: actor
    } do
      {:ok, %{binding: id}} = call(ctx, bind_args("btc"))
      {:ok, _} = call(ctx, bind_args("eth"))
      assert {:ok, []} = Feeds.latest(ctx, "btc")

      {:ok, slot} = Arca.ControlPlane.member_slot()
      {:ok, 1} = CronSchedule.claim_feed_seq(actor, id)
      {:ok, accepted} = Feeds.accept(ctx, id, 1, envelope(%{"price" => 4.0}), slot)

      assert {:ok, [^accepted]} = Feeds.latest(ctx, "btc")
      assert {:ok, []} = Feeds.latest(ctx, "eth")
      assert {:ok, []} = Feeds.latest(ctx, "nobody")
      assert {:ok, []} = Feeds.latest(foreign(ctx), "btc")

      {:ok, {_feed, stream}} = Sanctum.Catalog.lookup_stream("feed.results")
      assert :ok = Prima.Canvas.Shape.check(stream.shape, accepted)
    end

    test "the runs' is the athanor's newest runs as their last change, in its shape", %{
      ctx: ctx
    } do
      script!([%{"price" => 1.0}, %{"ok" => true}])
      {:ok, %{binding: id}} = call(ctx, bind_args("btc"))
      {:ok, _} = press(ctx, id, "refresh")
      {:ok, %{execution_id: ran}} = press(ctx, id, "buy")

      assert {:ok, changes} = Feed.recent_runs(ctx, nil)
      assert length(changes) == 2
      assert %{"kind" => "completed", "reference" => @pinned} = List.last(changes)
      assert List.last(changes)["execution_id"] == ran

      {:ok, {_feed, stream}} = Sanctum.Catalog.lookup_stream("runs.changes")
      for change <- changes, do: assert(:ok = Prima.Canvas.Shape.check(stream.shape, change))

      assert {:ok, []} = Feed.recent_runs(foreign(ctx), nil)
      assert {:error, :no_athanor} = Feed.recent_runs(%{ctx | athanor_id: nil}, nil)
    end

    test "the runs' carries a failed run's error in the live payload's form", %{
      ctx: ctx,
      actor: actor
    } do
      script!([%{"price" => 1.0}, {:error, "upstream gone"}])
      {:ok, %{binding: id}} = call(ctx, bind_args("btc"))
      {:ok, _} = press(ctx, id, "refresh")
      {:error, _failed} = press(ctx, id, "refresh")

      assert {:ok, [_, _] = changes} = Feed.recent_runs(ctx, nil)
      assert %{"error" => nil} = Enum.find(changes, &(&1["kind"] == "completed"))
      failed = Enum.find(changes, &(&1["kind"] == "failed"))

      # The record keeps the sentence and no class.
      assert %{"kind" => "failed", "error" => %{"class" => nil, "message" => message}} = failed
      assert is_binary(message) and message != ""

      {:ok, {_feed, stream}} = Sanctum.Catalog.lookup_stream("runs.changes")
      assert :ok = Prima.Canvas.Shape.check(stream.shape, failed)

      # A live failure's projected error is an object of the same keys on
      # the wire, and fits the same shape.
      grant = %Prima.StreamGrant{
        topic: :executions,
        projection: stream.projection,
        subject: nil,
        deadline: DateTime.utc_now(),
        grant_id: "sgr_runs"
      }

      live =
        Cyfr.Bus.Execution.new(actor, :failed,
          execution_id: "exec_live",
          reference: @pinned,
          component_type: :catalyst,
          error: "upstream gone"
        )

      projected = grant |> Prima.StreamGrant.project(Map.from_struct(live)) |> wire()
      refreshed = wire(failed)

      assert projected["error"] |> Map.keys() |> Enum.sort() ==
               refreshed["error"] |> Map.keys() |> Enum.sort()

      assert Enum.sort(Map.keys(refreshed["error"])) == ["class", "message"]
      assert :ok = Prima.Canvas.Shape.check(stream.shape, projected)
    end
  end

  # A payload as the stream's wire carries it: JSON text read back.
  defp wire(data), do: data |> Jason.encode!() |> Jason.decode!()

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp operations do
    [tool] = Feed.tools()
    Map.new(tool.operations, &{&1.action, &1})
  end

  defp call(ctx, args), do: Sanctum.Gate.call_external("feed", ctx, args)

  defp press(ctx, binding, action),
    do: call(ctx, %{"action" => "press", "binding" => binding, "action_name" => action})

  # A bind through the gate refused in `class` with the binding's
  # `sentence`, and the gate's one record of it failed in that class.
  defp binding_refused!(ctx, class, sentence) do
    assert bind_decisions(ctx) == []

    assert %Prima.Refusal{class: ^class, message: message} =
             refused(call(ctx, bind_args("btc")))

    assert message == "profile binding refused: " <> sentence
    assert bind_decisions(ctx) == [{"admitted", "failed", Atom.to_string(class)}]
  end

  defp bind_decisions(ctx) do
    Arca.Repo.all(
      from(d in Arca.Schemas.DecisionLog,
        where: d.athanor_id == ^ctx.athanor_id and d.tool == "feed" and d.action == "bind",
        select: {d.admission, d.completion, d.completion_class}
      )
    )
  end

  # A refused answer as every surface renders it: its class and sentence
  # (`Sanctum.Refusals.classify/1`).
  defp refused({:error, reason}), do: Sanctum.Refusals.classify(reason)

  defp bind_args(name, overrides \\ %{}) do
    Map.merge(
      %{
        "action" => "bind",
        "name" => name,
        "label" => "Feed #{name}",
        "reference" => @reference,
        "profile_id" => @profile_id,
        "operation" => "quote",
        "args" => %{"symbol" => "SECRET-#{name}"},
        "interval_minutes" => 5,
        "actions" => [
          %{"name" => "refresh", "label" => "Refresh", "kind" => "refresh"},
          %{
            "name" => "buy",
            "label" => "Buy",
            "kind" => "run",
            "operation" => "buy",
            "args" => %{"qty" => "SECRET-QTY"}
          }
        ]
      },
      overrides
    )
  end

  defp envelope(data), do: %{"status" => 200, "data" => data}

  # The same person's context, focused on another athanor.
  defp foreign(ctx),
    do: %{ctx | athanor_id: "ath_feed_foreign", user_id: "local|local|feed-stranger"}

  defp watch_feeds(actor), do: :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.feeds(actor))

  defp script!(items), do: start_supervised!({ScriptedWorker, ref: @reference, script: items})

  # The component, its `quote` operation's result shape declared.
  defp published!(ctx) do
    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm_path), %{
        name: "markets",
        version: "1.0.0",
        type: "catalyst",
        manifest: Jason.encode!(%{"results" => %{"quote" => @price}})
      })

    component.release_digest
  end

  defp consented!(ctx, release_digest) do
    profile = %{
      id: @profile_id,
      kind: :owner,
      source_ref: @reference,
      label: "default",
      status: :active
    }

    :ok =
      ConsentFixtures.seed_head!(ctx, profile, %{
        id: "consent-#{@profile_id}",
        revision: 1,
        scope: :versionless,
        pinned_version: "",
        invoke_mode: :open_inert,
        shape_digest: "sha256:shape-#{@profile_id}",
        commit_digest: "sha256:commit-#{@profile_id}",
        resolved_policy:
          Jason.encode!(%{
            "canonical" => "jcs-1",
            "nodes" => %{
              @reference => %{
                "limits" => AuthorityFixtures.limits_map(),
                "edges" => %{"@ingress" => %{}}
              }
            }
          }),
        activation: %{@reference => release_digest},
        admitted_origins: [:interactive, :schedule],
        vault_refs: []
      })
  end

  # A claimant runs, as a deployment's does, and this member holds its
  # slot: the umbrella's test configuration runs none, which would leave a
  # write's live check nothing to check. Restored when the case ends.
  defp claimant! do
    saved = Map.new(@keys, &{&1, :persistent_term.get(&1, :absent)})
    claim = Application.get_env(:arca, :control_plane_claim_enabled)

    on_exit(fn ->
      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end

      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    Application.put_env(:arca, :control_plane_claim_enabled, true)
    node = "node-feed-tool-#{System.unique_integer([:positive])}"
    {:ok, slot} = Arca.ControlPlane.take(node, node <> "#boot_a", 60_000)
    slot
  end

  # A successor takes the slot over after this member read it: this member
  # still believes it holds it, so only a write's own live check stands
  # between it and the row.
  defp take_over!(%{node: node, generation: generation}) do
    {1, _} =
      Arca.Repo.update_all(from(l in Arca.Schemas.CellLease, where: l.node == ^node),
        set: [owner: node <> "#boot_b", generation: generation + 1]
      )

    :ok
  end
end
