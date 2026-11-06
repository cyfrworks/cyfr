# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.Router do
  @moduledoc """
  The console's routes: the browser pipeline under the console's root
  layout, the browser sign-in pipelines and their throttles, the claim,
  legal-acceptance and attachment pipelines, browser sign-out, a sign-in's
  ticket completion, the company sign-in's page, start and callback, the
  claim and legal pages, the attachment and file downloads and the
  `:athanor` LiveView session.

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

      # The browser's sign-in and policy acceptance establish a person's
      # sign-in or complete it rather
      # than act under a context the gate admitted, so they decide for
      # themselves and record their own refusals: an admission entry each
      # (`Cyfr.Boundaries.admission_entries/0`), under the identity minted
      # here before the browser pipeline's first check.
      pipeline :sign_in_identity do
        plug CyfrWeb.Plugs.CallIdentity, tool: "sign_in"
      end

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

      # A protected device's unlock ticket: redeeming one consumes it, so
      # attempts need their own request budget.
      pipeline :device_unlock_throttle do
        plug CyfrWeb.Plugs.AuthRateLimit,
          bucket: :device_unlock,
          max_requests: 30,
          window_ms: 60_000
      end

      # A sign-in's ticket: looking one up consumes it, so attempts need
      # their own request budget.
      pipeline :passkey_complete_throttle do
        plug CyfrWeb.Plugs.AuthRateLimit,
          bucket: :passkey_complete,
          max_requests: 30,
          window_ms: 60_000
      end

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

      # Sign-out, a sign-in's ticket, a protected device's unlock ticket and
      # the company sign-in. A person signs in with their account at
      # `/login`; the OAuth grant callback is expanded before this scope by
      # the composition router.
      scope "/auth", PrismWeb do
        pipe_through [:sign_in_identity, :auth_browser]

        # POST, never GET: signing someone out must not be one <img src> away
        # — the browser pipeline's CSRF token guards the state change.
        post "/logout", AuthController, :browser_logout, metadata: %{auth: :browser_public_auth}

        # A protected device's unlock: the page takes the one-time ticket
        # from its fragment and posts it, with the browser pipeline's CSRF
        # token, for the session's cookie (`PrismWeb.DeviceUnlockController`).
        scope "/" do
          pipe_through :device_unlock_throttle

          get "/device/complete", DeviceUnlockController, :show,
            metadata: %{auth: :device_unlock_ticket}

          post "/device/complete", DeviceUnlockController, :redeem,
            metadata: %{auth: :device_unlock_ticket}
        end

        # A sign-in the sign-in page verified hands its one-time ticket
        # here, which sets the cookie session.
        scope "/" do
          pipe_through :passkey_complete_throttle

          get "/passkey/complete/:ticket", PasskeyController, :complete,
            metadata: %{auth: :browser_oauth_flow}
        end

        # A company sign-in, the standing condition a CYFR may require of
        # every person (`Sanctum.CompanyLogin`): its start, a POST the
        # browser pipeline's CSRF token guards from the company page,
        # under the browser's own session refused for that condition
        # alone, and the issuer's callback, which both company issuers
        # share.
        scope "/" do
          pipe_through :oauth_start_throttle

          post "/company", AuthController, :company_start,
            metadata: %{auth: :browser_company_login}
        end

        scope "/" do
          pipe_through :oauth_callback_throttle

          get "/company/callback", AuthController, :company_callback,
            metadata: %{auth: :browser_oauth_callback}
        end
      end

      # ==========================================================================
      # Prism — the LiveView face, on this origin
      # ==========================================================================

      # Sign in from the browser. `/login` sends the browser to the account
      # pages with this CYFR's request and takes the signed answer at its
      # return; signing out is `POST /auth/logout` above. `/pair` is the
      # page a pairing code opens on a new device:
      # sessionless like `/login`, it reads no session, and the invitation
      # in its fragment names the person. `/restore` is the page a fresh
      # installation serves its returning person: sessionless too, its form
      # posts the kit and the installation token to the restore ingress
      # (`POST /restore`) from the browser, never through this view.
      # `/setup` is the page the setup link opens: sessionless, the setup
      # token in its fragment held with the sign-in request it sends the
      # browser to the account pages with (`PrismWeb.SetupLive`).
      # `/invite` is the page an invitation link opens: sessionless, the
      # code in its fragment, whose hash the sign-in request holds
      # (`PrismWeb.InviteLive`). `/company-login` is the one page a
      # session refused for the company sign-in alone opens
      # (`PrismWeb.CompanyLoginLive`).
      scope "/", PrismWeb do
        pipe_through :browser

        live "/login", LoginLive, :login, metadata: %{auth: :browser_public_login}
        live "/restore", RestoreLive, :restore, metadata: %{auth: :browser_public_login}
        live "/setup", SetupLive, :setup, metadata: %{auth: :browser_public_login}
        live "/invite", InviteLive, :invite, metadata: %{auth: :browser_public_login}

        live "/company-login", CompanyLoginLive, :index, metadata: %{auth: :browser_company_login}
      end

      scope "/a/:athanor", PrismWeb do
        pipe_through [:attachment, :attachment_throttle]

        get "/attachments/:message_id/:filename", AttachmentController, :show,
          metadata: %{auth: :browser_focus_handler}

        get "/files/download/*path", FileController, :show,
          metadata: %{auth: :browser_focus_handler}
      end

      # A shared thread is no athanor's: its files are reached by the
      # person's seat in it, and no athanor is focused.
      scope "/shared/:thread", PrismWeb do
        pipe_through [:attachment, :attachment_throttle]

        get "/attachments/:message_id/:filename", SharedAttachmentController, :show,
          metadata: %{auth: :browser_session}
      end

      # Opening an athanor is a link: focus is in the URL, `/a/<athanor>/…` —
      # a person's athanor as `@<namespace>`. `PrismWeb.Focus` resolves the segment and narrows
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
          # The chat names its athanor in the query, not the path, and mounts under the
          # session's default (`PrismWeb.Focus` passes a bare mount through).
          live "/chat", ChatLive, :index, metadata: %{auth: :browser_authenticated}

          scope "/a/:athanor" do
            # Forward to /chat with the athanor selected.
            live "/", ChatRedirectLive, :index, metadata: %{auth: :browser_authenticated}
            live "/aqua", AquaLive, :index, metadata: %{auth: :browser_authenticated}
            live "/files", FilesLive, :index, metadata: %{auth: :browser_authenticated}
            # /activities: unified activities feed (mcp_log + execution fan-out).
            live "/activities", ActivitiesLive, :index, metadata: %{auth: :browser_authenticated}
            # /enforcements: live policy-decision feed (Arca.PolicyLog rows from
            # Opus.Admission + HTTP egress + tincture rate limiter). Click-through
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
            live "/webhooks", WebhooksLive, :index, metadata: %{auth: :browser_authenticated}
            live "/schedules", SchedulesLive, :index, metadata: %{auth: :browser_authenticated}
            live "/settings", SettingsLive, :index, metadata: %{auth: :browser_authenticated}
            live "/programs", ProgramsLive, :index, metadata: %{auth: :browser_authenticated}
            # /canvas: the Canvas mode, the person's canvases and the apps over
            # them (PrismWeb.ShellLive); every other page is the Dashboard.
            live "/canvas", ShellLive, :index, metadata: %{auth: :browser_authenticated}
            live "/legal", LegalLive, :index, metadata: %{auth: :browser_authenticated}
          end
        end
      end
    end
  end
end
