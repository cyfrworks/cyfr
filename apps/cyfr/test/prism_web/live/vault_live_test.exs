# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.VaultLiveTest do
  @moduledoc """
  Tests sign-in gating, vault-entry server references and management of
  operator OAuth client credentials on the Vault page.

  Storing client credentials is a sensitive change: the page asks
  through its system layer, and nothing is stored until the person
  confirms the record; the browser then submits the same form again,
  which still holds what was typed, and the page stores it. The page
  holds no typed secret while it waits. Listing and removing them need
  the session alone.
  """
  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait

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

    typed = %{
      "provider" => "google",
      "client_id" => "abc.apps.googleusercontent.com",
      "client_secret" => @client_secret
    }

    view |> form("form[phx-submit=set_client]", typed) |> render_submit()

    ctx =
      Sanctum.Context.build(
        user_id: user.user_id,
        athanor_id: seated_athanor().id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    # The change waits on its record, shown as this page's own; nothing is
    # stored, and neither the request's secret nor the client secret
    # appears in the page, its flash or its state.
    assert {:ok, [%{ref: ref, operation: "oauth.set_client"}]} =
             Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)

    wait_until(fn -> render(view) =~ ~s(data-ref="#{ref}") end, 2_000, "the page's prompt")

    # The form that typed it is marked, in the browser, with the prompt it
    # asks under.
    prompt_id = "confirmation-" <> ref
    assert_push_event(view, "system_layer:mark", %{form: "vault-client-form", prompt: ^prompt_id})

    state = inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity)
    refute state =~ @client_secret
    flash = inspect(:sys.get_state(view.pid).socket.assigns.flash)
    refute flash =~ "cnf_"
    refute flash =~ @client_secret
    rendered = render(view)
    assert rendered =~ "No client credentials stored"
    refute rendered =~ "cnf_"
    refute rendered =~ @client_secret
    assert {:error, _} = Sanctum.ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "google")

    # Confirmed, the browser is asked to submit the form again, as typed;
    # the page lists the provider alone.
    Sanctum.TestContext.prove!(ctx, ref)
    assert_push_event(view, "system_layer:resubmit", %{form: "vault-client-form"}, 2_000)
    view |> form("form[phx-submit=set_client]", typed) |> render_submit()

    # Completed: every form marked with its prompt is emptied.
    assert_push_event(
      view,
      "system_layer:clear",
      %{prompt: ^prompt_id, form: "vault-client-form"},
      2_000
    )

    rendered = render(view)
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

  test "a request dismissed before its proof is cancelled, and its typed form emptied",
       %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    {view, _html} = mount_athanor(conn, "/vault")
    render_click(view, "show_add", %{"mode" => "client"})

    view
    |> form("form[phx-submit=set_client]", %{
      "provider" => "github",
      "client_id" => "an-id",
      "client_secret" => @client_secret
    })
    |> render_submit()

    ctx = %{Sanctum.TestContext.local() | athanor_id: seated_athanor().id, user_id: user.user_id}

    assert {:ok, [%{ref: ref}]} =
             Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)

    prompt_id = "confirmation-" <> ref
    assert_push_event(view, "system_layer:mark", %{form: "vault-client-form", prompt: ^prompt_id})

    # The person cancels their own waiting request from its prompt.
    view |> element(~s(#system-layer-dialog [data-test="prompt-dismiss"])) |> render_click()

    assert_push_event(view, "system_layer:clear", %{prompt: ^prompt_id, form: "vault-client-form"})

    assert {:ok, %{state: "cancelled"}} =
             Arca.PendingConfirmations.get(Sanctum.Context.actor(ctx), ref)

    assert {:error, _} = Sanctum.ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "github")
    Cyfr.Test.Sandbox.end_views()
  end

  test "a request nobody confirms ends on the page at its expiry, and its typed form is emptied",
       %{conn: conn} do
    Cyfr.Test.Settings.put("confirmation_seconds", 2)
    user = test_user()
    conn = log_in_user(conn, user)
    {view, _html} = mount_athanor(conn, "/vault")
    render_click(view, "show_add", %{"mode" => "client"})

    view
    |> form("form[phx-submit=set_client]", %{
      "provider" => "github",
      "client_id" => "an-id",
      "client_secret" => @client_secret
    })
    |> render_submit()

    ctx = %{Sanctum.TestContext.local() | athanor_id: seated_athanor().id, user_id: user.user_id}

    assert {:ok, [%{ref: ref}]} =
             Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)

    prompt_id = "confirmation-" <> ref
    assert_push_event(view, "system_layer:mark", %{form: "vault-client-form", prompt: ^prompt_id})

    # Nothing repeats, so the home never announces the expiry: the page
    # ends the wait itself at the record's expiry and lets the form go.
    assert_push_event(
      view,
      "system_layer:clear",
      %{prompt: ^prompt_id, form: "vault-client-form"},
      5_000
    )

    assert render(view) =~ "This request expired"
    assert {:error, _} = Sanctum.ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "github")
    Cyfr.Test.Sandbox.end_views()
  end
end
