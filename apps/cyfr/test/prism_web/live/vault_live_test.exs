# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.VaultLiveTest do
  @moduledoc """
  Tests sign-in gating, vault-entry server references and management of
  operator OAuth client credentials on the Vault page.

  Storing client credentials is a sensitive change: the page meets the
  `confirmation_required` signal, and nothing is stored until the
  person proves it. Listing and removing them need the session alone.
  """
  use PrismWeb.ConnCase, async: false

  describe "GET /vault (unauthenticated)" do
    test "redirects to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} =
               live(conn, athanor_path("/vault", "@nobody"))
    end
  end

  test "a vault entry shows the MCP servers that read it through vault: headers", %{conn: conn} do
    user = test_user()
    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(user.user_id, "Wired #{user.namespace}")

    ctx =
      Sanctum.Context.build(
        user_id: user.user_id,
        athanor_id: group.id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    # Entering the credential is a sensitive change, made under the
    # confirmation its person proves (`Sanctum.TestContext.confirming/2`).
    {:ok, _} =
      Sanctum.TestContext.confirming(
        ctx,
        &Grimoire.call_external("vault", &1, %{
          "action" => "create",
          "name" => "bridge-token",
          "kind" => "api_key",
          "fields" => %{"TOKEN" => "t"}
        })
      )

    {:ok, _} =
      Grimoire.call_external("mcp_servers", ctx, %{
        "action" => "create",
        "name" => "bridge",
        "config" => %{
          "url" => "https://example.com/mcp",
          "headers" => %{"Authorization" => "vault:bridge-token"}
        }
      })

    conn = log_in_user(conn, user, athanor_id: group.id)
    {_view, html} = mount_athanor(conn, "/vault", group)
    assert html =~ "bridge-token"
    assert html =~ "used by MCP server bridge"

    # the list verb carries the names — never the header values
    assert {:ok, %{servers: [server]}} =
             Grimoire.call_external("mcp_servers", ctx, %{"action" => "list"})

    assert server.vault_refs == ["bridge-token"]
    refute inspect(server) =~ "Authorization"
  end

  # A secret no rendered page holds by accident: a LiveView's element id and
  # session token are random base64url text, where three letters turn up.
  @client_secret "client secret: never rendered"

  test "OAuth client credentials are stored, listed by provider only, and removed", %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    {view, html} = mount_athanor(conn, "/vault")
    assert html =~ "OAuth client credentials"
    assert html =~ "No client credentials stored"

    render_click(view, "show_add", %{"mode" => "client"})

    view
    |> form("form[phx-submit=set_client]", %{
      "provider" => "google",
      "client_id" => "abc.apps.googleusercontent.com",
      "client_secret" => @client_secret
    })
    |> render_submit()

    ctx =
      Sanctum.Context.build(
        user_id: user.user_id,
        athanor_id: seated_athanor().id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    # The page meets the signal, naming the change and never the secret
    # of the confirmation it opened, and stores nothing; the client secret
    # appears in neither the page nor the flash.
    flash = Phoenix.Flash.get(:sys.get_state(view.pid).socket.assigns.flash, :error)
    assert flash =~ "Confirmation required"

    assert {:ok, [%{ref: "cnr_" <> _, operation: "oauth.set_client"}]} =
             Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)

    refute flash =~ "cnf_"
    refute flash =~ @client_secret
    rendered = render(view)
    assert rendered =~ "No client credentials stored"
    refute rendered =~ @client_secret
    assert {:error, _} = Sanctum.ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "google")

    # Proven, the same change is made; the page lists the provider alone.
    :ok =
      Sanctum.TestContext.put_provider_credentials(
        ctx,
        "google",
        "abc.apps.googleusercontent.com",
        @client_secret
      )

    {view, rendered} = mount_athanor(conn, "/vault")
    assert rendered =~ "google"
    refute rendered =~ "No client credentials stored"
    refute rendered =~ @client_secret
    refute rendered =~ "abc.apps.googleusercontent.com"

    assert {:ok,
            %{"client_id" => "abc.apps.googleusercontent.com", "client_secret" => @client_secret}} =
             Sanctum.ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "google")

    assert {:ok, %{providers: [%{provider: "google"}]}} =
             Grimoire.call_external("oauth", ctx, %{"action" => "list"})

    view
    |> element("button[phx-click=delete_client][phx-value-provider=google]")
    |> render_click()

    assert render(view) =~ "No client credentials stored"
    assert {:error, _} = Sanctum.ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "google")

    # removing what is not there says so
    assert {:error, msg} =
             Grimoire.call_external("oauth", ctx, %{
               "action" => "delete_client",
               "provider" => "google"
             })

    assert msg =~ "No client credentials"
  end
end
