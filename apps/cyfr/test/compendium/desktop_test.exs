# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.DesktopTest do
  @moduledoc """
  A desktop's control read at the press as the call it makes: the
  declaration's own control, the control rule read again, run directly
  or once the person approves it on CYFR's preview, and a pick checked
  against the strings the stream publishes there now, read under the
  caller's context; and a frame's request read as what it asks the
  person for. Nothing is run here.
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
             {:ok, {:direct, {"schedule/pause", %{"schedule_id" => digest.id}}}}

    assert {:error, {:invalid_argument, _}} =
             Compendium.desktop_control(ctx, desktop, "pause", "sched_not_published")

    assert {:error, {:invalid_argument, _}} =
             Compendium.desktop_control(ctx, desktop, "pause", nil)

    # Another athanor's schedule is not what this stream publishes to this caller.
    elsewhere = schedule!(other, "elsewhere")

    assert {:error, {:invalid_argument, _}} =
             Compendium.desktop_control(ctx, desktop, "pause", elsewhere.id)
  end

  test "a control the desktop does not declare, or one the control rule refuses, makes no call",
       %{
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
        %{"id" => "list", "label" => "List", "operation" => "schedule.list"}
      ])

    assert Compendium.desktop_control(ctx, desktop, "fixed", nil) ==
             {:ok, {:direct, {"schedule/pause", %{"schedule_id" => "s"}}}}

    assert {:error, {:invalid_argument, _}} =
             Compendium.desktop_control(ctx, desktop, "fixed", "v")

    assert {:error, {:invalid_argument, _}} =
             Compendium.desktop_control(ctx, desktop, "nowhere", nil)

    assert {:error, {:invalid_argument, sentence}} =
             Compendium.desktop_control(ctx, desktop, "list", nil)

    assert sentence =~ "tincture.desktop.controls list"

    assert {:error, {:invalid_argument, _}} = Compendium.desktop_control(ctx, nil, "fixed", nil)
  end

  test "a control of a person-only or destructive act asks, with the preview of exactly its call",
       %{ctx: ctx} do
    digest = schedule!(ctx, "digest")

    desktop =
      desktop([
        %{
          "id" => "make",
          "label" => "Make",
          "operation" => "schedule.create",
          "args" => %{
            "name" => "nightly",
            "cron_expression" => "0 3 * * *",
            "reference" => "reagent:local.nightly",
            "profile_id" => "prof-default"
          }
        },
        %{"id" => "drop", "label" => "Delete", "operation" => "schedule.delete", "pick" => @pick}
      ])

    assert {:ok, {:asks, ask}} = Compendium.desktop_control(ctx, desktop, "make", nil)
    assert %{operation: "schedule.create", tool: "schedule/create"} = ask
    assert ask.args["name"] == "nightly"

    assert %Prima.Confirmation.Preview{operation: "schedule.create", details: details} =
             ask.preview

    assert details == %{
             "name" => "nightly",
             "cron_expression" => "0 3 * * *",
             "reference" => "reagent:local.nightly",
             "profile_id" => "prof-default"
           }

    # A pick is checked as a direct control's is before anything is asked.
    assert {:ok, {:asks, %{tool: "schedule/delete", args: %{"schedule_id" => id}}}} =
             Compendium.desktop_control(ctx, desktop, "drop", digest.id)

    assert id == digest.id

    assert {:error, {:invalid_argument, _}} =
             Compendium.desktop_control(ctx, desktop, "drop", "sched_not_published")
  end

  describe "a frame's request" do
    test "names a grant of an installed component, versionless", %{ctx: ctx} do
      assert {:error, {:not_found, "Component", "c:local.nothing-here"}} =
               Compendium.desktop_request(ctx, "grant", %{"ref" => "c:local.nothing-here"})
    end

    test "names a person-only act with arguments its declaration takes, previewed as it runs",
         %{ctx: ctx} do
      args = %{
        "name" => "digest",
        "cron_expression" => "0 8 * * *",
        "reference" => "formula:local.digest",
        "profile_id" => "prof-default",
        "input" => %{"b" => [1, 2], "a" => "x"}
      }

      assert {:ok, {:asks, ask}} = Compendium.desktop_request(ctx, "schedule.create", args)
      assert ask.tool == "schedule/create"
      assert ask.args == args
      assert ask.preview.details["input"] == ~s({"a":"x","b":[1,2]})
      assert ask.preview.athanor != nil
    end

    test "refuses what is not the person's own act, what the declaration does not take, and secrets",
         %{ctx: ctx} do
      for {operation, args} <- [
            {"schedule.pause", %{"schedule_id" => "s"}},
            {"profile.grant", %{}},
            {"schedule.list", %{}},
            {"schedule.create", %{"name" => "x", "action" => "delete"}},
            {"schedule.create", %{"nme" => "x"}},
            {"feed.bind", %{"name" => "x", "api_key" => "sk-1"}},
            {"schedule.create", %{"name" => String.duplicate("a", 2_000)}}
          ] do
        assert {:error, {:invalid_argument, sentence}} =
                 Compendium.desktop_request(ctx, operation, args),
               inspect({operation, args})

        assert is_binary(sentence)
      end
    end
  end
end
