defmodule PrismWeb.Router do
  use PrismWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PrismWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # Public auth routes
  scope "/auth", PrismWeb do
    pipe_through :browser

    get "/session", AuthController, :session
    get "/logout", AuthController, :logout
  end

  # Public login page
  scope "/", PrismWeb do
    pipe_through :browser

    live "/login", AuthLive, :login
  end

  # Tincture routes — unified path for public and private tinctures.
  # Public tinctures are accessible by anyone; private require authentication.
  pipeline :tincture do
    plug :accepts, ["html", "json"]
    plug :fetch_session
    plug :put_secure_browser_headers
    plug PrismWeb.Plugs.OptionalAuth
  end

  # Query endpoint — rate limited, CORS'd (used by standalone/public tinctures)
  pipeline :tincture_query do
    plug :accepts, ["json"]
    plug :put_secure_browser_headers
    plug PrismWeb.Plugs.PublicRateLimit
    plug PrismWeb.Plugs.PublicCors
  end

  scope "/t", PrismWeb do
    pipe_through :tincture_query
    get "/:publisher/:tincture_name/q/:query_name", TinctureController, :query
  end

  scope "/t", PrismWeb do
    pipe_through :tincture
    get "/:publisher/:tincture_name", TinctureController, :index
  end

  # Tincture static assets — public: served directly.
  # Private: require signed token (_s/:token) embedded in <base href> by index.
  scope "/t", PrismWeb do
    get "/:publisher/:tincture_name/*path", TinctureController, :asset
  end

  # Authenticated routes
  scope "/", PrismWeb do
    pipe_through :browser

    live_session :authenticated,
      on_mount: [{PrismWeb.LiveAuth, :require_auth}] do
      live "/", AgentLive, :index
      live "/executions", ExecutionsLive, :index
      live "/logs", LogsLive, :index
      live "/logs/:id", LogDetailLive, :show
      live "/components", ComponentsLive, :index
      live "/components/:ref", ComponentDetailLive, :show
      live "/builds", BuildsLive, :index
      live "/secrets", SecretsLive, :index
      live "/keys", ApiKeysLive, :index
      live "/schedules", SchedulesLive, :index
      live "/settings", SettingsLive, :index
      live "/mcp-servers", McpServersLive, :index
      live "/tinctures", ShellLive, :index
    end
  end
end
