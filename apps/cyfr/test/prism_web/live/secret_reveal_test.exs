# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SecretRevealTest do
  @moduledoc """
  The one-time reveal cards, and letting go of what they showed.

  Minting an API key and rotating a webhook's secret are sensitive
  changes: the page asks through its system layer, the person confirms
  the record, and the page makes the change once, revealing the secret in
  its card. Dismissing the card removes the plaintext from socket assigns
  and the DOM. The request's own secret, which only the page holds,
  reaches neither the page nor its flash.
  """
  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp open_confirmations(ctx) do
    {:ok, rows} = Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)
    rows
  end

  defp person(user) do
    %{Sanctum.TestContext.local() | athanor_id: seated_athanor().id, user_id: user.user_id}
  end

  # The page's own request waits on its record; the person proves it, by
  # its ref, as any client of theirs would, and the page repeats it.
  defp confirm!(view, ctx, operation) do
    assert [%{ref: ref, operation: ^operation}] = open_confirmations(ctx)
    wait_until(fn -> render(view) =~ ~s(data-ref="#{ref}") end, 2_000, "the page's own prompt")

    html = render(view)
    assert html =~ ~s(data-own="true")
    assert html =~ ~s(data-status="waiting")
    refute html =~ "cnf_"
    refute flash(view) =~ "cnf_"

    Sanctum.TestContext.prove!(ctx, ref)
    ref
  end

  defp flash(view), do: inspect(assigns(view).flash)

  test "a minted API key is dismissible and leaves the assigns with the card",
       %{conn: conn} do
    user = test_user()
    {view, _html} = conn |> log_in_user(user) |> mount_athanor("/api-keys")

    render_click(view, "toggle_create")
    render_submit(view, "create", %{"name" => "reveal-probe", "type" => "application"})

    # Nothing minted until the record is confirmed.
    refute assigns(view).new_key
    confirm!(view, person(user), "key.create")

    wait_until(fn -> is_map(assigns(view).new_key) end, 2_000, "the repeated create")
    key = assigns(view).new_key
    assert is_binary(key[:api_key])
    assert render(view) =~ "not be shown again"
    assert render(view) =~ ~s(data-status="completed")
    refute flash(view) =~ "cnf_"

    render_click(view, "dismiss_key")

    refute assigns(view).new_key
    refute settled_render(view) =~ "not be shown again"
    Cyfr.Test.Sandbox.end_views()
  end

  test "a webhook secret is dismissible too", %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    ctx = person(user)
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
    {:ok, %{secret: first}} =
      Sanctum.TestContext.create_webhook(ctx, %{
        name: name,
        replay_protection: "none",
        target_ref: "reagent:local.reveal-echo",
        profile_id: profile_id
      })

    {view, _html} = mount_athanor(conn, "/webhooks")

    # Rotating asks first, then reveals the new secret the way creating does.
    render_click(view, "rotate", %{"id" => name})
    refute assigns(view).new_secret
    confirm!(view, ctx, "webhook.rotate")

    wait_until(fn -> is_map(assigns(view).new_secret) end, 2_000, "the repeated rotation")
    secret = assigns(view).new_secret
    assert is_binary(secret[:secret])
    refute secret[:secret] == first
    refute flash(view) =~ "cnf_"

    render_click(view, "dismiss_secret")

    refute assigns(view).new_secret
    settled_render(view)
    Cyfr.Test.Sandbox.end_views()
  end
end
