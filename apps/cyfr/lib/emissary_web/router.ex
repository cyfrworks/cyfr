defmodule EmissaryWeb.Router do
  use EmissaryWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug EmissaryWeb.Plugs.RequirePersonalNamespace
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

  # OAuth callback for catalyst OAuth providers (not user auth)
  # Must be defined before the /:provider wildcard below
  scope "/auth/oauth", EmissaryWeb do
    pipe_through :api

    get "/callback", OAuthCallbackController, :callback
  end

  # OAuth/OIDC authentication routes (browser-based OAuth flow)
  scope "/auth", EmissaryWeb do
    pipe_through :browser

    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
  end

  # Personal-namespace claim gate (web flow).
  # Hit automatically by AuthController when post-login probe returns no
  # personal namespace; blocks dashboard access until the user claims a slug.
  scope "/claim-namespace", EmissaryWeb do
    pipe_through :browser

    get "/", ClaimNamespaceController, :show
    post "/submit", ClaimNamespaceController, :submit
  end

  # MCP endpoint - Model Context Protocol
  # Single endpoint path for POST (requests) and GET (SSE) per MCP 2025-11-25 spec
  scope "/mcp", EmissaryWeb do
    pipe_through :mcp

    post "/", MCPController, :handle
    get "/", SSEController, :stream
    delete "/", MCPController, :terminate_session
  end

  # Tincture serving — auth via query params (token, MCP session, API key)
  # No session cookie auth (EmissaryWeb and PrismWeb have separate session stores).
  pipeline :tincture do
    plug :accepts, ["html", "json"]
  end

  pipeline :tincture_invoke do
    plug :accepts, ["json"]
    plug EmissaryWeb.Plugs.CORS
  end

  scope "/t", EmissaryWeb do
    pipe_through :tincture_invoke
    post "/:publisher/:tincture_name/invoke", TinctureController, :invoke
    # OPTIONS preflight — CORS plug intercepts and sends 204 before reaching controller.
    # Required because sandboxed iframes (opaque origin) + POST with JSON content-type
    # triggers CORS preflight from the browser.
    match :options, "/:publisher/:tincture_name/invoke", TinctureController, :invoke
  end

  scope "/t", EmissaryWeb do
    pipe_through :tincture
    get "/:publisher/:tincture_name", TinctureController, :index
  end

  scope "/t", EmissaryWeb do
    get "/:publisher/:tincture_name/*path", TinctureController, :asset
  end

  # Health check endpoint
  scope "/api", EmissaryWeb do
    pipe_through :api

    get "/health", HealthController, :check
    get "/health/ready", HealthController, :ready
    get "/executions/:id/events", ExecutionEventsController, :stream
  end
end
