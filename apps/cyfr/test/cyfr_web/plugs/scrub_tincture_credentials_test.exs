# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.ScrubTinctureCredentialsTest do
  @moduledoc """
  A private tincture's served files and a canvas's host page carry their
  asset credential in the path, because a navigation, a script or an image
  fetch carries no header. Whatever else is true of that design, the
  credential must not survive into anything that names the request: the
  plug redacts it from `conn.request_path` by shape, while routing and the
  action still read it. The end-to-end check, through the endpoint's and
  the router's telemetry and the log, is the page's own test
  (`Emissary.Web.CanvasControllerTest`).
  """
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias CyfrWeb.Plugs.ScrubTinctureCredentials

  @credential "AbCdEfGhIjKlMnOpQrSt.uvwxyz0123456789_-"

  defp run(path) do
    :get
    |> conn(path)
    |> ScrubTinctureCredentials.call([])
  end

  test "redacts the credential segment, and routing still reads it" do
    conn = run("/_s/#{@credential}/local/game/1.0.0/assets/app.js")

    assert conn.request_path == "/_s/[REDACTED]/local/game/1.0.0/assets/app.js"
    refute conn.request_path =~ @credential
    # Routing matches on `path_info`, which keeps the credential.
    assert conn.path_info == ["_s", @credential, "local", "game", "1.0.0", "assets", "app.js"]
  end

  test "redacts by shape: a credential outside the grammar is redacted as well" do
    for segment <- ["short", "..", "has%20space", String.duplicate("x", 2_000)] do
      conn = run("/_s/#{segment}/index.html")
      assert conn.request_path == "/_s/[REDACTED]/index.html", segment
    end

    assert run("/_s/#{@credential}").request_path == "/_s/[REDACTED]"
  end

  test "a response answered before the action carries the redacted path" do
    sent =
      "/_s/#{@credential}/local/game/1.0.0/index.html"
      |> run()
      |> Map.put(:request_path, "/_s/#{@credential}/local/game/1.0.0/index.html")
      |> send_resp(429, "rate limited")

    assert sent.status == 429
    refute sent.request_path =~ @credential
  end

  test "leaves every other path as it is" do
    for path <- ["/t/home/local/demo", "/t/home/local/demo/_s/x/app.js", "/api/health", "/"] do
      assert run(path).request_path == path
    end
  end

  test "redact_path/1 names the served-file prefix of the URL grammar" do
    path = Prima.TinctureUrl.asset_path(@credential, ["local", "game", "1.0.0", "index.html"])
    assert ScrubTinctureCredentials.redact_path(path) =~ "/_s/[REDACTED]/"
  end

  # A value no request path may carry once the plug has run.
  @canary "c4n4ryP4geCredential0123456789_-"
  @frame "frm_8f3c2a1b9d"

  test "a canvas page credential is redacted, early refusals and malformed credentials included" do
    page = Prima.CanvasWire.page_path(@canary, @frame)
    assert String.starts_with?(page, Prima.CanvasWire.page_prefix())

    conn = run(page)
    assert conn.request_path == Prima.CanvasWire.page_prefix() <> "[REDACTED]/" <> @frame
    refute conn.request_path =~ @canary
    # Routing still reads the credential and the frame.
    assert conn.path_info == ["_c", "v1", @canary, @frame]

    # By shape: a credential outside the grammar, a path with no frame or
    # with more after it, and doubled slashes, which route as single ones.
    for path <- [
          "/_c/v1/#{@canary}!not-a-credential/#{@frame}",
          "/_c/v1/#{@canary}",
          "/_c/v1/#{@canary}/",
          "/_c/v1/#{@canary}/#{@frame}/extra",
          "/_c/v1//#{@canary}/#{@frame}",
          "/_c//v1//#{@canary}//#{@frame}",
          "/_c/v1/.#{@canary}./#{@frame}",
          "/_c/v1/#{String.duplicate(@canary, 64)}/#{@frame}"
        ] do
      scrubbed = run(path).request_path
      refute scrubbed =~ @canary, path
      assert scrubbed =~ "[REDACTED]", path
    end

    # A response answered before the action, as the rate limit answers
    # its 429, carries the redacted path too.
    sent =
      page
      |> run()
      |> Map.put(:request_path, page)
      |> send_resp(429, "rate limited")

    assert sent.status == 429
    refute sent.request_path =~ @canary

    # The served-file prefix is counted as routing counts it as well.
    refute run("/_s//#{@canary}/local/game/1.0.0/app.js").request_path =~ @canary

    # A prefix written with escapes is the prefix the router decodes and
    # routes, the served files' as much as the page's.
    for path <- [
          "/%5Fc/v1/#{@canary}/#{@frame}",
          "/_c/%76%31/#{@canary}/#{@frame}",
          "/%5f%63/%76%31/#{@canary}/#{@frame}",
          "/%5Fs/#{@canary}/local/game/1.0.0/app.js"
        ] do
      scrubbed = run(path).request_path
      refute scrubbed =~ @canary, path
      assert scrubbed =~ "/[REDACTED]/", path
    end

    # A segment whose escape does not decode is compared as it is written:
    # it routes nowhere, and the path is left as it came.
    assert run("/_c/v1%zz/#{@frame}/x").request_path == "/_c/v1%zz/#{@frame}/x"

    # A path the page prefix does not begin is not a page's.
    for path <- ["/_c", "/_c/v1", "/_c/v2/#{@frame}/x", "/a/_c/v1/x/y"] do
      assert run(path).request_path == path
    end
  end
end
