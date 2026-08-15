# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP do
  @moduledoc """
  MCP tool and resource provider for Sanctum identity & authorization service.

  ## Tools

  - `session` - Session management (login, logout, whoami)
  - `key` - API key management (create, get, list, revoke, rotate)
  - `tincture_visibility` - Tincture public/private visibility (set, get)

  ## Resources

  - `sanctum://identity` - Current user identity
  - `sanctum://permissions` - Current user permissions

  ## Architecture Note

  Tool definitions live next to their implementation under `lib/sanctum`.
  Authentication tools (login/logout) are handled differently as they
  require browser redirects.
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
    []
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
        annotations: %{
          readOnlyHint: false,
          destructiveHint: false,
          # Anonymous-allowed: `whoami` and the device-flow login actions need
          # to work before a credential exists, and `logout` only ever
          # destroys the caller's own session.
          actions: %{
            "login" => %{kind: :write, planes: [:external], auth: :anonymous},
            "logout" => %{kind: :write, planes: [:external], auth: :anonymous},
            "whoami" => %{kind: :read, planes: [:external], auth: :anonymous},
            "device_init" => %{kind: :write, planes: [:external], auth: :anonymous},
            "device_poll" => %{kind: :write, planes: [:external], auth: :anonymous}
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
                  "`/auth/<provider>`. Push-token identity (cyfr.run) lives on the " <>
                  "separate `registry` tool under Compendium — see its " <>
                  "`probe` and `claim_personal` actions."
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
        name: "oauth",
        title: "OAuth Provider Configuration",
        description:
          "Store OAuth app client credentials per provider. Grants are connection-keyed: " <>
            "start them with vault.authorize.",
        annotations: %{
          readOnlyHint: false,
          destructiveHint: false,
          actions: %{
            # External only, like every other credential write (key.create,
            # vault.create, webhook.create). This one writes the operator's
            # OAuth *client* secret, so a component reaching it from inside
            # the sandbox would be the widest of the set, not the narrowest.
            "set_client" => %{kind: :write, planes: [:external], permission: :vault_write}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["set_client"],
              "description" => "Action to perform"
            },
            "provider" => %{
              "type" => "string",
              "description" => "OAuth provider name (e.g. 'google')"
            },
            "client_id" => %{
              "type" => "string",
              "description" => "The OAuth app's client id"
            },
            "client_secret" => %{
              "type" => "string",
              "description" => "The OAuth app's client secret (omit for public clients)"
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
            "create" => %{kind: :write, planes: [:external], permission: :admin},
            "get" => %{kind: :read, planes: [:external], permission: :admin},
            "list" => %{kind: :read, planes: [:external], permission: :admin},
            "revoke" => %{kind: :write, planes: [:external], permission: :admin},
            "rotate" => %{kind: :write, planes: [:external], permission: :admin}
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
        name: "tincture_visibility",
        title: "Tincture Visibility",
        description:
          "Manage tincture public/private visibility. Visibility is an operator decision stored in Sanctum, not in manifests.",
        annotations: %{
          readOnlyHint: false,
          destructiveHint: false,
          actions: %{
            "set" => %{kind: :write, planes: [:external], permission: :execute},
            "get" => %{kind: :read, planes: [:external, :in_chain], permission: :storage_read}
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
            # create/update also require the registration's consent binding —
            # a conditional Authz check the annotation cannot express; it
            # stays in Sanctum.Webhook.
            "create" => %{kind: :write, planes: [:external], permission: :admin},
            "list" => %{kind: :read, planes: [:external, :in_chain], permission: :storage_read},
            "get" => %{kind: :read, planes: [:external, :in_chain], permission: :storage_read},
            "update" => %{kind: :write, planes: [:external], permission: :admin},
            "revoke" => %{kind: :write, planes: [:external], permission: :admin},
            "rotate" => %{kind: :write, planes: [:external], permission: :admin}
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
            "profile_id" => %{
              "type" => "string",
              "description" =>
                "Profile the webhook fires under (required on create). Deliveries run " <>
                  "with this profile's consented authority; binding takes the consent " <>
                  "authorization class, so an interactive session or consent-capable key is needed."
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
                "HTTP header carrying a unix-seconds timestamp for replay protection. When set, HMAC payload becomes '<ts>.<raw_body>' (Stripe-style) and requests outside ±5 min are rejected. LEFT UNSET, A CAPTURED DELIVERY CAN BE REPLAYED INDEFINITELY — a signature stays valid forever, so anyone who reads one off a proxy log or mirrored traffic can re-fire the bound component. Set it to whatever the sender emits ('stripe-signature' carries its own; GitHub has no timestamp header). Empty string clears the field."
            },
            "idempotency_key_header" => %{
              "type" => "string",
              "description" =>
                "HTTP header carrying a unique event id (e.g. 'x-github-delivery' for GitHub, the Stripe event id for Stripe). When set, repeat deliveries with the same id within ~24h short-circuit to a 200 with status 'duplicate'. Left unset, a sender's own retries each run the bound component again. Empty string clears the field."
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
      },
      %{
        name: "vault",
        title: "Vault Connections",
        description:
          "Manage vault entries (Connections) — the operator's credentials, shared across " <>
            "profiles through consent edges. Material is sealed at rest and never read back; " <>
            "rotate replaces material without re-consent, rebind changes what the credential " <>
            "talks to and blocks affected profiles until re-consented.",
        annotations: %{
          readOnlyHint: false,
          destructiveHint: true,
          actions: %{
            # Mutations are interactive-consent surfaces (OIDC sessions only,
            # by owner decision — no permission conjunct); list admits the
            # staging class so keys can enumerate entries.
            "list" => %{kind: :read, planes: [:external], consent: :staging},
            "create" => %{kind: :write, planes: [:external], consent: :interactive},
            "rename" => %{kind: :write, planes: [:external], consent: :interactive},
            "rotate" => %{kind: :write, planes: [:external], consent: :interactive},
            "rebind" => %{kind: :write, planes: [:external], consent: :interactive},
            "authorize" => %{kind: :write, planes: [:external], consent: :interactive},
            "revoke" => %{kind: :destructive, planes: [:external], consent: :interactive},
            "delete" => %{kind: :destructive, planes: [:external], consent: :interactive}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => [
                "list",
                "create",
                "rename",
                "rotate",
                "rebind",
                "authorize",
                "revoke",
                "delete"
              ],
              "description" => "Action to perform"
            },
            "id" => %{"type" => "string", "description" => "Vault entry id (vlt_…)"},
            "name" => %{
              "type" => "string",
              "description" => "Connection label — unique among living entries in the tenant"
            },
            "kind" => %{
              "type" => "string",
              "enum" => ["api_key", "oauth", "bundle"],
              "description" => "What the entry holds"
            },
            "provider_hint" => %{
              "type" => "string",
              "description" => "Immutable provider tag (e.g. 'google'); set at create only"
            },
            "fields" => %{
              "type" => "object",
              "description" => "Secret material as name → value; names mirror field_names"
            },
            "expected_payload_rev" => %{
              "type" => "integer",
              "description" => "CAS token for rotate — the revision the caller last saw"
            },
            "oauth_endpoints" => %{
              "type" => "object",
              "description" => "Binding field: token endpoint etc. Changing it is a rebind."
            },
            "oauth_scopes" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Binding field: scopes this credential was authorized for"
            },
            "field_names" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Binding field: the material's field schema (rebind only)"
            }
          },
          "required" => ["action"]
        }
      },
      %{
        name: "profile",
        title: "Profiles & Consent",
        description:
          "Grant, inspect and revoke profiles — the consent walk. plan stages the facts and " <>
            "candidates, preview renders exactly what would be granted and mints the proof, " <>
            "commit verifies the proof against a live recomputation and writes an immutable " <>
            "revision. Nothing is granted outside this walk.",
        annotations: %{
          readOnlyHint: false,
          destructiveHint: true,
          actions: %{
            # Dispatch applies the coarse consent class; the domain applies
            # the exact one (commit's digest-pinned key-capability arm lives
            # in Sanctum.Consent.Commit and stays there).
            "plan" => %{kind: :write, planes: [:external], consent: :staging},
            "preview" => %{kind: :write, planes: [:external], consent: :staging},
            "commit" => %{kind: :write, planes: [:external], consent: :staging},
            "publish" => %{kind: :write, planes: [:external], consent: :staging},
            "list" => %{kind: :read, planes: [:external], consent: :staging},
            "revoke" => %{kind: :destructive, planes: [:external], consent: :interactive}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["plan", "preview", "commit", "publish", "list", "revoke"],
              "description" => "Action to perform"
            },
            "need_ids" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" =>
                "publish only: edge keys whose credentials the public profile keeps " <>
                  "(default none — expose without credentials)"
            },
            "durable_storage" => %{
              "type" => "boolean",
              "description" =>
                "publish only: allow durable writes (default false — read-only storage)"
            },
            "ref" => %{
              "type" => "string",
              "description" => "Component reference to grant (name-level or versioned)"
            },
            "label" => %{"type" => "string", "description" => "Profile label (default 'default')"},
            "kind" => %{"type" => "string", "enum" => ["owner", "public"]},
            "profile_id" => %{"type" => "string", "description" => "Profile id (list/revoke)"},
            "decisions" => %{
              "type" => "object",
              "description" =>
                "The operator's choices: ref, scope, invoke_mode, bindings " <>
                  "[{need:'@ingress', entry_id, fields, scopes}], override, limits"
            },
            "plan_token" => %{"type" => "string", "description" => "From plan"},
            "proof" => %{"type" => "string", "description" => "From preview"},
            "commit_digest" => %{
              "type" => "string",
              "description" => "The digest preview rendered — what is being approved"
            },
            "expected_consent_revision" => %{
              "type" => "integer",
              "description" => "The revision plan reported"
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
  def handle("oauth", ctx, args), do: Sanctum.MCP.OAuthTool.handle(ctx, args)
  def handle("key", ctx, args), do: Sanctum.MCP.KeyTool.handle(ctx, args)

  def handle("tincture_visibility", ctx, args),
    do: Sanctum.MCP.TinctureVisibilityTool.handle(ctx, args)

  def handle("webhook", ctx, args), do: Sanctum.MCP.WebhookTool.handle(ctx, args)
  def handle("vault", ctx, args), do: Sanctum.MCP.VaultTool.handle(ctx, args)
  def handle("profile", ctx, args), do: Sanctum.MCP.ProfileTool.handle(ctx, args)

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end
end
