# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Router do
  use EmissaryWeb, :router

  # Pipelines define authentication and transport rules for the scopes below.

  # The browser pipeline serves the Prism LiveViews and the auth pages.
  # LiveView mounts are gated in `PrismWeb.LiveAuth`, because the LiveView
  # socket is handled by the endpoint before the router and never passes
  # through here.
  pipeline :browser do
    # First: a headless node serves none of this (CYFR_HEADLESS).
    plug EmissaryWeb.Plugs.Headless
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PrismWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug EmissaryWeb.Plugs.BrowserCSP
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug EmissaryWeb.Plugs.ApiSecurityHeaders
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

  # MCP accepts POST only. GET and DELETE return 405; preflight must
  # advertise only the supported method.
  pipeline :mcp do
    plug :accepts, ["json", "event-stream"]
    plug EmissaryWeb.Plugs.ApiSecurityHeaders
    plug EmissaryWeb.Plugs.CORS, methods: ~w(POST)
    plug EmissaryWeb.Plugs.MCPOrigin
    # Before Authenticate so unauthenticated floods never touch DB state.
    plug EmissaryWeb.Plugs.MCPRateLimit
    plug EmissaryWeb.Plugs.Authenticate
    plug EmissaryWeb.Plugs.MCPRequestMetadata
  end

  # Authenticated HTTP routes use the shared context resolver with API
  # error rendering and a separate rate-limit bucket.
  pipeline :authenticated_api do
    plug :accepts, ["json", "event-stream"]
    plug EmissaryWeb.Plugs.ApiSecurityHeaders
    plug EmissaryWeb.Plugs.CORS, methods: ~w(GET), headers: ~w(last-event-id)
    plug EmissaryWeb.Plugs.MCPOrigin, errors: EmissaryWeb.ApiError
    plug EmissaryWeb.Plugs.MCPRateLimit, bucket: :api, errors: EmissaryWeb.ApiError
    plug EmissaryWeb.Plugs.Authenticate, errors: EmissaryWeb.ApiError
  end

  # OAuth kickoff gets a conservative per-IP throttle; callbacks get the
  # generous :oauth_callback_throttle above.
  pipeline :oauth_start_throttle do
    plug EmissaryWeb.Plugs.AuthRateLimit,
      bucket: :oauth_start,
      max_requests: 30,
      window_ms: 60_000
  end

  # Submit path on the claim page: defends against username enumeration
  # (cyfr.run's 409 distinguishes SLUG_TAKEN / ALREADY_CLAIMED) and
  # claim-spam DOS.
  pipeline :claim_submit_throttle do
    plug EmissaryWeb.Plugs.AuthRateLimit,
      bucket: :claim_submit,
      max_requests: 10,
      window_ms: 60_000
  end

  # The legal pages proxy cyfr.run (a cold GET fetches every policy body;
  # the submit relays the acceptance) — a modest per-IP budget keeps one
  # client from turning this server into an amplifier against cyfr.run.
  pipeline :legal_accept_throttle do
    plug EmissaryWeb.Plugs.AuthRateLimit,
      bucket: :legal_accept,
      max_requests: 12,
      window_ms: 60_000
  end

  # Callbacks arrive from IdPs on real users' behalf, often through
  # shared-NAT corporate IPs, so their budget is generous — high enough
  # that a floor of real users never trips it, low enough that one IP
  # cannot spin the token-exchange machinery unboundedly.
  pipeline :oauth_callback_throttle do
    plug EmissaryWeb.Plugs.AuthRateLimit,
      bucket: :oauth_callback,
      max_requests: 60,
      window_ms: 60_000
  end

  # The OAuth grant callback serves a BROWSER page (PrismWeb.MinimalPage,
  # no session) — `:api`'s `accepts ["json"]` 406'd any client that sent a
  # strict `Accept: text/html`, which is what a browser redirect carries.
  pipeline :oauth_callback do
    plug :accepts, ["html", "json"]
    plug EmissaryWeb.Plugs.ApiSecurityHeaders
  end

  # Meter ticket adoption before authentication. Looking up a ticket
  # consumes it, so attempts need their own request budget.
  pipeline :device_complete_throttle do
    plug EmissaryWeb.Plugs.AuthRateLimit,
      bucket: :device_complete,
      max_requests: 30,
      window_ms: 60_000
  end

  # Tincture serving — auth via signed `?_t=` token or Authorization bearer.
  # No session cookie auth: a tincture page is embeddable cross-origin (see
  # the invoke pipeline below), and an ambient cookie credential on a
  # cross-origin surface is exactly the CSRF/rebinding food the design
  # refuses — there is one session store, and this surface ignores it.
  # Tinctures set their own CSP (the controller); the closed set here only
  # supplies what it does not touch (nosniff, referrer policy, HSTS) — the
  # controller replaces the CSP and framing headers on what it serves.
  pipeline :tincture do
    plug :accepts, ["html", "json"]
    plug EmissaryWeb.Plugs.ApiSecurityHeaders
    plug EmissaryWeb.Plugs.ScrubTinctureCredentials

    plug EmissaryWeb.Plugs.TinctureRateLimit,
      bucket: :page,
      max_requests: 60,
      window_ms: EmissaryWeb.Plugs.TinctureRateLimit.default_window_ms()
  end

  pipeline :tincture_invoke do
    plug :accepts, ["json"]
    plug EmissaryWeb.Plugs.ApiSecurityHeaders
    # Deliberately NO MCPOrigin here, unlike /mcp and /api: a public
    # tincture is embeddable from any origin, so this surface is
    # cross-origin BY DESIGN (the CORS plug below is its contract). The
    # DNS-rebinding class MCPOrigin defends against needs an ambient
    # credential to steal; invoke authenticates per request (Bearer or the
    # short-lived ?_t= mint) and the public route is credential-less.
    # POST for invoke, GET for the cross-origin `/t/access-token` mint.
    plug EmissaryWeb.Plugs.CORS, methods: ~w(GET POST)
    # Before the rate limiter so a 429 is scrubbed too — it is logged like any
    # other response, and it never reaches the action that reads the credential.
    plug EmissaryWeb.Plugs.ScrubTinctureCredentials
    # After CORS on purpose: OPTIONS preflights are halted with 204 above and
    # must never be counted or answered 429 without CORS headers.
    plug EmissaryWeb.Plugs.TinctureRateLimit,
      bucket: :invoke,
      max_requests: EmissaryWeb.Plugs.TinctureRateLimit.default_invoke_max(),
      window_ms: EmissaryWeb.Plugs.TinctureRateLimit.default_window_ms()
  end

  pipeline :tincture_asset do
    # No :accepts — assets serve arbitrary content types.
    plug EmissaryWeb.Plugs.ApiSecurityHeaders
    plug EmissaryWeb.Plugs.ScrubTinctureCredentials

    plug EmissaryWeb.Plugs.TinctureRateLimit,
      bucket: :asset,
      max_requests: 300,
      window_ms: EmissaryWeb.Plugs.TinctureRateLimit.default_window_ms()
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

  # Inbound webhook receiver. Rate-limited (per-slug + per-IP scan-evasion bucket)
  # before signature verification so unverified spam is dropped early. Raw body
  # is captured by `EmissaryWeb.Plugs.RawBodyReader` (registered as the
  # `Plug.Parsers` body_reader on the endpoint) so HMAC verification sees the
  # exact bytes the sender signed.
  pipeline :webhook do
    plug :accepts, ["json"]
    plug EmissaryWeb.Plugs.ApiSecurityHeaders
    plug EmissaryWeb.Plugs.WebhookRateLimit
    plug EmissaryWeb.Plugs.VerifyWebhookSignature
    plug EmissaryWeb.Plugs.WebhookIdempotency
  end

  # Focus is in the URL: `/a/<athanor>/…` — a person's athanor as
  # `@<namespace>`, a group's by slug. Two tabs can be two athanors, and
  # A chat attachment's bytes, for the member reading the thread on another
  # device. Its own pipeline: no `:accepts` (a browser asks for an image or
  # a PDF, not html), the session cookie for who, the URL's athanor for
  # where — the controller focuses it exactly as a LiveView mount does.
  pipeline :attachment do
    # A headless node serves no page surface, and a chat attachment is one.
    plug EmissaryWeb.Plugs.Headless
    plug :fetch_session
    # GET only, so this never verifies a token — but a pipeline that reads
    # the session carries the same forgery guard as `:browser`.
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug EmissaryWeb.Plugs.ApiSecurityHeaders
  end

  # A thread can legitimately render a handful of attachments at once;
  # the budget is sized for pages, not loops.
  pipeline :attachment_throttle do
    plug EmissaryWeb.Plugs.AuthRateLimit,
      bucket: :attachment,
      max_requests: 120,
      window_ms: 60_000
  end

  # Auth API routes (logout, whoami) - must be defined before wildcard /:provider
  scope "/auth", EmissaryWeb do
    pipe_through [:api, :auth_api_throttle]

    delete "/logout", AuthController, :logout
    get "/whoami", AuthController, :whoami
  end

  # OAuth callback for catalyst OAuth providers (not user auth)
  # Must be defined before the /:provider wildcard below
  scope "/auth/oauth", EmissaryWeb do
    pipe_through [:oauth_callback, :oauth_callback_throttle]

    get "/callback", OAuthCallbackController, :callback
  end

  # OAuth/OIDC authentication routes. GitHub/Google browser sign-in is
  # device flow on `/login`; `/auth/:provider` is the OIDC kickoff (and
  # leftover web OAuth if a client secret is configured). Static paths
  # sit above `/:provider` so they cannot be captured as a provider name.
  scope "/auth", EmissaryWeb do
    pipe_through :browser

    get "/post-legal-accept", AuthController, :post_legal_accept

    scope "/" do
      pipe_through :device_complete_throttle

      get "/device/complete/:ticket", AuthController, :device_complete
    end

    scope "/" do
      pipe_through :oauth_start_throttle

      get "/:provider", AuthController, :request
    end

    scope "/" do
      pipe_through :oauth_callback_throttle

      get "/:provider/callback", AuthController, :callback
    end
  end

  # The publisher-namespace claim (web flow): a person who wants to publish
  # to cyfr.run claims their namespace here, whenever they choose. Signing
  # in never depends on it.
  scope "/claim-namespace", PrismWeb do
    pipe_through :browser

    get "/", ClaimNamespaceController, :show

    # Submit is the only write endpoint; throttle it, not the form render.
    scope "/" do
      pipe_through :claim_submit_throttle

      post "/submit", ClaimNamespaceController, :submit
    end
  end

  # Policy acceptance: renders bundled policies and posts acceptance to
  # cyfr.run /v1/legal/accept. Used after a 412 POLICY_ACCEPTANCE_REQUIRED
  # response or during post-login setup.
  scope "/legal/accept", PrismWeb do
    pipe_through [:browser, :legal_accept_throttle]

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

  scope "/t", EmissaryWeb do
    pipe_through :tincture_invoke
    # Cross-origin token mint: session/Bearer header → short-lived ?_t=.
    get "/access-token", TinctureController, :access_token
    match :options, "/access-token", TinctureController, :access_token
    post "/:athanor/:publisher/:tincture_name/invoke", TinctureController, :invoke
    # OPTIONS preflight — CORS plug intercepts and sends 204 before reaching controller.
    # Required because sandboxed iframes (opaque origin) + POST with JSON content-type
    # triggers CORS preflight from the browser.
    match :options, "/:athanor/:publisher/:tincture_name/invoke", TinctureController, :invoke
  end

  scope "/t", EmissaryWeb do
    pipe_through :tincture
    get "/:athanor/:publisher/:tincture_name", TinctureController, :index
  end

  scope "/t", EmissaryWeb do
    pipe_through :tincture_asset
    get "/:athanor/:publisher/:tincture_name/*path", TinctureController, :asset
  end

  # Health check endpoint
  scope "/api", EmissaryWeb do
    pipe_through [:api, :health_throttle]

    get "/health", HealthController, :check
    get "/health/ready", HealthController, :ready
  end

  # Execution event SSE stream. Ownership is verified in the controller, on the
  # context `Plugs.Authenticate` resolved, before any event flows.
  scope "/api", EmissaryWeb do
    pipe_through :authenticated_api

    get "/executions/:id/events", ExecutionEventsController, :stream
  end

  scope "/hooks", EmissaryWeb do
    pipe_through :webhook
    post "/:slug", WebhookController, :invoke
  end

  # ==========================================================================
  # Prism — the LiveView face, on this origin
  # ==========================================================================

  # Sign in and out from the browser. `/login` starts GitHub/Google device
  # flow (or links to `/auth/oidcc`); `/auth/logout` drops the cookie
  # session and retires the Sanctum session behind it.
  scope "/", PrismWeb do
    pipe_through :browser

    live "/login", LoginLive, :login
    # POST, never GET: signing someone out must not be one <img src> away
    # — the browser pipeline's CSRF token guards the state change.
    post "/auth/logout", SessionController, :logout
  end

  scope "/a/:athanor", PrismWeb do
    pipe_through [:attachment, :attachment_throttle]

    get "/attachments/:message_id/:filename", AttachmentController, :show
    get "/files/download/*path", FileController, :show
  end

  # Opening an estate is a link. `PrismWeb.Focus` resolves the segment and narrows
  # the context (`Sanctum.Context.focus/2`) before the page mounts.
  scope "/", PrismWeb do
    pipe_through :browser

    live_session :athanor,
      on_mount: [
        {PrismWeb.LiveAuth, :require_auth},
        {PrismWeb.Focus, :assign},
        {PrismWeb.ActiveContext, :assign}
      ] do
      live "/", RootRedirectLive, :index
      live "/a", RootRedirectLive, :index
      # The chat is one zone across every estate the person belongs to; it
      # names its estate in the query, not the path, and mounts under the
      # session's default (`PrismWeb.Focus` passes a bare mount through).
      live "/chat", ChatLive, :index

      scope "/a/:athanor" do
        # Forward to /chat with the athanor selected.
        live "/", ChatRedirectLive, :index
        live "/aqua", AquaLive, :index
        live "/files", FilesLive, :index
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
        live "/components", ComponentsLive, :index
        live "/components/:ref", ComponentDetailLive, :show
        live "/registry", RegistryLive, :index
        live "/reports", MyReportsLive, :index
        live "/builds", BuildsLive, :index
        live "/vault", VaultLive, :index
        live "/api-keys", ApiKeysLive, :index
        live "/members", MembersLive, :index
        live "/webhooks", WebhooksLive, :index
        live "/schedules", SchedulesLive, :index
        live "/settings", SettingsLive, :index
        live "/mcp-servers", McpServersLive, :index
        live "/tinctures", ShellLive, :index
        live "/legal", LegalLive, :index
      end
    end
  end
end
