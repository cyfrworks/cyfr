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

      wasm = Cyfr.Test.Guests.wasm(:reagent)

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
      # this page's own; nothing is minted, no error is written, and no grant
      # is asked for: the profile's grant stands for every delivery.
      refute :sys.get_state(view.pid).socket.assigns.form_error
      refute has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))

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

      # Completed, the page's prompt closes, so nothing sits over the new
      # secret; a new webhook has no old secret to speak of.
      wait_until(
        fn -> not (render(view) =~ ~s(data-ref="#{ref}")) end,
        2_000,
        "the closed prompt"
      )

      refute has_element?(view, "#system-layer-dialog")
      assert render(view) =~ "not be shown again"
      refute has_element?(view, ~s([data-test="old-secret"]))
      Cyfr.Test.Sandbox.end_views()
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

    test "the profile is picked from the target component's grants",
         %{view: view, profile_id: profile_id} do
      render_click(view, "toggle_create")

      assert options(view) == [{"", "No grant to choose"}]
      refute has_element?(view, ~s(#webhook-form input[name="profile_id"]))

      view
      |> form("#webhook-form", %{"target_ref" => "reagent:local.hook-target"})
      |> render_change()

      assert options(view) == [{"", "Choose a grant"}, {profile_id, "default (#{profile_id})"}]

      view
      |> form("#webhook-form", %{"target_ref" => "reagent:local.not-installed"})
      |> render_change()

      assert options(view) == [{"", "No grant to choose"}]
    end
  end

  describe "the list" do
    setup %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)

      ctx = %{
        Sanctum.TestContext.local()
        | athanor_id: seated_athanor().id,
          user_id: user.user_id
      }

      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
          name: "listed-target",
          version: "0.1.0",
          type: "reagent",
          description: "webhook target"
        })

      profile_id =
        Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "reagent:local.listed-target")

      name = "listed-hook-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Sanctum.TestContext.create_webhook(ctx, %{
          name: name,
          target_ref: "reagent:local.listed-target",
          profile_id: profile_id,
          timestamp_header: "x-cyfr-timestamp",
          idempotency_key_header: "x-cyfr-delivery"
        })

      {view, _html} = mount_athanor(conn, "/webhooks")
      wait_until(fn -> has_element?(view, "#webhooks") end, 2_000, "the list")
      {:ok, view: view, name: name}
    end

    test "names every header a delivery is checked by, beside the signature header",
         %{view: view} do
      headers =
        view
        |> element(~s([data-test="webhook-headers"]))
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("div div")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))

      assert headers == [
               "Signature: #{Prima.Webhook.default_signature_header()}",
               "Timestamp: x-cyfr-timestamp",
               "Idempotency key: x-cyfr-delivery"
             ]
    end

    test "Revoke asks in the command's words, and the actions stack at phone width",
         %{view: view, name: name} do
      assert has_element?(
               view,
               ~s(button[phx-click="revoke"][data-confirm="Revoke webhook '#{name}'? The URL stops accepting POSTs."])
             )

      assert has_element?(view, ~s([data-test="webhook-actions"].flex-col))
    end
  end

  # The profile select's options, each as its value and its text.
  defp options(view) do
    view
    |> element(~s(#webhook-form select[name="profile_id"]))
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("option")
    |> Enum.map(fn option ->
      {option |> LazyHTML.attribute("value") |> List.first(),
       option |> LazyHTML.text() |> String.trim()}
    end)
  end
end
