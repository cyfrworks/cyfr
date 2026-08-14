# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.SafeRedirectTest do
  @moduledoc """
  Every login gate lands on the console root through this one helper —
  the target is fixed, never configuration and never user input.
  """
  use EmissaryWeb.ConnCase, async: true

  test "lands on the console root as an internal redirect", %{conn: conn} do
    conn = EmissaryWeb.SafeRedirect.post_login(conn)

    assert redirected_to(conn) == "/"
  end
end
