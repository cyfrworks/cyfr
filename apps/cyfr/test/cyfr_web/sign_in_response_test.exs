# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.SignInResponseTest do
  @moduledoc """
  The one transcription of an admitted sign-in to a browser response: a
  ticket's token becomes the session on a clean Plug session, and the
  browser lands on the console root. Nothing beside the session is
  written.
  """
  use CyfrWeb.ConnCase, async: false

  alias CyfrWeb.SignInResponse

  @secret String.duplicate("s", 64)

  defp browser_conn(session \\ %{}) do
    build_conn()
    |> Map.put(:secret_key_base, @secret)
    |> init_test_session(session)
    |> fetch_flash()
  end

  test "the session key is the context guard's" do
    assert SignInResponse.session_key() == CyfrWeb.ContextGuard.session_key()
  end

  describe "respond/3 — a proceed" do
    test "a ticket's token becomes the session and the console root is the landing" do
      conn =
        SignInResponse.respond(browser_conn(), :proceed, session: {:token, "tok-1"})

      assert redirected_to(conn) == "/"
      assert get_session(conn, SignInResponse.session_key()) == "tok-1"
    end

    test "the anonymous session is cleared before the token is written" do
      conn =
        %{"_csrf_token" => "planted"}
        |> browser_conn()
        |> SignInResponse.respond(:proceed, session: {:token, "tok-2"})

      assert get_session(conn, "_csrf_token") == nil
      assert get_session(conn, SignInResponse.session_key()) == "tok-2"
    end

    test "nothing beside the session is written: no provider token is kept" do
      conn = SignInResponse.respond(browser_conn(), :proceed, session: {:token, "tok-3"})

      assert conn.resp_cookies == %{}
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == nil
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == nil
    end

    test "a response without flash still lands" do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> SignInResponse.respond(:proceed, session: {:token, "tok-4"})

      assert redirected_to(conn) == "/"
      refute Map.has_key?(conn.assigns, :flash)
    end
  end

  describe "the flash helper" do
    test "put_flash_if_available/3 flashes when flash is fetched and is a no-op otherwise" do
      conn = SignInResponse.put_flash_if_available(browser_conn(), :info, "hello")
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "hello"

      bare = build_conn()
      assert SignInResponse.put_flash_if_available(bare, :info, "hello") == bare
    end
  end
end
