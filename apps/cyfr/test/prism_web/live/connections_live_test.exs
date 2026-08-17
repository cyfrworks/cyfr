# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ConnectionsLiveTest do
  @moduledoc """
  The Connections page: gated behind sign-in; each Connection says which
  MCP servers draw on it (so revoking is done knowing what it breaks); the
  operator's OAuth client credentials are stored, listed by provider and
  removed from here — the `lite` sheet's client-credentials arm.
  """
  use PrismWeb.ConnCase, async: false

  alias Emissary.MCP.ToolRegistry

  describe "GET /connections (unauthenticated)" do
    test "redirects to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, athanor_path("/connections"))
    end
  end

  test "a Connection shows the MCP servers that read it through vault: headers", %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
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

    {:ok, _} =
      ToolRegistry.call_external("vault", ctx, %{
        "action" => "create",
        "name" => "bridge-token",
        "kind" => "api_key",
        "fields" => %{"TOKEN" => "t"}
      })

    {:ok, _} =
      ToolRegistry.call_external("mcp_servers", ctx, %{
        "action" => "create",
        "name" => "bridge",
        "config" => %{
          "url" => "https://example.com/mcp",
          "headers" => %{"Authorization" => "vault:bridge-token"}
        }
      })

    conn = log_in_user(build_conn(), user, athanor_id: group.id)
    {_view, html} = mount_athanor(conn, "/connections", group)
    assert html =~ "bridge-token"
    assert html =~ "used by MCP server bridge"

    # the list verb carries the names — never the header values
    assert {:ok, %{servers: [server]}} =
             ToolRegistry.call_external("mcp_servers", ctx, %{"action" => "list"})

    assert server.vault_refs == ["bridge-token"]
    refute inspect(server) =~ "Authorization"
  end

  test "OAuth client credentials are stored, listed by provider only, and removed", %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    {view, html} = mount_athanor(conn, "/connections")
    assert html =~ "OAuth client credentials"
    assert html =~ "No client credentials stored"

    render_click(view, "show_add", %{"mode" => "client"})

    view
    |> form("form[phx-submit=set_client]", %{
      "provider" => "google",
      "client_id" => "abc.apps.googleusercontent.com",
      "client_secret" => "shh"
    })
    |> render_submit()

    rendered = render(view)
    assert rendered =~ "google"
    refute rendered =~ "shh"
    refute rendered =~ "abc.apps.googleusercontent.com"

    ctx =
      Sanctum.Context.build(
        user_id: user.user_id,
        athanor_id: Sanctum.Tenancy.Athanors.home!().id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    assert {:ok, %{"client_id" => "abc.apps.googleusercontent.com", "client_secret" => "shh"}} =
             Sanctum.ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "google")

    assert {:ok, %{providers: [%{provider: "google"}]}} =
             ToolRegistry.call_external("oauth", ctx, %{"action" => "list"})

    view |> element("button[phx-click=delete_client][phx-value-provider=google]") |> render_click()
    assert render(view) =~ "No client credentials stored"
    assert {:error, _} = Sanctum.ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "google")

    # removing what is not there says so
    assert {:error, msg} =
             ToolRegistry.call_external("oauth", ctx, %{"action" => "delete_client", "provider" => "google"})

    assert msg =~ "No client credentials"
  end
end
