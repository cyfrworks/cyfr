# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.HealthControllerTest do
  use EmissaryWeb.ConnCase, async: false

  describe "GET /api/health" do
    test "returns ok status", %{conn: conn} do
      conn = get(conn, "/api/health")

      assert json_response(conn, 200)
      response = json_response(conn, 200)
      assert response["status"] == "ok"
    end

    test "includes service name", %{conn: conn} do
      conn = get(conn, "/api/health")

      response = json_response(conn, 200)
      assert response["service"] == "emissary"
    end

    test "returns JSON content type", %{conn: conn} do
      conn = get(conn, "/api/health")

      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    end
  end

  describe "GET /api/health/ready" do
    test "returns ready with all subsystem checks", %{conn: conn} do
      conn = get(conn, "/api/health/ready")

      response = json_response(conn, 200)
      assert response["status"] == "ready"
      assert response["checks"]["database"] == "ok"
      assert response["checks"]["cache"] == "ok"
      assert response["checks"]["pubsub"] == "ok"
      assert response["checks"]["storage"] == "ok"
      assert response["checks"]["tool_registry"] == "ok"
      assert response["checks"]["resource_registry"] == "ok"
      assert response["checks"]["progress"] == "ok"
    end

    test "the write probe's root is a real global root" do
      # The controller spells "system" literally (global roots keep the
      # literal at their single consumer); this pins it to the roster so a
      # renamed row cannot leave the probe writing into a refused root.
      assert "system" in Arca.Storage.global_prefixes()
    end

    test "a stranded probe key is overwritten, not accumulated", %{conn: conn} do
      # The probe writes ONE fixed key and deletes it — a past failed
      # delete strands at most one object, reclaimed by the next probe's
      # overwrite (the retention sweep is the belt for legacy strays).
      # Bust the result cache so this request runs a real probe.
      :persistent_term.erase({EmissaryWeb.HealthController, :ready_cache})

      ctx = Sanctum.internal_context(user_id: "_test", permissions: [:storage_write])
      :ok = Arca.put(ctx, ["system", "health", ".write_probe"], "stranded")

      conn = get(conn, "/api/health/ready")
      assert json_response(conn, 200)["checks"]["storage"] == "ok"

      assert {:ok, []} = Arca.list_typed(ctx, ["system", "health"])
    end
  end
end
