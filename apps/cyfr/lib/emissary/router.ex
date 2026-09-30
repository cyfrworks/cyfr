# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Router do
  @moduledoc """
  Emissary's routes, with the pipelines they pass through: MCP, the HTTP
  API's sign-out and session read, the vault's OAuth grant callback,
  tincture serving and the tincture data routes, health, the
  execution-events stream, inbound webhooks and the identity directory.

  The composition router invokes `routes/0` where the adapter's routes
  stand, so its `__routes__/0` stays the total table. The quoted calls
  resolve where the macro expands, against the composition router's
  `use Phoenix.Router` and its imports; this module imports nothing.
  """

  use Boundary, top_level?: true, deps: [], exports: [], check: [aliases: true]

  # The root's table is the one table; `Phoenix.Router.forward/4` cannot span several prefixes.
  defmacro routes do
    quote do
      # MCP accepts POST only. GET and DELETE return 405; preflight must
      # advertise only the supported method.
      pipeline :mcp do
        plug CyfrWeb.Plugs.CallIdentity
        plug :accepts, ["json", "event-stream"]
        plug CyfrWeb.Plugs.ApiSecurityHeaders
        plug CyfrWeb.Plugs.CORS, methods: ~w(POST)
        # After CORS, whose preflight answer halts first; before the caller
        # is authenticated.
        plug CyfrWeb.Plugs.FrameRequest, errors: Emissary.Web.MCPError
        plug CyfrWeb.Plugs.MCPOrigin, errors: Emissary.Web.MCPError
        # Before Authenticate so unauthenticated floods never touch DB state.
        plug CyfrWeb.Plugs.MCPRateLimit, errors: Emissary.Web.MCPError
        plug CyfrWeb.Plugs.Authenticate, errors: Emissary.Web.MCPError
        plug Emissary.Web.Plugs.MCPRequestMetadata
      end

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
        # After CORS, whose preflight answer halts first; before the caller
        # is authenticated.
        plug CyfrWeb.Plugs.FrameRequest
        plug CyfrWeb.Plugs.MCPOrigin
        plug CyfrWeb.Plugs.MCPRateLimit, bucket: :api
        plug CyfrWeb.Plugs.Authenticate
      end

      # The OAuth grant callback's throttle, which the browser's sign-in
      # callbacks share: one definition in the host's shared pipelines.
      CyfrWeb.Pipelines.oauth_callback_throttle()

      # The OAuth grant callback serves a BROWSER page (CyfrWeb.MinimalPage,
      # no session) — `:api`'s `accepts ["json"]` 406'd any client that sent a
      # strict `Accept: text/html`, which is what a browser redirect carries.
      pipeline :oauth_callback do
        plug :accepts, ["html", "json"]
        plug CyfrWeb.Plugs.ApiSecurityHeaders
      end

      # Tincture serving — a public tincture at its address, a private
      # tincture version's files under the asset credential in their path.
      # No session cookie auth: a tincture page is embeddable cross-origin (see
      # the data pipeline below), and an ambient cookie credential on a
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

      # The tincture data routes (`Prima.TinctureWire`): a frame's invoke,
      # action and stream open, under the per-open frame credential as a
      # bearer, or a public tincture's page naming itself. No session and no
      # CSRF token: the bearer is the only credential, and a session cookie
      # is never consulted. Deliberately NO MCPOrigin: a frame's document is
      # sandboxed, so its origin is `null`, which only this mount's CORS
      # answers (`null_origin: true`); the DNS-rebinding class MCPOrigin
      # defends against needs an ambient credential to steal, and these
      # routes read none.
      pipeline :tincture_data do
        plug CyfrWeb.Plugs.CallIdentity, tool: "tincture"
        plug :accepts, ["json", "event-stream"]
        plug CyfrWeb.Plugs.ApiSecurityHeaders
        plug CyfrWeb.Plugs.CORS, methods: ~w(POST), null_origin: true
        # Before the rate limiter so a 429 is scrubbed too — it is logged like any
        # other response.
        plug CyfrWeb.Plugs.ScrubTinctureCredentials
        # After CORS on purpose: OPTIONS preflights are halted with 204 above and
        # must never be counted or answered 429 without CORS headers. A
        # per-address back-stop under the per-frame limits the controller
        # holds, answered in the wire's own refusal shape.
        plug CyfrWeb.Plugs.TinctureRateLimit,
          bucket: :invoke,
          max_requests: CyfrWeb.Plugs.TinctureRateLimit.default_invoke_max(),
          window_ms: CyfrWeb.Plugs.TinctureRateLimit.default_window_ms(),
          errors: Emissary.Web.TinctureDataController
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

      # MCP endpoint. POST is the only verb this revision defines: a request's own
      # response stream carries its progress, so there is no standalone stream to
      # open, and there is no session to terminate.
      scope "/mcp", Emissary.Web do
        pipe_through :mcp

        post "/", MCPController, :handle, metadata: %{auth: :authenticate_plug}
        get "/", MCPController, :method_not_allowed, metadata: %{auth: :authenticate_plug}
        delete "/", MCPController, :method_not_allowed, metadata: %{auth: :authenticate_plug}
      end

      # Auth API routes (logout, whoami). The composition router expands these
      # before the browser's `/auth/:provider` wildcard, so neither path is
      # captured as a provider name.
      scope "/auth", Emissary.Web do
        pipe_through [:api, :auth_api_throttle]

        delete "/logout", SessionController, :logout, metadata: %{auth: :handler_auth}
        get "/whoami", SessionController, :whoami, metadata: %{auth: :handler_auth}
      end

      # OAuth callback for catalyst OAuth providers (not user auth). Expanded
      # before the browser's `/auth/:provider/callback` wildcard, as above.
      scope "/auth/oauth", Emissary.Web do
        pipe_through [:oauth_callback, :oauth_callback_throttle]

        get "/callback", OAuthCallbackController, :callback,
          metadata: %{auth: :public_oauth_state}
      end

      # The data routes' paths are `Prima.TinctureWire.routes/0`'s.
      scope "/_f/v1", Emissary.Web do
        pipe_through :tincture_data

        post "/invoke", TinctureDataController, :invoke, metadata: %{auth: :frame_credential}

        post "/action", TinctureDataController, :system_action,
          metadata: %{auth: :frame_credential}

        post "/stream", TinctureDataController, :stream, metadata: %{auth: :frame_credential}

        # OPTIONS preflight — the CORS plug answers 204 before the controller.
        # A sandboxed frame's POST with a JSON body and a bearer is always
        # preflighted.
        match :options, "/invoke", TinctureDataController, :invoke,
          metadata: %{auth: :frame_credential}

        match :options, "/action", TinctureDataController, :system_action,
          metadata: %{auth: :frame_credential}

        match :options, "/stream", TinctureDataController, :stream,
          metadata: %{auth: :frame_credential}
      end

      scope "/t", Emissary.Web do
        pipe_through :tincture

        get "/:athanor/:publisher/:tincture_name", TinctureController, :index,
          metadata: %{auth: :tincture_handler_auth}
      end

      scope "/t", Emissary.Web do
        pipe_through :tincture_asset

        get "/:athanor/:publisher/:tincture_name/*path", TinctureController, :asset,
          metadata: %{auth: :tincture_handler_auth}
      end

      # A private tincture version's files, under the asset credential in
      # their path (`Prima.TinctureUrl`). The scrub plug redacts it from the
      # request path, and the route logs no dispatch, whose parameters would
      # carry it.
      scope "/", Emissary.Web do
        pipe_through :tincture_asset

        get "/_s/*path", TinctureController, :served,
          metadata: %{auth: :tincture_handler_auth},
          log: false
      end

      # Health check endpoint
      scope "/api", Emissary.Web do
        pipe_through [:api, :health_throttle]

        get "/health", HealthController, :check, metadata: %{auth: :public_health}
        get "/health/ready", HealthController, :ready, metadata: %{auth: :public_health}
      end

      # Execution event SSE stream. Ownership is verified in the controller, on the
      # context `Plugs.Authenticate` resolved, before any event flows.
      scope "/api", Emissary.Web do
        pipe_through :authenticated_api

        get "/executions/:id/events", ExecutionEventsController, :stream,
          metadata: %{auth: :authenticate_plug}
      end

      scope "/hooks", Emissary.Web do
        pipe_through :webhook
        post "/:slug", WebhookController, :invoke, metadata: %{auth: :webhook_hmac}
      end

      # The identity directory (`Sanctum.Directory`): no session, since a log
      # is public history and every signed write is verified against the
      # identifier's chain. A write's body is bounded to 16 KiB before it is
      # decoded (`CyfrWeb.Plugs.RawBodyReader`), and every request to the
      # directory's per-source and per-installation windows before any
      # signature is checked. The literal `genesis` is declared above the
      # `:identifier` routes.
      scope "/directory/v1", Emissary.Web do
        pipe_through :api

        post "/genesis", DirectoryController, :register, metadata: %{auth: :public_directory}
        get "/:identifier", DirectoryController, :resolve, metadata: %{auth: :public_directory}

        post "/:identifier/entries", DirectoryController, :append,
          metadata: %{auth: :directory_signed}

        post "/:identifier/recover", DirectoryController, :recover,
          metadata: %{auth: :directory_signed}

        get "/:identifier/requests/:request_id", DirectoryController, :outcome,
          metadata: %{auth: :public_directory}
      end
    end
  end
end
