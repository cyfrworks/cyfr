defmodule Sanctum.MCP do
  @moduledoc """
  MCP tool and resource provider for Sanctum identity & authorization service.

  ## Tools

  - `session` - Session management (login, logout, whoami)
  - `secret` - Secret management (set, get, delete, list, grant, revoke)
  - `permission` - Permission management (get, set, list)
  - `key` - API key management (create, get, list, revoke, rotate)
  - `audit` - Audit log access (list, export)
  - `policy` - Host Policy management (get, set, update_field, delete, list)
  - `config` - Component configuration (get, get_all, set, delete, list)

  ## Resources

  - `sanctum://identity` - Current user identity
  - `sanctum://permissions` - Current user permissions

  ## Architecture Note

  This module lives in the `sanctum` app, keeping tool definitions
  close to their implementation. Authentication tools (login/logout)
  are handled differently as they require browser redirects.
  """

  alias Sanctum.Context

  # ============================================================================
  # ResourceProvider Protocol
  # ============================================================================

  @doc """
  Returns available Sanctum resources.
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
      },
      %{
        uri: "sanctum://permissions/{reference}",
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
    {:ok,
     %{
       content:
         Jason.encode!(%{
           user_id: ctx.user_id,
           org_id: ctx.org_id,
           scope: ctx.scope
         }),
       mimeType: "application/json"
     }}
  end

  def read(%Context{} = ctx, "sanctum://permissions") do
    {:ok,
     %{
       content:
         Jason.encode!(%{
           permissions: format_permissions(ctx.permissions)
         }),
       mimeType: "application/json"
     }}
  end

  def read(%Context{} = ctx, "sanctum://permissions/" <> reference) do
    case Sanctum.Permission.get_for_resource(ctx, reference) do
      {:ok, perms} ->
        {:ok,
         %{
           content: Jason.encode!(%{reference: reference, permissions: perms}),
           mimeType: "application/json"
         }}

      {:error, _} ->
        {:ok,
         %{
           content: Jason.encode!(%{reference: reference, permissions: []}),
           mimeType: "application/json"
         }}
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
              "enum" => ["github", "google"],
              "description" => "OAuth provider for device flow (default: github)"
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
              "enum" => ["set", "get", "delete", "list", "grant", "revoke", "resolve_granted", "can_access"],
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
            "sudo_credential" => %{
              "type" => "string",
              "description" => "Elevated credential for sensitive operations"
            }
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
            },
            "sudo_credential" => %{
              "type" => "string",
              "description" => "Elevated credential for sensitive operations"
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
              "enum" => ["public", "secret", "admin"],
              "description" => "Key type: public (frontend), secret (backend), admin (CI/CD)"
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
            },
            "sudo_credential" => %{
              "type" => "string",
              "description" => "Elevated credential for sensitive operations"
            }
          },
          "required" => ["action"]
        }
      },
      %{
        name: "audit",
        title: "Audit Log",
        description: "Access audit logs and execution history - list, export, show, or executions",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["list", "export", "show", "executions", "log_violation"],
              "description" => "Action to perform: list audit entries, export to file, show execution details, or list recent executions"
            },
            "filters" => %{
              "type" => "object",
              "properties" => %{
                "start_date" => %{
                  "type" => "string",
                  "description" => "Start date (ISO 8601)"
                },
                "end_date" => %{
                  "type" => "string",
                  "description" => "End date (ISO 8601)"
                },
                "event_type" => %{
                  "type" => "string",
                  "enum" => ["execution", "auth", "policy", "secret_access"],
                  "description" => "Filter by event type"
                }
              }
            },
            "format" => %{
              "type" => "string",
              "enum" => ["json", "csv"],
              "description" => "Export format (default: json)"
            },
            "execution_id" => %{
              "type" => "string",
              "description" => "Execution ID for show action"
            },
            "limit" => %{
              "type" => "integer",
              "description" => "Maximum number of executions to return (default: 10)"
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
              "enum" => ["get", "set", "update_field", "delete", "list", "get_effective", "check_rate_limit"],
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
              "description" => "Full policy map (for set action)"
            }
          },
          "required" => ["action"]
        }
      },
      %{
        name: "config",
        title: "Component Configuration",
        description: "Manage component configuration - get, get_all, set, delete, or list configs",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["get", "get_all", "set", "delete", "list"],
              "description" => "Action to perform"
            },
            "component_ref" => %{
              "type" => "string",
              "description" => "Component reference: type:namespace.name:version (required, e.g., 'catalyst:local.stripe-catalyst:1.0.0')"
            },
            "key" => %{
              "type" => "string",
              "description" => "Config key name"
            },
            "value" => %{
              "type" => "string",
              "description" => "Config value (for set action)"
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

  def handle("session", %Context{} = ctx, %{"action" => "whoami"}) do
    {:ok,
     %{
       user_id: ctx.user_id,
       org_id: ctx.org_id,
       scope: ctx.scope,
       permissions: format_permissions(ctx.permissions)
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
        {:error, "Failed to initialize device flow: #{inspect(reason)}"}
    end
  end

  def handle("session", %Context{} = _ctx, %{"action" => "device-poll", "device_code" => device_code} = args) do
    provider = Map.get(args, "provider", "github")

    case Sanctum.Auth.DeviceFlow.poll_for_session(provider, device_code) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:client_id_not_configured, provider}} ->
        {:error, "#{provider} client ID not configured. Set CYFR_#{String.upcase(to_string(provider))}_CLIENT_ID"}

      {:error, reason} ->
        {:error, "Failed to poll for token: #{inspect(reason)}"}
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
    case Sanctum.Secrets.list(ctx) do
      {:ok, names} ->
        {:ok, %{secrets: names, count: length(names)}}

      {:error, reason} ->
        {:error, "Failed to list secrets: #{inspect(reason)}"}
    end
  end

  def handle("secret", %Context{} = ctx, %{"action" => "get", "name" => name} = args) do
    with :ok <- Sanctum.Sudo.maybe_require(ctx, args, "secret.get") do
      case Sanctum.Secrets.get(ctx, name) do
        {:ok, value} ->
          # Return masked value with length hint for security
          masked = mask_secret(value)
          {:ok, %{name: name, value: masked, length: String.length(value)}}

        {:error, :not_found} ->
          {:error, "Secret not found: #{name}"}

        {:error, reason} ->
          {:error, "Failed to get secret: #{inspect(reason)}"}
      end
    end
  end

  def handle("secret", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: name"}
  end

  def handle("secret", %Context{} = ctx, %{"action" => "set", "name" => name, "value" => value} = args) do
    with :ok <- Sanctum.Sudo.maybe_require(ctx, args, "secret.set"),
         :ok <- Sanctum.Secrets.set(ctx, name, value) do
      {:ok, %{stored: true, name: name}}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Failed to store secret: #{inspect(reason)}"}
    end
  end

  def handle("secret", _ctx, %{"action" => "set"}) do
    {:error, "Missing required arguments: name, value"}
  end

  def handle("secret", %Context{} = ctx, %{"action" => "delete", "name" => name} = args) do
    with :ok <- Sanctum.Sudo.maybe_require(ctx, args, "secret.delete"),
         :ok <- Sanctum.Secrets.delete(ctx, name) do
      {:ok, %{deleted: true, name: name}}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Failed to delete secret: #{inspect(reason)}"}
    end
  end

  def handle("secret", _ctx, %{"action" => "delete"}) do
    {:error, "Missing required argument: name"}
  end

  def handle("secret", %Context{} = ctx, %{
        "action" => "grant",
        "name" => name,
        "component_ref" => component_ref
      } = args) do
    with {:ok, component_ref} <- normalize_ref(component_ref),
         :ok <- Sanctum.Sudo.maybe_require(ctx, args, "secret.grant"),
         :ok <- Sanctum.Secrets.grant(ctx, name, component_ref) do
      {:ok, %{granted: true, secret: name, component: component_ref}}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Failed to grant access: #{inspect(reason)}"}
    end
  end

  def handle("secret", _ctx, %{"action" => "grant"}) do
    {:error, "Missing required arguments: name, component_ref"}
  end

  def handle("secret", %Context{} = ctx, %{
        "action" => "revoke",
        "name" => name,
        "component_ref" => component_ref
      } = args) do
    with {:ok, component_ref} <- normalize_ref(component_ref),
         :ok <- Sanctum.Sudo.maybe_require(ctx, args, "secret.revoke"),
         {:ok, status} <- Sanctum.Secrets.revoke(ctx, name, component_ref) do
      {:ok, %{status: status, secret: name, component: component_ref}}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Failed to revoke access: #{inspect(reason)}"}
    end
  end

  def handle("secret", _ctx, %{"action" => "revoke"}) do
    {:error, "Missing required arguments: name, component_ref"}
  end

  def handle("secret", %Context{} = ctx, %{"action" => "resolve_granted", "component_ref" => ref}) do
    with {:ok, ref} <- normalize_ref(ref) do
      case Sanctum.Secrets.resolve_granted_secrets(ctx, ref) do
        {:ok, secrets} -> {:ok, %{secrets: secrets}}
        {:error, reason} -> {:error, "Failed to resolve granted secrets: #{inspect(reason)}"}
      end
    end
  end

  def handle("secret", _ctx, %{"action" => "resolve_granted"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle("secret", %Context{} = ctx, %{"action" => "can_access", "name" => name, "component_ref" => ref}) do
    with {:ok, ref} <- normalize_ref(ref) do
      case Sanctum.Secrets.can_access?(ctx, name, ref) do
        {:ok, allowed} -> {:ok, %{allowed: allowed}}
        {:error, reason} -> {:error, "Failed to check secret access: #{inspect(reason)}"}
      end
    end
  end

  def handle("secret", _ctx, %{"action" => "can_access"}) do
    {:error, "Missing required arguments: name, component_ref"}
  end

  def handle("secret", _ctx, _args) do
    {:error, "Invalid secret action. Use: set, get, delete, list, grant, revoke, resolve_granted, or can_access"}
  end

  # ============================================================================
  # Permission Tool
  # ============================================================================

  def handle("permission", %Context{} = ctx, %{"action" => "list"}) do
    case Sanctum.Permission.list(ctx) do
      {:ok, entries} ->
        {:ok, %{permissions: entries, count: length(entries)}}

      {:error, reason} ->
        {:error, "Failed to list permissions: #{inspect(reason)}"}
    end
  end

  def handle("permission", %Context{} = ctx, %{"action" => "get", "subject" => subject}) do
    case Sanctum.Permission.get(ctx, subject) do
      {:ok, perms} ->
        {:ok, %{subject: subject, permissions: perms}}

      {:error, reason} ->
        {:error, "Failed to get permissions: #{inspect(reason)}"}
    end
  end

  def handle("permission", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: subject"}
  end

  def handle("permission", %Context{} = ctx, %{
        "action" => "set",
        "subject" => subject,
        "permissions" => perms
      } = args) do
    with :ok <- Sanctum.Sudo.maybe_require(ctx, args, "permission.set"),
         :ok <- Sanctum.Permission.set(ctx, subject, perms) do
      {:ok, %{updated: true, subject: subject, permissions: perms}}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Failed to set permissions: #{inspect(reason)}"}
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
    case Sanctum.ApiKey.list(ctx) do
      {:ok, keys} ->
        {:ok, %{keys: keys, count: length(keys)}}

      {:error, reason} ->
        {:error, "Failed to list keys: #{inspect(reason)}"}
    end
  end

  def handle("key", %Context{} = ctx, %{"action" => "get", "name" => name}) do
    case Sanctum.ApiKey.get(ctx, name) do
      {:ok, key_info} ->
        {:ok, key_info}

      {:error, :not_found} ->
        {:error, "Key not found: #{name}"}

      {:error, reason} ->
        {:error, "Failed to get key: #{inspect(reason)}"}
    end
  end

  def handle("key", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: name"}
  end

  def handle("key", %Context{} = ctx, %{"action" => "create", "name" => name} = args) do
    with :ok <- Sanctum.Sudo.maybe_require(ctx, args, "key.create"),
         {:ok, key_type} <- parse_key_type_arg(Map.get(args, "type", "public")) do
      opts = %{
        name: name,
        type: key_type,
        scope: Map.get(args, "scope", []),
        rate_limit: Map.get(args, "rate_limit"),
        ip_allowlist: Map.get(args, "ip_allowlist")
      }

      case Sanctum.ApiKey.create(ctx, opts) do
        {:ok, result} ->
          {:ok, result}

        {:error, :already_exists} ->
          {:error, "Key already exists: #{name}"}

        {:error, {:invalid_key_type, type}} ->
          {:error, "Invalid key type: #{type}. Use: public, secret, or admin"}

        {:error, reason} ->
          {:error, "Failed to create key: #{inspect(reason)}"}
      end
    end
  end

  def handle("key", _ctx, %{"action" => "create"}) do
    {:error, "Missing required argument: name"}
  end

  def handle("key", %Context{} = ctx, %{"action" => "revoke", "name" => name} = args) do
    with :ok <- Sanctum.Sudo.maybe_require(ctx, args, "key.revoke"),
         :ok <- Sanctum.ApiKey.revoke(ctx, name) do
      {:ok, %{revoked: true, name: name}}
    else
      {:error, :not_found} ->
        {:error, "Key not found: #{name}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Failed to revoke key: #{inspect(reason)}"}
    end
  end

  def handle("key", _ctx, %{"action" => "revoke"}) do
    {:error, "Missing required argument: name"}
  end

  def handle("key", %Context{} = ctx, %{"action" => "rotate", "name" => name} = args) do
    with :ok <- Sanctum.Sudo.maybe_require(ctx, args, "key.rotate") do
      case Sanctum.ApiKey.rotate(ctx, name) do
        {:ok, result} ->
          {:ok, result}

        {:error, :not_found} ->
          {:error, "Key not found: #{name}"}

        {:error, reason} ->
          {:error, "Failed to rotate key: #{inspect(reason)}"}
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
  # Audit Tool
  # ============================================================================

  def handle("audit", %Context{} = ctx, %{"action" => "list"} = args) do
    filters = Map.get(args, "filters", %{})
    # Audit.list/2 always returns {:ok, events} - errors are handled internally
    {:ok, events} = Sanctum.Audit.list(ctx, filters)
    {:ok, %{events: events, count: length(events)}}
  end

  def handle("audit", %Context{} = ctx, %{"action" => "export"} = args) do
    opts =
      args
      |> Map.get("filters", %{})
      |> Map.put(:format, Map.get(args, "format", "json"))

    case Sanctum.Audit.export(ctx, opts) do
      {:ok, data} ->
        {:ok, %{format: opts[:format], data: data}}

      {:error, reason} ->
        {:error, "Failed to export audit events: #{inspect(reason)}"}
    end
  end

  def handle("audit", %Context{} = ctx, %{"action" => "show", "execution_id" => exec_id}) do
    case Arca.MCP.handle("execution", ctx, %{"action" => "get", "id" => exec_id}) do
      {:error, _} ->
        {:error, "Execution not found: #{exec_id}"}

      {:ok, exec} ->
        {:ok, %{
          "execution_id" => exec.id,
          "reference" => decode_reference(exec.reference),
          "user_id" => exec.user_id,
          "component_type" => exec.component_type,
          "started_at" => exec.started_at,
          "completed_at" => exec.completed_at,
          "duration_ms" => exec.duration_ms,
          "status" => exec.status,
          "error_message" => exec.error_message,
          "input_hash" => exec.input_hash,
          "http_requests" => []  # Stubbed - populated when WASM HTTP proxy exists
        }}
    end
  end

  def handle("audit", _ctx, %{"action" => "show"}) do
    {:error, "Missing required argument: execution_id"}
  end

  def handle("audit", %Context{} = ctx, %{"action" => "executions"} = args) do
    limit = Map.get(args, "limit", 10)

    {:ok, result} = Arca.MCP.handle("execution", ctx, %{"action" => "list", "limit" => limit, "user_id" => ctx.user_id})
    executions = result.executions

    formatted = Enum.map(executions, fn exec ->
      %{
        "execution_id" => exec.id,
        "started_at" => exec.started_at,
        "reference" => format_ref_short(exec.reference),
        "status" => exec.status,
        "duration_ms" => exec.duration_ms
      }
    end)

    {:ok, %{"executions" => formatted, "count" => length(formatted)}}
  end

  def handle("audit", %Context{} = ctx, %{"action" => "log_violation"} = args) do
    attrs = %{
      component_ref: args["component_ref"],
      violation_type: args["violation_type"],
      details: args["details"],
      user_id: ctx.user_id,
      domain: args["domain"],
      method: args["method"],
      reason: args["reason"],
      timestamp: DateTime.utc_now()
    }

    Sanctum.PolicyLog.log_violation(attrs)
    {:ok, %{logged: true}}
  end

  def handle("audit", _ctx, _args) do
    {:error, "Invalid audit action. Use: list, export, show, executions, or log_violation"}
  end

  # ============================================================================
  # Policy Tool
  # ============================================================================

  def handle("policy", %Context{} = _ctx, %{"action" => "list"}) do
    case Sanctum.PolicyStore.list() do
      {:ok, policies} ->
        formatted = Enum.map(policies, fn %{component_ref: ref, policy: policy} ->
          %{component_ref: ref, policy: Map.from_struct(policy)}
        end)

        {:ok, %{policies: formatted, count: length(formatted)}}
    end
  end

  def handle("policy", %Context{} = _ctx, %{"action" => "get", "component_ref" => ref}) do
    with {:ok, ref} <- normalize_ref(ref) do
      case Sanctum.PolicyStore.get(ref) do
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

  def handle("policy", %Context{} = _ctx, %{"action" => "set", "component_ref" => ref, "policy" => policy_map}) do
    with {:ok, ref} <- normalize_ref(ref) do
      case Sanctum.PolicyStore.put(ref, policy_map) do
        :ok ->
          {:ok, %{stored: true, component_ref: ref}}

        {:error, reason} ->
          {:error, "Failed to set policy: #{inspect(reason)}"}
      end
    end
  end

  def handle("policy", _ctx, %{"action" => "set"}) do
    {:error, "Missing required arguments: component_ref, policy"}
  end

  def handle("policy", %Context{} = _ctx, %{
        "action" => "update_field",
        "component_ref" => ref,
        "field" => field,
        "value" => value
      }) do
    with {:ok, ref} <- normalize_ref(ref) do
      case Sanctum.PolicyStore.update_field(ref, field, value) do
        :ok ->
          {:ok, %{updated: true, component_ref: ref, field: field}}

        {:error, reason} ->
          {:error, "Failed to update policy field: #{inspect(reason)}"}
      end
    end
  end

  def handle("policy", _ctx, %{"action" => "update_field"}) do
    {:error, "Missing required arguments: component_ref, field, value"}
  end

  def handle("policy", %Context{} = _ctx, %{"action" => "delete", "component_ref" => ref}) do
    with {:ok, ref} <- normalize_ref(ref) do
      :ok = Sanctum.PolicyStore.delete(ref)
      {:ok, %{deleted: true, component_ref: ref}}
    end
  end

  def handle("policy", _ctx, %{"action" => "delete"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle("policy", %Context{} = ctx, %{"action" => "get_effective", "component_ref" => ref}) do
    with {:ok, ref} <- normalize_ref(ref) do
      case Sanctum.Policy.get_effective(ctx, ref) do
        {:ok, policy} -> {:ok, Sanctum.Policy.to_map(policy)}
        {:error, reason} -> {:error, "Failed to get effective policy: #{inspect(reason)}"}
      end
    end
  end

  def handle("policy", _ctx, %{"action" => "get_effective"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle("policy", %Context{} = ctx, %{"action" => "check_rate_limit", "component_ref" => ref}) do
    with {:ok, ref} <- normalize_ref(ref) do
      case Sanctum.PolicyStore.get(ref) do
        {:ok, policy} ->
          case Sanctum.Policy.check_rate_limit(policy, ctx, ref) do
            {:ok, remaining} -> {:ok, %{allowed: true, remaining: remaining}}
            {:error, :rate_limited, retry_after} -> {:ok, %{allowed: false, retry_after: retry_after}}
          end

        {:error, :not_found} ->
          # No policy = no rate limit
          {:ok, %{allowed: true, remaining: nil}}
      end
    end
  end

  def handle("policy", _ctx, %{"action" => "check_rate_limit"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle("policy", _ctx, _args) do
    {:error, "Invalid policy action. Use: get, set, update_field, delete, list, get_effective, or check_rate_limit"}
  end

  # ============================================================================
  # Config Tool
  # ============================================================================

  def handle("config", %Context{} = _ctx, %{"action" => "list"}) do
    case Sanctum.ComponentConfig.list_components(Sanctum.Context.local()) do
      {:ok, components} ->
        {:ok, %{components: components, count: length(components)}}
    end
  end

  def handle("config", %Context{} = _ctx, %{"action" => "get", "component_ref" => ref, "key" => key}) do
    with {:ok, ref} <- normalize_ref(ref) do
      case Sanctum.ComponentConfig.get(Sanctum.Context.local(), ref, key) do
        {:ok, value} ->
          {:ok, %{component_ref: ref, key: key, value: value}}

        {:error, :not_found} ->
          {:error, "Config key not found: #{key} for #{ref}"}
      end
    end
  end

  def handle("config", _ctx, %{"action" => "get"}) do
    {:error, "Missing required arguments: component_ref, key"}
  end

  def handle("config", %Context{} = _ctx, %{"action" => "get_all", "component_ref" => ref}) do
    with {:ok, ref} <- normalize_ref(ref) do
      case Sanctum.ComponentConfig.get_all(Sanctum.Context.local(), ref) do
        {:ok, config} ->
          {:ok, %{component_ref: ref, config: config}}
      end
    end
  end

  def handle("config", _ctx, %{"action" => "get_all"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle("config", %Context{} = _ctx, %{
        "action" => "set",
        "component_ref" => ref,
        "key" => key,
        "value" => value
      }) do
    with {:ok, ref} <- normalize_ref(ref) do
      case Sanctum.ComponentConfig.set(Sanctum.Context.local(), ref, key, value) do
        :ok ->
          {:ok, %{stored: true, component_ref: ref, key: key}}

        {:error, reason} ->
          {:error, "Failed to set config: #{inspect(reason)}"}
      end
    end
  end

  def handle("config", _ctx, %{"action" => "set"}) do
    {:error, "Missing required arguments: component_ref, key, value"}
  end

  def handle("config", %Context{} = _ctx, %{"action" => "delete", "component_ref" => ref, "key" => key}) do
    with {:ok, ref} <- normalize_ref(ref) do
      case Sanctum.ComponentConfig.delete(Sanctum.Context.local(), ref, key) do
        :ok ->
          {:ok, %{deleted: true, component_ref: ref, key: key}}

        {:error, reason} ->
          {:error, "Failed to delete config: #{inspect(reason)}"}
      end
    end
  end

  def handle("config", _ctx, %{"action" => "delete"}) do
    {:error, "Missing required arguments: component_ref, key"}
  end

  def handle("config", _ctx, _args) do
    {:error, "Invalid config action. Use: get, get_all, set, delete, or list"}
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
    case Sanctum.ComponentRef.normalize(ref) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _} = error -> error
    end
  end
  defp normalize_ref(ref), do: {:ok, ref}

  defp parse_key_type_arg("public"), do: {:ok, :public}
  defp parse_key_type_arg("secret"), do: {:ok, :secret}
  defp parse_key_type_arg("admin"), do: {:ok, :admin}
  defp parse_key_type_arg(invalid), do: {:error, "Invalid key type: #{invalid}. Use: public, secret, or admin"}

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

  defp decode_reference(ref) when is_binary(ref) do
    case Jason.decode(ref) do
      {:ok, decoded} -> decoded
      _ -> ref
    end
  end
  defp decode_reference(ref), do: ref


  defp format_ref_short(ref_json) when is_binary(ref_json) do
    case Jason.decode(ref_json) do
      {:ok, %{"local" => path}} -> Path.basename(path)
      {:ok, %{"oci" => oci}} -> oci
      {:ok, %{"registry" => ref}} -> ref
      _ -> "unknown"
    end
  end
  defp format_ref_short(_), do: "unknown"
end
