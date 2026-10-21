# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CronScheduleTest do
  # Every case switches the claimant on and takes a slot through
  # `Arca.ControlPlane`, which writes the process-wide standing record and
  # the application environment; each case restores both.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ControlPlane
  alias Arca.CronSchedule

  @athanor Arca.Test.Actor.athanor_id()

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
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

    # A claimant runs, as a deployment's does, and this member holds its
    # slot, whatever the build's own configuration says: every feed write
    # checks the slot live, and a case that loses it does so on purpose.
    Application.put_env(:arca, :control_plane_claim_enabled, true)
    node = "node-feeds-#{System.unique_integer([:positive])}"
    {:ok, slot} = ControlPlane.take(node, node <> "#boot_a", 60_000)

    actor = %Prima.Actor{
      athanor_id: @athanor,
      user_id: "test_user",
      authenticated: true,
      scope: :athanor,
      system: false
    }

    {:ok, actor: actor, slot: slot}
  end

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        user_id: "test_user",
        athanor_id: @athanor,
        name: "test-schedule-#{:rand.uniform(100_000)}",
        cron_expression: "*/5 * * * *",
        reference: "reagent:local.test:1.0.0",
        profile_id: "prof_test",
        cap: 1_000
      },
      overrides
    )
  end

  describe "create/2" do
    test "creates a schedule with valid attrs", %{actor: actor} do
      assert {:ok, schedule} = CronSchedule.create(actor, valid_attrs())
      assert schedule.user_id == "test_user"
      assert schedule.status == "active"
      assert schedule.run_count == 0
      assert schedule.error_count == 0
      assert String.starts_with?(schedule.id, "sched_")
    end

    test "requires name", %{actor: actor} do
      assert {:error, _} = CronSchedule.create(actor, valid_attrs(%{name: nil}))
    end

    test "requires cron_expression", %{actor: actor} do
      assert {:error, _} = CronSchedule.create(actor, valid_attrs(%{cron_expression: nil}))
    end

    test "requires reference", %{actor: actor} do
      assert {:error, _} = CronSchedule.create(actor, valid_attrs(%{reference: nil}))
    end

    test "refuses at the cap it is given, counting non-deleted schedules and no feed", %{
      actor: actor
    } do
      for i <- 1..3, do: {:ok, _} = feed!(actor, "f#{i}")
      {:ok, a} = CronSchedule.create(actor, valid_attrs(%{name: "a", cap: 2}))
      {:ok, b} = CronSchedule.create(actor, valid_attrs(%{name: "b", cap: 2}))

      # A paused schedule holds its place.
      {:ok, _} = CronSchedule.update(actor, b.id, %{status: "paused"})

      assert {:error, :schedule_cap} =
               CronSchedule.create(actor, valid_attrs(%{name: "c", cap: 2}))

      assert Arca.Test.CronSlots.occupied(actor, "schedule") == {:ok, 2}

      # A deleted one holds none.
      {:ok, _} = CronSchedule.soft_delete(actor, a.id)
      assert {:ok, _} = CronSchedule.create(actor, valid_attrs(%{name: "c", cap: 2}))

      # A cap of 0 is no ceiling, as the operator's setting reads.
      assert {:ok, _} = CronSchedule.create(actor, valid_attrs(%{name: "d", cap: 0}))
      assert Arca.Test.CronSlots.occupied(actor, "schedule") == {:ok, 3}
    end

    test "refuses a missing or malformed cap, writing nothing", %{actor: actor} do
      for attrs <- [
            Map.delete(valid_attrs(), :cap),
            valid_attrs(%{cap: -1}),
            valid_attrs(%{cap: "5"}),
            valid_attrs(%{cap: nil})
          ] do
        assert {:error, {:validation, %{cap: [_]}}} = CronSchedule.create(actor, attrs),
               inspect(Map.get(attrs, :cap))
      end

      assert Arca.Test.CronSlots.occupied(actor, "schedule") == {:ok, 0}
    end

    test "writes into the actor's athanor, whatever the attributes name", %{actor: actor} do
      assert {:ok, row} = CronSchedule.create(actor, valid_attrs(%{athanor_id: "ath_other"}))
      assert row.athanor_id == @athanor
    end

    test "refuses an actor with no athanor, and an athanor with no row", %{actor: actor} do
      assert {:error, :no_athanor} =
               CronSchedule.create(%{actor | athanor_id: nil}, valid_attrs())

      homeless = %{actor | athanor_id: "ath_cron_rowless_#{System.unique_integer([:positive])}"}
      assert {:error, :not_found} = CronSchedule.create(homeless, valid_attrs())
      assert Arca.Test.CronSlots.occupied(homeless, "schedule") == {:ok, 0}
    end
  end

  describe "get_by_id_or_name/2" do
    test "finds by name", %{actor: actor} do
      {:ok, schedule} = CronSchedule.create(actor, valid_attrs(%{name: "find-me"}))
      {:ok, found} = CronSchedule.get_by_id_or_name(actor, "find-me")
      assert found.id == schedule.id
    end

    test "finds by id", %{actor: actor} do
      {:ok, schedule} = CronSchedule.create(actor, valid_attrs())
      {:ok, found} = CronSchedule.get_by_id_or_name(actor, schedule.id)
      assert found.id == schedule.id
    end

    test "does not find deleted schedules", %{actor: actor} do
      {:ok, schedule} = CronSchedule.create(actor, valid_attrs(%{name: "deleted-one"}))
      CronSchedule.soft_delete(actor, schedule.id)

      assert CronSchedule.get_by_id_or_name(actor, "deleted-one") ==
               {:error, :not_found}
    end

    test "finds a fellow member's schedule in the same athanor (interchangeable)", %{actor: actor} do
      {:ok, created} =
        CronSchedule.create(actor, valid_attrs(%{name: "private", user_id: "other_user"}))

      actor = %Prima.Actor{
        athanor_id: @athanor,
        user_id: "test_user",
        authenticated: true,
        scope: :athanor,
        system: false
      }

      # Same athanor, different creator — visible.
      {:ok, found} = CronSchedule.get_by_id_or_name(actor, "private")
      assert found != nil
      assert found.id == created.id
    end
  end

  describe "list/2" do
    test "lists all non-deleted schedules in the athanor regardless of creator", %{actor: actor} do
      {:ok, _} = CronSchedule.create(actor, valid_attrs(%{name: "s1"}))
      {:ok, s2} = CronSchedule.create(actor, valid_attrs(%{name: "s2"}))
      {:ok, _} = CronSchedule.create(actor, valid_attrs(%{name: "other", user_id: "other_user"}))
      CronSchedule.soft_delete(actor, s2.id)

      {:ok, schedules} = CronSchedule.list(actor)
      names = Enum.map(schedules, & &1.name)

      assert length(schedules) == 2
      assert "s1" in names
      assert "other" in names
      refute "s2" in names
    end
  end

  describe "active_schedules/0" do
    test "returns only active schedules", %{actor: actor} do
      {:ok, _} = CronSchedule.create(actor, valid_attrs(%{name: "active1"}))
      {:ok, paused} = CronSchedule.create(actor, valid_attrs(%{name: "paused1"}))
      CronSchedule.update(actor, paused.id, %{status: "paused"})

      {:ok, active} = CronSchedule.active_schedules()
      names = Enum.map(active, & &1.name)
      assert "active1" in names
      refute "paused1" in names
    end
  end

  describe "record_run/3" do
    test "increments run_count and sets last_run_at", %{actor: actor} do
      {:ok, schedule} = CronSchedule.create(actor, valid_attrs())

      assert {:ok, updated} =
               CronSchedule.record_run(actor, schedule.id, "exec_123")

      assert updated.run_count == 1
      assert updated.last_execution_id == "exec_123"
      assert updated.last_run_at != nil
    end
  end

  describe "record_error/3" do
    test "increments error_count", %{actor: actor} do
      {:ok, schedule} = CronSchedule.create(actor, valid_attrs())

      assert {:ok, updated} =
               CronSchedule.record_error(actor, schedule.id, "boom")

      assert updated.error_count == 1
    end
  end

  describe "count_active/2" do
    test "counts non-deleted schedules", %{actor: actor} do
      {:ok, _} = CronSchedule.create(actor, valid_attrs(%{name: "c1"}))
      {:ok, s2} = CronSchedule.create(actor, valid_attrs(%{name: "c2"}))
      CronSchedule.soft_delete(actor, s2.id)

      assert Arca.Test.CronSlots.occupied(actor, "schedule") == {:ok, 1}
    end

    test "counts one kind: a feed is not a schedule", %{actor: actor} do
      {:ok, _} = CronSchedule.create(actor, valid_attrs(%{name: "c1"}))
      {:ok, _} = feed!(actor, "c1")
      {:ok, removed} = feed!(actor, "c2")
      {:ok, _} = CronSchedule.remove_feed(actor, removed.id)

      assert Arca.Test.CronSlots.occupied(actor, "schedule") == {:ok, 1}
      assert Arca.Test.CronSlots.occupied(actor, "feed") == {:ok, 1}
    end
  end

  describe "kinds" do
    test "create/2 always writes a schedule, whatever the attributes name", %{actor: actor} do
      {:ok, row} =
        CronSchedule.create(
          actor,
          valid_attrs(%{name: "not-a-feed", kind: "feed", feed_spec: "{}", feed_fire_seq: 9})
        )

      assert %{kind: "schedule", feed_spec: nil, feed_fire_seq: 0} = row
      assert {:error, :not_found} = CronSchedule.get_feed(actor, row.id)
    end

    test "a feed may share a schedule's name, and a kind-scoped read tells them apart", %{
      actor: actor
    } do
      {:ok, schedule} = CronSchedule.create(actor, valid_attrs(%{name: "btc"}))
      assert {:ok, feed} = feed!(actor, "btc")

      assert {:ok, %{id: id}} = CronSchedule.get_by_id_or_name(actor, "btc", kind: "schedule")
      assert id == schedule.id
      assert {:ok, %{id: id}} = CronSchedule.get_by_id_or_name(actor, "btc", kind: "feed")
      assert id == feed.id

      # A name both kinds hold names neither when no kind is asked; an id
      # names its row whatever its kind.
      assert {:error, :not_found} = CronSchedule.get_by_id_or_name(actor, "btc")
      assert {:ok, %{kind: "feed"}} = CronSchedule.get_by_id_or_name(actor, feed.id)

      assert {:error, :not_found} =
               CronSchedule.get_by_id_or_name(actor, feed.id, kind: "schedule")

      {:ok, schedules} = CronSchedule.list(actor, kind: "schedule")
      assert Enum.map(schedules, & &1.id) == [schedule.id]
      {:ok, both} = CronSchedule.list(actor)
      assert Enum.sort(Enum.map(both, & &1.id)) == Enum.sort([schedule.id, feed.id])

      # The scheduler fires both kinds.
      {:ok, active} = CronSchedule.active_schedules()
      assert feed.id in Enum.map(active, & &1.id)
      assert schedule.id in Enum.map(active, & &1.id)
    end
  end

  describe "create_feed/2" do
    test "writes the binding's row, due at once", %{actor: actor} do
      before = Arca.ServerMetaStorage.now!()
      binding = feed_binding("btc")

      assert {:ok, row} = feed!(actor, binding)

      assert Prima.Feed.binding_id?(row.id)

      assert %{
               kind: "feed",
               status: "active",
               user_id: "test_user",
               athanor_id: @athanor,
               name: "btc",
               cron_expression: "*/5 * * * *",
               reference: "catalyst:local.markets",
               resolved_reference: "catalyst:local.markets:1.0.0",
               profile_id: "prof_feed",
               concurrency: "forbid",
               feed_fire_seq: 0,
               feed_result_seq: 0,
               feed_result: nil,
               feed_result_at: nil
             } = row

      assert {:ok, Prima.Feed.input(binding)} == Prima.Json.decode(row.input)
      assert {:ok, Prima.Feed.Binding.to_json(binding)} == Prima.Json.decode(row.feed_spec)
      refute DateTime.compare(row.next_run_at, before) == :lt
      refute DateTime.compare(row.next_run_at, Arca.ServerMetaStorage.now!()) == :gt
    end

    test "refuses a live feed's name, and a removed one's name binds again as a new id", %{
      actor: actor
    } do
      {:ok, first} = feed!(actor, "btc")
      assert {:error, :conflict} = feed!(actor, "btc")

      {:ok, _} = CronSchedule.remove_feed(actor, first.id)
      assert {:ok, again} = feed!(actor, "btc")
      refute again.id == first.id
    end

    test "refuses at the cap it is given, counting live feeds and no schedule", %{actor: actor} do
      for i <- 1..3, do: {:ok, _} = CronSchedule.create(actor, valid_attrs(%{name: "s#{i}"}))
      {:ok, a} = feed!(actor, "a", 2)
      {:ok, _} = feed!(actor, "b", 2)

      assert {:error, :feed_cap} = feed!(actor, "c", 2)
      assert Arca.Test.CronSlots.occupied(actor, "feed") == {:ok, 2}

      {:ok, _} = CronSchedule.remove_feed(actor, a.id)
      assert {:ok, _} = feed!(actor, "c", 2)
      # A cap of 0 is no ceiling, as the operator's setting reads.
      assert {:ok, _} = feed!(actor, "d", 0)
    end

    test "refuses what it cannot write as a feed, before any row", %{actor: actor} do
      binding = feed_binding("btc")

      base = %{
        binding: binding,
        resolved_reference: "catalyst:local.markets:1.0.0",
        profile_id: "prof_feed",
        cap: 10
      }

      assert {:error, {:validation, %{resolved_reference: _}}} =
               CronSchedule.create_feed(actor, %{base | resolved_reference: nil})

      assert {:error, {:validation, %{profile_id: _}}} =
               CronSchedule.create_feed(actor, %{base | profile_id: nil})

      assert {:error, {:validation, %{binding: _}}} =
               CronSchedule.create_feed(actor, %{
                 base
                 | binding: Prima.Feed.Binding.to_json(binding)
               })

      # A hand-built struct its grammar refuses is refused too, one that
      # cannot even be written back among them.
      assert {:error, {:validation, %{binding: _}}} =
               CronSchedule.create_feed(actor, %{base | binding: %{binding | interval_minutes: 7}})

      assert {:error, {:validation, %{binding: _}}} =
               CronSchedule.create_feed(actor, %{base | binding: %{binding | actions: :none}})

      assert {:error, {:validation, %{cap: _}}} =
               CronSchedule.create_feed(actor, %{base | cap: -1})

      assert {:error, {:validation, _}} = CronSchedule.create_feed(actor, %{binding: binding})
      assert Arca.Test.CronSlots.occupied(actor, "feed") == {:ok, 0}
    end

    test "refuses an actor with no athanor, and an athanor with no row", %{actor: actor} do
      assert {:error, :no_athanor} = feed!(%{actor | athanor_id: nil}, "btc")

      homeless = %{actor | athanor_id: "ath_feed_rowless_#{System.unique_integer([:positive])}"}
      assert {:error, :not_found} = feed!(homeless, "btc")
      assert CronSchedule.list_feeds(homeless) == {:ok, []}
    end
  end

  describe "a feed's seq and result" do
    test "a result is accepted only for a claimed seq above the accepted one", %{
      actor: actor,
      slot: slot
    } do
      {:ok, feed} = feed!(actor, "btc")

      assert {:ok, 1} = CronSchedule.claim_feed_seq(actor, feed.id)
      assert {:ok, 2} = CronSchedule.claim_feed_seq(actor, feed.id)

      # The later-claimed result lands first; the earlier one is stale.
      assert {:ok, %{feed_result_seq: 2, feed_result: ~s({"price":2})} = row} =
               CronSchedule.accept_feed_result(actor, feed.id, 2, ~s({"price":2}), slot)

      assert %DateTime{} = row.feed_result_at
      assert {:error, :stale} = accept(actor, feed.id, 1, ~s({"price":1}), slot)
      assert {:error, :stale} = accept(actor, feed.id, 2, ~s({"price":3}), slot)

      # A seq nobody claimed writes nothing, so it can never make the next
      # claimed result stale.
      assert {:error, :unclaimed} = accept(actor, feed.id, 9, ~s({"price":9}), slot)
      assert {:ok, %{feed_result_seq: 2, feed_result: ~s({"price":2})}} = get_feed(actor, feed.id)

      assert {:ok, 3} = CronSchedule.claim_feed_seq(actor, feed.id)
      assert {:ok, %{feed_result_seq: 3}} = accept(actor, feed.id, 3, ~s({"price":3}), slot)
      assert {:ok, %{feed_fire_seq: 3}} = get_feed(actor, feed.id)
    end

    test "a schedule's id, a removed feed and an absent id are not feeds", %{
      actor: actor,
      slot: slot
    } do
      {:ok, schedule} = CronSchedule.create(actor, valid_attrs(%{name: "btc"}))
      {:ok, removed} = feed!(actor, "gone")
      {:ok, 1} = CronSchedule.claim_feed_seq(actor, removed.id)
      {:ok, _} = CronSchedule.remove_feed(actor, removed.id)

      for id <- [schedule.id, removed.id, Prima.UUID7.generate_id("feed")] do
        assert {:error, :not_found} = CronSchedule.get_feed(actor, id)
        assert {:error, :not_found} = CronSchedule.claim_feed_seq(actor, id)
        assert {:error, :not_found} = accept(actor, id, 1, "{}", slot)
        assert {:error, :not_found} = CronSchedule.remove_feed(actor, id)
      end

      assert {:ok, %{kind: "schedule", status: "active"}} = CronSchedule.get(actor, schedule.id)
      assert {:ok, []} = CronSchedule.list_feeds(actor)
    end

    test "list_feeds/1 answers the live feeds by name, undecoded", %{actor: actor} do
      {:ok, _} = CronSchedule.create(actor, valid_attrs(%{name: "a-schedule"}))
      {:ok, _} = feed!(actor, "zeta")
      {:ok, _} = feed!(actor, "alpha")
      {:ok, removed} = feed!(actor, "mid")
      {:ok, _} = CronSchedule.remove_feed(actor, removed.id)

      assert {:ok, [%{name: "alpha", feed_spec: spec}, %{name: "zeta"}]} =
               CronSchedule.list_feeds(actor)

      assert is_binary(spec)
    end
  end

  describe "another athanor's actor" do
    test "naming a feed id reads, claims, accepts and removes nothing", %{
      actor: actor,
      slot: slot
    } do
      {:ok, feed} = feed!(actor, "btc")
      {:ok, 1} = CronSchedule.claim_feed_seq(actor, feed.id)
      foreign = %{actor | athanor_id: "ath_other", user_id: "other_user"}

      assert {:ok, []} = CronSchedule.list_feeds(foreign)
      assert {:error, :not_found} = CronSchedule.get_feed(foreign, feed.id)
      assert {:error, :not_found} = CronSchedule.claim_feed_seq(foreign, feed.id)
      assert {:error, :not_found} = accept(foreign, feed.id, 1, ~s({"price":1}), slot)
      assert {:error, :not_found} = CronSchedule.remove_feed(foreign, feed.id)

      assert {:ok, %{status: "active", feed_fire_seq: 1, feed_result_seq: 0, feed_result: nil}} =
               get_feed(actor, feed.id)
    end
  end

  describe "a member that lost its slot" do
    test "creates, claims, accepts and removes nothing", %{actor: actor, slot: slot} do
      {:ok, feed} = feed!(actor, "btc")
      {:ok, 1} = CronSchedule.claim_feed_seq(actor, feed.id)

      # A successor takes the slot over after this member read it; only
      # each write's own live check stands between the member and the row.
      take_over!(slot)
      assert Arca.ControlPlane.held?()

      assert {:error, :not_owner} = feed!(actor, "eth")
      assert {:error, :not_owner} = CronSchedule.claim_feed_seq(actor, feed.id)
      assert {:error, :not_owner} = accept(actor, feed.id, 1, ~s({"price":1}), slot)
      assert {:error, :not_owner} = CronSchedule.remove_feed(actor, feed.id)

      assert {:ok, [%{id: id, status: "active", feed_fire_seq: 1, feed_result: nil}]} =
               CronSchedule.list_feeds(actor)

      assert id == feed.id
    end

    test "creates no schedule", %{actor: actor, slot: slot} do
      take_over!(slot)

      assert {:error, :not_owner} = CronSchedule.create(actor, valid_attrs(%{name: "late"}))
      assert Arca.Test.CronSlots.occupied(actor, "schedule") == {:ok, 0}
    end

    # Every generic writer, one case each: a person's through a surface, an
    # uninstall's included, and the scheduler's run writers. Every row is
    # fenced, whatever its kind.
    for writer <- [:update, :soft_delete, :record_run, :record_error] do
      test "#{writer} writes no feed's row and no schedule's", %{actor: actor, slot: slot} do
        {:ok, feed} = feed!(actor, "btc")
        {:ok, schedule} = CronSchedule.create(actor, valid_attrs(%{name: "btc"}))
        take_over!(slot)

        for id <- [feed.id, schedule.id] do
          before = CronSchedule.get_for_daemon(id)
          assert {:error, :not_owner} = write(unquote(writer), actor, id)
          assert CronSchedule.get_for_daemon(id) == before
        end
      end
    end

    test "every row is written by the generic writers while the slot holds", %{actor: actor} do
      {:ok, feed} = feed!(actor, "btc")
      {:ok, schedule} = CronSchedule.create(actor, valid_attrs(%{name: "btc"}))

      for id <- [feed.id, schedule.id] do
        assert {:ok, %{run_count: 1, last_execution_id: "exec_1"}} =
                 CronSchedule.record_run(actor, id, "exec_1")

        assert {:ok, %{error_count: 1}} = CronSchedule.record_error(actor, id, "boom")
        assert {:ok, %{status: "paused"}} = CronSchedule.update(actor, id, %{status: "paused"})
        assert {:ok, %{status: "deleted"}} = CronSchedule.soft_delete(actor, id)
      end
    end
  end

  describe "check_feed_acceptance/4" do
    test "answers what an acceptance would for the slot and the seq, and writes nothing", %{
      actor: actor,
      slot: slot
    } do
      {:ok, feed} = feed!(actor, "btc")
      {:ok, schedule} = CronSchedule.create(actor, valid_attrs(%{name: "btc"}))
      {:ok, 1} = CronSchedule.claim_feed_seq(actor, feed.id)
      {:ok, 2} = CronSchedule.claim_feed_seq(actor, feed.id)
      {:ok, _} = accept(actor, feed.id, 2, ~s({"price":2}), slot)
      before = CronSchedule.get_for_daemon(feed.id)

      assert {:error, :stale} = CronSchedule.check_feed_acceptance(actor, feed.id, 1, slot)
      assert {:error, :stale} = CronSchedule.check_feed_acceptance(actor, feed.id, 2, slot)
      assert {:error, :unclaimed} = CronSchedule.check_feed_acceptance(actor, feed.id, 3, slot)

      for id <- [schedule.id, Prima.UUID7.generate_id("feed")] do
        assert {:error, :not_found} = CronSchedule.check_feed_acceptance(actor, id, 1, slot)
      end

      foreign = %{actor | athanor_id: "ath_other"}
      assert {:error, :not_found} = CronSchedule.check_feed_acceptance(foreign, feed.id, 3, slot)

      assert {:error, :no_athanor} =
               CronSchedule.check_feed_acceptance(%{actor | athanor_id: nil}, feed.id, 3, slot)

      {:ok, 3} = CronSchedule.claim_feed_seq(actor, feed.id)
      assert :ok = CronSchedule.check_feed_acceptance(actor, feed.id, 3, slot)

      # The slot comes before the seq: a stale owner is answered as one,
      # whatever its seq.
      take_over!(slot)

      for seq <- [1, 3, 9] do
        assert {:error, :not_owner} =
                 CronSchedule.check_feed_acceptance(actor, feed.id, seq, slot)
      end

      # Nothing was written by any check.
      {:ok, unchanged} = CronSchedule.get_for_daemon(feed.id)
      assert {:ok, %{unchanged | feed_fire_seq: 2}} == before
    end
  end

  # ---- feed helpers ------------------------------------------------------------

  # One write of each generic writer.
  defp write(:update, actor, id), do: CronSchedule.update(actor, id, %{status: "paused"})
  defp write(:record_run, actor, id), do: CronSchedule.record_run(actor, id, "exec_1")
  defp write(:record_error, actor, id), do: CronSchedule.record_error(actor, id, "boom")
  defp write(:soft_delete, actor, id), do: CronSchedule.soft_delete(actor, id)

  defp feed_binding(name) do
    {:ok, binding} =
      Prima.Feed.Binding.validate(%{
        "name" => name,
        "label" => "Feed #{name}",
        "reference" => "catalyst:local.markets",
        "operation" => "quote",
        "args" => %{"symbol" => "BTC"},
        "interval_minutes" => 5,
        "result_shape" => %{
          "type" => "object",
          "fields" => %{"price" => %{"type" => "number"}},
          "required" => ["price"]
        },
        "actions" => [%{"name" => "refresh", "label" => "Refresh", "kind" => "refresh"}]
      })

    binding
  end

  defp feed!(actor, name_or_binding, cap \\ 10)

  defp feed!(actor, name, cap) when is_binary(name), do: feed!(actor, feed_binding(name), cap)

  defp feed!(actor, %Prima.Feed.Binding{} = binding, cap) do
    CronSchedule.create_feed(actor, %{
      binding: binding,
      resolved_reference: "catalyst:local.markets:1.0.0",
      profile_id: "prof_feed",
      cap: cap
    })
  end

  # The slot is the one the case holds, read as a claimant reads it.
  defp accept(actor, id, seq, json, slot),
    do: CronSchedule.accept_feed_result(actor, id, seq, json, slot)

  defp get_feed(actor, id), do: CronSchedule.get_feed(actor, id)

  # A successor takes the case's slot over after this member read it.
  defp take_over!(%{node: node, generation: generation}) do
    {1, _} =
      Arca.Repo.update_all(
        from(l in Arca.Schemas.CellLease, where: l.node == ^node),
        set: [owner: node <> "#boot_b", generation: generation + 1]
      )

    :ok
  end
end

defmodule Arca.CronScheduleTakeoverTest do
  @moduledoc """
  A stale member's run writes to an ordinary schedule's row, in the
  sequence that makes one stale with no clock drift and no edit to the
  lease row: the member's cached standing passes, its write waits on the
  row, its lease runs out on the cell's clock, a successor takes the slot
  through `Arca.ControlPlane.take/3`, and only then does the write go on.
  `record_run/3` and `record_error/3` check the member's slot in their own
  transaction, after the row lock, so the row's counters, `last_run_at`
  and `last_execution_id` do not move.

  The write runs on a connection of its own, outside the sandbox. On
  PostgreSQL it really waits, on the schedule's row, which another
  transaction holds locked across the expiry and the takeover. SQLite's
  one write lock would hold the successor's take behind that transaction
  too, so there the takeover commits first and the write runs while this
  member's cached standing still says it holds the slot: the same
  divergence between the cache and the row. The case works in an athanor
  of its own, whose rows it deletes when it ends.
  """

  # Writes the process-wide standing record and the claimant switch, and
  # holds a row locked across connections; the case restores both.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Arca.Test.Adapter, only: [postgres?: 0]

  alias Arca.{ControlPlane, CronSchedule}
  alias Arca.Schemas.CellLease
  alias Arca.Schemas.CronSchedule, as: ScheduleRow
  alias Arca.Test.LockWait
  alias Ecto.Adapters.SQL.Sandbox

  # Short enough to run out while the case waits; the setup is done under
  # a long lease, which the member then renews to this.
  @lease_ms 300

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup do
    saved = Map.new(@keys, &{&1, :persistent_term.get(&1, :absent)})
    claim = Application.get_env(:arca, :control_plane_claim_enabled)
    athanor = "ath_cron_fence_#{System.unique_integer([:positive])}"
    node = "node-cron-fence-#{System.unique_integer([:positive])}"
    unboxed(fn -> Arca.Test.Actor.ensure_athanor_row(athanor) end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(from(s in ScheduleRow, where: s.athanor_id == ^athanor))
        Arca.Repo.delete_all(from(a in Arca.Schemas.Athanor, where: a.id == ^athanor))
        Arca.Repo.delete_all(from(l in CellLease, where: l.node == ^node))
      end)

      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end

      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    # A claimant runs, as a deployment's does, and this member holds its
    # slot under a lease long enough for the case's own setup.
    Application.put_env(:arca, :control_plane_claim_enabled, true)
    {:ok, slot} = unboxed(fn -> ControlPlane.take(node, node <> "#boot_a", 60_000) end)

    {:ok, actor: Arca.Test.Actor.local(athanor_id: athanor), slot: slot}
  end

  for writer <- [:record_run, :record_error, :update, :soft_delete] do
    test "#{writer} on an ordinary schedule's row after ownership loss is refused :not_owner, the row unmoved",
         %{actor: actor, slot: slot} do
      schedule = unboxed(fn -> schedule!(actor) end)
      before = unboxed(fn -> CronSchedule.get_for_daemon(schedule.id) end)

      answer =
        stale_write(slot, lock_schedule(schedule.id), fn ->
          write(unquote(writer), actor, schedule.id)
        end)

      assert answer == {:error, :not_owner}

      assert {:ok, %{run_count: 1, error_count: 1, last_execution_id: "exec_before"} = row} =
               before

      assert {:ok, after_write} = unboxed(fn -> CronSchedule.get_for_daemon(schedule.id) end)
      assert after_write == row
    end
  end

  defp write(:record_run, actor, id), do: CronSchedule.record_run(actor, id, "exec_stale")
  defp write(:record_error, actor, id), do: CronSchedule.record_error(actor, id, "stale")
  defp write(:update, actor, id), do: CronSchedule.update(actor, id, %{status: "paused"})
  defp write(:soft_delete, actor, id), do: CronSchedule.soft_delete(actor, id)

  # An ordinary schedule with one run and one error on record, so a stale
  # write would move every column it writes.
  defp schedule!(actor) do
    {:ok, schedule} =
      CronSchedule.create(actor, %{
        user_id: actor.user_id,
        athanor_id: actor.athanor_id,
        name: "cron-fence-#{System.unique_integer([:positive])}",
        cron_expression: "*/5 * * * *",
        reference: "reagent:local.test:1.0.0",
        profile_id: "prof_test",
        cap: 1_000
      })

    {:ok, _} = CronSchedule.record_run(actor, schedule.id, "exec_before")
    {:ok, _} = CronSchedule.record_error(actor, schedule.id, "before")
    schedule
  end

  defp lock_schedule(id) do
    fn ->
      from(s in ScheduleRow, where: s.id == ^id)
      |> Arca.QueryHelpers.for_update()
      |> Arca.Repo.one()
    end
  end

  # ---- the stale write ---------------------------------------------------------

  # The member's cached standing passes, `write` waits, the lease runs out
  # and a successor takes the slot, then `write` goes on: on PostgreSQL it
  # waits on `lock`, held by another transaction until the takeover has
  # committed; on SQLite the takeover commits first. Answers what `write`
  # answered.
  defp stale_write(slot, lock, write) do
    slot = expiring!(slot)
    assert ControlPlane.held?()
    test = self()

    if postgres?() do
      holder = holding(lock)

      writer =
        Task.async(fn ->
          unboxed(fn ->
            send(test, {:backend, backend_pid()})
            write.()
          end)
        end)

      assert_receive {:backend, backend}, 15_000
      LockWait.await_lock_wait!(backend, [], timeout_ms: 10_000)
      taken_over!(slot)
      release(holder)
      Task.await(writer, 30_000)
    else
      taken_over!(slot)
      unboxed(write)
    end
  end

  # The member renews to a short lease, a write of its own, and its
  # cached standing is held whatever the lease then does.
  defp expiring!(slot) do
    {:ok, renewed} = unboxed(fn -> ControlPlane.renew(@lease_ms) end)
    assert renewed.generation == slot.generation
    hold_cached(renewed)
    renewed
  end

  defp hold_cached(slot) do
    ControlPlane.record_slot(slot)
    ControlPlane.record_generation(slot.generation)
    ControlPlane.record({:held, 60_000})
  end

  # The lease runs out on the cell's clock with no edit to its row, and a
  # successor takes the slot over through `take/3`. `take/3` records what
  # it won in this VM's standing; the successor is another member, so this
  # member's own standing is put back.
  defp taken_over!(slot) do
    await_expiry(slot.node)

    assert {:ok, %{generation: generation}} =
             unboxed(fn -> ControlPlane.take(slot.node, slot.node <> "#boot_b", 60_000) end)

    assert generation == slot.generation + 1
    hold_cached(slot)
  end

  defp await_expiry(node, tries \\ 500)
  defp await_expiry(_node, 0), do: flunk("the member's lease never ran out")

  defp await_expiry(node, tries) do
    expired? =
      unboxed(fn ->
        {:ok, %{lease_until: lease_until}} = ControlPlane.slot(node)
        DateTime.compare(lease_until, Arca.ServerMetaStorage.now!()) != :gt
      end)

    unless expired? do
      Process.sleep(20)
      await_expiry(node, tries - 1)
    end
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  # Run `lock` in a transaction of its own and hold it open until
  # `release/1`.
  defp holding(lock) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.transaction(fn ->
            lock.()
            send(test, {:holding, self()})

            receive do
              :commit -> :ok
            end
          end)
        end)
      end)

    assert_receive {:holding, _pid}, 15_000
    task
  end

  defp release(task) do
    send(task.pid, :commit)
    assert {:ok, _} = Task.await(task, 30_000)
  end

  defp backend_pid do
    %{rows: [[pid]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
    pid
  end
end

defmodule Arca.CronScheduleRaceTest do
  @moduledoc """
  Creates racing for an athanor's last schedule places, on connections of
  their own: inside the sandbox one shared connection would serialize
  them. On PostgreSQL every create is held behind a transaction that
  locks the athanor's row until each is seen waiting on it, so all of
  them race for the row when it is let go; SQLite's one write lock admits
  one transaction at a time, so there they run as concurrent processes.
  The case works in an athanor of its own, whose rows it deletes when it
  ends.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Arca.Test.Adapter, only: [postgres?: 0]

  alias Arca.CronSchedule
  alias Arca.Schemas.CronSchedule, as: ScheduleRow
  alias Arca.Test.LockWait
  alias Ecto.Adapters.SQL.Sandbox

  @cap 5
  @creates 12

  setup do
    athanor = "ath_cron_race_#{System.unique_integer([:positive])}"
    unboxed(fn -> Arca.Test.Actor.ensure_athanor_row(athanor) end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(from(s in ScheduleRow, where: s.athanor_id == ^athanor))
        Arca.Repo.delete_all(from(a in Arca.Schemas.Athanor, where: a.id == ^athanor))
      end)
    end)

    {:ok, actor: Arca.Test.Actor.local(athanor_id: athanor)}
  end

  test "concurrent creates stop at the cap", %{actor: actor} do
    test = self()

    create = fn name ->
      Task.async(fn ->
        unboxed(fn ->
          if postgres?(), do: send(test, {:backend, backend_pid()})
          create(actor, name, @cap)
        end)
      end)
    end

    answers =
      if postgres?() do
        holder =
          holding(fn ->
            from(a in Arca.Schemas.Athanor, where: a.id == ^actor.athanor_id)
            |> Arca.QueryHelpers.for_update()
            |> Arca.Repo.one()
          end)

        creators = for i <- 1..@creates, do: create.("race-#{i}")

        for _ <- creators do
          assert_receive {:backend, backend}, 15_000
          LockWait.await_lock_wait!(backend, [], timeout_ms: 10_000)
        end

        release(holder)
        Enum.map(creators, &Task.await(&1, 30_000))
      else
        for(i <- 1..@creates, do: create.("race-#{i}")) |> Enum.map(&Task.await(&1, 30_000))
      end

    assert Enum.count(answers, &match?({:ok, _}, &1)) == @cap
    assert Enum.count(answers, &(&1 == {:error, :schedule_cap})) == @creates - @cap

    assert @cap ==
             unboxed(fn ->
               Arca.Repo.aggregate(
                 from(s in ScheduleRow, where: s.athanor_id == ^actor.athanor_id),
                 :count
               )
             end)
  end

  defp create(actor, name, cap) do
    CronSchedule.create(actor, %{
      user_id: actor.user_id,
      name: name,
      cron_expression: "*/5 * * * *",
      reference: "reagent:local.test:1.0.0",
      profile_id: "prof_test",
      cap: cap
    })
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  defp backend_pid do
    %{rows: [[pid]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  # Run `lock` in a transaction of its own and hold it open until
  # `release/1`.
  defp holding(lock) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.transaction(fn ->
            lock.()
            send(test, {:holding, self()})

            receive do
              :commit -> :ok
            end
          end)
        end)
      end)

    assert_receive {:holding, _pid}, 15_000
    task
  end

  defp release(task) do
    send(task.pid, :commit)
    assert {:ok, _} = Task.await(task, 30_000)
  end
end
