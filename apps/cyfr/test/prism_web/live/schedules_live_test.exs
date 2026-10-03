# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SchedulesLiveTest do
  use PrismWeb.ConnCase, async: false

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    ctx = %{Sanctum.TestContext.local() | athanor_id: seated_athanor().id, user_id: user.user_id}

    wasm = File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))

    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, wasm, %{
        name: "schedule-target",
        version: "0.1.0",
        type: "reagent",
        description: "Schedule target"
      })

    profile_id =
      Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "reagent:local.schedule-target")

    {view, _html} = mount_athanor(conn, "/schedules")
    render_click(view, "toggle_create")
    render_change(view, "cron_preset_change", %{"cron_preset" => "custom"})

    params = %{
      "name" => "console-schedule-#{System.unique_integer([:positive])}",
      "reference" => "reagent:local.schedule-target",
      "profile_id" => profile_id,
      "cron_custom" => "0 0 1 1 *",
      "input" => ~s({"count":0,"enabled":false})
    }

    {:ok, view: view, ctx: ctx, params: params}
  end

  # The profile's grant, made again through the walk with `origins`.
  defp grant_origins!(ctx, origins) do
    ref = "reagent:local.schedule-target"
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref})
    decisions = %{ref: ref, origins: origins}
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, _} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })
  end

  defp schedule(ctx, params),
    do: Arca.CronSchedule.get_by_id_or_name(Sanctum.Context.actor(ctx), params["name"])

  defp grant_open?(view), do: has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))

  test "creation binds the explicitly entered profile and preserves JSON values", %{
    view: view,
    ctx: ctx,
    params: params
  } do
    grant_origins!(ctx, [:interactive, :schedule])
    assert has_element?(view, "input[name=profile_id][required]")
    render_submit(view, "create", params)

    assert {:ok, schedule} =
             Arca.CronSchedule.get_by_id_or_name(Sanctum.Context.actor(ctx), params["name"])

    assert schedule.profile_id == params["profile_id"]
    assert Jason.decode!(schedule.input) == %{"count" => 0, "enabled" => false}
    refute :sys.get_state(view.pid).socket.assigns.show_create
  end

  test "malformed and non-object JSON refuse without creating a schedule", %{
    view: view,
    ctx: ctx,
    params: params
  } do
    for input <- ["{broken", "[]", "null", "false", "1"] do
      submitted = Map.put(params, "input", input)
      html = render_submit(view, "create", submitted)
      assert html =~ "Input must be a valid JSON object"

      assert {:error, :not_found} =
               Arca.CronSchedule.get_by_id_or_name(Sanctum.Context.actor(ctx), params["name"])

      assert_form(view, submitted)
    end
  end

  test "a missing profile does not choose authority automatically", %{
    view: view,
    ctx: ctx,
    params: params
  } do
    submitted = Map.delete(params, "profile_id")
    html = render_submit(view, "create", submitted)
    assert html =~ "Please enter the profile"

    assert {:error, :not_found} =
             Arca.CronSchedule.get_by_id_or_name(Sanctum.Context.actor(ctx), params["name"])

    assert_form(view, Map.put(submitted, "profile_id", ""))
  end

  test "a refused profile binding keeps the form for correction", %{
    view: view,
    ctx: ctx,
    params: params
  } do
    submitted = Map.put(params, "profile_id", "nonexistent-profile")
    render_submit(view, "create", submitted)
    assert :sys.get_state(view.pid).socket.assigns.flash["error"]

    assert {:error, :not_found} =
             Arca.CronSchedule.get_by_id_or_name(Sanctum.Context.actor(ctx), params["name"])

    assert_form(view, submitted)
  end

  describe "a profile whose grant does not admit schedules" do
    test "raises the grant prompt first, and a dismissal makes no schedule", %{
      view: view,
      ctx: ctx,
      params: params
    } do
      render_submit(view, "create", params)
      render(view)

      assert grant_open?(view)
      assert {:error, :not_found} = schedule(ctx, params)
      refute has_element?(view, ~s(input[data-origin="schedule"][checked]))

      view |> element(~s(#system-layer button[phx-click="dismiss"])) |> render_click()
      render(view)

      assert {:error, :not_found} = schedule(ctx, params)
      assert :sys.get_state(view.pid).socket.assigns.flash["error"] =~ "No schedule was made"
    end

    test "granted with the schedule origin, the schedule is made", %{
      view: view,
      ctx: ctx,
      params: params
    } do
      render_submit(view, "create", params)
      render(view)
      assert grant_open?(view)

      view
      |> element(~s(input[phx-click="toggle_origin"][phx-value-origin="schedule"]))
      |> render_click()

      render(view)
      view |> element(~s(#system-layer button[phx-click="confirm"])) |> render_click()

      Prima.Test.Wait.wait_until(
        fn -> render(view) && match?({:ok, _}, schedule(ctx, params)) end,
        2_000,
        "the schedule"
      )

      {:ok, made} = schedule(ctx, params)
      assert made.profile_id == params["profile_id"]

      {:ok, head} = Sanctum.Consent.head_consent(ctx, params["profile_id"])
      assert :schedule in head.admitted_origins
    end

    test "granted without the schedule origin, no schedule is made", %{
      view: view,
      ctx: ctx,
      params: params
    } do
      render_submit(view, "create", params)
      render(view)
      view |> element(~s(#system-layer button[phx-click="confirm"])) |> render_click()

      Prima.Test.Wait.wait_until(
        fn ->
          render(view)
          (:sys.get_state(view.pid).socket.assigns.flash["error"] || "") =~ "No schedule was made"
        end,
        2_000,
        "the refusal"
      )

      assert {:error, :not_found} = schedule(ctx, params)
    end
  end

  defp assert_form(view, params) do
    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.show_create

    for field <- ~w(name reference profile_id input) do
      assert assigns.form.params[field] == params[field]
    end

    assert assigns.cron_preset == "custom"
    assert assigns.cron_custom == params["cron_custom"]
  end
end
