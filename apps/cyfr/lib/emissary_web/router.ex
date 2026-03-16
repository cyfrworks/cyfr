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
    plug :accepts, ["json", "event-stream"]
    plug EmissaryWeb.Plugs.CORS
    plug EmissaryWeb.Plugs.MCPOrigin
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
  # Single endpoint path for POST (requests) and GET (SSE) per MCP 2025-11-25 spec
  scope "/mcp", EmissaryWeb do
    pipe_through :mcp

    post "/", MCPController, :handle
    get "/", SSEController, :stream
    delete "/", MCPController, :terminate_session
  end

  # Health check endpoint
  scope "/api", EmissaryWeb do
    pipe_through :api

    get "/health", HealthController, :check
    get "/health/ready", HealthController, :ready
    get "/executions/:id/events", ExecutionEventsController, :stream
  end
end
