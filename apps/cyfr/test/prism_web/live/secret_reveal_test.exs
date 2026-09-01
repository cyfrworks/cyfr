# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SecretRevealTest do
  @moduledoc """
  The one-time reveal cards, and letting go of what they showed.

  A minted API key and a webhook secret are shown once, in plaintext, from
  socket assigns — and nothing ever cleared them. `Phoenix.LiveView.Socket`
  derives Inspect with `:assigns` in its `only:` list, so the value stayed in
  the process state (and so in any crash report) and in the DOM for the rest
  of the session. The webhook one was cleared only by the unrelated "edit"
  event. Both cards can be dismissed now.
  """
  use PrismWeb.ConnCase, async: false

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  test "a minted API key is dismissible and leaves the assigns with the card",
       %{conn: conn} do
    {view, _html} = conn |> log_in_user(test_user()) |> mount_athanor("/api-keys")

    render_click(view, "toggle_create")
    render_submit(view, "create", %{"name" => "reveal-probe", "type" => "application"})

    key = assigns(view).new_key
    assert is_map(key) and is_binary(key[:api_key])
    assert render(view) =~ "not be shown again"

    render_click(view, "dismiss_key")

    refute assigns(view).new_key
    refute settled_render(view) =~ "not be shown again"
  end

  test "a webhook secret is dismissible too", %{conn: conn} do
    user = test_user()
    home = Sanctum.Tenancy.Athanors.home!()
    ctx = %{Sanctum.TestContext.local() | athanor_id: home.id, user_id: user.user_id}
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
    :ok = Sanctum.Test.ConsentFixtures.start_source!()
    profile_id = Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "reagent:local.reveal-echo")

    {:ok, _} =
      Sanctum.Webhook.create(ctx, %{
        name: name,
        replay_protection: "none",
        target_ref: "reagent:local.reveal-echo",
        profile_id: profile_id
      })

    {view, _html} = conn |> log_in_user(user) |> mount_athanor("/webhooks")

    # Rotating reveals the new secret the same way creating does.
    render_click(view, "rotate", %{"id" => name})

    secret = assigns(view).new_secret
    assert is_map(secret) and is_binary(secret[:secret])

    render_click(view, "dismiss_secret")

    refute assigns(view).new_secret
    settled_render(view)
  end
end
