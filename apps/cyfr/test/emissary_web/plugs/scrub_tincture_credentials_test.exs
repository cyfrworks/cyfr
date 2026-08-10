# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.ScrubTinctureCredentialsTest do
  @moduledoc """
  A tincture credential may arrive as a query param (`?_t=`, `?_key=`,
  `?_session=`) because iframe and `<img>` URLs cannot carry headers. Whatever
  else is true of that design, the raw value must not survive into anything that
  logs the request.
  """
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias EmissaryWeb.Plugs.ScrubTinctureCredentials

  defp run(query_string) do
    conn =
      :get
      |> conn("/t/local/default/local/demo?" <> query_string)
      |> ScrubTinctureCredentials.call([])

    # The action still sees the raw credential — auth happens before the
    # response is sent.
    assert conn.query_string == query_string

    send_resp(conn, 200, "ok")
  end

  test "redacts a session credential before the response is sent" do
    sent = run("_session=cyfr_live_secret_value")

    refute sent.query_string =~ "cyfr_live_secret_value"
    assert sent.query_string =~ "REDACTED"
  end

  test "redacts every credential param shape" do
    for {key, value} <- [
          {"_session", "sess_secret"},
          {"_key", "cyfr_sk_secret"},
          {"_t", "signed_token_secret"}
        ] do
      sent = run("#{key}=#{value}")
      refute sent.query_string =~ value, "#{key} leaked its value"
    end
  end

  test "leaves non-credential params intact" do
    sent = run("_session=sess_secret&view=grid&page=2")

    refute sent.query_string =~ "sess_secret"
    assert sent.query_string =~ "view=grid"
    assert sent.query_string =~ "page=2"
  end

  test "scrubs responses that never reach authentication" do
    # A 429 or 503 is logged like any other response, and returns long before
    # the action reads the credential.
    conn =
      :get
      |> conn("/t/local/default/local/demo?_session=cyfr_live_secret_value")
      |> ScrubTinctureCredentials.call([])
      |> send_resp(429, "rate limited")

    assert conn.status == 429
    refute conn.query_string =~ "cyfr_live_secret_value"
  end

  test "is a no-op for a request with no query string" do
    sent =
      :get
      |> conn("/t/local/default/local/demo")
      |> ScrubTinctureCredentials.call([])
      |> send_resp(200, "ok")

    assert sent.query_string == ""
  end
end
