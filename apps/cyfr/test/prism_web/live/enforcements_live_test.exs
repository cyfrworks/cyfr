# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.EnforcementsLiveTest do
  @moduledoc """
  The enforcements log and its filters.

  Checks filter changes update the query string without crashing
  or resetting the LiveView.
  """
  use PrismWeb.ConnCase, async: false

  setup %{conn: conn} do
    conn = log_in_user(conn, test_user())
    {view, _html} = mount_athanor(conn, "/enforcements")
    {:ok, conn: conn, view: view}
  end

  defp filter(view, params) do
    defaults = %{"event_type" => "", "decision" => "", "component" => ""}
    render_change(view, "filter", Map.merge(defaults, params))
  end

  test "each filter patches instead of crashing", %{view: view} do
    filter(view, %{"event_type" => "policy_consultation"})
    assert settled_render(view) =~ "Enforcements"

    filter(view, %{"decision" => "denied"})
    assert settled_render(view) =~ "Enforcements"

    filter(view, %{"component" => "catalyst:local.http"})
    assert settled_render(view) =~ "Enforcements"
  end

  test "a filtered path is a real query string", %{view: view} do
    filter(view, %{"decision" => "denied", "component" => "catalyst:local.http"})

    path = assert_patch(view)
    assert path =~ "/enforcements?"

    assert URI.decode_query(URI.parse(path).query) == %{
             "decision" => "denied",
             "component" => "catalyst:local.http"
           }

    settled_render(view)
  end

  test "a component name with characters that need escaping survives", %{view: view} do
    # The reason to encode rather than interpolate: a ref carries `:` and a
    # `.`, and a filter value is free text.
    filter(view, %{"component" => "catalyst:local.a b&c"})

    path = assert_patch(view)
    assert URI.decode_query(URI.parse(path).query)["component"] == "catalyst:local.a b&c"
    settled_render(view)
  end

  test "clearing every filter patches back to the bare path", %{view: view} do
    filter(view, %{"decision" => "denied"})
    assert_patch(view)

    filter(view, %{})
    path = assert_patch(view)

    refute path =~ "?"
    settled_render(view)
  end

  test "a row's link opens the activities page on its request", %{conn: conn} do
    request_id = Prima.UUID7.request_id()

    {:ok, _row} =
      Arca.PolicyLog.record(%{
        id: Prima.UUID7.generate_id("pl"),
        request_id: request_id,
        athanor_id: seated_athanor().id,
        user_id: "user_enforcements",
        timestamp: DateTime.utc_now(),
        event_type: "policy_consultation",
        component_ref: "formula:local.enforced-fixture:0.1.0",
        component_type: "formula",
        decision: "allowed",
        decision_reason: "the row under test"
      })

    {view, _html} = mount_athanor(conn, "/enforcements")

    assert {:error, {:live_redirect, %{to: path}}} =
             view |> element("tbody tr", "formula:local.enforced-fixture") |> render_click()

    {:ok, activities, _html} = live(conn, path)
    assert :sys.get_state(activities.pid).socket.assigns.expanded_id == request_id
  end
end
