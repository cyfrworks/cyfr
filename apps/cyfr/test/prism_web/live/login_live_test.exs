# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LoginLiveTest do
  @moduledoc """
  Prism sign-in for GitHub and Google is device flow on this page; they
  have no browser callback. A deployment on its own issuer links to
  `/auth/oidcc`.
  """
  use PrismWeb.ConnCase, async: false

  defmodule FakeDeviceFlow do
    # Records the address it was handed. The `/live` socket passes no
    # rate-limit plug, so the LiveView supplying a real client IP is the
    # only per-address bound this surface has — a `nil` here would compile,
    # run, and silently leave sign-in exhaustible by one caller again.
    def init_device_flow(provider, client_ip) when provider in [:github, :google] do
      Application.put_env(:cyfr, :device_flow_last_ip, client_ip)

      {:ok,
       %{
         device_code: "dev-code",
         user_code: "WXYZ-1234",
         verification_uri: "https://github.com/login/device",
         expires_in: 900,
         interval: 60
       }}
    end

    def poll_for_session(_provider, _code, client_ip) do
      Application.put_env(:cyfr, :device_flow_last_ip, client_ip)
      Application.get_env(:cyfr, :device_flow_poll_result, {:ok, %{status: "pending"}})
    end
  end

  setup do
    originals = %{
      github_id: Application.get_env(:cyfr, :github_client_id),
      google_id: Application.get_env(:cyfr, :google_client_id),
      google_secret: Application.get_env(:cyfr, :google_client_secret),
      auth_provider: Application.get_env(:sanctum, :auth_provider),
      device_flow: Application.get_env(:cyfr, :device_flow),
      poll_result: Application.get_env(:cyfr, :device_flow_poll_result)
    }

    on_exit(fn ->
      restore(:github_client_id, originals.github_id)
      restore(:google_client_id, originals.google_id)
      restore(:google_client_secret, originals.google_secret)
      restore(:sanctum, :auth_provider, originals.auth_provider)
      restore(:device_flow, originals.device_flow)
      restore(:device_flow_poll_result, originals.poll_result)
    end)

    :ok
  end

  defp restore(key, value), do: restore(:cyfr, key, value)

  # The provider selection is the identity domain's key; everything else
  # here is the host's. Restoring the wrong application leaves a provider
  # set for every test that runs after this one.
  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  describe "provider buttons" do
    test "GitHub and Google start device flow on this page, not /auth/:provider",
         %{conn: conn} do
      Application.put_env(:cyfr, :github_client_id, "github-device-id")
      Application.put_env(:cyfr, :google_client_id, "google-device-id")
      Application.put_env(:cyfr, :google_client_secret, "google-device-secret")
      Application.put_env(:sanctum, :auth_provider, Sanctum.Auth.OAuth)

      {:ok, view, html} = live(conn, ~p"/login")

      refute html =~ ~r{href="[^"]*/auth/github"}
      refute html =~ ~r{href="[^"]*/auth/google"}
      assert has_element?(view, "button[phx-click=start][phx-value-provider=github]")
      assert has_element?(view, "button[phx-click=start][phx-value-provider=google]")
      assert html =~ "Sign in with GitHub"
      assert html =~ "Sign in with Google"
    end

    test "an OIDC deployment still kicks off through /auth/oidcc", %{conn: conn} do
      Application.put_env(:sanctum, :auth_provider, Sanctum.Auth.OIDC)

      {:ok, _view, html} = live(conn, ~p"/login")

      assert html =~ ~r{href="[^"]*/auth/oidcc"}
      refute html =~ "Sign in with GitHub"
    end
  end

  describe "device flow" do
    setup do
      Application.put_env(:cyfr, :github_client_id, "github-device-id")
      Application.put_env(:sanctum, :auth_provider, Sanctum.Auth.OAuth)
      Application.put_env(:cyfr, :device_flow, FakeDeviceFlow)
      :ok
    end

    test "start shows the user code and verification URL", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/login")

      view
      |> element("button[phx-click=start][phx-value-provider=github]")
      |> render_click()

      html = render(view)
      assert html =~ "WXYZ-1234"
      assert html =~ "https://github.com/login/device"
      assert html =~ "Waiting for authorization"
    end

    test "the flow is budgeted against a resolved client address", %{conn: conn} do
      Application.delete_env(:cyfr, :device_flow_last_ip)
      on_exit(fn -> Application.delete_env(:cyfr, :device_flow_last_ip) end)

      {:ok, view, _} = live(conn, ~p"/login")

      view
      |> element("button[phx-click=start][phx-value-provider=github]")
      |> render_click()

      # `/live` is handled by the endpoint before the router, so no plug
      # meters this socket: if the LiveView hands the flow a `nil` address,
      # one caller can exhaust the server-wide sign-in budget again.
      #
      # This covers the LiveView half only. `Phoenix.LiveViewTest` builds
      # `connect_info` from the test conn rather than from the endpoint's
      # socket declaration, so removing `:peer_data` from the endpoint
      # would NOT fail here — that half is pinned in
      # `EmissaryWeb.EndpointSocketTest`.
      ip = Application.get_env(:cyfr, :device_flow_last_ip)

      assert is_binary(ip), "the LiveView must budget the device flow by client address"

      assert {:ok, _} = :inet.parse_address(String.to_charlist(ip)),
             "expected a real address, got #{inspect(ip)}"

      refute ip == "0.0.0.0",
             "a connected socket must resolve a peer, not the fail-closed placeholder"
    end

    test "a completed poll redirects through the device-complete handshake", %{conn: conn} do
      ctx =
        Sanctum.Context.build(
          user_id: "github|https://github.com|login_live_#{System.unique_integer([:positive])}",
          email: "login@example.com",
          provider: "github",
          permissions: [:*],
          namespace: "testns",
          authenticated: true
        )

      {:ok, session} = Sanctum.Session.create(ctx)

      Application.put_env(
        :cyfr,
        :device_flow_poll_result,
        {:ok,
         %{
           status: "complete",
           session_token: session.token,
           outcome: {:proceed, %{unsynced: [], probe: :ok}}
         }}
      )

      # One browser start to finish. The ticket is bound to the session that
      # began the flow, so the visit that follows the redirect has to be the
      # same browser — here, the same conn carrying the same cookie.
      browser = get(conn, ~p"/login")

      {:ok, view, _} = live(browser, ~p"/login")

      view
      |> element("button[phx-click=start][phx-value-provider=github]")
      |> render_click()

      send(view.pid, :login_poll)
      {path, _flash} = assert_redirect(view)

      assert String.starts_with?(path, "/auth/device/complete/")

      landed = get(browser, path)
      assert redirected_to(landed) == "/"
      assert get_session(landed, :sanctum_session_token) == session.token
    end

    test "a boot that lost the control plane stops a waiting sign-in at its next poll, asking no provider",
         %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/login")

      view
      |> element("button[phx-click=start][phx-value-provider=github]")
      |> render_click()

      Cyfr.ControlPlane.mark(:lost)
      on_exit(fn -> Cyfr.ControlPlane.mark(:unclaimed) end)
      Application.delete_env(:cyfr, :device_flow_last_ip)
      on_exit(fn -> Application.delete_env(:cyfr, :device_flow_last_ip) end)

      send(view.pid, :login_poll)
      html = render(view)

      assert html =~ "not accepting sign-ins"
      refute html =~ "Waiting for authorization"
      assert Application.get_env(:cyfr, :device_flow_last_ip) == nil

      # Stopped: a later tick asks nothing either, owner again or not.
      Cyfr.ControlPlane.mark(:unclaimed)
      send(view.pid, :login_poll)
      _ = render(view)
      assert Application.get_env(:cyfr, :device_flow_last_ip) == nil
    end

    test "a page open on a boot that lost the control plane starts no sign-in", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/login")

      Cyfr.ControlPlane.mark(:lost)
      on_exit(fn -> Cyfr.ControlPlane.mark(:unclaimed) end)
      Application.delete_env(:cyfr, :device_flow_last_ip)
      on_exit(fn -> Application.delete_env(:cyfr, :device_flow_last_ip) end)

      html =
        view
        |> element("button[phx-click=start][phx-value-provider=github]")
        |> render_click()

      assert html =~ "not accepting sign-ins"
      refute html =~ "WXYZ-1234"
      assert Application.get_env(:cyfr, :device_flow_last_ip) == nil
    end

    test "a missing device-complete ticket returns to login", %{conn: conn} do
      conn = get(conn, "/auth/device/complete/not-a-real-ticket")
      assert redirected_to(conn) == "/login"
    end
  end
end
