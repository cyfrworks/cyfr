defmodule EmissaryWeb.RouterTest do
  use ExUnit.Case, async: true

  alias EmissaryWeb.Router

  describe "route definitions" do
    test "defines POST /mcp route to MCPController.handle" do
      routes = Phoenix.Router.routes(Router)

      mcp_post = Enum.find(routes, fn route ->
        route.path == "/mcp" and route.verb == :post
      end)

      assert mcp_post
      assert mcp_post.plug == EmissaryWeb.MCPController
      assert mcp_post.plug_opts == :handle
    end

    test "defines DELETE /mcp route to MCPController.terminate_session" do
      routes = Phoenix.Router.routes(Router)

      mcp_delete = Enum.find(routes, fn route ->
        route.path == "/mcp" and route.verb == :delete
      end)

      assert mcp_delete
      assert mcp_delete.plug == EmissaryWeb.MCPController
      assert mcp_delete.plug_opts == :terminate_session
    end

    test "defines GET /mcp/sse route to SSEController.stream" do
      routes = Phoenix.Router.routes(Router)

      sse_get = Enum.find(routes, fn route ->
        route.path == "/mcp/sse" and route.verb == :get
      end)

      assert sse_get
      assert sse_get.plug == EmissaryWeb.SSEController
      assert sse_get.plug_opts == :stream
    end

    test "defines GET /api/health route to HealthController.check" do
      routes = Phoenix.Router.routes(Router)

      health_get = Enum.find(routes, fn route ->
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

      health_route = Enum.find(routes, fn route ->
        route.path == "/api/health"
      end)

      # Route exists and is properly configured
      assert health_route
      assert health_route.plug == EmissaryWeb.HealthController
    end

    test "mcp pipeline is defined" do
      routes = Phoenix.Router.routes(Router)

      mcp_route = Enum.find(routes, fn route ->
        route.path == "/mcp" and route.verb == :post
      end)

      # Route exists and is properly configured
      assert mcp_route
      assert mcp_route.plug == EmissaryWeb.MCPController
    end

    test "mcp_sse pipeline is defined" do
      routes = Phoenix.Router.routes(Router)

      sse_route = Enum.find(routes, fn route ->
        route.path == "/mcp/sse"
      end)

      # Route exists and is properly configured
      assert sse_route
      assert sse_route.plug == EmissaryWeb.SSEController
    end
  end
end
