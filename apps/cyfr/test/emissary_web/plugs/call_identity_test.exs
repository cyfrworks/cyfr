# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.CallIdentityTest do
  # Records decisions through the store, so it owns the sandbox for its run.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias EmissaryWeb.Plugs.CallIdentity

  setup do
    Cyfr.Test.Sandbox.setup!()
    :ok
  end

  defp decisions(request_id),
    do: Arca.Repo.all(from(d in Arca.Schemas.DecisionLog, where: d.request_id == ^request_id))

  defp mcp_rows(request_id),
    do: Arca.Repo.all(from(l in Arca.Schemas.McpLog, where: l.request_id == ^request_id))

  describe "call/2" do
    test "mints both ids, answers the request id and ignores the client's" do
      conn =
        conn(:post, "/mcp")
        |> put_req_header("x-request-id", "client-said-so")
        |> CallIdentity.call(CallIdentity.init([]))

      assert "req_" <> _ = conn.assigns.request_id
      assert "call_" <> _ = conn.assigns.call_id
      assert get_resp_header(conn, "x-request-id") == [conn.assigns.request_id]
      refute conn.assigns.request_id == "client-said-so"
      assert Logger.metadata()[:request_id] == conn.assigns.request_id
      assert conn.assigns.call_tool == nil
    end

    test "carries the pipeline's tool for the names a refusal is recorded under" do
      conn = CallIdentity.call(conn(:get, "/t/x"), CallIdentity.init(tool: "tincture"))
      assert conn.assigns.call_tool == "tincture"
    end

    test "refuses an option it does not know" do
      assert_raise ArgumentError, fn -> CallIdentity.init(tool: "x", plane: :external) end
    end
  end

  describe "stamp/2" do
    test "puts the minted ids on the context and leaves an unminted conn's context alone" do
      ctx = Sanctum.TestContext.local()
      minted = CallIdentity.call(conn(:post, "/mcp"), [])

      stamped = CallIdentity.stamp(minted, ctx)
      assert stamped.request_id == minted.assigns.request_id
      assert stamped.call_id == minted.assigns.call_id

      assert CallIdentity.stamp(conn(:post, "/mcp"), %{ctx | request_id: "req_own"}).request_id ==
               "req_own"
    end
  end

  describe "refused/2" do
    test "records one refused decision under the call id, with no actor when no context exists" do
      conn = CallIdentity.call(conn(:post, "/mcp"), [])
      refused = CallIdentity.refused(conn, :invalid_bearer)

      assert refused.assigns.decision_recorded

      assert [decision] = decisions(conn.assigns.request_id)
      assert decision.call_id == conn.assigns.call_id
      assert decision.admission == "refused"
      assert decision.refusal_class == "unauthenticated"
      assert decision.plane == "external"
      assert is_nil(decision.athanor_id)
      assert is_nil(decision.user_id)
      assert decision.reason == Grimoire.render(:invalid_bearer)
      # A null-tenant decision has no request-log row.
      assert mcp_rows(conn.assigns.request_id) == []
    end

    test "records the context's actor and the request's names when it has them" do
      ctx = Sanctum.TestContext.local()

      conn =
        conn(:post, "/mcp", %{
          "method" => "tools/call",
          "params" => %{"name" => "system", "arguments" => %{"action" => "status"}}
        })
        |> CallIdentity.call([])

      conn = assign(conn, :context, CallIdentity.stamp(conn, ctx))
      _ = CallIdentity.refused(conn, :header_mismatch)

      assert [decision] = decisions(conn.assigns.request_id)
      assert decision.athanor_id == ctx.athanor_id
      assert decision.user_id == ctx.user_id
      assert decision.tool == "system"
      assert decision.action == "status"
      assert decision.refusal_class == "invalid_argument"

      assert [row] = mcp_rows(conn.assigns.request_id)
      assert row.id == decision.call_id
      assert row.method == "tools/call"
      assert row.status == "error"
      assert row.refusal_class == "invalid_argument"
    end

    test "names the pipeline's tool and the route's action outside JSON-RPC" do
      conn =
        conn(:get, "/t/ath/pub/name")
        |> put_private(:phoenix_action, :index)
        |> CallIdentity.call(tool: "tincture")

      _ = CallIdentity.refused(conn, :not_found)

      assert [%{tool: "tincture", action: "index"}] = decisions(conn.assigns.request_id)
    end

    test "appends once: a second render, and a request the gate decided, add nothing" do
      conn = CallIdentity.call(conn(:post, "/mcp"), [])

      conn
      |> CallIdentity.refused(:invalid_bearer)
      |> CallIdentity.refused(:origin_rejected)

      assert [_one] = decisions(conn.assigns.request_id)

      decided = CallIdentity.call(conn(:post, "/mcp"), []) |> CallIdentity.decided()
      _ = CallIdentity.refused(decided, :invalid_bearer)
      assert decisions(decided.assigns.request_id) == []
    end

    test "a request outside an entry pipeline carries no call id and records nothing" do
      conn = conn(:get, "/api/health")
      assert CallIdentity.refused(conn, :rate_limited) == conn
    end
  end
end
