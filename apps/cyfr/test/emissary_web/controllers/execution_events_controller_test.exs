# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.ExecutionEventsControllerTest do
  use EmissaryWeb.ConnCase, async: false

  # Execution-event access requires authentication and an ownership check.
  # Unknown and inaccessible ids return the same 404. This fixture uses the
  # shared test user and exercises an unknown execution id.
  describe "GET /api/executions/:id/events" do
    # The controller returns 503 when no worker service answers; the test
    # boot's Opus service does (`Cyfr.Test.OpusService`).

    # Sandbox is set up by ConnCase.

    test "returns 404 for unknown execution id (no info disclosure)", %{conn: conn} do
      conn = get(conn, "/api/executions/exec_does_not_exist/events")

      assert conn.status == 404
      assert json_response(conn, 404)["message"] == Prima.Refusal.message(:not_found)
    end

    test "a store that cannot answer is a 503, not a crash", %{conn: conn} do
      # `Arca.Execution.get_tenant/2` is wrapped in `with_db_rescue/2`, so an
      # adapter fault arrives as `{:error, :database_error}` — which bound to
      # `{:exec, {:error, :database_error}}` and matched none of the `with`'s
      # else clauses. The caller got a WithClauseError and a 500 stacktrace
      # where the neighbouring engine-unavailable branch answers 503.
      #
      # Dropping the table inside the sandbox transaction is deterministic and
      # rolls back with the test; `sessions` is untouched, so the request still
      # authenticates on its way in.
      drop_executions!()

      conn = get(conn, "/api/executions/exec_anything/events")

      assert conn.status == 503
      assert json_response(conn, 503)["code"] == "unavailable"
    end

    # Note: TestAuthProvider grants the test conn `[:*]` (wildcard), so a
    # cross-user 404 test would always succeed via the admin override.
    # The 403→404 collapse is verified by code review of the `with` chain
    # in execution_events_controller.ex (`{:error, :forbidden}` branch
    # returns 404, mirroring the `{:exec, nil}` branch). End-to-end coverage
    # against a non-admin user belongs in an integration test once a
    # session-with-narrow-permissions fixture exists.
  end

  # This HTTP endpoint must render plain API errors.
  describe "it does not answer in a protocol it does not speak" do
    test "a bad credential is a plain HTTP error, not a JSON-RPC envelope", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer cyfr_pk_invalid123456789012345678")
        |> get("/api/executions/exec_whatever/events")

      assert conn.status == 401
      body = json_response(conn, 401)

      refute Map.has_key?(body, "jsonrpc")
      refute Map.has_key?(body, "error") and is_map(body["error"])
      assert body["code"] == "unauthenticated"
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

  # An outage, simulated: the table is gone. Postgres holds the tables that
  # reference `executions` to it and drops them along; SQLite has no such
  # clause and no such need.
  #
  # config:compile-runtime-ok — must match what `Arca.Repo` compiled
  # against, as `Arca.TenantTables` does: the adapter is bound at compile
  # time, so a runtime branch on `__adapter__/0` is one the compiler
  # proves dead.
  @drop_executions (case Application.compile_env(:arca, :repo_adapter, Ecto.Adapters.SQLite3) do
                      Ecto.Adapters.Postgres -> "DROP TABLE executions CASCADE"
                      _sqlite -> "DROP TABLE executions"
                    end)

  defp drop_executions!, do: Arca.Repo.query!(@drop_executions)
end
