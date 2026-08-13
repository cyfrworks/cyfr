# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.ExecutionEventsControllerTest do
  use EmissaryWeb.ConnCase, async: false

  # This route used to live in the unauthenticated :api pipeline, letting any
  # client probe valid execution ids. It was moved under a pipeline that
  # resolves the caller's context, with an owner-or-admin check and a uniform
  # 404 (rather than a 403/404 split) so it cannot leak which ids exist.
  #
  # It rode the :mcp pipeline for a while to get that context, which handed an
  # SSE endpoint the whole protocol along with it. It now has its own
  # :authenticated_api pipeline and shares only `Plugs.Authenticate`.
  #
  # The shared test conn auto-authenticates via Emissary.TestAuthProvider
  # ("test_user"), so this test exercises the cross-tenant case: an
  # unknown execution id returns 404 rather than streaming events.
  # Cross-user-but-same-org and admin-overrides-ownership cases require
  # a real Opus.ExecutionEventBuffer fixture and are left to integration
  # tests.
  describe "GET /api/executions/:id/events" do
    # The controller returns 503 when Opus.ExecutionEventBuffer isn't loaded
    # as an umbrella sibling. cyfr's per-app test runs (`mix cmd --app cyfr`)
    # don't load Opus, so this assertion is only meaningful in umbrella-root
    # test runs where `:requires_opus` is included.
    @describetag :requires_opus

    # Sandbox is set up by ConnCase.

    test "returns 404 for unknown execution id (no info disclosure)", %{conn: conn} do
      conn = get(conn, "/api/executions/exec_does_not_exist/events")

      assert conn.status == 404
      assert json_response(conn, 404)["error"] =~ "not found"
    end

    # Note: TestAuthProvider grants the test conn `[:*]` (wildcard), so a
    # cross-user 404 test would always succeed via the admin override.
    # The 403→404 collapse is verified by code review of the `with` chain
    # in execution_events_controller.ex (`{:error, :forbidden}` branch
    # returns 404, mirroring the `{:exec, nil}` branch). End-to-end coverage
    # against a non-admin user belongs in an integration test once a
    # session-with-narrow-permissions fixture exists.
  end

  # This endpoint has never spoken JSON-RPC. While it rode the MCP pipeline its
  # rejections were rendered as JSON-RPC anyway — an envelope with a `jsonrpc`
  # field and a null `id`, for a caller that never sent a JSON-RPC request.
  describe "it does not answer in a protocol it does not speak" do
    @describetag :requires_opus

    test "a bad credential is a plain HTTP error, not a JSON-RPC envelope", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer cyfr_pk_invalid123456789012345678")
        |> get("/api/executions/exec_whatever/events")

      assert conn.status == 401
      body = json_response(conn, 401)

      refute Map.has_key?(body, "jsonrpc")
      refute Map.has_key?(body, "error") and is_map(body["error"])
      assert body["code"] == "auth_invalid"
      # RFC 9110 §15.5.2 still applies wherever the 401 is rendered.
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end

    test "a 404 is a plain HTTP error too", %{conn: conn} do
      body =
        conn
        |> get("/api/executions/exec_does_not_exist/events")
        |> json_response(404)

      refute Map.has_key?(body, "jsonrpc")
      assert body["code"] == "not_found"
    end
  end
end
