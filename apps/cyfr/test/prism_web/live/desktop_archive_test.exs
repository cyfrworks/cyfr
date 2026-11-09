# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.DesktopArchiveTest do
  @moduledoc """
  Archiving a person's athanor sends every open desktop
  (`PrismWeb.ShellLive`) away, the chat and AQUA's panel nested in it
  with it, and a fresh open of the athanor is refused.
  """

  use PrismWeb.ConnCase, async: false

  test "archiving the athanor sends every open desktop away, and a fresh open is refused",
       %{conn: conn} do
    conn = log_in_user(conn, test_user())
    athanor = seated_athanor()
    {view, _html} = mount_desktop(conn)

    Sanctum.TestContext.archive!(athanor.id)
    assert_redirect(view, "/", 5_000)

    # The root, or the login page when the archived athanor was the only
    # one the session had.
    assert {:error, {_, %{to: to}}} = live(conn, athanor_path("", athanor))
    assert to in ["/", "/login?error=no_athanor"]

    Cyfr.Test.Sandbox.end_views()
  end
end
