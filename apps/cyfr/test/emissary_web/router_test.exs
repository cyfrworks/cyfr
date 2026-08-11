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

  describe "pipeline definitions" do
    # Pipeline configuration is verified at the router module level
    # These tests ensure the pipelines are defined and routes are accessible

    test "api pipeline is defined" do
      # Verify the :api pipeline exists by checking that the route is accessible
      routes = Phoenix.Router.routes(Router)

      health_route =
        Enum.find(routes, fn route ->
          route.path == "/api/health"
        end)

      # Route exists and is properly configured
      assert health_route
      assert health_route.plug == EmissaryWeb.HealthController
    end

    test "mcp pipeline is defined" do
      routes = Phoenix.Router.routes(Router)

      mcp_route =
        Enum.find(routes, fn route ->
          route.path == "/mcp" and route.verb == :post
        end)

      # Route exists and is properly configured
      assert mcp_route
      assert mcp_route.plug == EmissaryWeb.MCPController
    end

    test "mcp_sse pipeline is defined" do
      routes = Phoenix.Router.routes(Router)

      sse_route =
        Enum.find(routes, fn route ->
          route.path == "/mcp" and route.verb == :get
        end)

      # Route exists and is properly configured
      assert sse_route
      assert sse_route.plug == EmissaryWeb.MCPController
    end
  end
end
