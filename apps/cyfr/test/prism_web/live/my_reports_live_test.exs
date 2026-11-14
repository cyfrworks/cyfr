# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.MyReportsLiveTest do
  @moduledoc """
  The reports page lists the abuse reports the person filed with the
  configured registry, and names it as the registry.
  """
  use PrismWeb.ConnCase, async: false

  setup %{conn: conn} do
    {:ok, conn: log_in_user(conn, test_user())}
  end

  # `config/test.exs` configures a registry that is not cyfr.run.
  test "the page speaks of the registry, never of cyfr.run", %{conn: conn} do
    {view, _html} = mount_athanor(conn, "/reports")
    html = render(view)
    assert html =~ "Abuse reports you&#39;ve filed with the registry."
    refute html =~ "cyfr.run"
  end

  # Reports are read with a push token. A person who holds none is offered
  # the Registry page, where its sync mints one, not a command to run.
  test "with no push token the page links the Registry page's sync", %{conn: conn} do
    {view, _html} = mount_athanor(conn, "/reports")

    Prima.Test.Wait.wait_until(
      fn -> has_element?(view, "a", "Sync push tokens") end,
      5_000,
      "the page to offer the sync"
    )

    assert has_element?(view, ~s(a[href$="/registry"]), "Sync push tokens")

    html = render(view)
    assert html =~ "Your reports are read with a push token, and you hold none yet."
    refute html =~ "Couldn&#39;t load reports"
    refute html =~ "cyfr registry sync"
  end
end
