# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.PendingProbeTest do
  @moduledoc """
  The pending-probe cookie the claim and legal pages read, and the
  provider a flow reports: an explicit valid parameter, else the one the
  session signed in with, else the device-flow roster's first.
  """
  use CyfrWeb.ConnCase, async: false

  alias CyfrWeb.PendingProbe
  alias CyfrWeb.SignInResponse

  @secret String.duplicate("p", 64)

  defp probe_cookie(token) do
    %{value: value} =
      build_conn()
      |> Map.put(:secret_key_base, @secret)
      |> put_resp_cookie(PendingProbe.cookie_name(), token, encrypt: true, max_age: 600)
      |> Map.fetch!(:resp_cookies)
      |> Map.fetch!(PendingProbe.cookie_name())

    value
  end

  defp conn_with(session, cookie \\ nil) do
    conn =
      build_conn()
      |> Map.put(:secret_key_base, @secret)
      |> init_test_session(session)

    if cookie, do: put_req_cookie(conn, PendingProbe.cookie_name(), cookie), else: conn
  end

  test "the cookie is the one the sign-in response writes" do
    assert PendingProbe.cookie_name() == "_cyfr_pending_probe"
  end

  describe "pop/1" do
    test "an encrypted cookie yields its token and stays in place" do
      assert {:ok, conn, "gho_probe"} =
               PendingProbe.pop(conn_with(%{}, probe_cookie("gho_probe")))

      refute Map.has_key?(conn.resp_cookies, PendingProbe.cookie_name())
    end

    test "a lapsed cookie with a session is expired" do
      session = %{SignInResponse.session_key() => "a-session"}
      assert {:expired, _conn} = PendingProbe.pop(conn_with(session))
    end

    test "neither cookie nor session is not logged in" do
      assert {:not_logged_in, _conn} = PendingProbe.pop(conn_with(%{}))
    end

    test "a cookie that does not decrypt reads as absent" do
      assert {:not_logged_in, _conn} = PendingProbe.pop(conn_with(%{}, "gho_plaintext"))
    end
  end

  test "clear/1 deletes the cookie" do
    conn = PendingProbe.clear(conn_with(%{}, probe_cookie("gho_probe")))

    assert %{max_age: 0} = conn.resp_cookies[PendingProbe.cookie_name()]
  end

  describe "current_provider/1,2" do
    test "a valid provider parameter wins" do
      assert PendingProbe.current_provider(conn_with(%{}), %{"provider" => "google"}) == "google"
    end

    test "with no session the roster's first stands in, whatever the parameter" do
      first = hd(Sanctum.Auth.DeviceFlow.providers())

      assert PendingProbe.current_provider(conn_with(%{})) == first
      assert PendingProbe.current_provider(conn_with(%{}), %{"provider" => "evil"}) == first
    end

    test "the session's provider is reported as it signed in, unfiltered by the roster" do
      ctx = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
      {:ok, session} = Sanctum.Session.create(ctx)
      conn = conn_with(%{SignInResponse.session_key() => session.token})

      assert PendingProbe.current_provider(conn) == "local"
      assert PendingProbe.current_provider(conn, %{"provider" => "evil"}) == "local"
      assert PendingProbe.current_provider(conn, %{"provider" => "github"}) == "github"

      Sanctum.Session.destroy(session.token)
    end
  end
end
