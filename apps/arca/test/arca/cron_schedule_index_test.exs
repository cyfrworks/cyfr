# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CronScheduleIndexTest do
  use ExUnit.Case, async: false

  alias Arca.CronSchedule

  # The partial unique index:
  #   (athanor_id, kind, name) WHERE status != 'deleted'
  #     — :cron_schedules_athanor_kind_name_active
  # A live name is unique per kind, so a feed may share a schedule's name.
  # These tests pin its semantics for schedules on both adapters:
  # soft-deleted rows release the name, everything else (active AND paused)
  # holds it, and the name is scoped to the athanor — a schedule is the
  # athanor's, whoever created it.

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    actor = Arca.Test.Actor.local()
    {:ok, actor: actor}
  end

  defp schedule_attrs(name, overrides \\ %{}) do
    Map.merge(
      %{
        user_id: "index-test-user",
        name: name,
        cron_expression: "0 * * * *",
        reference: "formula:local.index-test:1.0.0",
        resolved_reference: "formula:local.index-test:1.0.0",
        profile_id: "prof_test",
        athanor_id: Arca.Test.Actor.athanor_id(),
        cap: 1_000
      },
      overrides
    )
  end

  test "an active schedule blocks a duplicate name in the same athanor", %{actor: actor} do
    assert {:ok, _} = CronSchedule.create(actor, schedule_attrs("dup-active"))

    assert_raise Ecto.ConstraintError, fn ->
      CronSchedule.create(actor, schedule_attrs("dup-active"))
    end
  end

  test "a paused schedule still holds its name", %{actor: actor} do
    assert {:ok, _} =
             CronSchedule.create(actor, schedule_attrs("dup-paused", %{status: "paused"}))

    assert_raise Ecto.ConstraintError, fn ->
      CronSchedule.create(actor, schedule_attrs("dup-paused"))
    end
  end

  test "a soft-deleted schedule releases its name", %{actor: actor} do
    assert {:ok, first} = CronSchedule.create(actor, schedule_attrs("dup-deleted"))
    assert {:ok, _} = CronSchedule.soft_delete(actor, first.id)

    assert {:ok, _second} = CronSchedule.create(actor, schedule_attrs("dup-deleted"))
  end

  test "multiple soft-deleted namesakes coexist", %{actor: actor} do
    assert {:ok, first} = CronSchedule.create(actor, schedule_attrs("dup-many"))
    assert {:ok, _} = CronSchedule.soft_delete(actor, first.id)
    assert {:ok, second} = CronSchedule.create(actor, schedule_attrs("dup-many"))
    assert {:ok, _} = CronSchedule.soft_delete(actor, second.id)

    assert {:ok, _third} = CronSchedule.create(actor, schedule_attrs("dup-many"))
  end

  test "the same name from another member of the athanor is a duplicate", %{actor: actor} do
    assert {:ok, _} = CronSchedule.create(actor, schedule_attrs("shared-name"))
    other_member = Arca.Test.Actor.local(user_id: "other-user")

    assert_raise Ecto.ConstraintError, fn ->
      CronSchedule.create(other_member, schedule_attrs("shared-name", %{user_id: "other-user"}))
    end
  end

  test "the same name in a different athanor is unaffected", %{actor: actor} do
    assert {:ok, _} = CronSchedule.create(actor, schedule_attrs("shared-name"))
    other_athanor = Arca.Test.Actor.local(athanor_id: "ath_other")

    assert {:ok, _} =
             CronSchedule.create(
               other_athanor,
               schedule_attrs("shared-name", %{athanor_id: "ath_other"})
             )
  end
end
