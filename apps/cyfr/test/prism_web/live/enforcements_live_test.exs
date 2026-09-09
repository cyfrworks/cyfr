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
    {view, _html} = conn |> log_in_user(test_user()) |> mount_athanor("/enforcements")
    {:ok, view: view}
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
end
