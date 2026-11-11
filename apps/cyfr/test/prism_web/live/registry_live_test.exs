# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.RegistryLiveTest do
  @moduledoc """
  The registry page's acts are requests a passkey of the person's account
  signs: an appeal of a takedown, the acceptance of the registry's
  policies, and a sync of their push tokens. Each asks the registry tool
  for its request, bound to the person's session, and opens the account
  pages' sign page with it in a new tab; nothing reaches the registry
  until the answer returns to the sign-in page (`PrismWeb.LoginLiveTest`).
  No identity provider is asked for any of them.

  The registry is `Sanctum.Test.RegistryStub`, which answers the page's
  policy read and fails the case on any signed request.
  """
  use PrismWeb.ConnCase, async: false

  alias Sanctum.Test.RegistryStub

  @directory "https://dir-a.test"

  setup %{conn: conn} do
    Prima.Test.Env.put_app_env(:sanctum, :directory_url, @directory)
    user = test_user()

    RegistryStub.start!(fn
      %{method: "GET", path: "/v1/legal/version"} ->
        {200,
         RegistryStub.answer(%{
           "policy_version" => "2026-09",
           "policies" => [%{"name" => "terms", "title" => "Terms of Service", "sha256" => "x"}]
         })}

      %{method: "GET"} ->
        {404, ""}

      %{method: "POST", path: path} ->
        flunk("a signed request reached the registry from the page: #{path}")
    end)

    {:ok, conn: log_in_user(conn, user), user: user}
  end

  # The request the page opened the account pages with, in a new tab
  # through its layer: the registry request it carries, for the person's
  # account.
  defp hopped(view, user) do
    assert_push_event(view, "system_layer:hop", %{layer: "system-layer", url: url})
    assert String.starts_with?(url, @directory <> "/account/sign#")
    [_page, fragment] = String.split(url, "#", parts: 2)
    {:ok, map} = Prima.SignIn.parse_fragment(fragment)

    {:ok, %Prima.SignIn{purpose: :registry, registry_request: registry}} =
      Prima.SignIn.decode(map)

    assert {:ok, registry.identifier} == Sanctum.Tenancy.Users.identifier(user.user_id)
    registry
  end

  # `registry.whoami` names the person's publisher namespaces, and the page
  # lists each beside the personal one. The test registry is a closed
  # port, so the namespace is kept unconfirmed and its listing is refused.
  test "a publisher namespace the person holds a push token for is one the page reads",
       %{conn: conn, user: user} do
    ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: seated_athanor().id}

    :ok =
      Compendium.Registry.CredentialStore.put_push_token(
        ctx,
        Compendium.RegistryHost.canonical_host(),
        "acme.dev",
        "cyfr_pt_fake_acme",
        "owner"
      )

    {view, _html} = mount_athanor(conn, "/registry")
    assert "acme.dev" in :sys.get_state(view.pid).socket.assigns.namespaces
  end

  test "an appeal is a request the person's passkey signs, with no sign-in method asked",
       %{conn: conn, user: user} do
    {view, _html} = mount_athanor(conn, "/registry")
    html = render_click(view, "open-appeal", %{"id" => "cmp_taken_down"})
    refute html =~ "GitHub"
    refute html =~ "provider"

    html =
      render_submit(view, "submit-appeal", %{"argument" => "This named the wrong component."})

    assert %Prima.RegistryRequest{
             operation: "appeal.file",
             body: %{
               "action_type" => "takedown",
               "action_ref" => "cmp_taken_down",
               "argument" => "This named the wrong component."
             }
           } = hopped(view, user)

    assert html =~ "Sign the appeal"
    refute has_element?(view, "form[phx-submit=submit-appeal]")
  end

  test "an appeal whose request cannot be made keeps the form and what was typed",
       %{conn: conn} do
    {view, _html} = mount_athanor(conn, "/registry")
    render_click(view, "open-appeal", %{"id" => "cmp_taken_down"})
    Prima.Test.Env.put_app_env(:sanctum, :directory_url, nil)

    {submitted, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        render_submit(view, "submit-appeal", %{"argument" => "Again."})
      end)

    assert submitted =~ "Submit failed"
    assert has_element?(view, "form[phx-submit=submit-appeal]")
    assert render(view) =~ "Again."
  end

  # The registry is the configured one (`RegistryStub`'s host, not
  # cyfr.run): the page names it as the registry, never as cyfr.run.
  test "the page speaks of the registry, never of cyfr.run", %{conn: conn} do
    refute Compendium.RegistryHost.canonical_rest_host() =~ "cyfr.run"

    {view, _html} = mount_athanor(conn, "/registry")
    html = render(view)
    assert html =~ "Components you&#39;ve published to the registry."
    assert html =~ "The registry&#39;s policies, version"
    refute html =~ "cyfr.run"
  end

  test "the registry's policies are shown, and accepting asks a passkey to sign their version",
       %{conn: conn, user: user} do
    {view, _html} = mount_athanor(conn, "/registry")
    html = render(view)
    assert html =~ "Terms of Service"
    assert html =~ "Accept version 2026-09"

    html = render_click(view, "accept-policy", %{"version" => "2026-09"})

    assert %Prima.RegistryRequest{
             operation: "policy.accept",
             body: %{"policy_version" => "2026-09"}
           } = hopped(view, user)

    assert html =~ "Sign your acceptance of version 2026-09"
  end

  test "a sync asks a passkey to sign the mint and sends nothing until it is signed",
       %{conn: conn, user: user} do
    {view, _html} = mount_athanor(conn, "/registry")
    html = render_click(view, "sync", %{})

    assert %Prima.RegistryRequest{
             operation: "tokens.mint",
             body: %{"label" => label}
           } = hopped(view, user)

    assert label == Compendium.Registry.CredentialStore.wire_label()
    assert html =~ "Sign the sync"
    refute_received {:registry_request, %{method: "POST"}}
  end
end
