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

  # Authenticated routes
  scope "/", PrismWeb do
    pipe_through :browser

    live_session :authenticated,
      on_mount: [{PrismWeb.LiveAuth, :require_auth}] do
      live "/", DashboardLive, :index
      live "/executions", ExecutionsLive, :index
      live "/logs", LogsLive, :index
      live "/logs/:id", LogDetailLive, :show
      live "/components", ComponentsLive, :index
      live "/components/:ref", ComponentDetailLive, :show
      live "/builds", BuildsLive, :index
      live "/secrets", SecretsLive, :index
      live "/keys", ApiKeysLive, :index
      live "/settings", SettingsLive, :index
    end
  end
end
