defmodule Sanctum.MCP do
  @moduledoc """
  MCP tool and resource provider for Sanctum identity & authorization service.

  ## Tools

  - `session` - Session management (login, logout, whoami)
  - `secret` - Secret management (set, get, delete, list, grant, revoke)
  - `permission` - Permission management (get, set, list)
  - `key` - API key management (create, get, list, revoke, rotate)
  - `policy` - Host Policy management (get, set, update_field, delete, list)

  ## Resources

  - `sanctum://identity` - Current user identity
  - `sanctum://permissions` - Current user permissions

  ## Architecture Note

  This module lives in the `sanctum` app, keeping tool definitions
  close to their implementation. Authentication tools (login/logout)
  are handled differently as they require browser redirects.
  """

  @behaviour Emissary.MCP.ToolProvider

  require Logger

  alias Sanctum.Context

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
      case Jason.encode(%{permissions: format_permissions(ctx.permissions)}) do
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
          "Manage user sessions - login, logout, get identity, or device flow authentication",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => [
                "login",
                "logout",
                "whoami",
                "device-init",
                "device-poll",
                "registry-login"
              ],
              "description" => "Action to perform"
            },
            "registry" => %{
              "type" => "string",
              "description" => "Registry hostname (for registry-login action)"
            },
            "type" => %{
              "type" => "string",
              "enum" => ["basic", "bearer", "oauth2_client"],
              "description" => "Credential type (for registry-login action, default: basic)"
            },
            "username" => %{
              "type" => "string",
              "description" => "Username (for basic registry-login)"
            },
            "password" => %{
              "type" => "string",
              "description" => "Password or token (for basic registry-login)"
            },
            "token" => %{
              "type" => "string",
              "description" => "Bearer token (for bearer registry-login)"
            },
            "client_id" => %{
              "type" => "string",
              "description" => "OAuth2 client ID (for oauth2_client registry-login)"
            },
            "client_secret" => %{
              "type" => "string",
              "description" => "OAuth2 client secret (for oauth2_client registry-login)"
            },
            "token_url" => %{
              "type" => "string",
              "description" => "OAuth2 token URL (for oauth2_client registry-login)"
            },
            "provider" => %{
              "type" => "string",
              "enum" => ["github"],
              "description" => "OAuth provider for device flow"
            },
            "device_code" => %{
              "type" => "string",
              "description" => "Device code from device-init (for device-poll action)"
            }
          },
          "required" => ["action"]
        }
      },
      %{
        name: "secret",
        title: "Secret Management",
        description: "Manage encrypted secrets - set, get, delete, list, grant, or revoke access",
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
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["authorize", "status", "revoke"],
              "description" => "Action to perform"
            },
            "provider" => %{
              "type" => "string",
              "description" =>
                "OAuth provider name (must match manifest oauth block key, e.g. 'google')"
            },
            "component_ref" => %{
              "type" => "string",
              "description" =>
                "Component reference (e.g. 'catalyst:local.gmail:0.1.0')"
            },
          },
          "required" => ["action"]
        }
      },
      %{
        name: "permission",
        title: "Permission Management",
        description: "Manage RBAC permissions - get, set, or list permissions",
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
        description: "Manage host policies - get, set, update_field, delete, or list policies",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => [
                "get",
                "set",
                "update_field",
                "delete",
                "list",
                "get_effective",
                "get_ceiling",
                "check_rate_limit",
                "get_type_default",
                "set_type_default",
                "delete_type_default",
                "list_type_defaults",
                "migrate_to_name_level"
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
              "description" => "Policy field to update (for update_field action)"
            },
            "value" => %{
              "type" => "string",
              "description" => "Value to set (for update_field action)"
            },
            "policy" => %{
              "type" => "object",
              "description" => "Full policy map (for set/set_type_default action)"
            },
            "component_type" => %{
              "type" => "string",
              "enum" => ["catalyst", "formula", "reagent"],
              "description" => "Component type (for type default actions)"
            }
          },
          "required" => ["action"]
        }
      }
    ]
  end

  # ============================================================================
  # Session Tool
  # ============================================================================

  def handle("session", _ctx, %{"action" => "ping"}), do: {:ok, %{status: "ok"}}

  def handle("session", %Context{authenticated: false}, %{"action" => "whoami"}) do
    {:error, "Not authenticated. Run 'cyfr login' to sign in."}
  end

  def handle("session", %Context{} = ctx, %{"action" => "whoami"}) do
    {:ok,
     %{
       user_id: ctx.user_id,
       org_id: ctx.org_id,
       scope: ctx.scope,
       permissions: format_permissions(ctx.permissions),
       registry: Compendium.Registry.Identity.identity(ctx)
     }}
  end

  def handle("session", %Context{} = _ctx, %{"action" => "login"}) do
    # Login requires browser redirect in Sanctum
    {:ok, %{message: "Login requires browser authentication", redirect: "/auth/login"}}
  end

  def handle("session", %Context{} = _ctx, %{"action" => "logout"}) do
    # Logout is a no-op in Sanctum (stateless)
    {:ok, %{message: "Logged out successfully"}}
  end

  def handle("session", %Context{} = _ctx, %{"action" => "device-init"} = args) do
    provider = Map.get(args, "provider", "github")

    case Sanctum.Auth.DeviceFlow.init_device_flow(provider) do
      {:ok, device_info} ->
        {:ok,
         %{
           device_code: device_info.device_code,
           user_code: device_info.user_code,
           verification_uri: device_info.verification_uri,
           expires_in: device_info.expires_in,
           interval: device_info.interval
         }}

      {:error, {:client_id_not_configured, provider}} ->
        {:error,
         "#{provider} client ID not configured. Set CYFR_#{String.upcase(to_string(provider))}_CLIENT_ID"}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to initialize device flow: #{inspect(reason)}")
        {:error, "Failed to initialize device flow"}
    end
  end

  def handle(
        "session",
        %Context{} = _ctx,
        %{"action" => "device-poll", "device_code" => device_code} = args
      ) do
    provider = Map.get(args, "provider", "github")

    case Sanctum.Auth.DeviceFlow.poll_for_session(provider, device_code) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:client_id_not_configured, provider}} ->
        {:error,
         "#{provider} client ID not configured. Set CYFR_#{String.upcase(to_string(provider))}_CLIENT_ID"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to poll for token: #{inspect(reason)}")
        {:error, "Failed to poll for token"}
    end
  end

  def handle("session", _ctx, %{"action" => "device-poll"}) do
    {:error, "Missing required argument: device_code"}
  end

  def handle("session", %Context{} = ctx, %{"action" => "registry-login"} = args) do
    registry = Map.get(args, "registry", "registry.cyfr.run")
    cred_type = Map.get(args, "type", "basic")

    credential =
      case cred_type do
        "basic" ->
          username = args["username"]
          password = args["password"]

          if username && password do
            {:ok, %{type: :basic, username: username, password: password}}
          else
            {:error, "Missing required arguments for basic auth: username, password"}
          end

        "bearer" ->
          token = args["token"]

          if token do
            {:ok, %{type: :bearer, token: token}}
          else
            {:error, "Missing required argument for bearer auth: token"}
          end

        "oauth2_client" ->
          client_id = args["client_id"]
          client_secret = args["client_secret"]
          token_url = args["token_url"]

          if client_id && client_secret && token_url do
            {:ok,
             %{
               type: :oauth2_client,
               client_id: client_id,
               client_secret: client_secret,
               token_url: token_url
             }}
          else
            {:error,
             "Missing required arguments for oauth2_client auth: client_id, client_secret, token_url"}
          end

        other ->
          {:error, "Unsupported credential type: #{other}. Use: basic, bearer, or oauth2_client"}
      end

    case credential do
      {:ok, cred} ->
        case Compendium.Registry.CredentialStore.put(ctx.user_id, registry, cred) do
          :ok ->
            {:ok, %{stored: true, registry: registry, type: cred_type}}

          {:error, reason} ->
            Logger.error("[Sanctum.MCP] Failed to store registry credentials: #{inspect(reason)}")
            {:error, "Failed to store registry credentials"}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  def handle("session", _ctx, _args) do
    {:error,
     "Invalid session action. Use: login, logout, whoami, device-init, device-poll, or registry-login"}
  end

  # ============================================================================
  # Secret Tool
  # ============================================================================

  def handle("secret", %Context{} = ctx, %{"action" => "list"}) do
    with :ok <- require_permission(ctx, :secrets_read) do
      case Sanctum.Secrets.list(ctx) do
        {:ok, names} ->
          visible = Enum.reject(names, &Sanctum.Secrets.system_secret?/1)
          {:ok, %{secrets: visible, count: length(visible)}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to list secrets: #{inspect(reason)}")
          {:error, "Failed to list secrets"}
      end
    end
  end

  def handle("secret", %Context{} = ctx, %{"action" => "get", "name" => name} = _args) do
    with :ok <- require_permission(ctx, :secrets_read),
         :ok <- reject_system_secret(name) do
      case Sanctum.Secrets.get(ctx, name) do
        {:ok, value} ->
          # Return masked value with length hint for security
          masked = mask_secret(value)
          {:ok, %{name: name, value: masked, length: String.length(value)}}

        {:error, :not_found} ->
          {:error, "Secret not found: #{name}"}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to get secret: #{inspect(reason)}")
          {:error, "Failed to get secret"}
      end
    end
  end

  def handle("secret", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: name"}
  end

  def handle(
        "secret",
        %Context{} = ctx,
        %{"action" => "set", "name" => name, "value" => value} = _args
      ) do
    with :ok <- require_permission(ctx, :secrets_write),
         :ok <- reject_system_secret(name),
         :ok <- Sanctum.Secrets.set(ctx, name, value) do
      broadcast_secrets_changed(ctx)
      {:ok, %{stored: true, name: name}}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to store secret: #{inspect(reason)}")
        {:error, "Failed to store secret"}
    end
  end

  def handle("secret", _ctx, %{"action" => "set"}) do
    {:error, "Missing required arguments: name, value"}
  end

  def handle("secret", %Context{} = ctx, %{"action" => "delete", "name" => name} = _args) do
    with :ok <- require_permission(ctx, :secrets_write),
         :ok <- reject_system_secret(name),
         :ok <- Sanctum.Secrets.delete(ctx, name) do
      broadcast_secrets_changed(ctx)
      {:ok, %{deleted: true, name: name}}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to delete secret: #{inspect(reason)}")
        {:error, "Failed to delete secret"}
    end
  end

  def handle("secret", _ctx, %{"action" => "delete"}) do
    {:error, "Missing required argument: name"}
  end

  def handle(
        "secret",
        %Context{} = ctx,
        %{
          "action" => "grant",
          "name" => name,
          "component_ref" => component_ref
        } = args
      ) do
    pin_version = Map.get(args, "pin_version", false)

    with {:ok, component_ref} <- normalize_ref(component_ref),
         :ok <- require_permission(ctx, :secrets_write),
         :ok <- reject_system_secret(name),
         {:ok, store_ref, promoted_from} <-
           maybe_promote_to_name_level(component_ref, pin_version),
         :ok <- Sanctum.Secrets.grant(ctx, name, store_ref) do
      broadcast_secrets_changed(ctx)
      result = %{granted: true, secret: name, component: store_ref}
      result = if promoted_from, do: Map.put(result, :promoted_from, promoted_from), else: result
      {:ok, result}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to grant access: #{inspect(reason)}")
        {:error, "Failed to grant access"}
    end
  end

  def handle("secret", _ctx, %{"action" => "grant"}) do
    {:error, "Missing required arguments: name, component_ref"}
  end

  def handle(
        "secret",
        %Context{} = ctx,
        %{
          "action" => "revoke",
          "name" => name,
          "component_ref" => component_ref
        } = args
      ) do
    pin_version = Map.get(args, "pin_version", false)

    with {:ok, component_ref} <- normalize_ref(component_ref),
         :ok <- require_permission(ctx, :secrets_write),
         :ok <- reject_system_secret(name),
         {:ok, store_ref, promoted_from} <-
           maybe_promote_to_name_level(component_ref, pin_version),
         {:ok, status} <- Sanctum.Secrets.revoke(ctx, name, store_ref) do
      broadcast_secrets_changed(ctx)
      result = %{status: status, secret: name, component: store_ref}
      result = if promoted_from, do: Map.put(result, :promoted_from, promoted_from), else: result
      {:ok, result}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to revoke access: #{inspect(reason)}")
        {:error, "Failed to revoke access"}
    end
  end

  def handle("secret", _ctx, %{"action" => "revoke"}) do
    {:error, "Missing required arguments: name, component_ref"}
  end

  def handle("secret", %Context{} = ctx, %{
        "action" => "can_access",
        "name" => name,
        "component_ref" => ref
      }) do
    with :ok <- require_permission(ctx, :secrets_read),
         :ok <- reject_system_secret(name),
         {:ok, ref} <- normalize_ref(ref) do
      case Sanctum.Secrets.can_access?(ctx, name, ref) do
        {:ok, allowed} ->
          {:ok, %{allowed: allowed}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to check secret access: #{inspect(reason)}")
          {:error, "Failed to check secret access"}
      end
    end
  end

  def handle("secret", _ctx, %{"action" => "can_access"}) do
    {:error, "Missing required arguments: name, component_ref"}
  end

  def handle("secret", %Context{} = ctx, %{
        "action" => "list_component_grants",
        "component_ref" => ref
      }) do
    with :ok <- require_permission(ctx, :secrets_read),
         {:ok, ref} <- normalize_ref(ref) do
      case Sanctum.Secrets.list_component_grants(ctx, ref) do
        {:ok, names} ->
          visible = Enum.reject(names, &Sanctum.Secrets.system_secret?/1)
          {:ok, %{component_ref: ref, granted_secrets: visible}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to list component grants: #{inspect(reason)}")
          {:error, "Failed to list component grants"}
      end
    end
  end

  def handle("secret", _ctx, %{"action" => "list_component_grants"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle("secret", _ctx, %{"action" => "resolve_granted"}) do
    {:error,
     "Secret resolution is not permitted via MCP. Use 'can_access' to check access or 'list_component_grants' to list grants."}
  end

  def handle("secret", _ctx, _args) do
    {:error,
     "Invalid secret action. Use: set, get, delete, list, grant, revoke, can_access, or list_component_grants"}
  end

  # ============================================================================
  # OAuth Tool
  # ============================================================================

  def handle("oauth", %Context{} = ctx, %{
        "action" => "authorize",
        "component_ref" => component_ref,
        "provider" => provider
      }) do
    with :ok <- require_permission(ctx, :secrets_write) do
      case Sanctum.OAuth.authorize_url(ctx, component_ref, provider) do
        {:ok, result} ->
          {:ok,
           %{
             status: "ok",
             authorize_url: result.url,
             redirect_uri: result.redirect_uri,
             message:
               "Visit the authorize_url to grant access. " <>
                 "The redirect_uri (#{result.redirect_uri}) must be registered with your OAuth provider."
           }}

        {:error, reason} ->
          {:error, to_string(reason)}
      end
    end
  end

  def handle("oauth", _ctx, %{"action" => "authorize"}) do
    {:error, "authorize requires: component_ref, provider"}
  end

  def handle("oauth", %Context{} = ctx, %{"action" => "status", "component_ref" => component_ref}) do
    with :ok <- require_permission(ctx, :secrets_read) do
      case Sanctum.OAuth.status(ctx, component_ref) do
        {:ok, providers} -> {:ok, %{status: "ok", providers: providers}}
        {:error, reason} -> {:error, to_string(reason)}
      end
    end
  end

  def handle("oauth", _ctx, %{"action" => "status"}) do
    {:error, "status requires: component_ref"}
  end

  def handle("oauth", %Context{} = ctx, %{
        "action" => "revoke",
        "component_ref" => component_ref,
        "provider" => provider
      }) do
    with :ok <- require_permission(ctx, :secrets_write) do
      case Sanctum.OAuth.revoke(ctx, component_ref, provider) do
        :ok -> {:ok, %{status: "ok", message: "Token revoked for #{component_ref}/#{provider}"}}
        {:error, reason} -> {:error, to_string(reason)}
      end
    end
  end

  def handle("oauth", _ctx, %{"action" => "revoke"}) do
    {:error, "revoke requires: component_ref, provider"}
  end

  def handle("oauth", _ctx, _args) do
    {:error, "Invalid oauth action. Use: authorize, status, or revoke"}
  end

  # ============================================================================
  # Permission Tool
  # ============================================================================

  def handle("permission", %Context{} = ctx, %{"action" => "list"}) do
    with :ok <- require_permission(ctx, :users_read) do
      case Sanctum.Permission.list(ctx) do
        {:ok, entries} ->
          {:ok, %{permissions: entries, count: length(entries)}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to list permissions: #{inspect(reason)}")
          {:error, "Failed to list permissions"}
      end
    end
  end

  def handle("permission", %Context{} = ctx, %{"action" => "get", "subject" => subject}) do
    with :ok <- require_permission(ctx, :users_read) do
      case Sanctum.Permission.get(ctx, subject) do
        {:ok, perms} ->
          {:ok, %{subject: subject, permissions: perms}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to get permissions: #{inspect(reason)}")
          {:error, "Failed to get permissions"}
      end
    end
  end

  def handle("permission", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: subject"}
  end

  def handle(
        "permission",
        %Context{} = ctx,
        %{
          "action" => "set",
          "subject" => subject,
          "permissions" => perms
        } = _args
      ) do
    with :ok <- require_permission(ctx, :users_manage),
         :ok <- validate_permission_grant(ctx, subject, perms),
         :ok <- Sanctum.Permission.set(ctx, subject, perms) do
      {:ok, %{updated: true, subject: subject, permissions: perms}}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to set permissions: #{inspect(reason)}")
        {:error, "Failed to set permissions"}
    end
  end

  def handle("permission", _ctx, %{"action" => "set"}) do
    {:error, "Missing required arguments: subject, permissions"}
  end

  def handle("permission", _ctx, _args) do
    {:error, "Invalid permission action. Use: get, set, or list"}
  end

  # ============================================================================
  # Key Tool
  # ============================================================================

  def handle("key", %Context{} = ctx, %{"action" => "list"}) do
    with :ok <- require_permission(ctx, :admin) do
      case Sanctum.ApiKey.list(ctx) do
        {:ok, keys} ->
          {:ok, %{keys: keys, count: length(keys)}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to list keys: #{inspect(reason)}")
          {:error, "Failed to list keys"}
      end
    end
  end

  def handle("key", %Context{} = ctx, %{"action" => "get", "name" => name}) do
    with :ok <- require_permission(ctx, :admin) do
      case Sanctum.ApiKey.get(ctx, name) do
        {:ok, key_info} ->
          {:ok, key_info}

        {:error, :not_found} ->
          {:error, "Key not found: #{name}"}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to get key: #{inspect(reason)}")
          {:error, "Failed to get key"}
      end
    end
  end

  def handle("key", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: name"}
  end

  def handle("key", %Context{} = ctx, %{"action" => "create", "name" => name} = args) do
    with :ok <- require_permission(ctx, :admin),
         {:ok, key_type} <- parse_key_type_arg(Map.get(args, "type", "application")) do
      scope = Map.get(args, "scope", [])

      scope =
        cond do
          is_binary(scope) -> String.split(scope, ",", trim: true) |> Enum.map(&String.trim/1)
          is_list(scope) -> scope
          true -> []
        end

      opts = %{
        name: name,
        type: key_type,
        scope: scope,
        rate_limit: Map.get(args, "rate_limit"),
        ip_allowlist: Map.get(args, "ip_allowlist")
      }

      case Sanctum.ApiKey.create(ctx, opts) do
        {:ok, result} ->
          broadcast_api_keys_changed(ctx)
          {:ok, result}

        {:error, :already_exists} ->
          {:error, "Key already exists: #{name}"}

        {:error, :already_exists_revoked} ->
          {:error,
           "A revoked key named '#{name}' still exists. Choose a different name or delete the revoked key."}

        {:error, {:invalid_key_type, type}} ->
          {:error, "Invalid key type: #{type}. Use: application, service, or admin"}

        {:error, {:scope_exceeds_ceiling, scope_list, ceiling}} ->
          {:error,
           "Scope #{inspect(scope_list)} exceeds allowed scopes for this key type: #{inspect(ceiling)}"}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to create key: #{inspect(reason)}")
          {:error, "Failed to create key"}
      end
    end
  end

  def handle("key", _ctx, %{"action" => "create"}) do
    {:error, "Missing required argument: name"}
  end

  def handle("key", %Context{} = ctx, %{"action" => "revoke", "name" => name} = _args) do
    with :ok <- require_permission(ctx, :admin),
         :ok <- Sanctum.ApiKey.revoke(ctx, name) do
      broadcast_api_keys_changed(ctx)
      {:ok, %{revoked: true, name: name}}
    else
      {:error, :not_found} ->
        {:error, "Key not found: #{name}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to revoke key: #{inspect(reason)}")
        {:error, "Failed to revoke key"}
    end
  end

  def handle("key", _ctx, %{"action" => "revoke"}) do
    {:error, "Missing required argument: name"}
  end

  def handle("key", %Context{} = ctx, %{"action" => "rotate", "name" => name} = _args) do
    with :ok <- require_permission(ctx, :admin) do
      case Sanctum.ApiKey.rotate(ctx, name) do
        {:ok, result} ->
          broadcast_api_keys_changed(ctx)
          {:ok, result}

        {:error, :not_found} ->
          {:error, "Key not found: #{name}"}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to rotate key: #{inspect(reason)}")
          {:error, "Failed to rotate key"}
      end
    end
  end

  def handle("key", _ctx, %{"action" => "rotate"}) do
    {:error, "Missing required argument: name"}
  end

  def handle("key", _ctx, _args) do
    {:error, "Invalid key action. Use: create, get, list, revoke, or rotate"}
  end

  # ============================================================================
  # Policy Tool
  # ============================================================================

  def handle("policy", %Context{} = ctx, %{"action" => "list"}) do
    with :ok <- require_permission(ctx, :policy_read) do
      case Sanctum.PolicyStore.list(ctx) do
        {:ok, policies} ->
          formatted =
            Enum.map(policies, fn %{component_ref: ref, policy: policy} ->
              %{component_ref: ref, policy: Map.from_struct(policy)}
            end)

          {:ok, %{policies: formatted, count: length(formatted)}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to list policies: #{inspect(reason)}")
          {:error, "Failed to list policies"}
      end
    end
  end

  def handle("policy", %Context{} = ctx, %{"action" => "get", "component_ref" => ref}) do
    with :ok <- require_permission(ctx, :policy_read),
         {:ok, ref} <- normalize_ref(ref) do
      case Sanctum.PolicyStore.get(ctx, ref) do
        {:ok, policy} ->
          {:ok, %{component_ref: ref, policy: Map.from_struct(policy)}}

        {:error, :not_found} ->
          {:error, "Policy not found: #{ref}"}
      end
    end
  end

  def handle("policy", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle(
        "policy",
        %Context{} = ctx,
        %{
          "action" => "set",
          "component_ref" => ref,
          "policy" => policy_map
        } = args
      ) do
    pin_version = Map.get(args, "pin_version", false)

    with :ok <- require_permission(ctx, :policy_manage),
         {:ok, ref} <- normalize_ref(ref),
         :ok <- require_policy_ownership(ctx, ref),
         {:ok, store_ref, promoted_from} <- maybe_promote_to_name_level(ref, pin_version) do
      case Sanctum.PolicyStore.put(ctx, store_ref, policy_map) do
        :ok ->
          broadcast_policies_changed(ctx)
          result = %{stored: true, component_ref: store_ref}

          result =
            if promoted_from, do: Map.put(result, :promoted_from, promoted_from), else: result

          {:ok, result}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to set policy: #{inspect(reason)}")
          {:error, "Failed to set policy"}
      end
    end
  end

  def handle("policy", _ctx, %{"action" => "set"}) do
    {:error, "Missing required arguments: component_ref, policy"}
  end

  def handle(
        "policy",
        %Context{} = ctx,
        %{
          "action" => "update_field",
          "component_ref" => ref,
          "field" => field,
          "value" => value
        } = args
      ) do
    pin_version = Map.get(args, "pin_version", false)

    with :ok <- require_permission(ctx, :policy_manage),
         {:ok, ref} <- normalize_ref(ref),
         :ok <- require_policy_ownership(ctx, ref),
         {:ok, store_ref, promoted_from} <- maybe_promote_to_name_level(ref, pin_version) do
      case Sanctum.PolicyStore.update_field(ctx, store_ref, field, value) do
        :ok ->
          broadcast_policies_changed(ctx)
          result = %{updated: true, component_ref: store_ref, field: field}

          result =
            if promoted_from, do: Map.put(result, :promoted_from, promoted_from), else: result

          {:ok, result}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to update policy field: #{inspect(reason)}")
          {:error, "Failed to update policy field"}
      end
    end
  end

  def handle("policy", _ctx, %{"action" => "update_field"}) do
    {:error, "Missing required arguments: component_ref, field, value"}
  end

  def handle("policy", %Context{} = ctx, %{"action" => "delete", "component_ref" => ref}) do
    with :ok <- require_permission(ctx, :policy_manage),
         {:ok, ref} <- normalize_ref(ref),
         :ok <- require_policy_ownership(ctx, ref) do
      case Sanctum.PolicyStore.delete(ctx, ref) do
        :ok ->
          broadcast_policies_changed(ctx)
          {:ok, %{deleted: true, component_ref: ref}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to delete policy: #{inspect(reason)}")
          {:error, "Failed to delete policy"}
      end
    end
  end

  def handle("policy", _ctx, %{"action" => "delete"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle("policy", %Context{} = ctx, %{"action" => "get_effective", "component_ref" => ref}) do
    with :ok <- require_permission(ctx, :policy_read),
         {:ok, ref} <- normalize_ref(ref) do
      case Sanctum.Policy.get_effective(ctx, ref) do
        {:ok, policy, %{source: source} = meta} ->
          ceiling = Sanctum.Policy.Ceiling.effective_ceiling(ctx)
          clamped = Sanctum.Policy.Ceiling.clamp(policy, ceiling)

          result =
            Sanctum.Policy.to_map(policy)
            |> Map.put(:policy_source, source)
            |> Map.put(:effective, Sanctum.Policy.to_map(clamped))
            |> Map.put(:ceiling, ceiling)

          result =
            case Map.get(meta, :uncovered_capabilities) do
              nil -> result
              [] -> result
              caps -> Map.put(result, :uncovered_capabilities, caps)
            end

          {:ok, result}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to get effective policy: #{inspect(reason)}")
          {:error, "Failed to get effective policy"}
      end
    end
  end

  def handle("policy", _ctx, %{"action" => "get_effective"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle("policy", %Context{} = ctx, %{"action" => "get_ceiling"}) do
    with :ok <- require_permission(ctx, :policy_read) do
      ceiling = Sanctum.Policy.Ceiling.effective_ceiling(ctx)
      {:ok, %{ceiling: ceiling, edition: edition_label()}}
    end
  end

  def handle("policy", _ctx, %{"action" => "get_ceiling"}) do
    {:error, "Authentication required"}
  end

  def handle("policy", %Context{} = ctx, %{"action" => "check_rate_limit", "component_ref" => ref}) do
    with :ok <- require_permission(ctx, :policy_read),
         {:ok, ref} <- normalize_ref(ref),
         {:ok, policy, _meta} <- Sanctum.Policy.get_effective(ctx, ref) do
      case Sanctum.Policy.check_rate_limit(policy, ctx, ref) do
        {:ok, remaining} ->
          {:ok, %{allowed: true, remaining: remaining}}

        {:error, :rate_limited, retry_after} ->
          {:ok, %{allowed: false, retry_after: retry_after}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Rate limit check failed: #{inspect(reason)}")
          {:error, "Rate limit check failed"}
      end
    else
      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Rate limit check failed: #{inspect(reason)}")
        {:error, "Rate limit check failed"}
    end
  end

  def handle("policy", _ctx, %{"action" => "check_rate_limit"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle("policy", %Context{} = ctx, %{
        "action" => "get_type_default",
        "component_type" => type_str
      }) do
    with :ok <- require_permission(ctx, :policy_read),
         {:ok, type_atom} <- parse_component_type(type_str) do
      case Sanctum.PolicyStore.get_type_default(ctx, type_atom) do
        {:ok, policy} ->
          {:ok,
           %{component_type: type_str, source: "stored", policy: Sanctum.Policy.to_map(policy)}}

        {:error, :not_found} ->
          {:ok,
           %{
             component_type: type_str,
             source: "hardcoded",
             policy: Sanctum.Policy.to_map(Sanctum.Policy.default(type_atom))
           }}
      end
    end
  end

  def handle("policy", _ctx, %{"action" => "get_type_default"}) do
    {:error, "Missing required argument: component_type"}
  end

  def handle("policy", %Context{} = ctx, %{
        "action" => "set_type_default",
        "component_type" => type_str,
        "policy" => policy_map
      }) do
    with :ok <- require_permission(ctx, :policy_manage),
         {:ok, type_atom} <- parse_component_type(type_str),
         {:ok, policy} <- Sanctum.Policy.from_map(policy_map) do
      case Sanctum.PolicyStore.put_type_default(ctx, type_atom, policy) do
        :ok ->
          {:ok, %{stored: true, component_type: type_str}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to set type default: #{inspect(reason)}")
          {:error, "Failed to set type default"}
      end
    end
  end

  def handle("policy", _ctx, %{"action" => "set_type_default"}) do
    {:error, "Missing required arguments: component_type, policy"}
  end

  def handle("policy", %Context{} = ctx, %{
        "action" => "delete_type_default",
        "component_type" => type_str
      }) do
    with :ok <- require_permission(ctx, :policy_manage),
         {:ok, type_atom} <- parse_component_type(type_str) do
      case Sanctum.PolicyStore.delete_type_default(ctx, type_atom) do
        :ok ->
          {:ok, %{deleted: true, component_type: type_str}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to delete type default: #{inspect(reason)}")
          {:error, "Failed to delete type default"}
      end
    end
  end

  def handle("policy", _ctx, %{"action" => "delete_type_default"}) do
    {:error, "Missing required argument: component_type"}
  end

  def handle("policy", %Context{} = ctx, %{"action" => "list_type_defaults"}) do
    with :ok <- require_permission(ctx, :policy_read) do
      {:ok, defaults} = Sanctum.PolicyStore.list_type_defaults(ctx)

      formatted =
        Enum.map(defaults, fn %{type: type, source: source, policy: policy} ->
          %{component_type: type, source: source, policy: Sanctum.Policy.to_map(policy)}
        end)

      {:ok, %{type_defaults: formatted}}
    end
  end

  def handle("policy", %Context{} = ctx, %{
        "action" => "migrate_to_name_level",
        "component_ref" => ref
      }) do
    with :ok <- require_permission(ctx, :policy_manage),
         {:ok, ref} <- normalize_ref(ref),
         :ok <- require_policy_ownership(ctx, ref) do
      # Only versioned refs can be migrated
      case Sanctum.ComponentRef.parse(ref) do
        {:ok, %Sanctum.ComponentRef{version: nil}} ->
          {:error, "Reference is already name-level: #{ref}"}

        {:ok, parsed} ->
          name_ref = Sanctum.ComponentRef.to_name_ref(parsed)

          case Sanctum.PolicyStore.get(ctx, ref) do
            {:ok, policy} ->
              case Sanctum.PolicyStore.put(ctx, name_ref, policy) do
                :ok ->
                  Sanctum.PolicyStore.delete(ctx, ref)
                  {:ok, %{migrated: true, from: ref, to: name_ref}}

                {:error, reason} ->
                  Logger.error("[Sanctum.MCP] Failed to migrate policy: #{inspect(reason)}")
                  {:error, "Failed to store name-level policy"}
              end

            {:error, :not_found} ->
              {:error, "No version-specific policy found for: #{ref}"}

            {:error, reason} ->
              Logger.error(
                "[Sanctum.MCP] Failed to read policy for migration: #{inspect(reason)}"
              )

              {:error, "Failed to read policy for migration"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def handle("policy", _ctx, %{"action" => "migrate_to_name_level"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle("policy", _ctx, _args) do
    {:error,
     "Invalid policy action. Use: get, set, update_field, delete, list, get_effective, get_ceiling, check_rate_limit, get_type_default, set_type_default, delete_type_default, list_type_defaults, or migrate_to_name_level"}
  end

  # ============================================================================
  # Unknown Tool
  # ============================================================================

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp normalize_ref(ref) when is_binary(ref) do
    Sanctum.ComponentRef.normalize_or_name_ref(ref)
  end

  defp normalize_ref(ref), do: {:ok, ref}

  # Auto-promote versioned refs to name-level unless pin_version is true.
  # Returns {:ok, store_ref, promoted_from | nil}
  defp maybe_promote_to_name_level(ref, true = _pin_version), do: {:ok, ref, nil}

  defp maybe_promote_to_name_level(ref, _pin_version) do
    case Sanctum.ComponentRef.parse(ref) do
      {:ok, %Sanctum.ComponentRef{version: nil}} ->
        # Already name-level
        {:ok, ref, nil}

      {:ok, parsed} ->
        name_ref = Sanctum.ComponentRef.to_name_ref(parsed)
        {:ok, name_ref, ref}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_key_type_arg("application"), do: {:ok, :application}
  defp parse_key_type_arg("service"), do: {:ok, :service}
  defp parse_key_type_arg("admin"), do: {:ok, :admin}

  defp parse_key_type_arg(invalid),
    do: {:error, "Invalid key type: #{invalid}. Use: application, service, or admin"}

  defp parse_component_type(type) when type in ["catalyst", "formula", "reagent"] do
    {:ok, String.to_existing_atom(type)}
  end

  defp parse_component_type(invalid) do
    {:error,
     "Invalid component_type '#{inspect(invalid)}'. Must be one of: catalyst, formula, reagent"}
  end

  defp mask_secret(value) when byte_size(value) <= 8, do: "****"

  defp mask_secret(value) do
    first = String.slice(value, 0, 4)
    "#{first}...****"
  end

  defp format_permissions(permissions) do
    permissions
    |> MapSet.to_list()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp validate_permission_grant(%Context{} = ctx, subject, perms) do
    is_admin = Context.has_permission?(ctx, :admin)

    cond do
      is_admin ->
        :ok

      subject == ctx.user_id ->
        {:error, "Cannot modify own permissions without admin privilege"}

      true ->
        granted = Enum.map(perms, &Sanctum.Atoms.safe_to_permission_atom/1)
        caller_perms = ctx.permissions

        unauthorized =
          Enum.reject(granted, fn perm -> MapSet.member?(caller_perms, perm) end)

        if unauthorized == [] do
          :ok
        else
          names = unauthorized |> Enum.map(&to_string/1) |> Enum.join(", ")
          {:error, "Cannot grant permissions you do not possess: #{names}"}
        end
    end
  end

  defp require_policy_ownership(ctx, ref) do
    if Context.has_permission?(ctx, :admin) do
      :ok
    else
      case Sanctum.ComponentRef.parse(ref) do
        {:ok, %Sanctum.ComponentRef{namespace: "local"}} ->
          :ok

        _ ->
          {:error,
           "Unauthorized: modifying policies for non-local components requires admin permission"}
      end
    end
  end

  defp reject_system_secret(name) do
    if Sanctum.Secrets.system_secret?(name) do
      {:error, "Access denied: system secrets cannot be managed through this interface"}
    else
      :ok
    end
  end

  defp require_permission(ctx, permission), do: Context.require_permission(ctx, permission)

  defp edition_label do
    if Application.get_env(:cyfr, :edition, :core) == :arx, do: "arx", else: "core"
  end

  # PubSub broadcasts for Prism LiveView reactivity
  defp broadcast_secrets_changed(ctx) do
    topic = Sanctum.PubSub.topic("prism:secrets", ctx)
    Phoenix.PubSub.broadcast(Emissary.PubSub, topic, :secrets_changed)
  end

  defp broadcast_policies_changed(ctx) do
    topic = Sanctum.PubSub.topic("prism:policies", ctx)
    Phoenix.PubSub.broadcast(Emissary.PubSub, topic, :policies_changed)
  end

  defp broadcast_api_keys_changed(ctx) do
    topic = Sanctum.PubSub.topic("prism:api_keys", ctx)
    Phoenix.PubSub.broadcast(Emissary.PubSub, topic, :api_keys_changed)
  end
end
