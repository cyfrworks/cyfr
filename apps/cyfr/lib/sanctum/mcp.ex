# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP do
  @moduledoc """
  MCP tool and resource provider for Sanctum identity & authorization service.

  ## Tools

  - `session` - Session management (login, logout, whoami)
  - `secret` - Secret management (set, get, delete, list, grant, revoke)
  - `permission` - Permission management (get, set, list)
  - `key` - API key management (create, get, list, revoke, rotate)
  - `policy` - Host Policy management (get, set, patch, delete, list)
  - `tincture_visibility` - Tincture public/private visibility (set, get)

  ## Resources

  - `sanctum://identity` - Current user identity
  - `sanctum://permissions` - Current user permissions

  ## Architecture Note

  This module lives in the `sanctum` app, keeping tool definitions
  close to their implementation. Authentication tools (login/logout)
  are handled differently as they require browser redirects.
  """

  @behaviour Emissary.MCP.ToolProvider

  alias Sanctum.Context
  alias Sanctum.MCP.Shared

  # ============================================================================
  # ResourceProvider Protocol
  # ============================================================================

  @doc """
  Returns available Sanctum resources (concrete URIs only).
  """
  def resources do
    [
      %{
        uri: "sanctum://identity",
        name: "Current Identity",
        description: "Current authenticated user identity",
        mimeType: "application/json"
      },
      %{
        uri: "sanctum://permissions",
        name: "User Permissions",
        description: "Current user's granted permissions",
        mimeType: "application/json"
      }
    ]
  end

  @doc """
  Returns Sanctum resource templates (RFC 6570 URI templates).
  """
  def resource_templates do
    [
      %{
        uriTemplate: "sanctum://permissions/{reference}",
        name: "Resource Permissions",
        description: "Access permissions for a specific resource",
        mimeType: "application/json"
      }
    ]
  end

  @doc """
  Read a resource by URI.
  """
  def read(%Context{} = ctx, "sanctum://identity") do
    content =
      case Jason.encode(%{user_id: ctx.user_id, org_id: ctx.org_id, scope: ctx.scope}) do
        {:ok, json} -> json
        {:error, _} -> ~s({"error":"encoding_error"})
      end

    {:ok, %{content: content, mimeType: "application/json"}}
  end

  def read(%Context{} = ctx, "sanctum://permissions") do
    content =
      case Jason.encode(%{permissions: Shared.format_permissions(ctx.permissions)}) do
        {:ok, json} -> json
        {:error, _} -> ~s({"error":"encoding_error"})
      end

    {:ok, %{content: content, mimeType: "application/json"}}
  end

  def read(%Context{} = ctx, "sanctum://permissions/" <> reference) do
    case Sanctum.Permission.get_for_resource(ctx, reference) do
      {:ok, perms} ->
        content =
          case Jason.encode(%{reference: reference, permissions: perms}) do
            {:ok, json} -> json
            {:error, _} -> ~s({"error":"encoding_error"})
          end

        {:ok, %{content: content, mimeType: "application/json"}}

      {:error, _} ->
        content =
          case Jason.encode(%{reference: reference, permissions: []}) do
            {:ok, json} -> json
            {:error, _} -> ~s({"error":"encoding_error"})
          end

        {:ok, %{content: content, mimeType: "application/json"}}
    end
  end

  def read(_ctx, uri) do
    {:error, "Unknown resource URI: #{uri}"}
  end

  # ============================================================================
  # ToolProvider Protocol
  # ============================================================================

  def tools do
    [
      %{
        name: "session",
        title: "Session Management",
        description:
          "Manage user sessions — login, logout, get local identity, or run device-flow OAuth. " <>
            "Registry identity (push tokens, namespaces) is a separate `registry` tool under Compendium.",
        # Anonymous-allowed: `whoami` and the device-flow login actions need
        # to work before the user is authenticated.
        requires_auth: false,
        annotations: %{
          readOnlyHint: false,
          destructiveHint: false,
          actions: %{
            "login" => %{kind: :write, planes: [:external]},
            "logout" => %{kind: :write, planes: [:external]},
            "whoami" => %{kind: :read, planes: [:external]},
            "device_init" => %{kind: :write, planes: [:external]},
            "device_poll" => %{kind: :write, planes: [:external]}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => [
                "login",
                "logout",
                "whoami",
                "device_init",
                "device_poll"
              ],
              "description" =>
                "Action to perform. `device_init`/`device_poll` require the " <>
                  "default OAuth provider (`auth_provider = Sanctum.Auth.OAuth`); " <>
                  "deployments with a configured OIDC auth provider authenticate " <>
                  "via the web OIDC flow at " <>
                  "`/auth/<provider>`. Push-token identity (cyfr.run) is a " <>
                  "separate `registry` tool under Compendium — the legacy " <>
                  "`registry-login` action is no longer supported; use the " <>
                  "`registry` tool's `probe` and `claim_personal` actions instead."
            },
            "provider" => %{
              "type" => "string",
              "enum" => ["github", "google"],
              "description" => "OAuth provider for device flow"
            },
            "device_code" => %{
              "type" => "string",
              "description" => "Device code from device_init (for device_poll action)"
            }
          },
          "required" => ["action"]
        }
      },
      %{
        name: "secret",
        title: "Secret Management",
        description: "Manage encrypted secrets - set, get, delete, list, grant, or revoke access",
        annotations: %{
          readOnlyHint: false,
          destructiveHint: true,
          actions: %{
            "set" => %{kind: :write, planes: [:external]},
            "get" => %{kind: :read, planes: [:external, :in_chain]},
            "delete" => %{kind: :destructive, planes: [:external]},
            "list" => %{kind: :read, planes: [:external, :in_chain]},
            "grant" => %{kind: :write, planes: [:external]},
            "revoke" => %{kind: :write, planes: [:external]},
            "can_access" => %{kind: :read, planes: [:external, :in_chain]},
            "list_component_grants" => %{kind: :read, planes: [:external, :in_chain]}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => [
                "set",
                "get",
                "delete",
                "list",
                "grant",
                "revoke",
                "can_access",
                "list_component_grants"
              ],
              "description" => "Action to perform"
            },
            "name" => %{
              "type" => "string",
              "description" => "Name of the secret"
            },
            "value" => %{
              "type" => "string",
              "description" => "Secret value (for set action)"
            },
            "component_ref" => %{
              "type" => "string",
              "description" =>
                "Component reference (e.g., 'catalyst:local.stripe-catalyst' for all versions, or 'catalyst:local.stripe-catalyst:1.0.0' for specific version). Grants default to name-level unless pin_version is true."
            },
            "pin_version" => %{
              "type" => "boolean",
              "description" =>
                "When true, store version-specific grant instead of promoting to name-level (default: false)"
            }
          },
          "required" => ["action"]
        }
      },
      %{
        name: "oauth",
        title: "OAuth Management",
        description:
          "Manage OAuth providers for catalysts - setup credentials, authorize, check status, or revoke",
        annotations: %{
          readOnlyHint: false,
          destructiveHint: false,
          actions: %{
            "authorize" => %{kind: :write, planes: [:external, :in_chain]},
            "status" => %{kind: :read, planes: [:external, :in_chain]},
            "revoke" => %{kind: :write, planes: [:external, :in_chain]},
            "set_client" => %{kind: :write, planes: [:external, :in_chain]}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["authorize", "status", "revoke", "set_client"],
              "description" => "Action to perform"
            },
            "provider" => %{
              "type" => "string",
              "description" =>
                "OAuth provider name (must match manifest oauth block key, e.g. 'google')"
            },
            "client_id" => %{
              "type" => "string",
              "description" => "For set_client: the OAuth app's client id"
            },
            "client_secret" => %{
              "type" => "string",
              "description" =>
                "For set_client: the OAuth app's client secret (omit for public clients)"
            },
            "component_ref" => %{
              "type" => "string",
              "description" =>
                "Component reference (e.g. 'catalyst:local.gmail'). Versionless preferred — tokens are shared across versions by default."
            },
            "pin_version" => %{
              "type" => "boolean",
              "description" =>
                "When true, store version-specific token instead of promoting to name-level (default: false)"
            }
          },
          "required" => ["action"]
        }
      },
      %{
        name: "permission",
        title: "Permission Management",
        description: "Manage RBAC permissions - get, set, or list permissions",
        annotations: %{
          readOnlyHint: false,
          destructiveHint: false,
          actions: %{
            "get" => %{kind: :read, planes: [:external]},
            "set" => %{kind: :write, planes: [:external]},
            "list" => %{kind: :read, planes: [:external]}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["get", "set", "list"],
              "description" => "Action to perform"
            },
            "subject" => %{
              "type" => "string",
              "description" => "User or resource identifier"
            },
            "permissions" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "List of permissions to set"
            },
            "resource" => %{
              "type" => "string",
              "description" => "Resource path (e.g., 'components/...')"
            }
          },
          "required" => ["action"]
        }
      },
      %{
        name: "key",
        title: "API Key Management",
        description: "Manage API keys - create, get, list, revoke, or rotate keys",
        annotations: %{
          readOnlyHint: false,
          destructiveHint: false,
          actions: %{
            "create" => %{kind: :write, planes: [:external]},
            "get" => %{kind: :read, planes: [:external]},
            "list" => %{kind: :read, planes: [:external]},
            "revoke" => %{kind: :write, planes: [:external]},
            "rotate" => %{kind: :write, planes: [:external]}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["create", "get", "list", "revoke", "rotate"],
              "description" => "Action to perform"
            },
            "name" => %{
              "type" => "string",
              "description" => "Human-readable name for the key"
            },
            "key" => %{
              "type" => "string",
              "description" => "API key value (for validation)"
            },
            "type" => %{
              "type" => "string",
              "enum" => ["application", "service", "admin"],
              "description" =>
                "Key type: application (frontend), service (backend), admin (CI/CD)"
            },
            "scope" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Permissions scope for the key"
            },
            "rate_limit" => %{
              "type" => "string",
              "description" => "Rate limit (e.g., '100/1m')"
            },
            "ip_allowlist" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "List of allowed IPs/CIDRs (e.g., ['192.168.1.0/24', '10.0.0.1'])"
            }
          },
          "required" => ["action"]
        }
      },
      %{
        name: "policy",
        title: "Host Policy Management",
        description: "Manage host policies - get, set, patch, delete, or list policies",
        annotations: %{
          readOnlyHint: false,
          destructiveHint: true,
          actions: %{
            "get" => %{kind: :read, planes: [:external, :in_chain]},
            "set" => %{kind: :write, planes: [:external]},
            "patch" => %{kind: :write, planes: [:external]},
            "delete" => %{kind: :destructive, planes: [:external]},
            "list" => %{kind: :read, planes: [:external, :in_chain]},
            "get_effective" => %{kind: :read, planes: [:external, :in_chain]},
            "get_ceiling" => %{kind: :read, planes: [:external, :in_chain]},
            "check_rate_limit" => %{kind: :read, planes: [:external, :in_chain]},
            "get_type_default" => %{kind: :read, planes: [:external, :in_chain]},
            "set_type_default" => %{kind: :write, planes: [:external]},
            "delete_type_default" => %{kind: :destructive, planes: [:external]},
            "list_type_defaults" => %{kind: :read, planes: [:external, :in_chain]},
            "migrate" => %{kind: :write, planes: [:external]}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => [
                "get",
                "set",
                "patch",
                "delete",
                "list",
                "get_effective",
                "get_ceiling",
                "check_rate_limit",
                "get_type_default",
                "set_type_default",
                "delete_type_default",
                "list_type_defaults",
                "migrate"
              ],
              "description" => "Action to perform"
            },
            "component_ref" => %{
              "type" => "string",
              "description" =>
                "Component reference (e.g., 'catalyst:local.stripe-catalyst' for name-level or 'catalyst:local.stripe-catalyst:1.0.0' for version-specific). Policies default to name-level (identity-based) unless pin_version is true."
            },
            "pin_version" => %{
              "type" => "boolean",
              "description" =>
                "When true, store version-specific policy instead of promoting to name-level (default: false)"
            },
            "field" => %{
              "type" => "string",
              "description" => "Policy field to update (for patch action)"
            },
            "value" => %{
              "type" => "string",
              "description" => "Value to set (for patch action)"
            },
            "policy" => %{
              "type" => "object",
              "description" => "Full policy map (for set/set_type_default action)"
            },
            "component_type" => %{
              "type" => "string",
              "enum" => Sanctum.ComponentRef.valid_types(),
              "description" => "Component type (for type default actions)"
            }
          },
          "required" => ["action"]
        }
      },
      %{
        name: "tincture_visibility",
        title: "Tincture Visibility",
        description:
          "Manage tincture public/private visibility. Visibility is an operator decision stored in Sanctum, not in manifests.",
        annotations: %{
          readOnlyHint: false,
          destructiveHint: false,
          actions: %{
            "set" => %{kind: :write, planes: [:external]},
            "get" => %{kind: :read, planes: [:external, :in_chain]}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["set", "get"],
              "description" => "Action to perform"
            },
            "publisher" => %{
              "type" => "string",
              "description" => "Tincture publisher (e.g. 'local', 'moonmoon69')"
            },
            "name" => %{
              "type" => "string",
              "description" => "Tincture name"
            },
            "public" => %{
              "type" => "boolean",
              "description" =>
                "Set to true for public visibility, false for private (for set action)"
            }
          },
          "required" => ["action", "publisher", "name"]
        }
      },
      %{
        name: "webhook",
        title: "Webhook Management",
        description:
          "Manage inbound webhooks — stable URLs that accept HMAC-SHA256-signed POSTs and dispatch to a target component. Secrets are returned plaintext exactly once on create/rotate.",
        annotations: %{
          readOnlyHint: false,
          destructiveHint: false,
          actions: %{
            "create" => %{kind: :write, planes: [:external]},
            "list" => %{kind: :read, planes: [:external, :in_chain]},
            "get" => %{kind: :read, planes: [:external, :in_chain]},
            "update" => %{kind: :write, planes: [:external]},
            "revoke" => %{kind: :write, planes: [:external]},
            "rotate" => %{kind: :write, planes: [:external]}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["create", "list", "get", "update", "revoke", "rotate"],
              "description" => "Action to perform"
            },
            "name" => %{
              "type" => "string",
              "description" => "Human-readable name for the webhook (unique per tenant)"
            },
            "target_ref" => %{
              "type" => "string",
              "description" =>
                "Component reference to invoke on inbound delivery (e.g. 'f:local.handle-github-push')"
            },
            "input_template" => %{
              "type" => "object",
              "description" =>
                "JSON object merged into the invocation envelope. The reserved key '_webhook' is set by the controller and must not be present here. Max 16 KB."
            },
            "signature_header" => %{
              "type" => "string",
              "description" =>
                "HTTP header carrying the HMAC signature (default 'x-cyfr-signature'). Use 'x-hub-signature-256' for GitHub, 'stripe-signature' for Stripe, etc."
            },
            "timestamp_header" => %{
              "type" => "string",
              "description" =>
                "Optional. HTTP header carrying a unix-seconds timestamp for replay protection. When set, HMAC payload becomes '<ts>.<raw_body>' (Stripe-style) and requests outside ±5 min are rejected. Empty string clears the field."
            },
            "idempotency_key_header" => %{
              "type" => "string",
              "description" =>
                "Optional. HTTP header carrying a unique event id (e.g. 'x-github-delivery' for GitHub, the Stripe event id for Stripe). When set, repeat deliveries with the same id within ~24h short-circuit to a 200 with status 'duplicate'. Empty string clears the field."
            },
            "description" => %{
              "type" => "string",
              "description" => "Free-form description for operator reference"
            },
            "rate_limit" => %{
              "type" => "string",
              "description" =>
                "Per-slug rate limit (e.g. '100/1m', '1000/1h'). Default 100/1m if unset."
            }
          },
          "required" => ["action"]
        }
      }
    ]
  end

  # ============================================================================
  # Tool Handlers — delegated to per-tool modules
  # ============================================================================

  def handle("session", ctx, args), do: Sanctum.MCP.SessionTool.handle(ctx, args)
  def handle("secret", ctx, args), do: Sanctum.MCP.SecretTool.handle(ctx, args)
  def handle("oauth", ctx, args), do: Sanctum.MCP.OAuthTool.handle(ctx, args)
  def handle("permission", ctx, args), do: Sanctum.MCP.PermissionTool.handle(ctx, args)
  def handle("key", ctx, args), do: Sanctum.MCP.KeyTool.handle(ctx, args)
  def handle("policy", ctx, args), do: Sanctum.MCP.PolicyTool.handle(ctx, args)

  def handle("tincture_visibility", ctx, args),
    do: Sanctum.MCP.TinctureVisibilityTool.handle(ctx, args)

  def handle("webhook", ctx, args), do: Sanctum.MCP.WebhookTool.handle(ctx, args)

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end
end
