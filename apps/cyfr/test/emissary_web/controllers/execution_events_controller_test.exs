defmodule EmissaryWeb.ExecutionEventsControllerTest do
  use EmissaryWeb.ConnCase, async: false

  # The /api/executions/:id/events route used to live in the unauthenticated
  # :api pipeline, letting any client probe valid execution ids. Fix B1
  # moved it under the :mcp pipeline (so MCPSession populates the auth
  # context) and added an owner-or-admin check + uniform 404 (rather than
  # 403/404 split) in the controller to avoid leaking which ids exist.
  #
  # The shared test conn auto-authenticates via Emissary.TestAuthProvider
  # ("test_user"), so this test exercises the cross-tenant case: an
  # unknown execution id returns 404 rather than streaming events.
  # Cross-user-but-same-org and admin-overrides-ownership cases require
  # a real Opus.ExecutionEventBuffer fixture and are left to integration
  # tests.
  describe "GET /api/executions/:id/events" do
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
end
