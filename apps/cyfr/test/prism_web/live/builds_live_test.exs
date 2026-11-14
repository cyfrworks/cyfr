# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.BuildsLiveTest do
  @moduledoc """
  The Builds page's compile form.
  """
  use PrismWeb.ConnCase, async: false

  setup %{conn: conn} do
    conn = log_in_user(conn, test_user())
    {view, _html} = mount_athanor(conn, "/builds")
    {:ok, view: view}
  end

  # The placeholder is submitted like any choice, so a compile with
  # nothing chosen is answered rather than dropped. A browser submits no
  # value for a disabled option, which this test's form submission does
  # not model, so the option's markup is asserted too.
  test "Compile with nothing chosen says to choose a component", %{view: view} do
    assert has_element?(view, ~s(select[name="reference"] option[value=""]))
    refute has_element?(view, ~s(select[name="reference"] option[value=""][disabled]))

    view |> form(~s(form[phx-submit="compile"])) |> render_submit()

    assert :sys.get_state(view.pid).socket.assigns.flash ==
             %{"error" => "Please select a component first."}
  end
end
