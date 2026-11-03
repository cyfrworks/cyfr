# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.DeviceAddLiveTest do
  @moduledoc """
  `/devices/add`, the page a new device's QR code opens: session-only, so a
  person not signed in is sent through the sign-in page. The page's script
  hands it the key's digest from the fragment; the page opens the Devices
  prompt with the key's code filled in, and nothing begins until the person
  asks there, under the prompt's fresh confirmation. With no key, or a
  fragment that names none, the prompt opens empty for a typed code.
  """

  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait

  alias Sanctum.Context

  setup %{conn: conn} do
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()

    ctx =
      Context.build(
        user_id: user.user_id,
        athanor_id: athanor.id,
        permissions: Context.person_permissions(),
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    %{conn: conn, ctx: ctx}
  end

  defp digest do
    {public, _private} = :crypto.generate_key(:eddsa, :ed25519)
    Prima.Device.key_digest(public)
  end

  defp open_record!(ctx, operation) do
    {:ok, rows} = Arca.PendingConfirmations.list_open(Context.actor(ctx), ctx.user_id)
    assert [%{ref: ref, operation: ^operation}] = rows
    ref
  end

  test "a person not signed in here is sent through the sign-in page" do
    assert {:error, {:redirect, %{to: "/login"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/devices/add")
  end

  test "the scanned key opens the Devices prompt with its code, and pairs only once the person asks and confirms",
       %{conn: conn, ctx: ctx} do
    digest = digest()
    code = Prima.Device.key_code(digest)
    {:ok, view, html} = live(conn, ~p"/devices/add")
    assert html =~ ~s(phx-hook="DeviceAdd")

    render_hook(view, "device_key", %{"key_digest" => digest})
    assert has_element?(view, ~s([data-test="device-add-code"]), code)

    wait_until(
      fn -> has_element?(view, ~s([data-test="pairing-key-input"][value="#{code}"])) end,
      2_000,
      "the prompt with the code"
    )

    # Nothing has begun.
    assert {:ok, []} = Arca.PendingConfirmations.list_open(Context.actor(ctx), ctx.user_id)

    view |> form("#pairing-add-pairing-begin", %{"key_code" => code}) |> render_submit()
    ref = open_record!(ctx, "pairing.begin")
    assert has_element?(view, ~s([data-test="confirmation-preview"]), code)

    Sanctum.TestContext.prove!(ctx, ref)
    wait_until(fn -> has_element?(view, ~s([data-test="pairing-link"])) end, 2_000, "the link")
  end

  test "no key, or a fragment that names none, opens the prompt empty for a typed code", %{
    conn: conn
  } do
    for params <- [%{"key_digest" => nil}, %{"key_digest" => "not-a-digest"}, %{}] do
      {:ok, view, _html} = live(conn, ~p"/devices/add")
      render_hook(view, "device_key", params)
      assert has_element?(view, ~s([data-test="device-add-none"]))

      wait_until(
        fn -> has_element?(view, ~s([data-test="pairing-key-input"])) end,
        2_000,
        "the empty prompt"
      )

      refute has_element?(view, ~s([data-test="pairing-key-input"][value]))
    end
  end
end
