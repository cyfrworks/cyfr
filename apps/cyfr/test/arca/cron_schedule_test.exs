# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CronScheduleTest do
  use ExUnit.Case, async: false

  alias Arca.CronSchedule
  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx =
      Context.build(
        user_id: "test_user",
        permissions: [:*],
        scope: :project,
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
        name: "test-schedule-#{:rand.uniform(100_000)}",
        cron_expression: "*/5 * * * *",
        reference: "reagent:local.test:1.0.0"
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

  describe "get_by_user/2" do
    test "finds by name", %{ctx: ctx} do
      {:ok, schedule} = CronSchedule.create(valid_attrs(%{name: "find-me"}))
      found = CronSchedule.get_by_user(ctx, "find-me")
      assert found.id == schedule.id
    end

    test "finds by id", %{ctx: ctx} do
      {:ok, schedule} = CronSchedule.create(valid_attrs())
      found = CronSchedule.get_by_user(ctx, schedule.id)
      assert found.id == schedule.id
    end

    test "does not find deleted schedules", %{ctx: ctx} do
      {:ok, schedule} = CronSchedule.create(valid_attrs(%{name: "deleted-one"}))
      CronSchedule.soft_delete(ctx, schedule.id)
      assert CronSchedule.get_by_user(ctx, "deleted-one") == nil
    end

    test "finds a fellow member's schedule in the same project (interchangeable)" do
      {:ok, created} = CronSchedule.create(valid_attrs(%{name: "private", user_id: "other_user"}))

      ctx =
        Context.build(
          user_id: "test_user",
          permissions: [:*],
          scope: :project,
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      # Same tenant (default org/project), different creator — now visible.
      found = CronSchedule.get_by_user(ctx, "private")
      assert found != nil
      assert found.id == created.id
    end
  end

  describe "list_by_user/2" do
    test "lists all non-deleted schedules in the project regardless of creator", %{ctx: ctx} do
      {:ok, _} = CronSchedule.create(valid_attrs(%{name: "s1"}))
      {:ok, s2} = CronSchedule.create(valid_attrs(%{name: "s2"}))
      {:ok, _} = CronSchedule.create(valid_attrs(%{name: "other", user_id: "other_user"}))
      CronSchedule.soft_delete(ctx, s2.id)

      schedules = CronSchedule.list_by_user(ctx)
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

      active = CronSchedule.active_schedules()
      names = Enum.map(active, & &1.name)
      assert "active1" in names
      refute "paused1" in names
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

  describe "count_by_user/1" do
    test "counts non-deleted schedules", %{ctx: ctx} do
      {:ok, _} = CronSchedule.create(valid_attrs(%{name: "c1"}))
      {:ok, s2} = CronSchedule.create(valid_attrs(%{name: "c2"}))
      CronSchedule.soft_delete(ctx, s2.id)

      assert CronSchedule.count_by_user(ctx) == 1
    end
  end
end
