# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ActivitiesLiveTest do
  @moduledoc """
  The activities log and its filters.

  Checks that filter changes update the query string and preserve
  the LiveView session, that the rows are the athanor's admission
  decisions, and that a row is keyed by the request its call belongs to
  and expands into that request's correlation.
  """
  use PrismWeb.ConnCase, async: false

  setup %{conn: conn} do
    conn = log_in_user(conn, test_user())
    {view, _html} = mount_athanor(conn, "/activities")
    {:ok, view: view, conn: conn}
  end

  test "the source and admission filters patch instead of crashing", %{view: view} do
    html = render_change(view, "filter", %{"source" => "mcp", "admission" => ""})
    assert is_binary(html)
    assert settled_render(view) =~ "Activities"

    render_change(view, "filter", %{"source" => "", "admission" => "refused"})
    render_change(view, "filter", %{"source" => "tincture", "admission" => "admitted"})
    render_change(view, "filter", %{"source" => "", "admission" => "not_an_admission"})

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
    render_change(view, "filter", %{"source" => "mcp", "admission" => "refused"})

    path = assert_patch(view)
    assert path =~ "/activities?"

    assert URI.decode_query(URI.parse(path).query) == %{
             "source" => "mcp",
             "admission" => "refused"
           }

    settled_render(view)
  end

  test "clearing every filter patches back to the bare path", %{view: view} do
    render_change(view, "filter", %{"source" => "mcp", "admission" => ""})
    assert_patch(view)

    render_change(view, "filter", %{"source" => "", "admission" => ""})
    path = assert_patch(view)

    refute path =~ "?"
    settled_render(view)
  end

  test "a row is keyed by its request, and expanding it correlates that request",
       %{conn: conn} do
    ctx = athanor_context()

    # One recorded call under a request, and an execution the same request
    # started.
    decision = decision(ctx, tool: "execution", action: "run")
    :ok = Grimoire.open_decision(ctx, decision, %{input: %{"reference" => "probe-input"}})
    _lineage = Cyfr.Test.AttemptFixtures.lineage!(ctx)

    {view, _html} = mount_athanor(conn, "/activities")

    row = ~s(tr[phx-value-id="#{ctx.request_id}"])
    assert has_element?(view, row)
    refute has_element?(view, ~s(tr[phx-value-id="#{decision.call_id}"]))

    # The row is the decision: its operation, plane and admission, and no
    # completion yet.
    assert has_element?(view, ~s(tr[data-call-id="#{decision.call_id}"]), "execution.run")
    assert has_element?(view, ~s(tr[data-call-id="#{decision.call_id}"]), "external")
    assert has_element?(view, ~s(tr[data-call-id="#{decision.call_id}"]), "admitted")
    assert has_element?(view, ~s(tr[data-call-id="#{decision.call_id}"]), "unknown")

    # The fan-out count is the request's: the execution it started.
    assert has_element?(view, ~s(tr[data-call-id="#{decision.call_id}"] span.font-mono), "1")

    view |> element(row) |> render_click()
    html = settled_render(view)

    # The expansion is the request's: its decision, the execution it
    # started, and the call's input from its request-log row.
    assert html =~ "Decisions (1)"
    assert html =~ "Executions (1)"
    assert html =~ "lineage-fixture"
    assert html =~ "probe-input"
  end

  test "a refusal is a row with its class, and a completion shows how the work ended",
       %{conn: conn} do
    ctx = athanor_context()

    refused =
      decision(ctx,
        tool: "storage",
        action: "put",
        admission: :refused,
        refusal_class: :forbidden,
        reason: "Not allowed here."
      )

    :ok = Grimoire.open_decision(ctx, refused, %{input: %{}})

    admitted = decision(ctx, tool: "storage", action: "get")
    :ok = Grimoire.open_decision(ctx, admitted, %{input: %{}})

    :ok =
      Grimoire.close_decision(ctx, admitted.call_id, %{
        result: {:error, {:not_found, "File", "x"}},
        duration_ms: 3
      })

    # The host's own row — a refusal before any caller — is never the
    # athanor's to see.
    host = decision(nil, tool: "storage", admission: :refused, refusal_class: :unauthenticated)
    :ok = Arca.DecisionLog.append(nil, host)

    {view, _html} = mount_athanor(conn, "/activities")

    assert has_element?(view, ~s(tr[data-call-id="#{refused.call_id}"]), "refused: forbidden")
    assert has_element?(view, ~s(tr[data-call-id="#{admitted.call_id}"]), "failed: not_found")
    refute has_element?(view, ~s(tr[data-call-id="#{host.call_id}"]))

    # The admission filter narrows the list to the refusals.
    render_change(view, "filter", %{"source" => "", "admission" => "refused"})
    assert_patch(view)
    settled_render(view)

    assert has_element?(view, ~s(tr[data-call-id="#{refused.call_id}"]))
    refute has_element?(view, ~s(tr[data-call-id="#{admitted.call_id}"]))
  end

  test "?id=req_… focuses the request and correlates it", %{conn: conn} do
    ctx = athanor_context()
    decision = decision(ctx, tool: "execution", action: "run")
    :ok = Grimoire.open_decision(ctx, decision, %{input: %{}})

    {view, _html} = mount_athanor(conn, "/activities?id=#{ctx.request_id}")
    html = settled_render(view)

    assert html =~ "Decisions (1)"
    assert html =~ decision.call_id
  end

  # A context in the seated athanor under a request of its own.
  defp athanor_context do
    %{
      Sanctum.TestContext.local(:prism)
      | athanor_id: seated_athanor().id,
        request_id: Prima.UUID7.request_id()
    }
  end

  # One decision under `ctx`, or under none for the host's row, with
  # `fields` over an admitted default.
  defp decision(ctx, fields) do
    Prima.Decision.new(
      Keyword.merge(
        [
          call_id: Prima.UUID7.generate_id("call"),
          request_id: (ctx && ctx.request_id) || Prima.UUID7.request_id(),
          user_id: ctx && ctx.user_id,
          athanor_id: ctx && ctx.athanor_id,
          plane: :external,
          inserted_at: DateTime.utc_now(),
          admission: :admitted
        ],
        fields
      )
    )
  end
end
