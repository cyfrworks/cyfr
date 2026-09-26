# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# The route map: every route provider's routes and pipelines, one section
# per provider. `CyfrWeb.RouterTest` holds it equal to the compiled table
# and to each provider's source, so a route, posture, pipeline or plug
# cannot move or vanish without this file changing with it.
%{
  providers: %{
    "CyfrWeb.Ingress.Router" => %{
      file: "apps/cyfr/lib/cyfr_web/ingress/router.ex",
      pipelines: %{
        "api" => [":accepts", "CyfrWeb.Plugs.ApiSecurityHeaders"],
        "auth_api_throttle" => ["CyfrWeb.Plugs.AuthRateLimit"],
        "auth_browser" => [
          "CyfrWeb.Plugs.Headless",
          ":accepts",
          ":fetch_session",
          ":fetch_live_flash",
          ":protect_from_forgery",
          ":put_secure_browser_headers",
          "CyfrWeb.Plugs.BrowserCSP"
        ],
        "authenticated_api" => [
          "CyfrWeb.Plugs.CallIdentity",
          ":accepts",
          "CyfrWeb.Plugs.ApiSecurityHeaders",
          "CyfrWeb.Plugs.CORS",
          "CyfrWeb.Plugs.MCPOrigin",
          "CyfrWeb.Plugs.MCPRateLimit",
          "CyfrWeb.Plugs.Authenticate"
        ],
        "device_complete_throttle" => ["CyfrWeb.Plugs.AuthRateLimit"],
        "health_throttle" => ["CyfrWeb.Plugs.AuthRateLimit"],
        "oauth_callback" => [":accepts", "CyfrWeb.Plugs.ApiSecurityHeaders"],
        "oauth_callback_throttle" => ["CyfrWeb.Plugs.AuthRateLimit"],
        "oauth_start_throttle" => ["CyfrWeb.Plugs.AuthRateLimit"],
        "tincture" => [
          "CyfrWeb.Plugs.CallIdentity",
          ":accepts",
          "CyfrWeb.Plugs.ApiSecurityHeaders",
          "CyfrWeb.Plugs.ScrubTinctureCredentials",
          "CyfrWeb.Plugs.TinctureRateLimit"
        ],
        "tincture_data" => [
          "CyfrWeb.Plugs.CallIdentity",
          ":accepts",
          "CyfrWeb.Plugs.ApiSecurityHeaders",
          "CyfrWeb.Plugs.CORS",
          "CyfrWeb.Plugs.ScrubTinctureCredentials",
          "CyfrWeb.Plugs.TinctureRateLimit"
        ],
        "tincture_asset" => [
          "CyfrWeb.Plugs.ApiSecurityHeaders",
          "CyfrWeb.Plugs.ScrubTinctureCredentials",
          "CyfrWeb.Plugs.TinctureRateLimit"
        ],
        "webhook" => [
          "CyfrWeb.Plugs.CallIdentity",
          ":accepts",
          "CyfrWeb.Plugs.ApiSecurityHeaders",
          "CyfrWeb.Plugs.WebhookRateLimit",
          "CyfrWeb.Plugs.VerifyWebhookSignature",
          "CyfrWeb.Plugs.WebhookIdempotency"
        ]
      },
      routes: [
        %{
          verb: "OPTIONS",
          path: "/_f/v1/action",
          plug: "CyfrWeb.Ingress.TinctureDataController",
          plug_opts: ":system_action",
          auth: "frame_credential",
          live_view: nil,
          pipe_through: ["tincture_data"]
        },
        %{
          verb: "POST",
          path: "/_f/v1/action",
          plug: "CyfrWeb.Ingress.TinctureDataController",
          plug_opts: ":system_action",
          auth: "frame_credential",
          live_view: nil,
          pipe_through: ["tincture_data"]
        },
        %{
          verb: "OPTIONS",
          path: "/_f/v1/invoke",
          plug: "CyfrWeb.Ingress.TinctureDataController",
          plug_opts: ":invoke",
          auth: "frame_credential",
          live_view: nil,
          pipe_through: ["tincture_data"]
        },
        %{
          verb: "POST",
          path: "/_f/v1/invoke",
          plug: "CyfrWeb.Ingress.TinctureDataController",
          plug_opts: ":invoke",
          auth: "frame_credential",
          live_view: nil,
          pipe_through: ["tincture_data"]
        },
        %{
          verb: "OPTIONS",
          path: "/_f/v1/stream",
          plug: "CyfrWeb.Ingress.TinctureDataController",
          plug_opts: ":stream",
          auth: "frame_credential",
          live_view: nil,
          pipe_through: ["tincture_data"]
        },
        %{
          verb: "POST",
          path: "/_f/v1/stream",
          plug: "CyfrWeb.Ingress.TinctureDataController",
          plug_opts: ":stream",
          auth: "frame_credential",
          live_view: nil,
          pipe_through: ["tincture_data"]
        },
        %{
          verb: "GET",
          path: "/_s/*path",
          plug: "CyfrWeb.Ingress.TinctureController",
          plug_opts: ":served",
          auth: "tincture_handler_auth",
          live_view: nil,
          pipe_through: ["tincture_asset"]
        },
        %{
          verb: "GET",
          path: "/api/executions/:id/events",
          plug: "CyfrWeb.Ingress.ExecutionEventsController",
          plug_opts: ":stream",
          auth: "authenticate_plug",
          live_view: nil,
          pipe_through: ["authenticated_api"]
        },
        %{
          verb: "GET",
          path: "/api/health",
          plug: "CyfrWeb.Ingress.HealthController",
          plug_opts: ":check",
          auth: "public_health",
          live_view: nil,
          pipe_through: ["api", "health_throttle"]
        },
        %{
          verb: "GET",
          path: "/api/health/ready",
          plug: "CyfrWeb.Ingress.HealthController",
          plug_opts: ":ready",
          auth: "public_health",
          live_view: nil,
          pipe_through: ["api", "health_throttle"]
        },
        %{
          verb: "GET",
          path: "/auth/:provider",
          plug: "CyfrWeb.Ingress.AuthController",
          plug_opts: ":request",
          auth: "browser_oauth_start",
          live_view: nil,
          pipe_through: ["auth_browser", "oauth_start_throttle"]
        },
        %{
          verb: "GET",
          path: "/auth/:provider/callback",
          plug: "CyfrWeb.Ingress.AuthController",
          plug_opts: ":callback",
          auth: "browser_oauth_callback",
          live_view: nil,
          pipe_through: ["auth_browser", "oauth_callback_throttle"]
        },
        %{
          verb: "GET",
          path: "/auth/device/complete/:ticket",
          plug: "CyfrWeb.Ingress.AuthController",
          plug_opts: ":device_complete",
          auth: "browser_oauth_flow",
          live_view: nil,
          pipe_through: ["auth_browser", "device_complete_throttle"]
        },
        %{
          verb: "DELETE",
          path: "/auth/logout",
          plug: "CyfrWeb.Ingress.AuthController",
          plug_opts: ":logout",
          auth: "handler_auth",
          live_view: nil,
          pipe_through: ["api", "auth_api_throttle"]
        },
        %{
          verb: "POST",
          path: "/auth/logout",
          plug: "CyfrWeb.Ingress.AuthController",
          plug_opts: ":browser_logout",
          auth: "browser_public_auth",
          live_view: nil,
          pipe_through: ["auth_browser"]
        },
        %{
          verb: "GET",
          path: "/auth/oauth/callback",
          plug: "CyfrWeb.Ingress.OAuthCallbackController",
          plug_opts: ":callback",
          auth: "public_oauth_state",
          live_view: nil,
          pipe_through: ["oauth_callback", "oauth_callback_throttle"]
        },
        %{
          verb: "GET",
          path: "/auth/post-legal-accept",
          plug: "CyfrWeb.Ingress.AuthController",
          plug_opts: ":post_legal_accept",
          auth: "browser_oauth_flow",
          live_view: nil,
          pipe_through: ["auth_browser"]
        },
        %{
          verb: "GET",
          path: "/auth/whoami",
          plug: "CyfrWeb.Ingress.AuthController",
          plug_opts: ":whoami",
          auth: "handler_auth",
          live_view: nil,
          pipe_through: ["api", "auth_api_throttle"]
        },
        %{
          verb: "POST",
          path: "/hooks/:slug",
          plug: "CyfrWeb.Ingress.WebhookController",
          plug_opts: ":invoke",
          auth: "webhook_hmac",
          live_view: nil,
          pipe_through: ["webhook"]
        },
        %{
          verb: "GET",
          path: "/t/:athanor/:publisher/:tincture_name",
          plug: "CyfrWeb.Ingress.TinctureController",
          plug_opts: ":index",
          auth: "tincture_handler_auth",
          live_view: nil,
          pipe_through: ["tincture"]
        },
        %{
          verb: "GET",
          path: "/t/:athanor/:publisher/:tincture_name/*path",
          plug: "CyfrWeb.Ingress.TinctureController",
          plug_opts: ":asset",
          auth: "tincture_handler_auth",
          live_view: nil,
          pipe_through: ["tincture_asset"]
        }
      ]
    },
    "Emissary.Router" => %{
      file: "apps/cyfr/lib/emissary/router.ex",
      pipelines: %{
        "mcp" => [
          "CyfrWeb.Plugs.CallIdentity",
          ":accepts",
          "CyfrWeb.Plugs.ApiSecurityHeaders",
          "CyfrWeb.Plugs.CORS",
          "CyfrWeb.Plugs.MCPOrigin",
          "CyfrWeb.Plugs.MCPRateLimit",
          "CyfrWeb.Plugs.Authenticate",
          "Emissary.Web.Plugs.MCPRequestMetadata"
        ]
      },
      routes: [
        %{
          verb: "DELETE",
          path: "/mcp",
          plug: "Emissary.Web.MCPController",
          plug_opts: ":method_not_allowed",
          auth: "authenticate_plug",
          live_view: nil,
          pipe_through: ["mcp"]
        },
        %{
          verb: "GET",
          path: "/mcp",
          plug: "Emissary.Web.MCPController",
          plug_opts: ":method_not_allowed",
          auth: "authenticate_plug",
          live_view: nil,
          pipe_through: ["mcp"]
        },
        %{
          verb: "POST",
          path: "/mcp",
          plug: "Emissary.Web.MCPController",
          plug_opts: ":handle",
          auth: "authenticate_plug",
          live_view: nil,
          pipe_through: ["mcp"]
        }
      ]
    },
    "Prism.Router" => %{
      file: "apps/cyfr/lib/prism/router.ex",
      pipelines: %{
        "attachment" => [
          "CyfrWeb.Plugs.Headless",
          ":fetch_session",
          ":protect_from_forgery",
          ":put_secure_browser_headers",
          "CyfrWeb.Plugs.ApiSecurityHeaders"
        ],
        "attachment_throttle" => ["CyfrWeb.Plugs.AuthRateLimit"],
        "browser" => [
          "CyfrWeb.Plugs.Headless",
          ":accepts",
          ":fetch_session",
          ":fetch_live_flash",
          ":put_root_layout",
          ":protect_from_forgery",
          ":put_secure_browser_headers",
          "CyfrWeb.Plugs.BrowserCSP"
        ],
        "claim_submit_throttle" => ["CyfrWeb.Plugs.AuthRateLimit"],
        "legal_accept_throttle" => ["CyfrWeb.Plugs.AuthRateLimit"]
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
        }
      ]
    }
  }
}
