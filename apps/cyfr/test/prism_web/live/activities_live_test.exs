# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ActivitiesLiveTest do
  @moduledoc """
  The activities log and its filters.

  Checks that filter changes update the query string and preserve
  the LiveView session, and that a row is keyed by the request its call
  belongs to.
  """
  use PrismWeb.ConnCase, async: false

  setup %{conn: conn} do
    conn = log_in_user(conn, test_user())
    {view, _html} = mount_athanor(conn, "/activities")
    {:ok, view: view, conn: conn}
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

      assert settled_render(view) =~ "Activities",
             "the #{inspect(window)} window crashed the view"
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

  test "a row is keyed by its request, and expanding it correlates that request",
       %{conn: conn} do
    estate = seated_athanor()

    ctx = %{
      Sanctum.TestContext.local()
      | athanor_id: estate.id,
        request_id: Prima.UUID7.request_id()
    }

    # One recorded call under a request, and an execution the same request
    # started.
    decision =
      Prima.Decision.new(
        call_id: Prima.UUID7.generate_id("call"),
        request_id: ctx.request_id,
        user_id: ctx.user_id,
        athanor_id: estate.id,
        plane: :external,
        tool: "execution",
        action: "run",
        inserted_at: DateTime.utc_now(),
        admission: :admitted
      )

    :ok = Grimoire.open_decision(ctx, decision, %{input: %{}})
    _lineage = Cyfr.Test.AttemptFixtures.lineage!(ctx)

    {view, _html} = mount_athanor(conn, "/activities")

    row = ~s(tr[phx-value-id="#{ctx.request_id}"])
    assert has_element?(view, row)
    refute has_element?(view, ~s(tr[phx-value-id="#{decision.call_id}"]))

    view |> element(row) |> render_click()
    html = settled_render(view)

    # The expansion is the request's: the execution it started is there.
    assert html =~ "Executions (1)"
    assert html =~ "lineage-fixture"
  end
end
