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
    content = case Jason.encode(%{user_id: ctx.user_id, org_id: ctx.org_id, scope: ctx.scope}) do
      {:ok, json} -> json
      {:error, _} -> ~s({"error":"encoding_error"})
    end
    {:ok, %{content: content, mimeType: "application/json"}}
  end

  def read(%Context{} = ctx, "sanctum://permissions") do
    content = case Jason.encode(%{permissions: format_permissions(ctx.permissions)}) do
      {:ok, json} -> json
      {:error, _} -> ~s({"error":"encoding_error"})
    end
    {:ok, %{content: content, mimeType: "application/json"}}
  end

  def read(%Context{} = ctx, "sanctum://permissions/" <> reference) do
    case Sanctum.Permission.get_for_resource(ctx, reference) do
      {:ok, perms} ->
        content = case Jason.encode(%{reference: reference, permissions: perms}) do
          {:ok, json} -> json
          {:error, _} -> ~s({"error":"encoding_error"})
        end
        {:ok, %{content: content, mimeType: "application/json"}}

      {:error, _} ->
        content = case Jason.encode(%{reference: reference, permissions: []}) do
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
        description: "Manage user sessions - login, logout, get identity, or device flow authentication",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["login", "logout", "whoami", "device-init", "device-poll"],
              "description" => "Action to perform"
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
              "enum" => ["set", "get", "delete", "list", "grant", "revoke", "can_access", "list_component_grants"],
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
              "description" => "Component reference: type:namespace.name:version (required, e.g., 'catalyst:local.stripe-catalyst:1.0.0')"
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
              "description" => "Key type: application (frontend), service (backend), admin (CI/CD)"
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
              "enum" => ["get", "set", "update_field", "delete", "list", "get_effective",
                         "check_rate_limit", "get_type_default", "set_type_default",
                         "delete_type_default", "list_type_defaults"],
              "description" => "Action to perform"
            },
            "component_ref" => %{
              "type" => "string",
              "description" => "Component reference: type:namespace.name:version (required, e.g., 'catalyst:local.stripe-catalyst:1.0.0')"
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
      },
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
        {:ok, %{
          device_code: device_info.device_code,
          user_code: device_info.user_code,
          verification_uri: device_info.verification_uri,
          expires_in: device_info.expires_in,
          interval: device_info.interval
        }}

      {:error, {:client_id_not_configured, provider}} ->
        {:error, "#{provider} client ID not configured. Set CYFR_#{String.upcase(to_string(provider))}_CLIENT_ID"}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to initialize device flow: #{inspect(reason)}")
        {:error, "Failed to initialize device flow"}
    end
  end

  def handle("session", %Context{} = _ctx, %{"action" => "device-poll", "device_code" => device_code} = args) do
    provider = Map.get(args, "provider", "github")

    case Sanctum.Auth.DeviceFlow.poll_for_session(provider, device_code) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:client_id_not_configured, provider}} ->
        {:error, "#{provider} client ID not configured. Set CYFR_#{String.upcase(to_string(provider))}_CLIENT_ID"}

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

  def handle("session", _ctx, _args) do
    {:error, "Invalid session action. Use: login, logout, whoami, device-init, or device-poll"}
  end

  # ============================================================================
  # Secret Tool
  # ============================================================================

  def handle("secret", %Context{} = ctx, %{"action" => "list"}) do
    with :ok <- require_permission(ctx, :secrets_read) do
      case Sanctum.Secrets.list(ctx) do
        {:ok, names} ->
          {:ok, %{secrets: names, count: length(names)}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to list secrets: #{inspect(reason)}")
          {:error, "Failed to list secrets"}
      end
    end
  end

  def handle("secret", %Context{} = ctx, %{"action" => "get", "name" => name} = _args) do
    with :ok <- require_permission(ctx, :secrets_read) do
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

  def handle("secret", %Context{} = ctx, %{"action" => "set", "name" => name, "value" => value} = _args) do
    with :ok <- require_permission(ctx, :secrets_write),
         :ok <- Sanctum.Secrets.set(ctx, name, value) do
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
         :ok <- Sanctum.Secrets.delete(ctx, name) do
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

  def handle("secret", %Context{} = ctx, %{
        "action" => "grant",
        "name" => name,
        "component_ref" => component_ref
      } = _args) do
    with {:ok, component_ref} <- normalize_ref(component_ref),
         :ok <- require_permission(ctx, :secrets_write),
         :ok <- Sanctum.Secrets.grant(ctx, name, component_ref) do
      {:ok, %{granted: true, secret: name, component: component_ref}}
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

  def handle("secret", %Context{} = ctx, %{
        "action" => "revoke",
        "name" => name,
        "component_ref" => component_ref
      } = _args) do
    with {:ok, component_ref} <- normalize_ref(component_ref),
         :ok <- require_permission(ctx, :secrets_write),
         {:ok, status} <- Sanctum.Secrets.revoke(ctx, name, component_ref) do
      {:ok, %{status: status, secret: name, component: component_ref}}
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

  def handle("secret", %Context{} = ctx, %{"action" => "can_access", "name" => name, "component_ref" => ref}) do
    with :ok <- require_permission(ctx, :secrets_read),
         {:ok, ref} <- normalize_ref(ref) do
      case Sanctum.Secrets.can_access?(ctx, name, ref) do
        {:ok, allowed} -> {:ok, %{allowed: allowed}}
        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to check secret access: #{inspect(reason)}")
          {:error, "Failed to check secret access"}
      end
    end
  end

  def handle("secret", _ctx, %{"action" => "can_access"}) do
    {:error, "Missing required arguments: name, component_ref"}
  end

  def handle("secret", %Context{} = ctx, %{"action" => "list_component_grants", "component_ref" => ref}) do
    with :ok <- require_permission(ctx, :secrets_read),
         {:ok, ref} <- normalize_ref(ref) do
      case Sanctum.Secrets.list_component_grants(ctx, ref) do
        {:ok, names} -> {:ok, %{component_ref: ref, granted_secrets: names}}
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
    {:error, "Secret resolution is not permitted via MCP. Use 'can_access' to check access or 'list_component_grants' to list grants."}
  end

  def handle("secret", _ctx, _args) do
    {:error, "Invalid secret action. Use: set, get, delete, list, grant, revoke, can_access, or list_component_grants"}
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

  def handle("permission", %Context{} = ctx, %{
        "action" => "set",
        "subject" => subject,
        "permissions" => perms
      } = _args) do
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
          {:ok, result}

        {:error, :already_exists} ->
          {:error, "Key already exists: #{name}"}

        {:error, {:invalid_key_type, type}} ->
          {:error, "Invalid key type: #{type}. Use: application, service, or admin"}

        {:error, {:scope_exceeds_ceiling, scope_list, ceiling}} ->
          {:error, "Scope #{inspect(scope_list)} exceeds allowed scopes for this key type: #{inspect(ceiling)}"}

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
          formatted = Enum.map(policies, fn %{component_ref: ref, policy: policy} ->
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

  def handle("policy", %Context{} = ctx, %{"action" => "set", "component_ref" => ref, "policy" => policy_map}) do
    with :ok <- require_permission(ctx, :policy_manage),
         {:ok, ref} <- normalize_ref(ref),
         :ok <- require_policy_ownership(ctx, ref) do
      case Sanctum.PolicyStore.put(ctx, ref, policy_map) do
        :ok ->
          {:ok, %{stored: true, component_ref: ref}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to set policy: #{inspect(reason)}")
          {:error, "Failed to set policy"}
      end
    end
  end

  def handle("policy", _ctx, %{"action" => "set"}) do
    {:error, "Missing required arguments: component_ref, policy"}
  end

  def handle("policy", %Context{} = ctx, %{
        "action" => "update_field",
        "component_ref" => ref,
        "field" => field,
        "value" => value
      }) do
    with :ok <- require_permission(ctx, :policy_manage),
         {:ok, ref} <- normalize_ref(ref),
         :ok <- require_policy_ownership(ctx, ref) do
      case Sanctum.PolicyStore.update_field(ctx, ref, field, value) do
        :ok ->
          {:ok, %{updated: true, component_ref: ref, field: field}}

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
        :ok -> {:ok, %{deleted: true, component_ref: ref}}
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
        {:ok, policy, %{source: source}} ->
          {:ok, Sanctum.Policy.to_map(policy) |> Map.put(:policy_source, source)}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to get effective policy: #{inspect(reason)}")
          {:error, "Failed to get effective policy"}
      end
    end
  end

  def handle("policy", _ctx, %{"action" => "get_effective"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle("policy", %Context{} = ctx, %{"action" => "check_rate_limit", "component_ref" => ref}) do
    with :ok <- require_permission(ctx, :policy_read),
         {:ok, ref} <- normalize_ref(ref),
         {:ok, policy, _meta} <- Sanctum.Policy.get_effective(ctx, ref) do
      case Sanctum.Policy.check_rate_limit(policy, ctx, ref) do
        {:ok, remaining} -> {:ok, %{allowed: true, remaining: remaining}}
        {:error, :rate_limited, retry_after} -> {:ok, %{allowed: false, retry_after: retry_after}}
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

  def handle("policy", %Context{} = ctx, %{"action" => "get_type_default", "component_type" => type_str}) do
    with :ok <- require_permission(ctx, :policy_read),
         {:ok, type_atom} <- parse_component_type(type_str) do
      case Sanctum.PolicyStore.get_type_default(ctx, type_atom) do
        {:ok, policy} ->
          {:ok, %{component_type: type_str, source: "stored", policy: Sanctum.Policy.to_map(policy)}}

        {:error, :not_found} ->
          {:ok, %{component_type: type_str, source: "hardcoded", policy: Sanctum.Policy.to_map(Sanctum.Policy.default(type_atom))}}
      end
    end
  end

  def handle("policy", _ctx, %{"action" => "get_type_default"}) do
    {:error, "Missing required argument: component_type"}
  end

  def handle("policy", %Context{} = ctx, %{"action" => "set_type_default", "component_type" => type_str, "policy" => policy_map}) do
    with :ok <- require_permission(ctx, :policy_manage),
         {:ok, type_atom} <- parse_component_type(type_str),
         {:ok, policy} <- Sanctum.Policy.from_map(policy_map) do
      case Sanctum.PolicyStore.put_type_default(ctx, type_atom, policy) do
        :ok -> {:ok, %{stored: true, component_type: type_str}}
        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to set type default: #{inspect(reason)}")
          {:error, "Failed to set type default"}
      end
    end
  end

  def handle("policy", _ctx, %{"action" => "set_type_default"}) do
    {:error, "Missing required arguments: component_type, policy"}
  end

  def handle("policy", %Context{} = ctx, %{"action" => "delete_type_default", "component_type" => type_str}) do
    with :ok <- require_permission(ctx, :policy_manage),
         {:ok, type_atom} <- parse_component_type(type_str) do
      case Sanctum.PolicyStore.delete_type_default(ctx, type_atom) do
        :ok -> {:ok, %{deleted: true, component_type: type_str}}
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

      formatted = Enum.map(defaults, fn %{type: type, source: source, policy: policy} ->
        %{component_type: type, source: source, policy: Sanctum.Policy.to_map(policy)}
      end)

      {:ok, %{type_defaults: formatted}}
    end
  end

  def handle("policy", _ctx, _args) do
    {:error, "Invalid policy action. Use: get, set, update_field, delete, list, get_effective, check_rate_limit, get_type_default, set_type_default, delete_type_default, or list_type_defaults"}
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

  defp parse_key_type_arg("application"), do: {:ok, :application}
  defp parse_key_type_arg("service"), do: {:ok, :service}
  defp parse_key_type_arg("admin"), do: {:ok, :admin}
  defp parse_key_type_arg(invalid), do: {:error, "Invalid key type: #{invalid}. Use: application, service, or admin"}

  defp parse_component_type(type) when type in ["catalyst", "formula", "reagent"] do
    {:ok, String.to_existing_atom(type)}
  end

  defp parse_component_type(invalid) do
    {:error, "Invalid component_type '#{inspect(invalid)}'. Must be one of: catalyst, formula, reagent"}
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
        {:ok, %Sanctum.ComponentRef{namespace: "local"}} -> :ok
        _ -> {:error, "Unauthorized: modifying policies for non-local components requires admin permission"}
      end
    end
  end

  defp require_permission(ctx, permission), do: Context.require_permission(ctx, permission)
end
