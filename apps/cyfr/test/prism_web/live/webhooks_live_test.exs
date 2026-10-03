# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.WebhooksLiveTest do
  @moduledoc """
  The route is wired and gated, and the create form can express the
  replay-protection decision `Sanctum.Webhook.create/2` requires.

  The form must submit an explicit replay-protection choice when
  neither replay header is configured. Minting the webhook's secret is
  a sensitive change: the page asks through its system layer, nothing is
  minted until the person confirms the record, and the page then creates
  the webhook once.
  """

  use PrismWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Prima.Test.Wait

  describe "GET /webhooks (unauthenticated)" do
    test "redirects to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} =
               live(conn, athanor_path("/webhooks", "@nobody"))
    end
  end

  describe "the create form and the replay decision" do
    setup %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)

      ctx = %{
        Sanctum.TestContext.local()
        | athanor_id: seated_athanor().id,
          user_id: user.user_id
      }

      wasm = File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))

      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, wasm, %{
          name: "hook-target",
          version: "0.1.0",
          type: "reagent",
          description: "webhook target"
        })

      profile_id = Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "reagent:local.hook-target")

      {view, _html} = mount_athanor(conn, "/webhooks")
      {:ok, view: view, profile_id: profile_id, ctx: ctx}
    end

    test "ticking the box creates a webhook that names neither header",
         %{view: view, profile_id: profile_id, ctx: ctx} do
      grant_origins!(ctx, [:interactive, :webhook])
      name = "console-hook-#{System.unique_integer([:positive])}"

      render_click(view, "toggle_create")

      render_submit(view, "submit", %{
        "name" => name,
        "target_ref" => "reagent:local.hook-target",
        "profile_id" => profile_id,
        "accept_replays" => "on",
        "input_template" => "{}"
      })

      # Past the replay decision, the create waits on its record, shown as
      # this page's own; nothing is minted, and no error is written.
      refute :sys.get_state(view.pid).socket.assigns.form_error

      assert {:ok, [%{ref: ref, operation: "webhook.create"}]} =
               Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)

      wait_until(fn -> render(view) =~ ~s(data-ref="#{ref}") end, 2_000, "the page's prompt")
      refute render(view) =~ "cnf_"
      assert {:error, :not_found} = Sanctum.Webhook.get(ctx, name)

      # Confirmed: the page creates it, once.
      Sanctum.TestContext.prove!(ctx, ref)
      wait_until(fn -> match?({:ok, _}, Sanctum.Webhook.get(ctx, name)) end, 2_000, "the create")

      refute :sys.get_state(view.pid).socket.assigns.form_error
      assert {:ok, %{name: ^name}} = Sanctum.Webhook.get(ctx, name)
      wait_until(fn -> render(view) =~ ~s(data-status="completed") end, 2_000, "completed")
      Cyfr.Test.Sandbox.end_views()
    end

    test "leaving it unticked refuses, and says which decision is missing",
         %{view: view, profile_id: profile_id, ctx: ctx} do
      grant_origins!(ctx, [:interactive, :webhook])
      render_click(view, "toggle_create")

      render_submit(view, "submit", %{
        "name" => "console-hook-refused-#{System.unique_integer([:positive])}",
        "target_ref" => "reagent:local.hook-target",
        "profile_id" => profile_id,
        "input_template" => "{}"
      })

      error = :sys.get_state(view.pid).socket.assigns.form_error
      assert is_binary(error) and error =~ "replay"
    end
  end

  describe "a profile whose grant does not admit webhooks" do
    setup %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)

      ctx = %{
        Sanctum.TestContext.local()
        | athanor_id: seated_athanor().id,
          user_id: user.user_id
      }

      wasm = File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))

      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, wasm, %{
          name: "hook-target",
          version: "0.1.0",
          type: "reagent",
          description: "webhook target"
        })

      profile_id = Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "reagent:local.hook-target")
      {view, _html} = mount_athanor(conn, "/webhooks")
      render_click(view, "toggle_create")

      params = %{
        "name" => "console-hook-origin-#{System.unique_integer([:positive])}",
        "target_ref" => "reagent:local.hook-target",
        "profile_id" => profile_id,
        "accept_replays" => "on",
        "input_template" => "{}"
      }

      {:ok, view: view, ctx: ctx, params: params}
    end

    test "raises the grant prompt first, and a dismissal makes no webhook",
         %{view: view, ctx: ctx, params: params} do
      render_submit(view, "submit", params)
      render(view)

      assert has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))
      assert {:error, :not_found} = Sanctum.Webhook.get(ctx, params["name"])

      # No secret was asked for: nothing waits on a confirmation.
      assert {:ok, []} =
               Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)

      view |> element(~s(#system-layer button[phx-click="dismiss"])) |> render_click()
      render(view)

      assert :sys.get_state(view.pid).socket.assigns.form_error =~ "No webhook was made"
      assert {:error, :not_found} = Sanctum.Webhook.get(ctx, params["name"])
    end

    test "granted without the webhook origin, no webhook is made",
         %{view: view, ctx: ctx, params: params} do
      render_submit(view, "submit", params)
      render(view)
      assert has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))

      # Confirmed as it opened: the grant is made again, still without
      # webhooks, and the page's second check makes nothing.
      view |> element(~s(#system-layer button[phx-click="confirm"])) |> render_click()

      wait_until(
        fn ->
          render(view)

          (:sys.get_state(view.pid).socket.assigns.form_error || "") =~
            "No webhook was made: the grant does not let webhooks start this profile"
        end,
        2_000,
        "the refusal"
      )

      {:ok, head} = Sanctum.Consent.head_consent(ctx, params["profile_id"])
      refute :webhook in head.admitted_origins
      assert {:error, :not_found} = Sanctum.Webhook.get(ctx, params["name"])

      assert {:ok, []} =
               Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)
    end

    test "granted with the webhook origin, the create goes on to its confirmation",
         %{view: view, ctx: ctx, params: params} do
      render_submit(view, "submit", params)
      render(view)

      view
      |> element(~s(input[phx-click="toggle_origin"][phx-value-origin="webhook"]))
      |> render_click()

      render(view)
      view |> element(~s(#system-layer button[phx-click="confirm"])) |> render_click()

      wait_until(
        fn ->
          render(view)

          match?(
            {:ok, [%{operation: "webhook.create"}]},
            Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)
          )
        end,
        2_000,
        "the create's confirmation"
      )

      {:ok, head} = Sanctum.Consent.head_consent(ctx, params["profile_id"])
      assert :webhook in head.admitted_origins
      Cyfr.Test.Sandbox.end_views()
    end
  end

  # The profile's grant, made again through the walk with `origins`.
  defp grant_origins!(ctx, origins) do
    ref = "reagent:local.hook-target"
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
end
