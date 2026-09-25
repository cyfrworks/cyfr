# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Ingress.Router do
  @moduledoc """
  The host's HTTP ingress routes: sign-in and sign-out, the OAuth grant
  callback, tincture serving, health, the execution-events stream and
  inbound webhooks, with the pipelines they pass through.

  The composition router invokes `routes/0` where these routes stand, so
  its `__routes__/0` stays the total table. The quoted calls resolve where
  the macro expands, against the composition router's `use Phoenix.Router`
  and its imports; this module imports nothing.
  """

  # The root's table is the one table; `Phoenix.Router.forward/4` cannot span several prefixes.
  defmacro routes do
    quote do
      # Sign-in, sign-out and the OAuth grant callback render through
      # `CyfrWeb.MinimalPage`, so their browser pipeline sets no root layout.
      CyfrWeb.Pipelines.browser(:auth_browser)

      pipeline :api do
        plug :accepts, ["json"]
        plug CyfrWeb.Plugs.ApiSecurityHeaders
      end

      # Client-driven auth-API endpoints (logout, whoami) self-gate in the
      # controller (401/400 without a token) but were otherwise unmetered — a
      # session-token brute-force / Session.get amplification surface. The
      # IdP-driven callbacks stay unthrottled (shared-NAT corporate IPs).
      pipeline :auth_api_throttle do
        plug CyfrWeb.Plugs.AuthRateLimit,
          bucket: :auth_api,
          max_requests: 30,
          window_ms: 60_000
      end

      # Authenticated HTTP routes use the shared context resolver with API
      # error rendering and a separate rate-limit bucket.
      pipeline :authenticated_api do
        plug CyfrWeb.Plugs.CallIdentity, tool: "execution"
        plug :accepts, ["json", "event-stream"]
        plug CyfrWeb.Plugs.ApiSecurityHeaders
        plug CyfrWeb.Plugs.CORS, methods: ~w(GET), headers: ~w(last-event-id)
        plug CyfrWeb.Plugs.MCPOrigin
        plug CyfrWeb.Plugs.MCPRateLimit, bucket: :api
        plug CyfrWeb.Plugs.Authenticate
      end

      # OAuth kickoff gets a conservative per-IP throttle; callbacks get the
      # generous :oauth_callback_throttle below.
      pipeline :oauth_start_throttle do
        plug CyfrWeb.Plugs.AuthRateLimit,
          bucket: :oauth_start,
          max_requests: 30,
          window_ms: 60_000
      end

      # Callbacks arrive from IdPs on real users' behalf, often through
      # shared-NAT corporate IPs, so their budget is generous — high enough
      # that a floor of real users never trips it, low enough that one IP
      # cannot spin the token-exchange machinery unboundedly.
      pipeline :oauth_callback_throttle do
        plug CyfrWeb.Plugs.AuthRateLimit,
          bucket: :oauth_callback,
          max_requests: 60,
          window_ms: 60_000
      end

      # The OAuth grant callback serves a BROWSER page (CyfrWeb.MinimalPage,
      # no session) — `:api`'s `accepts ["json"]` 406'd any client that sent a
      # strict `Accept: text/html`, which is what a browser redirect carries.
      pipeline :oauth_callback do
        plug :accepts, ["html", "json"]
        plug CyfrWeb.Plugs.ApiSecurityHeaders
      end

      # Meter ticket adoption before authentication. Looking up a ticket
      # consumes it, so attempts need their own request budget.
      pipeline :device_complete_throttle do
        plug CyfrWeb.Plugs.AuthRateLimit,
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
        plug CyfrWeb.Plugs.CallIdentity, tool: "tincture"
        plug :accepts, ["html", "json"]
        plug CyfrWeb.Plugs.ApiSecurityHeaders
        plug CyfrWeb.Plugs.ScrubTinctureCredentials

        plug CyfrWeb.Plugs.TinctureRateLimit,
          bucket: :page,
          max_requests: 60,
          window_ms: CyfrWeb.Plugs.TinctureRateLimit.default_window_ms()
      end

      pipeline :tincture_invoke do
        plug CyfrWeb.Plugs.CallIdentity, tool: "tincture"
        plug :accepts, ["json"]
        plug CyfrWeb.Plugs.ApiSecurityHeaders
        # Deliberately NO MCPOrigin here, unlike /mcp and /api: a public
        # tincture is embeddable from any origin, so this surface is
        # cross-origin BY DESIGN (the CORS plug below is its contract). The
        # DNS-rebinding class MCPOrigin defends against needs an ambient
        # credential to steal; invoke authenticates per request (Bearer or the
        # short-lived ?_t= mint) and the public route is credential-less.
        # POST for invoke, GET for the cross-origin `/t/access-token` mint.
        plug CyfrWeb.Plugs.CORS, methods: ~w(GET POST)
        # Before the rate limiter so a 429 is scrubbed too — it is logged like any
        # other response, and it never reaches the action that reads the credential.
        plug CyfrWeb.Plugs.ScrubTinctureCredentials
        # After CORS on purpose: OPTIONS preflights are halted with 204 above and
        # must never be counted or answered 429 without CORS headers.
        plug CyfrWeb.Plugs.TinctureRateLimit,
          bucket: :invoke,
          max_requests: CyfrWeb.Plugs.TinctureRateLimit.default_invoke_max(),
          window_ms: CyfrWeb.Plugs.TinctureRateLimit.default_window_ms()
      end

      pipeline :tincture_asset do
        # No :accepts — assets serve arbitrary content types.
        plug CyfrWeb.Plugs.ApiSecurityHeaders
        plug CyfrWeb.Plugs.ScrubTinctureCredentials

        plug CyfrWeb.Plugs.TinctureRateLimit,
          bucket: :asset,
          max_requests: 300,
          window_ms: CyfrWeb.Plugs.TinctureRateLimit.default_window_ms()
      end

      # Anonymous and internet-reachable behind the tls proxy, and /ready does
      # real DB/storage work per uncached hit — metered per IP so it cannot be
      # used to drive storage round-trips (billable PUTs on S3) at will.
      pipeline :health_throttle do
        plug CyfrWeb.Plugs.AuthRateLimit,
          bucket: :health,
          max_requests: 60,
          window_ms: 60_000
      end

      # Inbound webhook receiver. Rate-limited (per-slug + per-IP scan-evasion bucket)
      # before signature verification so unverified spam is dropped early. Raw body
      # is captured by `CyfrWeb.Plugs.RawBodyReader` (registered as the
      # `Plug.Parsers` body_reader on the endpoint) so HMAC verification sees the
      # exact bytes the sender signed.
      pipeline :webhook do
        plug CyfrWeb.Plugs.CallIdentity, tool: "webhook"
        plug :accepts, ["json"]
        plug CyfrWeb.Plugs.ApiSecurityHeaders
        plug CyfrWeb.Plugs.WebhookRateLimit
        plug CyfrWeb.Plugs.VerifyWebhookSignature
        plug CyfrWeb.Plugs.WebhookIdempotency
      end

      # Auth API routes (logout, whoami) - must be defined before wildcard /:provider
      scope "/auth", CyfrWeb.Ingress do
        pipe_through [:api, :auth_api_throttle]

        delete "/logout", AuthController, :logout, metadata: %{auth: :handler_auth}
        get "/whoami", AuthController, :whoami, metadata: %{auth: :handler_auth}
      end

      # OAuth callback for catalyst OAuth providers (not user auth)
      # Must be defined before the /:provider wildcard below
      scope "/auth/oauth", CyfrWeb.Ingress do
        pipe_through [:oauth_callback, :oauth_callback_throttle]

        get "/callback", OAuthCallbackController, :callback,
          metadata: %{auth: :public_oauth_state}
      end

      # Sign-in routes. GitHub/Google sign in by device flow on `/login`;
      # `/auth/:provider` is the OIDC kickoff. Static paths
      # sit above `/:provider` so they cannot be captured as a provider name.
      scope "/auth", CyfrWeb.Ingress do
        pipe_through :auth_browser

        # POST, never GET: signing someone out must not be one <img src> away
        # — the browser pipeline's CSRF token guards the state change. The
        # DELETE above is the API callers' sign-out, by bearer token.
        post "/logout", AuthController, :browser_logout, metadata: %{auth: :browser_public_auth}

        get "/post-legal-accept", AuthController, :post_legal_accept,
          metadata: %{auth: :browser_oauth_flow}

        scope "/" do
          pipe_through :device_complete_throttle

          get "/device/complete/:ticket", AuthController, :device_complete,
            metadata: %{auth: :browser_oauth_flow}
        end

        scope "/" do
          pipe_through :oauth_start_throttle

          get "/:provider", AuthController, :request, metadata: %{auth: :browser_oauth_start}
        end

        scope "/" do
          pipe_through :oauth_callback_throttle

          get "/:provider/callback", AuthController, :callback,
            metadata: %{auth: :browser_oauth_callback}
        end
      end

      scope "/t", CyfrWeb.Ingress do
        pipe_through :tincture_invoke
        # Cross-origin token mint: session/Bearer header → short-lived ?_t=.
        get "/access-token", TinctureController, :access_token,
          metadata: %{auth: :tincture_handler_auth}

        match :options, "/access-token", TinctureController, :access_token,
          metadata: %{auth: :tincture_handler_auth}

        post "/:athanor/:publisher/:tincture_name/invoke", TinctureController, :invoke,
          metadata: %{auth: :tincture_handler_auth}

        # OPTIONS preflight — CORS plug intercepts and sends 204 before reaching controller.
        # Required because sandboxed iframes (opaque origin) + POST with JSON content-type
        # triggers CORS preflight from the browser.
        match :options, "/:athanor/:publisher/:tincture_name/invoke", TinctureController, :invoke,
          metadata: %{auth: :tincture_handler_auth}
      end

      scope "/t", CyfrWeb.Ingress do
        pipe_through :tincture

        get "/:athanor/:publisher/:tincture_name", TinctureController, :index,
          metadata: %{auth: :tincture_handler_auth}
      end

      scope "/t", CyfrWeb.Ingress do
        pipe_through :tincture_asset

        get "/:athanor/:publisher/:tincture_name/*path", TinctureController, :asset,
          metadata: %{auth: :tincture_handler_auth}
      end

      # Health check endpoint
      scope "/api", CyfrWeb.Ingress do
        pipe_through [:api, :health_throttle]

        get "/health", HealthController, :check, metadata: %{auth: :public_health}
        get "/health/ready", HealthController, :ready, metadata: %{auth: :public_health}
      end

      # Execution event SSE stream. Ownership is verified in the controller, on the
      # context `Plugs.Authenticate` resolved, before any event flows.
      scope "/api", CyfrWeb.Ingress do
        pipe_through :authenticated_api

        get "/executions/:id/events", ExecutionEventsController, :stream,
          metadata: %{auth: :authenticate_plug}
      end

      scope "/hooks", CyfrWeb.Ingress do
        pipe_through :webhook
        post "/:slug", WebhookController, :invoke, metadata: %{auth: :webhook_hmac}
      end
    end
  end
end
