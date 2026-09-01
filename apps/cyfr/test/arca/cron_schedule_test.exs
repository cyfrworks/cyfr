# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CronScheduleTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.CronSchedule
  alias Sanctum.Context

  @athanor Sanctum.TestContext.athanor_id()

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx =
      Context.build(
        user_id: "test_user",
        athanor_id: @athanor,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        namespace: "testns",
        authenticated: true
      )

    {:ok, ctx: ctx}
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
    test "finds by name", %{ctx: ctx} do
      {:ok, schedule} = CronSchedule.create(valid_attrs(%{name: "find-me"}))
      {:ok, found} = CronSchedule.get_by_id_or_name(ctx, "find-me")
      assert found.id == schedule.id
    end

    test "finds by id", %{ctx: ctx} do
      {:ok, schedule} = CronSchedule.create(valid_attrs())
      {:ok, found} = CronSchedule.get_by_id_or_name(ctx, schedule.id)
      assert found.id == schedule.id
    end

    test "does not find deleted schedules", %{ctx: ctx} do
      {:ok, schedule} = CronSchedule.create(valid_attrs(%{name: "deleted-one"}))
      CronSchedule.soft_delete(ctx, schedule.id)
      assert CronSchedule.get_by_id_or_name(ctx, "deleted-one") == {:error, :not_found}
    end

    test "finds a fellow member's schedule in the same athanor (interchangeable)" do
      {:ok, created} = CronSchedule.create(valid_attrs(%{name: "private", user_id: "other_user"}))

      ctx =
        Context.build(
          user_id: "test_user",
          athanor_id: @athanor,
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      # Same athanor, different creator — visible.
      {:ok, found} = CronSchedule.get_by_id_or_name(ctx, "private")
      assert found != nil
      assert found.id == created.id
    end
  end

  describe "list/2" do
    test "lists all non-deleted schedules in the athanor regardless of creator", %{ctx: ctx} do
      {:ok, _} = CronSchedule.create(valid_attrs(%{name: "s1"}))
      {:ok, s2} = CronSchedule.create(valid_attrs(%{name: "s2"}))
      {:ok, _} = CronSchedule.create(valid_attrs(%{name: "other", user_id: "other_user"}))
      CronSchedule.soft_delete(ctx, s2.id)

      {:ok, schedules} = CronSchedule.list(ctx)
      names = Enum.map(schedules, & &1.name)

      assert length(schedules) == 2
      assert "s1" in names
      assert "other" in names
      refute "s2" in names
    end
  end

  describe "active_schedules/0" do
    test "returns only active schedules", %{ctx: ctx} do
      {:ok, _} = CronSchedule.create(valid_attrs(%{name: "active1"}))
      {:ok, paused} = CronSchedule.create(valid_attrs(%{name: "paused1"}))
      CronSchedule.update(ctx, paused.id, %{status: "paused"})

      {:ok, active} = CronSchedule.active_schedules()
      names = Enum.map(active, & &1.name)
      assert "active1" in names
      refute "paused1" in names
    end
  end

  describe "claim/4 and release_claim/2" do
    # The claim takes an OCCURRENCE, so a claimable schedule is one whose
    # `next_run_at` is due. `create/1` computes it from the expression, so
    # tests that want a due occurrence say so.
    defp due!(name) do
      {:ok, schedule} = CronSchedule.create(valid_attrs(%{name: name}))
      past = DateTime.utc_now() |> DateTime.add(-60, :second)

      {1, _} =
        Arca.Repo.update_all(
          from(s in Arca.CronSchedule, where: s.id == ^schedule.id),
          set: [next_run_at: past]
        )

      schedule
    end

    defp next_occurrence, do: DateTime.utc_now() |> DateTime.add(300, :second)

    defp next_run_at!(id) do
      {:ok, row} = CronSchedule.get_for_daemon(id)
      row.next_run_at
    end

    test "one claimant wins; the claim lapses and comes back" do
      schedule = due!("claimed")

      assert :claimed = CronSchedule.claim(schedule.id, "node-a", 60, next_occurrence())
      assert :held = CronSchedule.claim(schedule.id, "node-b", 60, next_occurrence())
      assert :held = CronSchedule.claim(schedule.id, "node-a", 60, next_occurrence())

      # Only the claimant releases; a stranger's release is a no-op.
      :ok = CronSchedule.release_claim(schedule.id, "node-b")
      assert :held = CronSchedule.claim(schedule.id, "node-b", 60, next_occurrence())
      :ok = CronSchedule.release_claim(schedule.id, "node-a")

      # Released — but the OCCURRENCE has moved on, so there is nothing to
      # take until the next one falls due. That is the fix: releasing the
      # claim no longer re-offers the firing that was already run.
      assert :held = CronSchedule.claim(schedule.id, "node-b", 60, next_occurrence())
    end

    test "two nodes racing the same occurrence: exactly one fires it" do
      # The double-fire, directly. Node A claims, runs, and gives the claim
      # back within the second; node B's jittered timer for the SAME
      # occurrence arrives next. Before the advance was part of the CAS, B
      # found a free claim and an unadvanced `next_run_at` and fired the
      # occurrence a second time — only the per-node `running` MapSet stood
      # in the way, and that is per node.
      schedule = due!("raced")
      advanced_to = next_occurrence()

      assert :claimed = CronSchedule.claim(schedule.id, "node-a", 60, advanced_to)
      :ok = CronSchedule.release_claim(schedule.id, "node-a")

      assert :held = CronSchedule.claim(schedule.id, "node-b", 60, next_occurrence()),
             "a second node fired an occurrence node-a had already taken"

      assert DateTime.compare(next_run_at!(schedule.id), advanced_to) == :eq,
             "the winner's advance must stand — the loser must not overwrite it"
    end

    test "a lapsed claim is superseded only if the occurrence is still due" do
      schedule = due!("lapsed")

      # A claim that has already run out, but which advanced the occurrence
      # past now: the lapse alone does not re-offer it.
      assert :claimed = CronSchedule.claim(schedule.id, "node-a", -1, next_occurrence())
      assert :held = CronSchedule.claim(schedule.id, "node-b", 60, next_occurrence())

      # With the occurrence due again, the lapsed claim is superseded.
      past = DateTime.utc_now() |> DateTime.add(-1, :second)

      {1, _} =
        Arca.Repo.update_all(
          from(s in Arca.CronSchedule, where: s.id == ^schedule.id),
          set: [next_run_at: past]
        )

      assert :claimed = CronSchedule.claim(schedule.id, "node-b", 60, next_occurrence())
    end

    test "an inactive schedule cannot be claimed" do
      {:ok, schedule} = CronSchedule.create(valid_attrs(%{name: "paused", status: "paused"}))
      assert :held = CronSchedule.claim(schedule.id, "node-a", 60, next_occurrence())
    end

    test "an occurrence that is not yet due cannot be claimed" do
      {:ok, schedule} = CronSchedule.create(valid_attrs(%{name: "early"}))
      assert :held = CronSchedule.claim(schedule.id, "node-a", 60, next_occurrence())
    end
  end

  describe "record_run/3" do
    test "increments run_count and sets last_run_at", %{ctx: ctx} do
      {:ok, schedule} = CronSchedule.create(valid_attrs())
      assert {:ok, updated} = CronSchedule.record_run(ctx, schedule.id, "exec_123")
      assert updated.run_count == 1
      assert updated.last_execution_id == "exec_123"
      assert updated.last_run_at != nil
    end
  end

  describe "record_error/3" do
    test "increments error_count", %{ctx: ctx} do
      {:ok, schedule} = CronSchedule.create(valid_attrs())
      assert {:ok, updated} = CronSchedule.record_error(ctx, schedule.id, "boom")
      assert updated.error_count == 1
    end
  end

  describe "count_active/1" do
    test "counts non-deleted schedules", %{ctx: ctx} do
      {:ok, _} = CronSchedule.create(valid_attrs(%{name: "c1"}))
      {:ok, s2} = CronSchedule.create(valid_attrs(%{name: "c2"}))
      CronSchedule.soft_delete(ctx, s2.id)

      assert CronSchedule.count_active(ctx) == {:ok, 1}
    end
  end
end
