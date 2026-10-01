# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.WebhooksLiveTest do
  @moduledoc """
  The route is wired and gated, and the create form can express the
  replay-protection decision `Sanctum.Webhook.create/2` requires.

  The form must submit an explicit replay-protection choice when
  neither replay header is configured. Minting the webhook's secret is
  a sensitive change: a decided form meets the `confirmation_required`
  signal, and nothing is minted until its person proves it.
  """

  use PrismWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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

    test "ticking the box decides the replay posture, and the create meets the confirmation signal",
         %{view: view, profile_id: profile_id, ctx: ctx} do
      name = "console-hook-#{System.unique_integer([:positive])}"

      render_click(view, "toggle_create")

      render_submit(view, "submit", %{
        "name" => name,
        "target_ref" => "reagent:local.hook-target",
        "profile_id" => profile_id,
        "accept_replays" => "on",
        "input_template" => "{}"
      })

      # Past the replay decision, the page meets the signal for this
      # create, naming the change and never the request's confirmation
      # secret, and no secret is minted.
      error = :sys.get_state(view.pid).socket.assigns.form_error
      assert is_binary(error) and error =~ "Confirmation required"
      refute error =~ "replay"

      assert {:ok, [%{ref: "cnr_" <> _, operation: "webhook.create"}]} =
               Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)

      refute error =~ "cnf_"
      assert {:error, :not_found} = Sanctum.Webhook.get(ctx, name)
    end

    test "leaving it unticked refuses, and says which decision is missing",
         %{view: view, profile_id: profile_id} do
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
end
