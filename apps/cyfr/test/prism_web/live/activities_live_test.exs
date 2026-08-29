# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ActivitiesLiveTest do
  @moduledoc """
  The activities log and its filters.

  `filters_path/1` built the query string by interpolating a list of
  `{key, value}` tuples, which raises — `String.Chars` has no implementation
  for a list of tuples. Every filter that was not "all" therefore crashed the
  LiveView on `push_patch`, the client reconnected with the filters reset, and
  the page had no test to say so.
  """
  use PrismWeb.ConnCase, async: false

  setup %{conn: conn} do
    {view, _html} = conn |> log_in_user(test_user()) |> mount_athanor("/activities")
    {:ok, view: view}
  end

  test "the source and status filters patch instead of crashing", %{view: view} do
    html = render_change(view, "filter", %{"source" => "mcp", "status" => ""})
    assert is_binary(html)
    assert settled_render(view) =~ "Activities"

    render_change(view, "filter", %{"source" => "", "status" => "error"})
    render_change(view, "filter", %{"source" => "tincture", "status" => "success"})

    assert settled_render(view) =~ "Activities"
  end

  test "the time filter patches instead of crashing", %{view: view} do
    for window <- ["1h", "24h", "7d", ""] do
      render_change(view, "time_filter", %{"time" => window})
      assert settled_render(view) =~ "Activities", "the #{inspect(window)} window crashed the view"
    end
  end

  test "a filtered path is a real query string", %{view: view} do
    # The proof the crash is gone AND that the URL is well-formed: the patch
    # must carry `source=mcp`, not an inspected keyword list.
    render_change(view, "filter", %{"source" => "mcp", "status" => "error"})

    path = assert_patch(view)
    assert path =~ "/activities?"
    assert URI.decode_query(URI.parse(path).query) == %{"source" => "mcp", "status" => "error"}
    settled_render(view)
  end

  test "clearing every filter patches back to the bare path", %{view: view} do
    render_change(view, "filter", %{"source" => "mcp", "status" => ""})
    assert_patch(view)

    render_change(view, "filter", %{"source" => "", "status" => ""})
    path = assert_patch(view)

    refute path =~ "?"
    settled_render(view)
  end
end
