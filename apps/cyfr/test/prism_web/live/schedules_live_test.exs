# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SchedulesLiveTest do
  use PrismWeb.ConnCase, async: false

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    ctx = %{Sanctum.TestContext.local() | athanor_id: seated_athanor().id, user_id: user.user_id}

    wasm = Cyfr.Test.Guests.wasm(:reagent)

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

    {:ok, conn: conn, view: view, ctx: ctx, params: params}
  end

  # The profile's grant, made again through the walk as the grant sheet
  # commits it.
  defp grant!(ctx) do
    ref = "reagent:local.schedule-target"
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref})
    decisions = %{ref: ref}
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
    assert has_element?(view, ~s(#schedule-form [data-test="schedule-form-error"]))
    refute :sys.get_state(view.pid).socket.assigns.flash["error"]

    assert {:error, :not_found} =
             Arca.CronSchedule.get_by_id_or_name(Sanctum.Context.actor(ctx), params["name"])

    assert_form(view, submitted)
  end

  describe "a line for Aqua" do
    test "the form takes a line in place of a component, a profile and input, and the schedule holds it",
         %{view: view, ctx: ctx, params: params} do
      render_change(view, "target_change", %{"target" => "aqua"})

      assert has_element?(view, "textarea[name=line][required]")
      refute has_element?(view, "input[name=profile_id]")
      refute has_element?(view, "input[name=input]")

      render_submit(view, "create", %{
        "name" => params["name"],
        "target" => "aqua",
        "line" => "summarise what is unread",
        "cron_custom" => "0 0 1 1 *",
        "missed_runs" => "skip"
      })

      assert {:ok, schedule} = schedule(ctx, params)

      assert %{
               reference: "agent:local.aqua",
               resolved_reference: "agent:local.aqua",
               profile_id: nil
             } =
               schedule

      assert Jason.decode!(schedule.input) == %{"line" => "summarise what is unread"}
      assert render(view) =~ "Aqua: summarise what is unread"
    end

    test "an empty line makes no schedule and keeps the form", %{
      view: view,
      ctx: ctx,
      params: params
    } do
      render_change(view, "target_change", %{"target" => "aqua"})

      render_submit(view, "create", %{
        "name" => params["name"],
        "target" => "aqua",
        "line" => "   ",
        "cron_custom" => "0 0 1 1 *"
      })

      assert render(view) =~ "A line for Aqua must say something"
      assert {:error, :not_found} = schedule(ctx, params)
      assert has_element?(view, "textarea[name=line]")
    end
  end

  # `ui.schedule.focus` names a schedule by its id: that one row is marked,
  # and a page opened without one marks none.
  test "the schedule a focus link names is the one row marked", %{
    conn: conn,
    view: view,
    ctx: ctx,
    params: params
  } do
    render_submit(view, "create", params)
    assert {:ok, %{id: id}} = schedule(ctx, params)

    marked = ~s(tr[class*="bg-gray-800/80"] #missed-#{id})

    {focused, _html} = mount_athanor(conn, "/schedules?id=#{id}")
    assert has_element?(focused, marked)

    {unfocused, _html} = mount_athanor(conn, "/schedules")
    assert has_element?(unfocused, "#missed-#{id}")
    refute has_element?(unfocused, marked)
  end

  describe "a run that did not succeed" do
    test "the row says what its schedule says of it and links its run, until a good run clears it",
         %{conn: conn, view: view, ctx: ctx, params: params} do
      render_submit(view, "create", params)
      assert {:ok, %{id: id} = schedule} = schedule(ctx, params)
      actor = Sanctum.Context.actor(ctx)
      failed = "Last run failed: The upstream closed the connection."
      unknown = "Last run did not report its end, so whether it had its effect is not known."
      run = athanor_path("/executions?id=exec_failed")

      {:ok, _} = Arca.CronSchedule.record_error(actor, id, failed, occurrence!(ctx, schedule))
      {page, _html} = mount_athanor(conn, "/schedules")
      assert has_element?(page, "p", failed)
      assert has_element?(page, ~s(a[href="#{run}"]), "Open the run")

      # A run whose end was never recorded is never called a failure.
      {:ok, _} = Arca.CronSchedule.record_error(actor, id, unknown, occurrence!(ctx, schedule))
      {page, _html} = mount_athanor(conn, "/schedules")
      assert has_element?(page, "p", unknown)
      refute has_element?(page, "p", "Last run failed")
      assert has_element?(page, ~s(a[href="#{run}"]), "Open the run")

      # A run that never started names no run.
      {:ok, _} =
        Arca.CronSchedule.record_error(
          actor,
          id,
          "Last run did not start: Invalid JSON input",
          nil
        )

      {page, _html} = mount_athanor(conn, "/schedules")
      assert has_element?(page, "p", "Last run did not start: Invalid JSON input")
      refute has_element?(page, "a", "Open the run")

      {:ok, _} = Arca.CronSchedule.record_run(actor, id, "exec_good")
      {page, _html} = mount_athanor(conn, "/schedules")
      refute has_element?(page, "p", "Last run")
      refute has_element?(page, "a", "Open the run")
    end
  end

  # An ended occurrence of `schedule` whose run is `exec_failed`, each due
  # at a time of its own.
  defp occurrence!(ctx, schedule) do
    n = System.unique_integer([:positive, :monotonic])

    Arca.Repo.insert!(%Arca.Schemas.ScheduleOccurrence{
      id: "occ_" <> Integer.to_string(n),
      athanor_id: ctx.athanor_id,
      schedule_id: schedule.id,
      scheduled_for: DateTime.add(DateTime.utc_now(), -n, :second),
      state: "failed",
      execution_id: "exec_failed",
      claimed_at: DateTime.utc_now()
    }).id
  end

  describe "missed runs" do
    test "a schedule is made with the policy chosen, its row shows it, and the row saves a change",
         %{view: view, ctx: ctx, params: params} do
      render_submit(
        view,
        "create",
        Map.merge(params, %{"missed_runs" => "catch_up", "catch_up_limit" => "3"})
      )

      assert {:ok, %{id: id, missed_runs: "catch_up", catch_up_limit: 3}} = schedule(ctx, params)

      # The row shows the policy it holds.
      assert has_element?(view, ~s(#missed-#{id} option[value="catch_up"][selected]))
      assert has_element?(view, ~s(#missed-#{id} input[name="catch_up_limit"][value="3"]))

      view
      |> form("#missed-#{id}", %{"missed_runs" => "catch_up", "catch_up_limit" => "5"})
      |> render_submit()

      assert {:ok, %{catch_up_limit: 5}} = schedule(ctx, params)
      assert has_element?(view, ~s(#missed-#{id} input[name="catch_up_limit"][value="5"]))

      view |> form("#missed-#{id}", %{"missed_runs" => "skip"}) |> render_submit()
      assert {:ok, %{missed_runs: "skip", catch_up_limit: nil}} = schedule(ctx, params)
      assert has_element?(view, ~s(#missed-#{id} option[value="skip"][selected]))
    end

    test "a catch-up without a whole limit, or with 0, is refused and the schedule stands",
         %{view: view, ctx: ctx, params: params} do
      render_submit(
        view,
        "create",
        Map.merge(params, %{"missed_runs" => "catch_up", "catch_up_limit" => ""})
      )

      assert {:error, :not_found} = schedule(ctx, params)

      render_submit(view, "create", params)
      assert {:ok, %{id: id, missed_runs: "skip"}} = schedule(ctx, params)

      for limit <- ["0", "two"] do
        html =
          view
          |> form("#missed-#{id}", %{"missed_runs" => "catch_up", "catch_up_limit" => limit})
          |> render_submit()

        assert html =~ "Failed"
        assert {:ok, %{missed_runs: "skip", catch_up_limit: nil}} = schedule(ctx, params)
      end
    end
  end

  describe "a profile whose grant was made through the walk" do
    test "making a schedule for it creates the schedule at once, with no grant prompt", %{
      view: view,
      ctx: ctx,
      params: params
    } do
      grant!(ctx)
      render_submit(view, "create", params)
      render(view)

      refute grant_open?(view)
      assert {:ok, %{id: id} = made} = schedule(ctx, params)
      assert made.profile_id == params["profile_id"]
      assert has_element?(view, "#missed-#{id}")
      assert :sys.get_state(view.pid).socket.assigns.flash == %{"info" => "Schedule created"}
    end
  end

  describe "the feeds" do
    test "lists each feed and never its arguments or result, reads them again on a publication, " <>
           "and removes one through feed.remove",
         %{view: view, ctx: ctx} do
      actor = Sanctum.Context.actor(ctx)
      {feed, binding} = feed!(actor, "btc")
      refute render(view) =~ feed.id

      # A published result sends the page back to the feeds' list.
      envelope =
        Prima.Feed.envelope(feed.id, binding, 1, DateTime.utc_now(), %{"price" => "SECRET-PRICE"})

      :ok =
        Cyfr.Bus.broadcast(
          actor,
          Cyfr.Bus.feeds(actor),
          Cyfr.Bus.FeedPublished.new(actor, envelope)
        )

      Prima.Test.Wait.wait_until(fn -> render(view) =~ feed.id end, 2_000, "the feed's row")

      row = view |> element("#feed-#{feed.id}") |> render()

      for shown <- [
            "btc",
            feed.id,
            "catalyst:local.markets",
            "quote",
            "Every 5 minutes",
            "Refresh"
          ],
          do: assert(row =~ shown, shown)

      refute render(view) =~ "SECRET"

      view
      |> element(~s(button[phx-click="remove_feed"][phx-value-id="#{feed.id}"]))
      |> render_click()

      assert {:error, :not_found} = Arca.CronSchedule.get_feed(actor, feed.id)
      refute render(view) =~ feed.id
      assert :sys.get_state(view.pid).socket.assigns.flash["info"] == "Feed removed"
    end
  end

  defp feed!(actor, name) do
    {:ok, binding} =
      Prima.Feed.Binding.validate(%{
        "name" => name,
        "label" => "Feed #{name}",
        "reference" => "catalyst:local.markets",
        "operation" => "quote",
        "args" => %{"symbol" => "SECRET-ARG"},
        "interval_minutes" => 5,
        "result_shape" => %{"type" => "json"},
        "actions" => [%{"name" => "refresh", "label" => "Refresh", "kind" => "refresh"}]
      })

    {:ok, feed} =
      Arca.CronSchedule.create_feed(actor, %{
        binding: binding,
        resolved_reference: "catalyst:local.markets:1.0.0",
        profile_id: "prof_schedules_page",
        cap: 1_000
      })

    {feed, binding}
  end

  describe "editing a schedule" do
    # A schedule made through the form, and its row as stored.
    defp made!(view, ctx, params) do
      render_submit(view, "create", params)
      {:ok, row} = schedule(ctx, params)
      row
    end

    defp edit!(view, id), do: render_click(view, "edit", %{"id" => id})

    defp form_error(view),
      do: view |> element(~s(#schedule-form [data-test="schedule-form-error"])) |> render()

    # Only what the update may change moves; the rest of the row stays.
    defp same_but(before, now, fields) do
      for key <-
            [
              :name,
              :cron_expression,
              :reference,
              :resolved_reference,
              :profile_id,
              :input,
              :status,
              :missed_runs,
              :catch_up_limit,
              :thread_id
            ] -- fields do
        assert Map.fetch!(now, key) == Map.fetch!(before, key), "#{key} moved"
      end
    end

    test "Edit opens the one form prefilled, and Save changes the name, the time, the input and the missed runs",
         %{view: view, ctx: ctx, params: params} do
      before = made!(view, ctx, params)
      edit!(view, before.id)

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.show_create and assigns.editing.schedule_id == before.id
      assert assigns.cron_preset == "custom" and assigns.cron_custom == "0 0 1 1 *"

      assert assigns.form.params ==
               %{
                 "name" => params["name"],
                 "target" => "component",
                 "line" => "",
                 "reference" => "reagent:local.schedule-target",
                 "profile_id" => params["profile_id"],
                 "input" => ~s({"count":0,"enabled":false}),
                 "missed_runs" => "skip",
                 "catch_up_limit" => ""
               }

      # The schedule's unversioned reference is offered though the list names versions.
      assert has_element?(
               view,
               ~s(#schedule-form select[name=reference] option[value="reagent:local.schedule-target"][selected])
             )

      assert has_element?(view, ~s(#schedule-form [data-test="schedule-editing"]), params["name"])

      renamed = params["name"] <> "-renamed"

      render_submit(
        view,
        "save",
        %{
          params
          | "name" => renamed,
            "cron_custom" => "0 0 2 2 *",
            "input" => ~s({"count":1})
        }
        |> Map.merge(%{"missed_runs" => "catch_up", "catch_up_limit" => "2"})
      )

      {:ok, now} = Arca.CronSchedule.get(Sanctum.Context.actor(ctx), before.id)

      assert %{
               name: ^renamed,
               cron_expression: "0 0 2 2 *",
               missed_runs: "catch_up",
               catch_up_limit: 2
             } =
               now

      assert Jason.decode!(now.input) == %{"count" => 1}
      assert %DateTime{month: 2, day: 2, hour: 0, minute: 0} = now.next_run_at
      same_but(before, now, [:name, :cron_expression, :input, :missed_runs, :catch_up_limit])
      refute :sys.get_state(view.pid).socket.assigns.show_create
      assert :sys.get_state(view.pid).socket.assigns.flash == %{"info" => "Schedule saved"}

      # An emptied input clears it.
      edit!(view, before.id)
      render_submit(view, "save", %{params | "name" => renamed, "input" => ""})
      {:ok, cleared} = Arca.CronSchedule.get(Sanctum.Context.actor(ctx), before.id)
      assert cleared.input == nil
    end

    test "what it runs moves to a component the new profile's grant covers",
         %{view: view, ctx: ctx, params: params} do
      before = made!(view, ctx, params)

      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
          name: "other-target",
          version: "0.1.0",
          type: "reagent",
          description: "Another target"
        })

      other_profile =
        Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "reagent:local.other-target")

      edit!(view, before.id)

      render_submit(view, "save", %{
        params
        | "reference" => "reagent:local.other-target:0.1.0",
          "profile_id" => other_profile
      })

      {:ok, now} = Arca.CronSchedule.get(Sanctum.Context.actor(ctx), before.id)

      assert %{
               reference: "reagent:local.other-target:0.1.0",
               resolved_reference: "reagent:local.other-target:0.1.0",
               profile_id: ^other_profile
             } = now

      same_but(before, now, [:reference, :resolved_reference, :profile_id])
    end

    test "a repoint the grant does not cover, or a time that is no time, is refused in the form and the row is unchanged",
         %{view: view, ctx: ctx, params: params} do
      before = made!(view, ctx, params)

      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
          name: "uncovered",
          version: "0.1.0",
          type: "reagent",
          description: "No grant covers it"
        })

      edit!(view, before.id)
      repoint = %{params | "reference" => "reagent:local.uncovered:0.1.0"}
      render_submit(view, "save", repoint)

      assert form_error(view) =~ "profile binding refused"
      refute :sys.get_state(view.pid).socket.assigns.flash["info"] == "Schedule saved"

      assert :sys.get_state(view.pid).socket.assigns.form.params["reference"] ==
               repoint["reference"]

      {:ok, now} = Arca.CronSchedule.get(Sanctum.Context.actor(ctx), before.id)
      same_but(before, now, [])

      render_submit(view, "save", %{params | "cron_custom" => "* * *"})
      assert form_error(view) =~ "cron"
      {:ok, now} = Arca.CronSchedule.get(Sanctum.Context.actor(ctx), before.id)
      same_but(before, now, [])
    end

    test "a line for Aqua is edited by its person, and an empty one is refused in the tool's words",
         %{view: view, ctx: ctx, params: params} do
      render_change(view, "target_change", %{"target" => "aqua"})

      aqua = %{
        "name" => params["name"],
        "target" => "aqua",
        "line" => "summarise what is unread",
        "cron_custom" => "0 0 1 1 *",
        "missed_runs" => "skip"
      }

      before = made!(view, ctx, aqua)
      edit!(view, before.id)

      assert :sys.get_state(view.pid).socket.assigns.form.params["line"] ==
               "summarise what is unread"

      assert has_element?(view, "#schedule-form textarea[name=line]", "summarise what is unread")

      render_submit(view, "save", %{aqua | "line" => "list what is due today"})
      {:ok, now} = Arca.CronSchedule.get(Sanctum.Context.actor(ctx), before.id)
      assert Jason.decode!(now.input) == %{"line" => "list what is due today"}
      same_but(before, now, [:input])

      edit!(view, before.id)
      render_submit(view, "save", %{aqua | "line" => "  "})
      assert form_error(view) =~ "A line for Aqua must say something"
      {:ok, unchanged} = Arca.CronSchedule.get(Sanctum.Context.actor(ctx), before.id)
      same_but(now, unchanged, [])
    end

    test "a component's schedule becomes a line for Aqua and back, binding a profile again",
         %{view: view, ctx: ctx, params: params} do
      before = made!(view, ctx, params)

      edit!(view, before.id)
      render_change(view, "target_change", %{"target" => "aqua"})

      render_submit(view, "save", %{
        "name" => params["name"],
        "target" => "aqua",
        "line" => "what changed overnight",
        "cron_custom" => "0 0 1 1 *",
        "missed_runs" => "skip"
      })

      {:ok, aqua} = Arca.CronSchedule.get(Sanctum.Context.actor(ctx), before.id)

      assert %{
               reference: "agent:local.aqua",
               resolved_reference: "agent:local.aqua",
               profile_id: nil
             } =
               aqua

      assert Jason.decode!(aqua.input) == %{"line" => "what changed overnight"}

      # Back to a component: the profile is asked for, then bound.
      edit!(view, before.id)
      assert :sys.get_state(view.pid).socket.assigns.form.params["target"] == "aqua"
      render_change(view, "target_change", %{"target" => "component"})
      back = Map.put(params, "target", "component")
      render_submit(view, "save", %{back | "profile_id" => ""})
      assert form_error(view) =~ "Please enter the profile"
      {:ok, still} = Arca.CronSchedule.get(Sanctum.Context.actor(ctx), before.id)
      same_but(aqua, still, [])

      render_submit(view, "save", back)
      {:ok, now} = Arca.CronSchedule.get(Sanctum.Context.actor(ctx), before.id)
      same_but(before, now, [])
    end

    test "a paused schedule edited stays paused", %{view: view, ctx: ctx, params: params} do
      before = made!(view, ctx, params)
      render_click(view, "pause", %{"id" => before.id})
      edit!(view, before.id)
      render_submit(view, "save", %{params | "name" => params["name"] <> "-p"})

      {:ok, now} = Arca.CronSchedule.get(Sanctum.Context.actor(ctx), before.id)
      assert %{status: "paused"} = now
      assert now.name == params["name"] <> "-p"
    end

    test "a person who is not the schedule's cannot edit it", %{
      view: view,
      ctx: ctx,
      params: params
    } do
      before = made!(view, ctx, params)

      other = test_user()
      other_conn = log_in_user(build_conn(), other)
      {other_view, _html} = mount_athanor(other_conn, "/schedules")

      # Their page lists none of it, so Edit opens nothing.
      edit!(other_view, before.id)
      refute :sys.get_state(other_view.pid).socket.assigns.show_create
      render_submit(other_view, "save", %{params | "name" => "taken"})

      other_ctx = %{
        Sanctum.TestContext.local()
        | athanor_id: seated_athanor().id,
          user_id: other.user_id
      }

      assert {:error, _not_found} =
               Opus.Schedules.Provider.handle("schedule", other_ctx, %{
                 "action" => "update",
                 "schedule_id" => before.id,
                 "name" => "taken"
               })

      {:ok, now} = Arca.CronSchedule.get(Sanctum.Context.actor(ctx), before.id)
      same_but(before, now, [])
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
