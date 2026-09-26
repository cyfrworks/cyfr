# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.Router do
  @moduledoc """
  The console's routes: the browser pipeline under the console's root
  layout, the claim, legal-acceptance and attachment pipelines, the
  claim and legal pages, sign-in, the attachment and file downloads and
  the `:athanor` LiveView session.

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
      # (or links to `/auth/oidcc`); signing out is the ingress's
      # `POST /auth/logout`.
      scope "/", PrismWeb do
        pipe_through :browser

        live "/login", LoginLive, :login, metadata: %{auth: :browser_public_login}
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
