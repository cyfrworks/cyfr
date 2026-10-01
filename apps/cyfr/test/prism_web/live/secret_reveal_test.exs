# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SecretRevealTest do
  @moduledoc """
  The one-time reveal cards, and what a page reveals when the change that
  would mint a secret is not yet confirmed.

  Minting an API key and rotating a webhook's secret are sensitive
  changes: from a session with no proof, the page meets the
  `confirmation_required` signal, naming the change and never the
  secret of the confirmation it opened, and reveals no card, since
  nothing was minted.
  """
  use PrismWeb.ConnCase, async: false

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp open_confirmations(user_id) do
    ctx = %{Sanctum.TestContext.local() | athanor_id: seated_athanor().id, user_id: user_id}
    {:ok, rows} = Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), user_id)
    rows
  end

  test "a key minted from the page meets the confirmation signal, and no card is revealed",
       %{conn: conn} do
    user = test_user()
    {view, _html} = conn |> log_in_user(user) |> mount_athanor("/api-keys")

    render_click(view, "toggle_create")
    render_submit(view, "create", %{"name" => "reveal-probe", "type" => "application"})

    assert [%{ref: "cnr_" <> _, operation: "key.create"}] = open_confirmations(user.user_id)

    flash = Phoenix.Flash.get(assigns(view).flash, :error)
    assert flash =~ "Confirmation required"
    refute flash =~ "cnf_"

    refute assigns(view).new_key
    refute render(view) =~ "not be shown again"
  end

  test "a webhook secret rotated from the page meets the signal, and the old one stands",
       %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    ctx = %{Sanctum.TestContext.local() | athanor_id: seated_athanor().id, user_id: user.user_id}
    name = "reveal-hook-#{System.unique_integer([:positive])}"

    wasm = File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))

    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, wasm, %{
        name: "reveal-echo",
        version: "0.1.0",
        type: "reagent",
        description: "webhook target"
      })

    # A webhook fires under a bound profile's consent, so it needs one.
    profile_id = Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "reagent:local.reveal-echo")

    # Created under the confirmation its person proved
    # (`Sanctum.TestContext.create_webhook/2`).
    {:ok, %{secret: secret}} =
      Sanctum.TestContext.create_webhook(ctx, %{
        name: name,
        replay_protection: "none",
        target_ref: "reagent:local.reveal-echo",
        profile_id: profile_id
      })

    {view, _html} = mount_athanor(conn, "/webhooks")

    # Rotating from the page asks first: no new secret is revealed, and
    # the secret minted before still verifies.
    render_click(view, "rotate", %{"id" => name})

    assert [%{ref: "cnr_" <> _, operation: "webhook.rotate"}] = open_confirmations(user.user_id)

    flash = Phoenix.Flash.get(assigns(view).flash, :error)
    assert flash =~ "Confirmation required"
    refute flash =~ "cnf_"

    refute assigns(view).new_secret
    refute render(view) =~ secret

    {:ok, %{slug: slug}} = Sanctum.Webhook.get(ctx, name)
    {:ok, hook} = Arca.WebhookStorage.get_by_slug(slug)
    # No rotation happened: there is no previous secret in its grace.
    assert hook.previous_secret_encrypted == nil
    body = "reveal"

    signature =
      "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

    assert :ok = Sanctum.Webhook.verify_with_grace(hook, body, signature)
  end
end
