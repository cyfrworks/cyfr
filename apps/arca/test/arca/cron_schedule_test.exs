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
        profile_id: "prof_test"
      },
      overrides
    )
  end

  describe "create/1" do
    test "creates a schedule with valid attrs" do
      assert {:ok, schedule} = CronSchedule.create(valid_attrs())
      assert schedule.user_id == "test_user"
      assert schedule.status == "active"
      assert schedule.run_count == 0
      assert schedule.error_count == 0
      assert String.starts_with?(schedule.id, "sched_")
    end

    test "requires name" do
      assert {:error, _} = CronSchedule.create(valid_attrs(%{name: nil}))
    end

    test "requires cron_expression" do
      assert {:error, _} = CronSchedule.create(valid_attrs(%{cron_expression: nil}))
    end

    test "requires reference" do
      assert {:error, _} = CronSchedule.create(valid_attrs(%{reference: nil}))
    end
  end

  describe "get_by_id_or_name/2" do
    test "finds by name", %{actor: actor} do
      {:ok, schedule} = CronSchedule.create(valid_attrs(%{name: "find-me"}))
      {:ok, found} = CronSchedule.get_by_id_or_name(actor, "find-me")
      assert found.id == schedule.id
    end

    test "finds by id", %{actor: actor} do
      {:ok, schedule} = CronSchedule.create(valid_attrs())
      {:ok, found} = CronSchedule.get_by_id_or_name(actor, schedule.id)
      assert found.id == schedule.id
    end

    test "does not find deleted schedules", %{actor: actor} do
      {:ok, schedule} = CronSchedule.create(valid_attrs(%{name: "deleted-one"}))
      CronSchedule.soft_delete(actor, schedule.id)

      assert CronSchedule.get_by_id_or_name(actor, "deleted-one") ==
               {:error, :not_found}
    end

    test "finds a fellow member's schedule in the same athanor (interchangeable)" do
      {:ok, created} = CronSchedule.create(valid_attrs(%{name: "private", user_id: "other_user"}))

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
      {:ok, _} = CronSchedule.create(valid_attrs(%{name: "s1"}))
      {:ok, s2} = CronSchedule.create(valid_attrs(%{name: "s2"}))
      {:ok, _} = CronSchedule.create(valid_attrs(%{name: "other", user_id: "other_user"}))
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
      {:ok, _} = CronSchedule.create(valid_attrs(%{name: "active1"}))
      {:ok, paused} = CronSchedule.create(valid_attrs(%{name: "paused1"}))
      CronSchedule.update(actor, paused.id, %{status: "paused"})

      {:ok, active} = CronSchedule.active_schedules()
      names = Enum.map(active, & &1.name)
      assert "active1" in names
      refute "paused1" in names
    end
  end

  describe "record_run/3" do
    test "increments run_count and sets last_run_at", %{actor: actor} do
      {:ok, schedule} = CronSchedule.create(valid_attrs())

      assert {:ok, updated} =
               CronSchedule.record_run(actor, schedule.id, "exec_123")

      assert updated.run_count == 1
      assert updated.last_execution_id == "exec_123"
      assert updated.last_run_at != nil
    end
  end

  describe "record_error/3" do
    test "increments error_count", %{actor: actor} do
      {:ok, schedule} = CronSchedule.create(valid_attrs())

      assert {:ok, updated} =
               CronSchedule.record_error(actor, schedule.id, "boom")

      assert updated.error_count == 1
    end
  end

  describe "count_active/2" do
    test "counts non-deleted schedules", %{actor: actor} do
      {:ok, _} = CronSchedule.create(valid_attrs(%{name: "c1"}))
      {:ok, s2} = CronSchedule.create(valid_attrs(%{name: "c2"}))
      CronSchedule.soft_delete(actor, s2.id)

      assert CronSchedule.count_active(actor, "schedule") == {:ok, 1}
    end

    test "counts one kind: a feed is not a schedule", %{actor: actor} do
      {:ok, _} = CronSchedule.create(valid_attrs(%{name: "c1"}))
      {:ok, _} = feed!(actor, "c1")
      {:ok, removed} = feed!(actor, "c2")
      {:ok, _} = CronSchedule.remove_feed(actor, removed.id)

      assert CronSchedule.count_active(actor, "schedule") == {:ok, 1}
      assert CronSchedule.count_active(actor, "feed") == {:ok, 1}
    end
  end

  describe "kinds" do
    test "create/1 always writes a schedule, whatever the attributes name", %{actor: actor} do
      {:ok, row} =
        CronSchedule.create(
          valid_attrs(%{name: "not-a-feed", kind: "feed", feed_spec: "{}", feed_fire_seq: 9})
        )

      assert %{kind: "schedule", feed_spec: nil, feed_fire_seq: 0} = row
      assert {:error, :not_found} = CronSchedule.get_feed(actor, row.id)
    end

    test "a feed may share a schedule's name, and a kind-scoped read tells them apart", %{
      actor: actor
    } do
      {:ok, schedule} = CronSchedule.create(valid_attrs(%{name: "btc"}))
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
      for i <- 1..3, do: {:ok, _} = CronSchedule.create(valid_attrs(%{name: "s#{i}"}))
      {:ok, a} = feed!(actor, "a", 2)
      {:ok, _} = feed!(actor, "b", 2)

      assert {:error, :feed_cap} = feed!(actor, "c", 2)
      assert CronSchedule.count_active(actor, "feed") == {:ok, 2}

      {:ok, _} = CronSchedule.remove_feed(actor, a.id)
      assert {:ok, _} = feed!(actor, "c", 2)
      assert {:error, :feed_cap} = feed!(actor, "d", 0)
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
      assert CronSchedule.count_active(actor, "feed") == {:ok, 0}
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
      {:ok, schedule} = CronSchedule.create(valid_attrs(%{name: "btc"}))
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
      {:ok, _} = CronSchedule.create(valid_attrs(%{name: "a-schedule"}))
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
  end

  # ---- feed helpers ------------------------------------------------------------

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
