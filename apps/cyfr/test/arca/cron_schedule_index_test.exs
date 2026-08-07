# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CronScheduleIndexTest do
  use ExUnit.Case, async: false

  alias Arca.CronSchedule

  # The repo's original partial unique index:
  #   (user_id, name) WHERE status != 'deleted'  — :cron_schedules_user_name_active
  # These tests pin its semantics on both adapters: soft-deleted rows release
  # the name, everything else (active AND paused) holds it.

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()
    {:ok, ctx: ctx}
  end

  defp schedule_attrs(name, overrides \\ %{}) do
    Map.merge(
      %{
        user_id: "index-test-user",
        name: name,
        cron_expression: "0 * * * *",
        reference: "formula:local.index-test:1.0.0",
        org_id: "local",
        project_id: "default"
      },
      overrides
    )
  end

  test "an active schedule blocks a duplicate name for the same user" do
    assert {:ok, _} = CronSchedule.create(schedule_attrs("dup-active"))

    assert_raise Ecto.ConstraintError, fn ->
      CronSchedule.create(schedule_attrs("dup-active"))
    end
  end

  test "a paused schedule still holds its name" do
    assert {:ok, _} = CronSchedule.create(schedule_attrs("dup-paused", %{status: "paused"}))

    assert_raise Ecto.ConstraintError, fn ->
      CronSchedule.create(schedule_attrs("dup-paused"))
    end
  end

  test "a soft-deleted schedule releases its name", %{ctx: ctx} do
    assert {:ok, first} = CronSchedule.create(schedule_attrs("dup-deleted"))
    assert {:ok, _} = CronSchedule.soft_delete(ctx, first.id)

    assert {:ok, _second} = CronSchedule.create(schedule_attrs("dup-deleted"))
  end

  test "multiple soft-deleted namesakes coexist", %{ctx: ctx} do
    assert {:ok, first} = CronSchedule.create(schedule_attrs("dup-many"))
    assert {:ok, _} = CronSchedule.soft_delete(ctx, first.id)
    assert {:ok, second} = CronSchedule.create(schedule_attrs("dup-many"))
    assert {:ok, _} = CronSchedule.soft_delete(ctx, second.id)

    assert {:ok, _third} = CronSchedule.create(schedule_attrs("dup-many"))
  end

  test "the same name under a different user is unaffected" do
    assert {:ok, _} = CronSchedule.create(schedule_attrs("shared-name"))

    assert {:ok, _} =
             CronSchedule.create(schedule_attrs("shared-name", %{user_id: "other-user"}))
  end
end
