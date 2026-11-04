# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.PairLiveTest do
  @moduledoc """
  `/pair`, where a pairing link opens in a browser: sessionless, it pairs
  nothing and holds no key. A pairing link is for a command line or a
  box's own screen, which keeps its key under a local unlock; the page
  says so, and the code stays in the fragment the browser never sends.
  """

  use PrismWeb.ConnCase, async: false

  test "says where a pairing link goes, and holds no key to pair with", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/pair")

    assert html =~ ~s(data-test="pair-elsewhere")
    assert html =~ "cyfr login"
    refute html =~ "phx-hook"
    refute html =~ ~s(data-glass)
  end
end
