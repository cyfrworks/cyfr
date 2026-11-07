# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Emissary.Web.DirectoryPrivacyTest do
  @moduledoc """
  A directory keeps no record of who was asked about past its rate
  windows: through the mounted endpoint, a directory request's log lines
  name its route pattern and never an identifier, an unmatched path under
  a directory prefix names no text the caller put in it, and no level
  logs what a request submitted (`CyfrWeb.Plugs.ScrubTinctureCredentials`,
  the routes' `log: false`).
  """
  use CyfrWeb.ConnCase, async: false

  setup do
    Prima.Test.Env.put_app_env(:sanctum, :public_url, "https://dir.example")
    Cyfr.Test.Settings.put("directory_serve", "writer")
    Prima.Test.RateLimiter.reset!()
    on_exit(&Prima.Test.RateLimiter.reset!/0)
    :ok
  end

  test "directory request logs carry the route, never the account identifier", %{conn: conn} do
    Prima.Test.Env.configure_logger(level: :info)
    identifier = "per_" <> String.duplicate("a", 64)

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        assert get(conn, "/directory/v1/" <> identifier).status == 404
      end)

    refute log =~ identifier
  end

  test "directory debug logging carries no submitted account data", %{conn: conn} do
    Prima.Test.Env.configure_logger(level: :debug)
    canary = "astra-private-label-canary"

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert conn
               |> put_req_header("content-type", "application/json")
               |> post("/directory/v1/register", Jason.encode!(%{"label" => canary}))
               |> Map.fetch!(:status) == 422
      end)

    refute log =~ canary
  end

  test "the handle registry's and the account pages' requests are logged by their route alone",
       %{conn: conn} do
    canary = "registrycanary"
    Prima.Test.Env.configure_logger(level: :info)

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        get(conn, "/v1/handles/" <> canary)
        get(conn, "/v1/handles/" <> canary <> "/more")
      end)

    assert log =~ "GET /v1/handles/:handle"
    assert log =~ "GET /v1/handles/[REDACTED]"
    refute log =~ canary

    # The account pages read no account: at debug too, their lines name the
    # route and no dispatch names the page asked for.
    Prima.Test.Env.configure_logger(level: :debug)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        get(conn, "/account/" <> canary)
        get(conn, "/account/" <> canary <> "/more")
      end)

    assert log =~ "GET /account/:name"
    assert log =~ "GET /account/[REDACTED]"
    refute log =~ "Processing with"
    refute log =~ canary
  end

  test "unmatched directory paths cannot make identifiable request log lines", %{conn: conn} do
    Prima.Test.Env.configure_logger(level: :info)
    canary = "astra-unmatched-person-canary"

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        assert get(conn, "/directory/v1/unmatched/" <> canary).status == 404
      end)

    refute log =~ canary
  end
end
