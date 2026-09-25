# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# The route map: every route provider's routes and pipelines, one section
# per provider. `CyfrWeb.RouterTest` holds it equal to the compiled table
# and to each provider's source, so a route, posture, pipeline or plug
# cannot move or vanish without this file changing with it.
%{
  providers: %{
    "EmissaryWeb.Router" => %{
      file: "apps/cyfr/lib/emissary_web/router.ex",
      pipelines: %{
        "api" => [":accepts", "EmissaryWeb.Plugs.ApiSecurityHeaders"],
        "attachment" => [
          "EmissaryWeb.Plugs.Headless",
          ":fetch_session",
          ":protect_from_forgery",
          ":put_secure_browser_headers",
          "EmissaryWeb.Plugs.ApiSecurityHeaders"
        ],
        "attachment_throttle" => ["EmissaryWeb.Plugs.AuthRateLimit"],
        "auth_api_throttle" => ["EmissaryWeb.Plugs.AuthRateLimit"],
        "authenticated_api" => [
          "EmissaryWeb.Plugs.CallIdentity",
          ":accepts",
          "EmissaryWeb.Plugs.ApiSecurityHeaders",
          "EmissaryWeb.Plugs.CORS",
          "EmissaryWeb.Plugs.MCPOrigin",
          "EmissaryWeb.Plugs.MCPRateLimit",
          "EmissaryWeb.Plugs.Authenticate"
        ],
        "browser" => [
          "EmissaryWeb.Plugs.Headless",
          ":accepts",
          ":fetch_session",
          ":fetch_live_flash",
          ":put_root_layout",
          ":protect_from_forgery",
          ":put_secure_browser_headers",
          "EmissaryWeb.Plugs.BrowserCSP"
        ],
        "claim_submit_throttle" => ["EmissaryWeb.Plugs.AuthRateLimit"],
        "device_complete_throttle" => ["EmissaryWeb.Plugs.AuthRateLimit"],
        "health_throttle" => ["EmissaryWeb.Plugs.AuthRateLimit"],
        "legal_accept_throttle" => ["EmissaryWeb.Plugs.AuthRateLimit"],
        "mcp" => [
          "EmissaryWeb.Plugs.CallIdentity",
          ":accepts",
          "EmissaryWeb.Plugs.ApiSecurityHeaders",
          "EmissaryWeb.Plugs.CORS",
          "EmissaryWeb.Plugs.MCPOrigin",
          "EmissaryWeb.Plugs.MCPRateLimit",
          "EmissaryWeb.Plugs.Authenticate",
          "EmissaryWeb.Plugs.MCPRequestMetadata"
        ],
        "oauth_callback" => [":accepts", "EmissaryWeb.Plugs.ApiSecurityHeaders"],
        "oauth_callback_throttle" => ["EmissaryWeb.Plugs.AuthRateLimit"],
        "oauth_start_throttle" => ["EmissaryWeb.Plugs.AuthRateLimit"],
        "tincture" => [
          "EmissaryWeb.Plugs.CallIdentity",
          ":accepts",
          "EmissaryWeb.Plugs.ApiSecurityHeaders",
          "EmissaryWeb.Plugs.ScrubTinctureCredentials",
          "EmissaryWeb.Plugs.TinctureRateLimit"
        ],
        "tincture_asset" => [
          "EmissaryWeb.Plugs.ApiSecurityHeaders",
          "EmissaryWeb.Plugs.ScrubTinctureCredentials",
          "EmissaryWeb.Plugs.TinctureRateLimit"
        ],
        "tincture_invoke" => [
          "EmissaryWeb.Plugs.CallIdentity",
          ":accepts",
          "EmissaryWeb.Plugs.ApiSecurityHeaders",
          "EmissaryWeb.Plugs.CORS",
          "EmissaryWeb.Plugs.ScrubTinctureCredentials",
          "EmissaryWeb.Plugs.TinctureRateLimit"
        ],
        "webhook" => [
          "EmissaryWeb.Plugs.CallIdentity",
          ":accepts",
          "EmissaryWeb.Plugs.ApiSecurityHeaders",
          "EmissaryWeb.Plugs.WebhookRateLimit",
          "EmissaryWeb.Plugs.VerifyWebhookSignature",
          "EmissaryWeb.Plugs.WebhookIdempotency"
        ]
      },
      routes: [
        %{
          verb: "GET",
          path: "/",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.RootRedirectLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.RootRedirectLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.ChatRedirectLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/activities",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.ActivitiesLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/api-keys",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.ApiKeysLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/aqua",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.AquaLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/attachments/:message_id/:filename",
          plug: "PrismWeb.AttachmentController",
          plug_opts: ":show",
          auth: "browser_focus_handler",
          live_view: nil,
          pipe_through: ["attachment", "attachment_throttle"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/builds",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.BuildsLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/components",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.ComponentsLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/components/:ref",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":show",
          auth: "browser_authenticated",
          live_view: "PrismWeb.ComponentDetailLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/enforcements",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.EnforcementsLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/executions",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.ExecutionsLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/files",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.FilesLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/files/download/*path",
          plug: "PrismWeb.FileController",
          plug_opts: ":show",
          auth: "browser_focus_handler",
          live_view: nil,
          pipe_through: ["attachment", "attachment_throttle"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/legal",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.LegalLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/mcp-servers",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.McpServersLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/members",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.MembersLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/registry",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.RegistryLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/reports",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.MyReportsLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/schedules",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.SchedulesLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/settings",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.SettingsLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/tinctures",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.ShellLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/vault",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.VaultLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/a/:athanor/webhooks",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.WebhooksLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/api/executions/:id/events",
          plug: "EmissaryWeb.ExecutionEventsController",
          plug_opts: ":stream",
          auth: "authenticate_plug",
          live_view: nil,
          pipe_through: ["authenticated_api"]
        },
        %{
          verb: "GET",
          path: "/api/health",
          plug: "EmissaryWeb.HealthController",
          plug_opts: ":check",
          auth: "public_health",
          live_view: nil,
          pipe_through: ["api", "health_throttle"]
        },
        %{
          verb: "GET",
          path: "/api/health/ready",
          plug: "EmissaryWeb.HealthController",
          plug_opts: ":ready",
          auth: "public_health",
          live_view: nil,
          pipe_through: ["api", "health_throttle"]
        },
        %{
          verb: "GET",
          path: "/auth/:provider",
          plug: "EmissaryWeb.AuthController",
          plug_opts: ":request",
          auth: "browser_oauth_start",
          live_view: nil,
          pipe_through: ["browser", "oauth_start_throttle"]
        },
        %{
          verb: "GET",
          path: "/auth/:provider/callback",
          plug: "EmissaryWeb.AuthController",
          plug_opts: ":callback",
          auth: "browser_oauth_callback",
          live_view: nil,
          pipe_through: ["browser", "oauth_callback_throttle"]
        },
        %{
          verb: "GET",
          path: "/auth/device/complete/:ticket",
          plug: "EmissaryWeb.AuthController",
          plug_opts: ":device_complete",
          auth: "browser_oauth_flow",
          live_view: nil,
          pipe_through: ["browser", "device_complete_throttle"]
        },
        %{
          verb: "DELETE",
          path: "/auth/logout",
          plug: "EmissaryWeb.AuthController",
          plug_opts: ":logout",
          auth: "handler_auth",
          live_view: nil,
          pipe_through: ["api", "auth_api_throttle"]
        },
        %{
          verb: "POST",
          path: "/auth/logout",
          plug: "PrismWeb.SessionController",
          plug_opts: ":logout",
          auth: "browser_public_auth",
          live_view: nil,
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/auth/oauth/callback",
          plug: "EmissaryWeb.OAuthCallbackController",
          plug_opts: ":callback",
          auth: "public_oauth_state",
          live_view: nil,
          pipe_through: ["oauth_callback", "oauth_callback_throttle"]
        },
        %{
          verb: "GET",
          path: "/auth/post-legal-accept",
          plug: "EmissaryWeb.AuthController",
          plug_opts: ":post_legal_accept",
          auth: "browser_oauth_flow",
          live_view: nil,
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/auth/whoami",
          plug: "EmissaryWeb.AuthController",
          plug_opts: ":whoami",
          auth: "handler_auth",
          live_view: nil,
          pipe_through: ["api", "auth_api_throttle"]
        },
        %{
          verb: "GET",
          path: "/chat",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":index",
          auth: "browser_authenticated",
          live_view: "PrismWeb.ChatLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "GET",
          path: "/claim-namespace",
          plug: "PrismWeb.ClaimNamespaceController",
          plug_opts: ":show",
          auth: "browser_claim_gate",
          live_view: nil,
          pipe_through: ["browser"]
        },
        %{
          verb: "POST",
          path: "/claim-namespace/submit",
          plug: "PrismWeb.ClaimNamespaceController",
          plug_opts: ":submit",
          auth: "browser_claim_gate",
          live_view: nil,
          pipe_through: ["browser", "claim_submit_throttle"]
        },
        %{
          verb: "POST",
          path: "/hooks/:slug",
          plug: "EmissaryWeb.WebhookController",
          plug_opts: ":invoke",
          auth: "webhook_hmac",
          live_view: nil,
          pipe_through: ["webhook"]
        },
        %{
          verb: "GET",
          path: "/legal/accept",
          plug: "PrismWeb.LegalAcceptController",
          plug_opts: ":show",
          auth: "browser_public_legal",
          live_view: nil,
          pipe_through: ["browser", "legal_accept_throttle"]
        },
        %{
          verb: "POST",
          path: "/legal/accept/submit",
          plug: "PrismWeb.LegalAcceptController",
          plug_opts: ":submit",
          auth: "browser_public_legal",
          live_view: nil,
          pipe_through: ["browser", "legal_accept_throttle"]
        },
        %{
          verb: "GET",
          path: "/login",
          plug: "Phoenix.LiveView.Plug",
          plug_opts: ":login",
          auth: "browser_public_login",
          live_view: "PrismWeb.LoginLive",
          pipe_through: ["browser"]
        },
        %{
          verb: "DELETE",
          path: "/mcp",
          plug: "EmissaryWeb.MCPController",
          plug_opts: ":method_not_allowed",
          auth: "authenticate_plug",
          live_view: nil,
          pipe_through: ["mcp"]
        },
        %{
          verb: "GET",
          path: "/mcp",
          plug: "EmissaryWeb.MCPController",
          plug_opts: ":method_not_allowed",
          auth: "authenticate_plug",
          live_view: nil,
          pipe_through: ["mcp"]
        },
        %{
          verb: "POST",
          path: "/mcp",
          plug: "EmissaryWeb.MCPController",
          plug_opts: ":handle",
          auth: "authenticate_plug",
          live_view: nil,
          pipe_through: ["mcp"]
        },
        %{
          verb: "GET",
          path: "/t/:athanor/:publisher/:tincture_name",
          plug: "EmissaryWeb.TinctureController",
          plug_opts: ":index",
          auth: "tincture_handler_auth",
          live_view: nil,
          pipe_through: ["tincture"]
        },
        %{
          verb: "GET",
          path: "/t/:athanor/:publisher/:tincture_name/*path",
          plug: "EmissaryWeb.TinctureController",
          plug_opts: ":asset",
          auth: "tincture_handler_auth",
          live_view: nil,
          pipe_through: ["tincture_asset"]
        },
        %{
          verb: "OPTIONS",
          path: "/t/:athanor/:publisher/:tincture_name/invoke",
          plug: "EmissaryWeb.TinctureController",
          plug_opts: ":invoke",
          auth: "tincture_handler_auth",
          live_view: nil,
          pipe_through: ["tincture_invoke"]
        },
        %{
          verb: "POST",
          path: "/t/:athanor/:publisher/:tincture_name/invoke",
          plug: "EmissaryWeb.TinctureController",
          plug_opts: ":invoke",
          auth: "tincture_handler_auth",
          live_view: nil,
          pipe_through: ["tincture_invoke"]
        },
        %{
          verb: "GET",
          path: "/t/access-token",
          plug: "EmissaryWeb.TinctureController",
          plug_opts: ":access_token",
          auth: "tincture_handler_auth",
          live_view: nil,
          pipe_through: ["tincture_invoke"]
        },
        %{
          verb: "OPTIONS",
          path: "/t/access-token",
          plug: "EmissaryWeb.TinctureController",
          plug_opts: ":access_token",
          auth: "tincture_handler_auth",
          live_view: nil,
          pipe_through: ["tincture_invoke"]
        }
      ]
    }
  }
}
