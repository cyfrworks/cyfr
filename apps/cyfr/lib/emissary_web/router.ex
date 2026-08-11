# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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

  # Client-driven auth-API endpoints (logout, whoami) self-gate in the
  # controller (401/400 without a token) but were otherwise unmetered — a
  # session-token brute-force / Session.get amplification surface. The
  # IdP-driven callbacks stay unthrottled (shared-NAT corporate IPs).
  pipeline :auth_api_throttle do
    plug EmissaryWeb.Plugs.AuthRateLimit,
      bucket: :auth_api,
      max_requests: 30,
      window_ms: 60_000
  end

  pipeline :mcp do
    plug :accepts, ["json", "event-stream"]
    # POST is the only verb this protocol revision defines for the MCP endpoint.
    # The GET below is the retired standalone SSE stream and is on its way out;
    # `/api/executions/:id/events` also pipes through here and is a GET, so the
    # verb list stays until both are settled.
    plug EmissaryWeb.Plugs.CORS, methods: ~w(GET POST)
    plug EmissaryWeb.Plugs.MCPOrigin
    # Before MCPSession so unauthenticated floods never touch session/DB
    # state. Also covers /api/executions/:id/events (pipes through :mcp).
    plug EmissaryWeb.Plugs.MCPRateLimit
    plug EmissaryWeb.Plugs.MCPSession
  end

  # Auth API routes (logout, whoami) - must be defined before wildcard /:provider
  scope "/auth", EmissaryWeb do
    pipe_through [:api, :auth_api_throttle]

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

  # OAuth kickoff gets a conservative per-IP throttle; callbacks do not
  # (they come from IdPs on behalf of real users, and shared-NAT corporate
  # IPs would be locked out if we throttled callbacks).
  pipeline :oauth_start_throttle do
    plug EmissaryWeb.Plugs.AuthRateLimit,
      bucket: :oauth_start,
      max_requests: 30,
      window_ms: 60_000
  end

  # Submit path on the claim gate: defends against username enumeration
  # (cyfr.run's 409 distinguishes SLUG_TAKEN / ALREADY_CLAIMED) and
  # claim-spam DOS.
  pipeline :claim_submit_throttle do
    plug EmissaryWeb.Plugs.AuthRateLimit,
      bucket: :claim_submit,
      max_requests: 10,
      window_ms: 60_000
  end

  # OAuth/OIDC authentication routes (browser-based OAuth flow)
  scope "/auth", EmissaryWeb do
    pipe_through :browser

    # Throttle only the kickoff endpoint; the callback path is reached by
    # the IdP, not the client, and must not be throttled.
    scope "/" do
      pipe_through :oauth_start_throttle

      get "/:provider", AuthController, :request
    end

    get "/:provider/callback", AuthController, :callback

    # Re-probe landing after a successful /legal/accept submit. Reads the
    # _cyfr_pending_probe cookie to recover the IdP access_token, re-runs
    # probe_and_store, and routes to /claim-namespace or the dashboard.
    get "/post-legal-accept", AuthController, :post_legal_accept
  end

  # Personal-namespace claim gate (web flow).
  # Hit automatically by AuthController when post-login probe returns no
  # personal namespace; blocks dashboard access until the user claims a slug.
  scope "/claim-namespace", EmissaryWeb do
    pipe_through :browser

    get "/", ClaimNamespaceController, :show

    # Submit is the only write endpoint; throttle it, not the form render.
    scope "/" do
      pipe_through :claim_submit_throttle

      post "/submit", ClaimNamespaceController, :submit
    end
  end

  # Policy-acceptance gate (R1.11 / cyfr.run §3.12). Hit when cyfr.run
  # returns 412 POLICY_ACCEPTANCE_REQUIRED on a claim attempt, or
  # proactively from the post-login flow. Renders the bundled policies
  # for read + clickwrap, then POSTs to cyfr.run /v1/legal/accept.
  scope "/legal/accept", EmissaryWeb do
    pipe_through :browser

    get "/", LegalAcceptController, :show
    post "/submit", LegalAcceptController, :submit
  end

  # MCP endpoint. POST is the only verb this revision defines: a request's own
  # response stream carries its progress, so there is no standalone stream to
  # open, and there is no session to terminate.
  scope "/mcp", EmissaryWeb do
    pipe_through :mcp

    post "/", MCPController, :handle
    get "/", MCPController, :method_not_allowed
    delete "/", MCPController, :method_not_allowed
  end

  # Tincture serving — auth via query params (token, MCP session, API key)
  # No session cookie auth (EmissaryWeb and PrismWeb have separate session stores).
  pipeline :tincture do
    plug :accepts, ["html", "json"]
    plug EmissaryWeb.Plugs.ScrubTinctureCredentials
    plug EmissaryWeb.Plugs.TinctureRateLimit, bucket: :page, max_requests: 60, window_ms: 60_000
  end

  pipeline :tincture_invoke do
    plug :accepts, ["json"]
    # POST for invoke, GET for the cross-origin `/t/access-token` mint.
    plug EmissaryWeb.Plugs.CORS, methods: ~w(GET POST)
    # Before the rate limiter so a 429 is scrubbed too — it is logged like any
    # other response, and it never reaches the action that reads the credential.
    plug EmissaryWeb.Plugs.ScrubTinctureCredentials
    # After CORS on purpose: OPTIONS preflights are halted with 204 above and
    # must never be counted or answered 429 without CORS headers.
    plug EmissaryWeb.Plugs.TinctureRateLimit,
      bucket: :invoke,
      max_requests: 120,
      window_ms: 60_000
  end

  pipeline :tincture_asset do
    # No :accepts — assets serve arbitrary content types.
    plug EmissaryWeb.Plugs.ScrubTinctureCredentials
    plug EmissaryWeb.Plugs.TinctureRateLimit, bucket: :asset, max_requests: 300, window_ms: 60_000
  end

  scope "/t", EmissaryWeb do
    pipe_through :tincture_invoke
    # Cross-origin token mint (Porta): session/Bearer header → short-lived ?_t=.
    get "/access-token", TinctureController, :access_token
    match :options, "/access-token", TinctureController, :access_token
    post "/:org/:project/:publisher/:tincture_name/invoke", TinctureController, :invoke
    # OPTIONS preflight — CORS plug intercepts and sends 204 before reaching controller.
    # Required because sandboxed iframes (opaque origin) + POST with JSON content-type
    # triggers CORS preflight from the browser.
    match :options, "/:org/:project/:publisher/:tincture_name/invoke", TinctureController, :invoke
  end

  scope "/t", EmissaryWeb do
    pipe_through :tincture
    get "/:org/:project/:publisher/:tincture_name", TinctureController, :index
  end

  scope "/t", EmissaryWeb do
    pipe_through :tincture_asset
    get "/:org/:project/:publisher/:tincture_name/*path", TinctureController, :asset
  end

  # Anonymous and internet-reachable behind the tls proxy, and /ready does
  # real DB/storage work per uncached hit — metered per IP so it cannot be
  # used to drive storage round-trips (billable PUTs on S3) at will.
  pipeline :health_throttle do
    plug EmissaryWeb.Plugs.AuthRateLimit,
      bucket: :health,
      max_requests: 60,
      window_ms: 60_000
  end

  # Health check endpoint
  scope "/api", EmissaryWeb do
    pipe_through [:api, :health_throttle]

    get "/health", HealthController, :check
    get "/health/ready", HealthController, :ready
  end

  # Execution event SSE stream — runs through the MCP pipeline so MCPSession
  # establishes the caller's Sanctum.Context (session cookie or API key).
  # Ownership is then verified in the controller before any event flows.
  scope "/api", EmissaryWeb do
    pipe_through :mcp

    get "/executions/:id/events", ExecutionEventsController, :stream
  end

  # Inbound webhook receiver. Rate-limited (per-slug + per-IP scan-evasion bucket)
  # before signature verification so unverified spam is dropped early. Raw body
  # is captured by `EmissaryWeb.Plugs.RawBodyReader` (registered as the
  # `Plug.Parsers` body_reader on the endpoint) so HMAC verification sees the
  # exact bytes the sender signed.
  pipeline :webhook do
    plug :accepts, ["json"]
    plug EmissaryWeb.Plugs.WebhookRateLimit
    plug EmissaryWeb.Plugs.VerifyWebhookSignature
    plug EmissaryWeb.Plugs.WebhookIdempotency
  end

  scope "/hooks", EmissaryWeb do
    pipe_through :webhook
    post "/:slug", WebhookController, :invoke
  end
end
