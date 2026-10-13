# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.ExecutionEventsControllerTest do
  use CyfrWeb.ConnCase, async: false

  @moduletag auth: :person

  # Execution-event access requires authentication, a tenant-scoped read and
  # `storage_read` on the execution. Unknown and inaccessible ids return the
  # same 404.
  describe "GET /api/executions/:id/events" do
    # The controller returns 503 when no worker service answers; the test
    # boot's runtime does (`Cyfr.Test.RuntimeService`).

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

    @tag auth: :none
    test "no credential is a 401", %{conn: conn} do
      conn = get(conn, "/api/executions/#{admit!(Sanctum.TestContext.local()).id}/events")

      assert json_response(conn, 401)["code"] == "unauthenticated"
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end

    test "an execution in another athanor is a 404, as an unknown id is", %{conn: conn} do
      {_ctx_a, ctx_b} = Sanctum.TestContext.two_contexts()
      exec = admit!(ctx_b)
      terminal!(exec)

      conn = get(conn, "/api/executions/#{exec.id}/events")

      assert json_response(conn, 404)["code"] == "not_found"
    end

    # Members of an athanor are interchangeable, so the read is gated by the
    # credential's `storage_read`, not by who started the execution. An
    # application key defaults to `execute`, `component_read` and
    # `storage_read`; this one is narrowed to `execute`. The terminal row
    # makes a controller that skipped the check end its stream at once
    # rather than hang the test.
    test "a key without storage_read in the execution's own athanor is a 404", %{conn: conn} do
      ctx = Sanctum.TestContext.local()
      exec = admit!(ctx)
      terminal!(exec)

      {ctx, user} = Sanctum.TestContext.person!(ctx, %{email: "testns@example.com"})
      {:ok, _} = Sanctum.Tenancy.Users.set_namespace(user, ctx.namespace)

      {:ok, key} =
        Sanctum.TestContext.create_key(ctx, %{
          name: "events-execute-only",
          type: :application,
          scope: ["execute"]
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> key.api_key)
        |> get("/api/executions/#{exec.id}/events")

      assert json_response(conn, 404)["code"] == "not_found"
    end
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

  defp admit!(%Sanctum.Context{} = ctx) do
    {:ok, %{execution: execution}} =
      Arca.Execution.admit(
        %{
          id: Prima.UUID7.execution_id(),
          reference: "reagent:local.sse:0.1.0",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "reagent",
          origin: :programmatic
        },
        Cyfr.Test.AttemptFixtures.standing(ctx.athanor_id)
      )

    execution
  end

  defp terminal!(exec) do
    {:ok, _row} =
      Arca.ExecutionEvents.append(
        Prima.Actor.in_athanor(exec.athanor_id),
        exec.id,
        "execution.completed",
        data: %{"status" => "completed"}
      )

    :ok
  end
end
