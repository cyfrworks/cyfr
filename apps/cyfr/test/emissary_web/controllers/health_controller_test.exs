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
    test "returns ready in core mode", %{conn: conn} do
      Application.put_env(:cyfr, :edition, :core)
      conn = get(conn, "/api/health/ready")

      response = json_response(conn, 200)
      assert response["status"] == "ready"
      assert response["checks"]["database"] == "ok"
      assert response["checks"]["cache"] == "ok"
      # Core mode should NOT include Arx-specific checks
      refute Map.has_key?(response["checks"], "pubsub")
      refute Map.has_key?(response["checks"], "tool_registry")
    end

    test "includes Arx checks in arx mode", %{conn: conn} do
      original = Application.get_env(:cyfr, :edition)
      Application.put_env(:cyfr, :edition, :arx)

      on_exit(fn ->
        if original,
          do: Application.put_env(:cyfr, :edition, original),
          else: Application.delete_env(:cyfr, :edition)
      end)

      conn = get(conn, "/api/health/ready")

      response = json_response(conn, 200)
      assert response["checks"]["database"] == "ok"
      assert response["checks"]["cache"] == "ok"
      assert response["checks"]["pubsub"] == "ok"
      assert response["checks"]["tool_registry"] == "ok"
      assert response["checks"]["resource_registry"] == "ok"
      assert response["checks"]["sse_buffer"] == "ok"
    end
  end
end
