defmodule EmissaryWeb.Router do
  use EmissaryWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :mcp do
    plug :accepts, ["json"]
    plug EmissaryWeb.Plugs.MCPSession
  end

  pipeline :mcp_sse do
    plug :accepts, ["event-stream", "json"]
    plug EmissaryWeb.Plugs.MCPSession
  end

  # Auth API routes (logout, whoami) - must be defined before wildcard /:provider
  scope "/auth", EmissaryWeb do
    pipe_through :api

    delete "/logout", AuthController, :logout
    post "/logout", AuthController, :logout
    get "/whoami", AuthController, :whoami
  end

  # OAuth/OIDC authentication routes (browser-based OAuth flow)
  scope "/auth", EmissaryWeb do
    pipe_through :browser

    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
  end

  # MCP endpoint - Model Context Protocol
  scope "/mcp", EmissaryWeb do
    pipe_through :mcp

    post "/", MCPController, :handle
    delete "/", MCPController, :terminate_session
  end

  # MCP SSE endpoint for server-sent events
  scope "/mcp", EmissaryWeb do
    pipe_through :mcp_sse

    get "/sse", SSEController, :stream
  end

  # Health check endpoint
  scope "/api", EmissaryWeb do
    pipe_through :api

    get "/health", HealthController, :check
  end
end

