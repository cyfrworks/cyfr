# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.Router do
  @moduledoc """
  The console's routes: the browser pipeline under the console's root
  layout, the browser sign-in pipelines and their throttles, the claim,
  legal-acceptance and attachment pipelines, browser sign-in and
  sign-out with their callbacks, linking an OpenID Connect door, passkey
  sign-in's completion, the `cyfr` door's challenge hop and callback, the
  OpenID Connect re-authentication's callback, the claim and legal pages, the
  attachment and file downloads and the `:athanor` LiveView session.

  The composition router invokes `routes/0` where these routes stand, so
  its `__routes__/0` stays the total table. The quoted calls resolve where
  the macro expands, against the composition router's `use Phoenix.Router`
  and its imports; this module imports nothing.
  """

  use Boundary, top_level?: true, deps: [], exports: [], check: [aliases: true]

  # The root's table is the one table; `Phoenix.Router.forward/4` cannot span several prefixes.
  defmacro routes do
    quote do
      # The browser pipeline serves the Prism LiveViews and the console's
      # pages, under the console's root layout. LiveView mounts are gated in `CyfrWeb.ContextGuard`, because the
      # LiveView socket is handled by the endpoint before the router and never
      # passes through here.
      CyfrWeb.Pipelines.browser(:browser, root_layout: {PrismWeb.Layouts, :root})

      # Sign-in and sign-out render through `CyfrWeb.MinimalPage`, so their
      # browser pipeline sets no root layout.
      CyfrWeb.Pipelines.browser(:auth_browser)

      # OAuth kickoff gets a conservative per-IP throttle; callbacks get the
      # generous :oauth_callback_throttle below.
      pipeline :oauth_start_throttle do
        plug CyfrWeb.Plugs.AuthRateLimit,
          bucket: :oauth_start,
          max_requests: 30,
          window_ms: 60_000
      end

      # The sign-in callbacks' throttle, which the vault's OAuth grant
      # callback shares: one definition in the host's shared pipelines.
      CyfrWeb.Pipelines.oauth_callback_throttle()

      # Meter ticket adoption before authentication. Looking up a ticket
      # consumes it, so attempts need their own request budget.
      pipeline :device_complete_throttle do
        plug CyfrWeb.Plugs.AuthRateLimit,
          bucket: :device_complete,
          max_requests: 30,
          window_ms: 60_000
      end

      # A passkey sign-in's ticket, like a device flow's: looking one up
      # consumes it, so attempts need their own request budget.
      pipeline :passkey_complete_throttle do
        plug CyfrWeb.Plugs.AuthRateLimit,
          bucket: :passkey_complete,
          max_requests: 30,
          window_ms: 60_000
      end

      # Submit path on the claim page: defends against username enumeration
      # (cyfr.run's 409 distinguishes SLUG_TAKEN / ALREADY_CLAIMED) and
      # claim-spam DOS.
      pipeline :claim_submit_throttle do
        plug CyfrWeb.Plugs.AuthRateLimit,
          bucket: :claim_submit,
          max_requests: 10,
          window_ms: 60_000
      end

      # The legal pages proxy cyfr.run (a cold GET fetches every policy body;
      # the submit relays the acceptance) — a modest per-IP budget keeps one
      # client from turning this server into an amplifier against cyfr.run.
      pipeline :legal_accept_throttle do
        plug CyfrWeb.Plugs.AuthRateLimit,
          bucket: :legal_accept,
          max_requests: 12,
          window_ms: 60_000
      end

      # Focus is in the URL: `/a/<athanor>/…` — a person's athanor as
      # `@<namespace>`, a group's by slug. Two tabs can be two athanors, and
      # A chat attachment's bytes, for the member reading the thread on another
      # device. Its own pipeline: no `:accepts` (a browser asks for an image or
      # a PDF, not html), the session cookie for who, the URL's athanor for
      # where — the controller focuses it exactly as a LiveView mount does.
      pipeline :attachment do
        # A headless node serves no page surface, and a chat attachment is one.
        plug CyfrWeb.Plugs.Headless
        # Before the session: a frame's request reaches none.
        plug CyfrWeb.Plugs.FrameRequest
        plug :fetch_session
        # GET only, so this never verifies a token — but a pipeline that reads
        # the session carries the same forgery guard as `:browser`.
        plug :protect_from_forgery
        plug :put_secure_browser_headers
        plug CyfrWeb.Plugs.ApiSecurityHeaders
      end

      # A thread can legitimately render a handful of attachments at once;
      # the budget is sized for pages, not loops.
      pipeline :attachment_throttle do
        plug CyfrWeb.Plugs.AuthRateLimit,
          bucket: :attachment,
          max_requests: 120,
          window_ms: 60_000
      end

      # Sign-in routes. GitHub/Google sign in by device flow on `/login`;
      # `/auth/:provider` is the OIDC kickoff. Static paths
      # sit above `/:provider` so they cannot be captured as a provider name;
      # the API's `/auth` paths and the OAuth grant callback are expanded
      # before this scope by the composition router.
      scope "/auth", PrismWeb do
        pipe_through :auth_browser

        # POST, never GET: signing someone out must not be one <img src> away
        # — the browser pipeline's CSRF token guards the state change. The
        # API callers' sign-out is `DELETE /auth/logout`, by bearer token.
        post "/logout", AuthController, :browser_logout, metadata: %{auth: :browser_public_auth}

        get "/post-legal-accept", AuthController, :post_legal_accept,
          metadata: %{auth: :browser_oauth_flow}

        scope "/" do
          pipe_through :device_complete_throttle

          get "/device/complete/:ticket", AuthController, :device_complete,
            metadata: %{auth: :browser_oauth_flow}
        end

        # A passkey sign-in the sign-in page verified hands its one-time
        # ticket here, which sets the cookie session.
        scope "/" do
          pipe_through :passkey_complete_throttle

          get "/passkey/complete/:ticket", PasskeyController, :complete,
            metadata: %{auth: :browser_oauth_flow}
        end

        # The issuer's answer to a re-authentication for one pending
        # confirmation: its own redirect URI, beside the sign-in callback,
        # which verifies the login and shows what it would confirm. The
        # person's answer is a POST the browser pipeline's CSRF token
        # guards, spending the verified proof's single-use ticket the
        # cookie session holds.
        scope "/" do
          pipe_through :oauth_callback_throttle

          get "/oidcc/reauth", ReauthController, :callback,
            metadata: %{auth: :browser_oauth_callback}

          post "/oidcc/reauth", ReauthController, :decide, metadata: %{auth: :browser_oauth_flow}
        end

        # The `cyfr` door's callback: the sign-in page posts the assertion
        # the person's own home signed over the challenge this browser's
        # session holds, with the browser pipeline's CSRF token.
        scope "/" do
          pipe_through :oauth_callback_throttle

          post "/cyfr/callback", AuthController, :cyfr_callback,
            metadata: %{auth: :browser_cyfr_callback}
        end

        # Linking an OpenID Connect door to the person signed in: a POST the
        # browser pipeline's CSRF token guards, under the browser's own
        # session, which holds the link intent and starts the issuer's
        # sign-in. Above `/:provider` so it is never read as a provider.
        scope "/" do
          pipe_through :oauth_start_throttle

          post "/link/oidcc", AuthController, :link_start, metadata: %{auth: :browser_session}
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

      # The publisher-namespace claim (web flow): a person who wants to publish
      # to cyfr.run claims their namespace here, whenever they choose. Signing
      # in never depends on it.
      scope "/claim-namespace", PrismWeb do
        pipe_through :browser

        get "/", ClaimNamespaceController, :show, metadata: %{auth: :browser_claim_gate}

        # Submit is the only write endpoint; throttle it, not the form render.
        scope "/" do
          pipe_through :claim_submit_throttle

          post "/submit", ClaimNamespaceController, :submit,
            metadata: %{auth: :browser_claim_gate}
        end
      end

      # Policy acceptance: renders bundled policies and posts acceptance to
      # cyfr.run /v1/legal/accept. Used after a 412 POLICY_ACCEPTANCE_REQUIRED
      # response or during post-login setup.
      scope "/legal/accept", PrismWeb do
        pipe_through [:browser, :legal_accept_throttle]

        get "/", LegalAcceptController, :show, metadata: %{auth: :browser_public_legal}
        post "/submit", LegalAcceptController, :submit, metadata: %{auth: :browser_public_legal}
      end

      # ==========================================================================
      # Prism — the LiveView face, on this origin
      # ==========================================================================

      # Sign in from the browser. `/login` starts GitHub/Google device flow
      # (or links to `/auth/oidcc`); signing out is `POST /auth/logout`
      # above. `/pair` is the page a pairing code opens on a new glass:
      # sessionless like `/login`, it reads no session, and the invitation
      # in its fragment names the person.
      scope "/", PrismWeb do
        pipe_through :browser

        live "/login", LoginLive, :login, metadata: %{auth: :browser_public_login}
        live "/pair", PairLive, :pair, metadata: %{auth: :browser_public_login}
      end

      scope "/a/:athanor", PrismWeb do
        pipe_through [:attachment, :attachment_throttle]

        get "/attachments/:message_id/:filename", AttachmentController, :show,
          metadata: %{auth: :browser_focus_handler}

        get "/files/download/*path", FileController, :show,
          metadata: %{auth: :browser_focus_handler}
      end

      # Opening an athanor is a link. `PrismWeb.Focus` resolves the segment and narrows
      # the context (`Sanctum.Context.focus/2`) before the page mounts.
      scope "/", PrismWeb do
        pipe_through :browser

        live_session :athanor,
          on_mount: [
            {CyfrWeb.ContextGuard, :protected},
            {PrismWeb.Focus, :assign},
            {PrismWeb.ActiveContext, :assign}
          ] do
          live "/", RootRedirectLive, :index, metadata: %{auth: :browser_authenticated}
          live "/a", RootRedirectLive, :index, metadata: %{auth: :browser_authenticated}
          # The chat is one zone across every athanor the person belongs to; it
          # names its athanor in the query, not the path, and mounts under the
          # session's default (`PrismWeb.Focus` passes a bare mount through).
          live "/chat", ChatLive, :index, metadata: %{auth: :browser_authenticated}
          # The sign-in carry at the person's own home: a person signed in
          # here begins a sign-in at another home, confirms its assertion
          # and reads how it ended. Session-only, so a person not signed in
          # is sent through `/login`, which keeps the carry's fragment.
          live "/carry", CarryLive, :index, metadata: %{auth: :browser_authenticated}

          scope "/a/:athanor" do
            # Forward to /chat with the athanor selected.
            live "/", ChatRedirectLive, :index, metadata: %{auth: :browser_authenticated}
            live "/aqua", AquaLive, :index, metadata: %{auth: :browser_authenticated}
            live "/files", FilesLive, :index, metadata: %{auth: :browser_authenticated}
            # /activities: unified activities feed (mcp_log + execution fan-out).
            live "/activities", ActivitiesLive, :index, metadata: %{auth: :browser_authenticated}
            # /enforcements: live policy-decision feed (Arca.PolicyLog rows from
            # Crucible.Admission + HTTP egress + tincture rate limiter). Click-through
            # to /activities?request_id=… for the request-anchored causal chain.
            live "/enforcements", EnforcementsLive, :index,
              metadata: %{auth: :browser_authenticated}

            # /executions: dedicated Opus execution monitor (parent_execution_id
            # tree, component_digest, host_policy, WASI trace). Distinct from
            # /activities which is request-anchored.
            live "/executions", ExecutionsLive, :index, metadata: %{auth: :browser_authenticated}
            live "/components", ComponentsLive, :index, metadata: %{auth: :browser_authenticated}

            live "/components/:ref", ComponentDetailLive, :show,
              metadata: %{auth: :browser_authenticated}

            live "/registry", RegistryLive, :index, metadata: %{auth: :browser_authenticated}
            live "/reports", MyReportsLive, :index, metadata: %{auth: :browser_authenticated}
            live "/builds", BuildsLive, :index, metadata: %{auth: :browser_authenticated}
            live "/vault", VaultLive, :index, metadata: %{auth: :browser_authenticated}
            live "/api-keys", ApiKeysLive, :index, metadata: %{auth: :browser_authenticated}
            live "/members", MembersLive, :index, metadata: %{auth: :browser_authenticated}
            live "/webhooks", WebhooksLive, :index, metadata: %{auth: :browser_authenticated}
            live "/schedules", SchedulesLive, :index, metadata: %{auth: :browser_authenticated}
            live "/settings", SettingsLive, :index, metadata: %{auth: :browser_authenticated}
            live "/mcp-servers", McpServersLive, :index, metadata: %{auth: :browser_authenticated}
            live "/tinctures", ShellLive, :index, metadata: %{auth: :browser_authenticated}
            live "/legal", LegalLive, :index, metadata: %{auth: :browser_authenticated}
          end
        end
      end
    end
  end
end
