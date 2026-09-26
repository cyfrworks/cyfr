# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.ScrubTinctureCredentialsTest do
  @moduledoc """
  A private tincture's served files carry their asset credential in the
  path, because a script or image fetch carries no header. Whatever else is
  true of that design, the credential must not survive into anything that
  names the request: the plug redacts it from `conn.request_path` by shape,
  while routing and the action still read it.
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
end
