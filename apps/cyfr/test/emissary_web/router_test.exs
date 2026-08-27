# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.RouterTest do
  use ExUnit.Case, async: true

  alias EmissaryWeb.Router

  describe "route definitions" do
    test "defines POST /mcp route to MCPController.handle" do
      routes = Phoenix.Router.routes(Router)

      mcp_post =
        Enum.find(routes, fn route ->
          route.path == "/mcp" and route.verb == :post
        end)

      assert mcp_post
      assert mcp_post.plug == EmissaryWeb.MCPController
      assert mcp_post.plug_opts == :handle
    end

    # GET opened the standalone notification stream and DELETE terminated a
    # session; both were removed from the transport. They stay routed so the
    # server can answer 405 — a route-miss 404 reads as "wrong URL" and sends an
    # older client looking for an endpoint that does not exist elsewhere.
    test "answers GET and DELETE /mcp with 405 rather than dropping the routes" do
      routes = Phoenix.Router.routes(Router)

      for verb <- [:get, :delete] do
        route = Enum.find(routes, &(&1.path == "/mcp" and &1.verb == verb))

        assert route, "GET/DELETE /mcp must stay routed so the server can say 405"
        assert route.plug == EmissaryWeb.MCPController
        assert route.plug_opts == :method_not_allowed
      end
    end

    test "defines GET /api/health route to HealthController.check" do
      routes = Phoenix.Router.routes(Router)

      health_get =
        Enum.find(routes, fn route ->
          route.path == "/api/health" and route.verb == :get
        end)

      assert health_get
      assert health_get.plug == EmissaryWeb.HealthController
      assert health_get.plug_opts == :check
    end
  end

  describe "pipelines on the wire-facing routes" do
    test "POST /mcp rides :mcp and /api/health rides :api" do
      assert %{pipe_through: pipelines} = Phoenix.Router.route_info(Router, "POST", "/mcp", nil)
      assert :mcp in pipelines

      assert %{pipe_through: pipelines} =
               Phoenix.Router.route_info(Router, "GET", "/api/health", nil)

      assert :api in pipelines
    end

    test "the 405 methods on /mcp ride the same pipeline as POST" do
      # GET /mcp is the retired notification stream, kept routed only to
      # answer 405 — it must see the same plugs as the live method, not a
      # phantom SSE pipeline.
      %{pipe_through: post_pipelines} = Phoenix.Router.route_info(Router, "POST", "/mcp", nil)

      for verb <- ["GET", "DELETE"] do
        assert %{pipe_through: ^post_pipelines} =
                 Phoenix.Router.route_info(Router, verb, "/mcp", nil)
      end
    end
  end
end
