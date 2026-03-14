defmodule EmissaryWeb.HealthControllerTest do
  use EmissaryWeb.ConnCase

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
end
