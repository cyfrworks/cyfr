# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.DesktopTest do
  @moduledoc """
  A desktop's control read at the press as the call it makes: the
  declaration's own control, the direct rule read again, and a pick
  checked against the strings the stream publishes there now, read under
  the caller's context. Nothing is run here.
  """

  use ExUnit.Case, async: false

  alias Prima.Manifest.Tincture

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {ctx, other} = Sanctum.TestContext.two_contexts()
    {:ok, ctx: ctx, other: other}
  end

  defp desktop(controls) do
    {:ok, declaration} =
      Tincture.from_manifest(%{
        "tincture" => %{"desktop" => %{"data" => ["schedules.changes"], "controls" => controls}}
      })

    declaration.desktop
  end

  defp schedule!(ctx, name) do
    {:ok, row} =
      Arca.CronSchedule.create(Sanctum.Context.actor(ctx), %{
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        name: name,
        cron_expression: "0 3 * * *",
        reference: "reagent:local.#{name}",
        resolved_reference: "reagent:local.#{name}:1.0.0",
        profile_id: "prof-#{name}",
        next_run_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
        cap: 0
      })

    row
  end

  @pick %{"stream" => "schedules.changes", "field" => "/schedule_id", "arg" => "schedule_id"}

  test "a picked control's call takes a value the stream publishes now, and only such a value",
       %{ctx: ctx, other: other} do
    desktop =
      desktop([
        %{"id" => "pause", "label" => "Pause", "operation" => "schedule.pause", "pick" => @pick}
      ])

    digest = schedule!(ctx, "digest")

    assert Compendium.desktop_control(ctx, desktop, "pause", digest.id) ==
             {:ok, {"schedule/pause", %{"schedule_id" => digest.id}}}

    assert {:error, {:invalid_argument, _}} =
             Compendium.desktop_control(ctx, desktop, "pause", "sched_not_published")

    assert {:error, {:invalid_argument, _}} =
             Compendium.desktop_control(ctx, desktop, "pause", nil)

    # Another athanor's schedule is not what this stream publishes to this caller.
    elsewhere = schedule!(other, "elsewhere")

    assert {:error, {:invalid_argument, _}} =
             Compendium.desktop_control(ctx, desktop, "pause", elsewhere.id)
  end

  test "a control the desktop does not declare, or one the direct rule refuses, makes no call", %{
    ctx: ctx
  } do
    desktop =
      desktop([
        %{
          "id" => "fixed",
          "label" => "Pause",
          "operation" => "schedule.pause",
          "args" => %{"schedule_id" => "s"}
        },
        %{"id" => "make", "label" => "Make", "operation" => "schedule.create"},
        %{"id" => "list", "label" => "List", "operation" => "schedule.list"}
      ])

    assert Compendium.desktop_control(ctx, desktop, "fixed", nil) ==
             {:ok, {"schedule/pause", %{"schedule_id" => "s"}}}

    assert {:error, {:invalid_argument, _}} =
             Compendium.desktop_control(ctx, desktop, "fixed", "v")

    assert {:error, {:invalid_argument, _}} =
             Compendium.desktop_control(ctx, desktop, "nowhere", nil)

    for id <- ~w(make list) do
      assert {:error, {:invalid_argument, sentence}} =
               Compendium.desktop_control(ctx, desktop, id, nil)

      assert sentence =~ "tincture.desktop.controls #{id}"
    end

    assert {:error, {:invalid_argument, _}} = Compendium.desktop_control(ctx, nil, "fixed", nil)
  end
end
