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
end
