# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LoginLiveTest do
  @moduledoc """
  Prism sign-in uses GitHub/Google device flow on this page, not the
  leftover Ueberauth web-callback at `/auth/:provider`. A GitHub OAuth
  app that only has a client id (device flow) must not be sent there —
  that path `fetch_env!`s `Ueberauth.Strategy.Github.OAuth` and 500s.
  """
  use PrismWeb.ConnCase, async: false

  defmodule FakeDeviceFlow do
    def init_device_flow(provider) when provider in [:github, :google] do
      {:ok,
       %{
         device_code: "dev-code",
         user_code: "WXYZ-1234",
         verification_uri: "https://github.com/login/device",
         expires_in: 900,
         interval: 60
       }}
    end

    def poll_for_session(_provider, _code) do
      Application.get_env(:cyfr, :device_flow_poll_result, {:ok, %{status: "pending"}})
    end
  end

  setup do
    originals = %{
      github_id: Application.get_env(:cyfr, :github_client_id),
      google_id: Application.get_env(:cyfr, :google_client_id),
      google_secret: Application.get_env(:cyfr, :google_client_secret),
      auth_provider: Application.get_env(:cyfr, :auth_provider),
      device_flow: Application.get_env(:cyfr, :device_flow),
      poll_result: Application.get_env(:cyfr, :device_flow_poll_result)
    }

    on_exit(fn ->
      restore(:github_client_id, originals.github_id)
      restore(:google_client_id, originals.google_id)
      restore(:google_client_secret, originals.google_secret)
      restore(:auth_provider, originals.auth_provider)
      restore(:device_flow, originals.device_flow)
      restore(:device_flow_poll_result, originals.poll_result)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:cyfr, key)
  defp restore(key, value), do: Application.put_env(:cyfr, key, value)

  describe "provider buttons" do
    test "GitHub and Google start device flow on this page, not /auth/:provider",
         %{conn: conn} do
      Application.put_env(:cyfr, :github_client_id, "github-device-id")
      Application.put_env(:cyfr, :google_client_id, "google-device-id")
      Application.put_env(:cyfr, :google_client_secret, "google-device-secret")
      Application.put_env(:cyfr, :auth_provider, Sanctum.Auth.OAuth)

      {:ok, view, html} = live(conn, ~p"/login")

      refute html =~ ~r{href="[^"]*/auth/github"}
      refute html =~ ~r{href="[^"]*/auth/google"}
      assert has_element?(view, "button[phx-click=start][phx-value-provider=github]")
      assert has_element?(view, "button[phx-click=start][phx-value-provider=google]")
      assert html =~ "Sign in with GitHub"
      assert html =~ "Sign in with Google"
    end

    test "an OIDC deployment still kicks off through /auth/oidcc", %{conn: conn} do
      Application.put_env(:cyfr, :auth_provider, Sanctum.Auth.OIDC)

      {:ok, _view, html} = live(conn, ~p"/login")

      assert html =~ ~r{href="[^"]*/auth/oidcc"}
      refute html =~ "Sign in with GitHub"
    end
  end

  describe "device flow" do
    setup do
      Application.put_env(:cyfr, :github_client_id, "github-device-id")
      Application.put_env(:cyfr, :auth_provider, Sanctum.Auth.OAuth)
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

      {:ok, view, _} = live(conn, ~p"/login")

      view
      |> element("button[phx-click=start][phx-value-provider=github]")
      |> render_click()

      send(view.pid, :login_poll)
      {path, _flash} = assert_redirect(view)

      assert String.starts_with?(path, "/auth/device/complete/")

      landed = get(build_conn(), path)
      assert redirected_to(landed) == "/"
      assert get_session(landed, :sanctum_session_token) == session.token
    end

    test "a missing device-complete ticket returns to login", %{conn: conn} do
      conn = get(conn, "/auth/device/complete/not-a-real-ticket")
      assert redirected_to(conn) == "/login"
    end
  end
end
