# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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

  # Tincture routes moved to EmissaryWeb — all clients use port 4000.
  # ShellLive iframes point to EmissaryWeb.Endpoint.url() <> "/t/...".

  # Authenticated routes
  scope "/", PrismWeb do
    pipe_through :browser

    live_session :authenticated,
      on_mount: [
        {PrismWeb.LiveAuth, :require_auth},
        {PrismWeb.LiveClaimGate, :require_claim},
        {PrismWeb.ActiveContext, :assign}
      ] do
      live "/", RootRedirectLive, :index
      # /activities: unified activities feed (mcp_log + execution fan-out).
      live "/activities", ActivitiesLive, :index
      # /enforcements: live policy-decision feed (Arca.PolicyLog rows from
      # Opus.Executor + HTTP egress + tincture rate limiter). Click-through
      # to /activities?request_id=… for the request-anchored causal chain.
      live "/enforcements", EnforcementsLive, :index
      # /executions: dedicated Opus execution monitor (parent_execution_id
      # tree, component_digest, host_policy, WASI trace). Distinct from
      # /activities which is request-anchored.
      live "/executions", ExecutionsLive, :index
      # /logs and /logs/:id are folded into /activities (request-anchored
      # view). Thin redirects preserve old bookmarks.
      live "/logs", LogsRedirectLive, :index
      live "/logs/:id", LogsRedirectLive, :show
      live "/components", ComponentsLive, :index
      live "/components/:ref", ComponentDetailLive, :show
      live "/registry", RegistryLive, :index
      live "/reports", MyReportsLive, :index
      live "/builds", BuildsLive, :index
      live "/secrets", SecretsLive, :index
      live "/api-keys", ApiKeysLive, :index
      live "/webhooks", WebhooksLive, :index
      live "/schedules", SchedulesLive, :index
      live "/settings", SettingsLive, :index
      live "/mcp-servers", McpServersLive, :index
      live "/tinctures", ShellLive, :index
      live "/legal", LegalLive, :index
    end
  end
end
