defmodule Arca.MCP do
  @moduledoc """
  MCP tool provider for Arca storage service.

  Exposes Arca's storage operations as a single `storage` tool with action-based dispatch:
  - `list` - List files/directories at a path
  - `read` - Read file contents (base64)
  - `write` - Write content to a file
  - `delete` - Delete a file
  - `retention` - Manage retention policies

  ## Access Levels

  Per PRD requirements:
  - `read` and `list` require `application` level (any valid key)
  - `write`, `delete`, and `retention.set/cleanup` require `admin` level

  ## Path Format

  Paths can be specified as either:
  - String: `"artifacts/my-tool/file.txt"`
  - Array: `["artifacts", "my-tool", "file.txt"]`

  ## Retention Action

  The `retention` action manages data retention policies:

      # Get current settings
      {"action": "retention", "retention_action": "get"}

      # Update settings (admin only)
      {"action": "retention", "retention_action": "set",
       "settings": {"executions": 5, "builds": 3, "audit_days": 14}}

      # Run cleanup (admin only)
      {"action": "retention", "retention_action": "cleanup",
       "cleanup_type": "executions", "dry_run": false}

  ## Architecture Note

  This module lives in the `arca` app, keeping tool definitions
  close to their implementation. Emissary discovers this provider
  via configuration and delegates calls here.

  Implements the ToolProvider protocol (tools/0 and handle/3)
  which is validated at runtime by Emissary.MCP.ToolRegistry.
  """

  alias Arca.AccessLevel
  alias Sanctum.Context

  # ============================================================================
  # ToolProvider Protocol (validated at runtime)
  # ============================================================================

  @path_schema %{
    "oneOf" => [
      %{"type" => "string", "description" => "Path as string, e.g. \"artifacts/my-tool/file.txt\""},
      %{"type" => "array", "items" => %{"type" => "string"}, "description" => "Path as segments, e.g. [\"artifacts\", \"my-tool\"]"}
    ],
    "description" => "Path (string or array of segments)"
  }

  # ============================================================================
  # ResourceProvider Protocol
  # ============================================================================

  @doc """
  Returns available Arca resources.
  """
  def resources do
    [
      %{
        uri: "arca://files/{path}",
        name: "Arca Files",
        description: "Read files from Arca storage by path",
        mimeType: "application/octet-stream"
      }
    ]
  end

  @doc """
  Read a resource by URI.
  """
  def read(%Context{} = ctx, "arca://files/" <> path) do
    segments = String.split(path, "/") |> Enum.reject(&(&1 == ""))

    case Arca.get(ctx, segments) do
      {:ok, content} ->
        {:ok, %{content: Base.encode64(content), mimeType: "application/octet-stream"}}

      {:error, :not_found} ->
        {:error, "File not found: #{path}"}

      {:error, reason} ->
        {:error, "Failed to read: #{inspect(reason)}"}
    end
  end

  def read(_ctx, uri) do
    {:error, "Unknown resource URI: #{uri}"}
  end

  def tools do
    [
      %{
        name: "secret_store",
        title: "Secret Storage",
        description: "Manage encrypted secrets storage - put, get, list, delete secrets and grants",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["put", "get", "list", "delete", "put_grant", "delete_grant", "list_grants", "grants_for_component"],
              "description" => "Action to perform"
            },
            "name" => %{"type" => "string", "description" => "Secret name"},
            "encrypted_value" => %{"type" => "string", "description" => "Base64-encoded encrypted value"},
            "scope" => %{"type" => "string", "description" => "Scope (personal or org)"},
            "org_id" => %{"type" => "string", "description" => "Organization ID"},
            "component_ref" => %{"type" => "string", "description" => "Component reference in canonical format: namespace.name:version (e.g., 'local.my-tool:1.0.0')"}
          },
          "required" => ["action"]
        }
      },
      %{
        name: "session_store",
        title: "Session Storage",
        description: "Manage session storage - create, get, refresh, delete, list, cleanup sessions and revocations",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["create", "get", "refresh", "delete", "list_active", "cleanup_expired", "put_revocation", "check_revoked", "cleanup_revocations"],
              "description" => "Action to perform"
            },
            "token_hash" => %{"type" => "string", "description" => "Base64-encoded token hash"},
            "attrs" => %{"type" => "object", "description" => "Session attributes"},
            "new_expires_at" => %{"type" => "string", "description" => "ISO 8601 new expiration time"},
            "session_id" => %{"type" => "string", "description" => "Session ID for revocation"},
            "revoked_at" => %{"type" => "string", "description" => "ISO 8601 revocation time"},
            "expires_at" => %{"type" => "string", "description" => "ISO 8601 revocation expiry"}
          },
          "required" => ["action"]
        }
      },
      %{
        name: "api_key_store",
        title: "API Key Storage",
        description: "Manage API key storage - create, get, list, revoke, rotate keys",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["create", "get", "get_by_hash", "list", "revoke", "rotate"],
              "description" => "Action to perform"
            },
            "attrs" => %{"type" => "object", "description" => "Key attributes for create"},
            "name" => %{"type" => "string", "description" => "Key name"},
            "scope_type" => %{"type" => "string", "description" => "Scope type"},
            "org_id" => %{"type" => "string", "description" => "Organization ID"},
            "key_hash" => %{"type" => "string", "description" => "Base64-encoded key hash"},
            "new_key_hash" => %{"type" => "string", "description" => "Base64-encoded new key hash for rotation"},
            "new_key_prefix" => %{"type" => "string", "description" => "New key prefix for rotation"}
          },
          "required" => ["action"]
        }
      },
      %{
        name: "permission_store",
        title: "Permission Storage",
        description: "Manage permission storage - get, set, list, delete permissions",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["get", "set", "list", "delete"],
              "description" => "Action to perform"
            },
            "subject" => %{"type" => "string", "description" => "Subject identifier"},
            "permissions" => %{"type" => "string", "description" => "JSON-encoded permissions"},
            "scope_type" => %{"type" => "string", "description" => "Scope type"},
            "org_id" => %{"type" => "string", "description" => "Organization ID"}
          },
          "required" => ["action"]
        }
      },
      %{
        name: "policy_store",
        title: "Policy Storage",
        description: "Manage policy storage - get, put, delete, list policies",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["get", "put", "delete", "list"],
              "description" => "Action to perform"
            },
            "component_ref" => %{"type" => "string", "description" => "Component reference in canonical format: namespace.name:version (e.g., 'local.my-tool:1.0.0')"},
            "attrs" => %{"type" => "object", "description" => "Policy attributes for put"}
          },
          "required" => ["action"]
        }
      },
      %{
        name: "component_config_store",
        title: "Component Config Storage",
        description: "Manage per-component user config overrides in SQLite - get_all, put, delete, delete_all, list",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["get_all", "put", "delete", "delete_all", "list"],
              "description" => "Action to perform"
            },
            "component_ref" => %{"type" => "string", "description" => "Component reference in canonical format: namespace.name:version (e.g., 'local.stripe-catalyst:1.0.0')"},
            "key" => %{"type" => "string", "description" => "Config key name"},
            "value" => %{"description" => "Config value (any JSON type)"}
          },
          "required" => ["action"]
        }
      },
      %{
        name: "component_store",
        title: "Component Storage",
        description: "Manage component storage - put, get, list, delete, check existence",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["put", "get", "list", "delete", "exists"],
              "description" => "Action to perform"
            },
            "attrs" => %{"type" => "object", "description" => "Component attributes for put"},
            "name" => %{"type" => "string", "description" => "Component name"},
            "version" => %{"type" => "string", "description" => "Component version"},
            "publisher" => %{"type" => "string", "description" => "Filter by publisher namespace"},
            "component_type" => %{"type" => "string", "description" => "Filter by component type"},
            "query" => %{"type" => "string", "description" => "Search query"},
            "category" => %{"type" => "string", "description" => "Filter by category"},
            "limit" => %{"type" => "integer", "description" => "Max results to return"}
          },
          "required" => ["action"]
        }
      },
      %{
        name: "execution",
        title: "Execution Records",
        description: "Manage execution records - record start/complete, get, or list executions",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["record_start", "record_complete", "get", "list"],
              "description" => "Action to perform"
            },
            "id" => %{
              "type" => "string",
              "description" => "Execution ID"
            },
            "reference" => %{
              "type" => "string",
              "description" => "JSON-encoded component reference"
            },
            "input_hash" => %{
              "type" => "string",
              "description" => "SHA256 hash of input"
            },
            "user_id" => %{
              "type" => "string",
              "description" => "User who initiated execution"
            },
            "component_type" => %{
              "type" => "string",
              "description" => "Component type: catalyst, reagent, or formula"
            },
            "component_digest" => %{
              "type" => "string",
              "description" => "SHA256 digest of the WASM component"
            },
            "started_at" => %{
              "type" => "string",
              "description" => "ISO 8601 timestamp when execution started"
            },
            "completed_at" => %{
              "type" => "string",
              "description" => "ISO 8601 timestamp when execution completed"
            },
            "duration_ms" => %{
              "type" => "integer",
              "description" => "Execution duration in milliseconds"
            },
            "status" => %{
              "type" => "string",
              "description" => "Execution status: running, completed, failed, cancelled"
            },
            "error_message" => %{
              "type" => "string",
              "description" => "Error message if execution failed"
            },
            "limit" => %{
              "type" => "integer",
              "description" => "Maximum number of records to return (default: 20)"
            }
          },
          "required" => ["action"]
        }
      },
      %{
        name: "mcp_log",
        title: "MCP Request Logs",
        description: "Manage MCP request logs - log started/completed/failed, list, get, or correlate logs",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["log_started", "log_completed", "log_failed", "list", "get", "delete", "correlate"],
              "description" => "Action to perform"
            },
            "id" => %{"type" => "string", "description" => "Request ID"},
            "request_id" => %{"type" => "string", "description" => "Request ID for correlation"},
            "tool" => %{"type" => "string", "description" => "Tool name (for log_started)"},
            "tool_action" => %{"type" => "string", "description" => "Action within tool (for log_started)"},
            "method" => %{"type" => "string", "description" => "MCP method (for log_started)"},
            "input" => %{"type" => "object", "description" => "Request input (for log_started)"},
            "output" => %{"type" => "object", "description" => "Response output (for log_completed)"},
            "error" => %{"type" => "string", "description" => "Error message (for log_failed)"},
            "error_code" => %{"type" => "integer", "description" => "JSON-RPC error code (for log_failed)"},
            "duration_ms" => %{"type" => "integer", "description" => "Request duration in ms"},
            "routed_to" => %{"type" => "string", "description" => "Service that handled request"},
            "user_id" => %{"type" => "string", "description" => "Filter by user ID"},
            "session_id" => %{"type" => "string", "description" => "Filter by session ID"},
            "status" => %{"type" => "string", "description" => "Filter by status"},
            "limit" => %{"type" => "integer", "description" => "Max results (default: 20)"}
          },
          "required" => ["action"]
        }
      },
      %{
        name: "policy_log",
        title: "Policy Logs",
        description: "Manage policy consultation logs - log, list, get, or correlate logs",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["log", "list", "get", "delete", "correlate"],
              "description" => "Action to perform"
            },
            "id" => %{"type" => "string", "description" => "Policy log ID"},
            "request_id" => %{"type" => "string", "description" => "Filter by request ID"},
            "execution_id" => %{"type" => "string", "description" => "Filter by execution ID"},
            "component_ref" => %{"type" => "string", "description" => "Component reference in canonical format: namespace.name:version (e.g., 'local.my-tool:1.0.0')"},
            "component_type" => %{"type" => "string", "description" => "Component type"},
            "host_policy_snapshot" => %{"type" => "object", "description" => "Policy snapshot"},
            "decision" => %{"type" => "string", "description" => "Policy decision"},
            "decision_reason" => %{"type" => "string", "description" => "Reason for decision"},
            "user_id" => %{"type" => "string", "description" => "Filter by user ID"},
            "event_type" => %{"type" => "string", "description" => "Filter by event type"},
            "limit" => %{"type" => "integer", "description" => "Max results (default: 20)"}
          },
          "required" => ["action"]
        }
      },
      %{
        name: "audit_log",
        title: "Audit Events",
        description: "Manage audit events - log, list, get, or correlate events",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["log", "list", "get", "correlate"],
              "description" => "Action to perform"
            },
            "id" => %{"type" => "string", "description" => "Audit event ID"},
            "request_id" => %{"type" => "string", "description" => "Filter by request ID"},
            "user_id" => %{"type" => "string", "description" => "Filter by user ID"},
            "event_type" => %{"type" => "string", "description" => "Event type (for log action)"},
            "data" => %{"type" => "object", "description" => "Event data (for log action)"},
            "limit" => %{"type" => "integer", "description" => "Max results (default: 20)"}
          },
          "required" => ["action"]
        }
      },
      %{
        name: "storage",
        title: "Storage",
        description: "Manage file storage and retention policies",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["list", "read", "write", "delete", "retention"],
              "description" => "Action to perform"
            },
            "path" => @path_schema,
            "content" => %{
              "type" => "string",
              "description" => "Base64-encoded file content (required for write action)"
            },
            "retention_action" => %{
              "type" => "string",
              "enum" => ["get", "set", "cleanup"],
              "description" => "Retention sub-action: get settings, set settings, or run cleanup"
            },
            "settings" => %{
              "type" => "object",
              "properties" => %{
                "executions" => %{"type" => "integer", "description" => "Number of executions to keep per user"},
                "builds" => %{"type" => "integer", "description" => "Number of builds to keep per user"},
                "audit_days" => %{"type" => "integer", "description" => "Number of days to keep audit logs"}
              },
              "description" => "Retention settings (for retention action with set)"
            },
            "cleanup_type" => %{
              "type" => "string",
              "enum" => ["executions", "builds", "audit"],
              "description" => "Type of data to clean up (for retention action with cleanup)"
            },
            "dry_run" => %{
              "type" => "boolean",
              "description" => "If true, show what would be deleted without actually deleting"
            }
          },
          "required" => ["action"]
        }
      }
    ]
  end

  # ============================================================================
  # Execution Tool
  # ============================================================================

  def handle("execution", ctx, %{"action" => "record_start"} = args) do
    user_id = args["user_id"] || ctx.user_id
    started_at_str = args["started_at"] || DateTime.to_iso8601(DateTime.utc_now())
    reference = parse_json_string(args["reference"])

    case Arca.Execution.record_start(%{
      id: args["id"],
      request_id: args["request_id"],
      reference: encode_if_map(reference),
      input_hash: args["input_hash"] || hash_input(args["input"]),
      user_id: user_id,
      component_type: to_string(args["component_type"] || "reagent"),
      component_digest: args["component_digest"],
      started_at: parse_datetime(started_at_str),
      status: "running",
      input: encode_json(args["input"] || %{}),
      host_policy: encode_json(args["host_policy"]),
      parent_execution_id: args["parent_execution_id"]
    }) do
      {:ok, _} -> {:ok, %{recorded: true}}
      {:error, reason} -> {:error, "Failed to record start: #{inspect(reason)}"}
    end
  end

  def handle("execution", _ctx, %{"action" => "record_complete", "id" => id} = args) do
    status = to_string(args["status"] || "completed")
    completed_at_str = args["completed_at"] || DateTime.to_iso8601(DateTime.utc_now())

    case Arca.Execution.record_complete(id, %{
      completed_at: parse_datetime(completed_at_str),
      duration_ms: args["duration_ms"],
      status: status,
      error_message: args["error_message"],
      output: encode_json(args["output"]),
      wasi_trace: encode_json(args["wasi_trace"])
    }) do
      {:ok, _} -> {:ok, %{recorded: true}}
      {:error, reason} -> {:error, "Failed to record completion: #{inspect(reason)}"}
    end
  end

  def handle("execution", _ctx, %{"action" => "record_complete"}) do
    {:error, "Missing required argument: id"}
  end

  def handle("execution", _ctx, %{"action" => "get", "id" => id}) do
    case Arca.Execution.get(id) do
      nil -> {:error, "Execution not found: #{id}"}
      record -> {:ok, execution_to_map(record)}
    end
  end

  def handle("execution", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: id"}
  end

  def handle("execution", ctx, %{"action" => "list"} = args) do
    opts = [limit: args["limit"] || 20]
    user_id = args["user_id"] || (ctx && ctx.user_id)
    opts = if user_id, do: Keyword.put(opts, :user_id, user_id), else: opts
    opts = if args["status"], do: Keyword.put(opts, :status, args["status"]), else: opts
    opts = if args["parent_execution_id"], do: Keyword.put(opts, :parent_execution_id, args["parent_execution_id"]), else: opts

    records = Arca.Execution.list(opts)
    {:ok, %{executions: Enum.map(records, &execution_to_map/1)}}
  end

  def handle("execution", _ctx, _args) do
    {:error, "Invalid execution action. Use: record_start, record_complete, get, or list"}
  end

  # ============================================================================
  # MCP Log Tool
  # ============================================================================

  def handle("mcp_log", ctx, %{"action" => "log_started", "id" => id} = args) do
    now = DateTime.utc_now()

    case Arca.McpLog.record(%{
      id: id,
      session_id: ctx && ctx.session_id,
      user_id: (ctx && ctx.user_id) || args["user_id"] || "system",
      timestamp: now,
      tool: args["tool"],
      action: args["tool_action"],
      method: args["method"],
      status: "pending",
      input: encode_json(args["input"] || %{})
    }) do
      {:ok, _} -> {:ok, %{logged: true}}
      {:error, reason} -> {:error, "Failed to log started: #{inspect(reason)}"}
    end
  end

  def handle("mcp_log", _ctx, %{"action" => "log_started"}) do
    {:error, "Missing required argument: id"}
  end

  def handle("mcp_log", _ctx, %{"action" => "log_completed", "id" => id} = args) do
    case Arca.McpLog.record_update(id, %{
      status: "success",
      duration_ms: args["duration_ms"],
      routed_to: args["routed_to"],
      output: encode_json(args["output"])
    }) do
      {:ok, _} -> {:ok, %{logged: true}}
      {:error, reason} -> {:error, "Failed to log completed: #{inspect(reason)}"}
    end
  end

  def handle("mcp_log", _ctx, %{"action" => "log_completed"}) do
    {:error, "Missing required argument: id"}
  end

  def handle("mcp_log", _ctx, %{"action" => "log_failed", "id" => id} = args) do
    case Arca.McpLog.record_update(id, %{
      status: "error",
      error_code: args["error_code"],
      duration_ms: args["duration_ms"],
      error: args["error"]
    }) do
      {:ok, _} -> {:ok, %{logged: true}}
      {:error, reason} -> {:error, "Failed to log failed: #{inspect(reason)}"}
    end
  end

  def handle("mcp_log", _ctx, %{"action" => "log_failed"}) do
    {:error, "Missing required argument: id"}
  end

  def handle("mcp_log", _ctx, %{"action" => "get", "id" => id}) do
    case Arca.McpLog.get(id) do
      nil -> {:error, "MCP log not found: #{id}"}
      record -> {:ok, mcp_log_to_map(record)}
    end
  end

  def handle("mcp_log", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: id"}
  end

  def handle("mcp_log", ctx, %{"action" => "list"} = args) do
    opts = [limit: args["limit"] || 20]
    user_id = args["user_id"] || (ctx && ctx.user_id)
    opts = if user_id, do: Keyword.put(opts, :user_id, user_id), else: opts
    opts = if args["status"], do: Keyword.put(opts, :status, args["status"]), else: opts
    session_id = args["session_id"] || (ctx && ctx.session_id)
    opts = if session_id, do: Keyword.put(opts, :session_id, session_id), else: opts

    records = Arca.McpLog.list(opts)
    {:ok, %{logs: Enum.map(records, &mcp_log_to_map/1)}}
  end

  def handle("mcp_log", _ctx, %{"action" => "delete", "id" => id}) do
    case Arca.McpLog.get(id) do
      nil -> {:error, "MCP log not found: #{id}"}
      record ->
        case Arca.Repo.delete(record) do
          {:ok, _} -> {:ok, %{deleted: true}}
          {:error, reason} -> {:error, "Failed to delete MCP log: #{inspect(reason)}"}
        end
    end
  end

  def handle("mcp_log", _ctx, %{"action" => "delete"}) do
    {:error, "Missing required argument: id"}
  end

  def handle("mcp_log", _ctx, %{"action" => "correlate", "request_id" => request_id}) do
    mcp_logs =
      case Arca.McpLog.get(request_id) do
        nil -> []
        log -> [mcp_log_to_map(log)]
      end

    import Ecto.Query
    executions =
      from(e in Arca.Execution, where: e.request_id == ^request_id, order_by: [desc: e.started_at], limit: 100)
      |> Arca.Repo.all()
      |> Enum.map(&execution_to_map/1)

    policy_logs = Arca.PolicyLog.list(request_id: request_id, limit: 100)
    |> Enum.map(&policy_log_to_map/1)

    audit_events = Arca.AuditEvent.list(request_id: request_id, limit: 100)
    |> Enum.map(&audit_event_to_map/1)

    {:ok, %{
      request_id: request_id,
      mcp_logs: mcp_logs,
      executions: executions,
      policy_logs: policy_logs,
      audit_events: audit_events
    }}
  end

  def handle("mcp_log", _ctx, %{"action" => "correlate"}) do
    {:error, "Missing required argument: request_id"}
  end

  def handle("mcp_log", _ctx, _args) do
    {:error, "Invalid mcp_log action. Use: log_started, log_completed, log_failed, list, get, delete, or correlate"}
  end

  # ============================================================================
  # Policy Log Tool
  # ============================================================================

  def handle("policy_log", ctx, %{"action" => "log"} = args) do
    request_id = (ctx && ctx.request_id) || generate_id("req")
    now = DateTime.utc_now()
    component_ref = normalize_component_ref(args["component_ref"])

    case Arca.PolicyLog.record(%{
      id: generate_id("plog"),
      request_id: request_id,
      execution_id: args["execution_id"],
      session_id: ctx && ctx.session_id,
      user_id: args["user_id"] || (ctx && ctx.user_id),
      timestamp: now,
      event_type: args["event_type"] || "policy_consultation",
      component_ref: component_ref,
      component_type: normalize_component_type(args["component_type"]),
      decision: args["decision"],
      host_policy_snapshot: encode_json(args["host_policy_snapshot"] || %{}),
      decision_reason: args["decision_reason"]
    }) do
      {:ok, _} -> {:ok, %{logged: true}}
      {:error, reason} -> {:error, "Failed to log policy consultation: #{inspect(reason)}"}
    end
  end

  def handle("policy_log", _ctx, %{"action" => "get", "id" => id}) do
    record = Arca.PolicyLog.get(id) || Arca.PolicyLog.get_by_request_id(id)

    case record do
      nil -> {:error, "Policy log not found: #{id}"}
      record -> {:ok, policy_log_to_map(record)}
    end
  end

  def handle("policy_log", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: id"}
  end

  def handle("policy_log", ctx, %{"action" => "list"} = args) do
    opts = [limit: args["limit"] || 20]
    user_id = args["user_id"] || (ctx && ctx.user_id)
    opts = if user_id, do: Keyword.put(opts, :user_id, user_id), else: opts
    opts = if args["request_id"], do: Keyword.put(opts, :request_id, args["request_id"]), else: opts
    opts = if args["execution_id"], do: Keyword.put(opts, :execution_id, args["execution_id"]), else: opts
    opts = if args["event_type"], do: Keyword.put(opts, :event_type, args["event_type"]), else: opts

    records = Arca.PolicyLog.list(opts)
    {:ok, %{logs: Enum.map(records, &policy_log_to_map/1)}}
  end

  def handle("policy_log", _ctx, %{"action" => "delete", "id" => id}) do
    record = Arca.PolicyLog.get(id) || Arca.PolicyLog.get_by_request_id(id)

    case record do
      nil -> {:error, "Policy log not found: #{id}"}
      record ->
        case Arca.Repo.delete(record) do
          {:ok, _} -> {:ok, %{deleted: true}}
          {:error, reason} -> {:error, "Failed to delete policy log: #{inspect(reason)}"}
        end
    end
  end

  def handle("policy_log", _ctx, %{"action" => "delete"}) do
    {:error, "Missing required argument: id"}
  end

  def handle("policy_log", _ctx, %{"action" => "correlate", "request_id" => request_id}) do
    policy_logs = Arca.PolicyLog.list(request_id: request_id, limit: 100)
    |> Enum.map(&policy_log_to_map/1)

    {:ok, %{request_id: request_id, policy_logs: policy_logs}}
  end

  def handle("policy_log", _ctx, %{"action" => "correlate"}) do
    {:error, "Missing required argument: request_id"}
  end

  def handle("policy_log", _ctx, _args) do
    {:error, "Invalid policy_log action. Use: log, list, get, delete, or correlate"}
  end

  # ============================================================================
  # Audit Log Tool
  # ============================================================================

  def handle("audit_log", ctx, %{"action" => "log"} = args) do
    now = DateTime.utc_now()

    case Arca.AuditEvent.record(%{
      id: generate_id("audit"),
      request_id: ctx && ctx.request_id,
      session_id: ctx && ctx.session_id,
      user_id: args["user_id"] || (ctx && ctx.user_id),
      timestamp: now,
      event_type: args["event_type"],
      data: encode_json(args["data"] || %{})
    }) do
      {:ok, _} -> {:ok, %{logged: true}}
      {:error, reason} -> {:error, "Failed to log audit event: #{inspect(reason)}"}
    end
  end

  def handle("audit_log", _ctx, %{"action" => "get", "id" => id}) do
    case Arca.AuditEvent.get(id) do
      nil -> {:error, "Audit event not found: #{id}"}
      record -> {:ok, audit_event_to_map(record)}
    end
  end

  def handle("audit_log", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: id"}
  end

  def handle("audit_log", ctx, %{"action" => "list"} = args) do
    opts = [limit: args["limit"] || 20]
    user_id = args["user_id"] || (ctx && ctx.user_id)
    opts = if user_id, do: Keyword.put(opts, :user_id, user_id), else: opts
    opts = if args["request_id"], do: Keyword.put(opts, :request_id, args["request_id"]), else: opts
    opts = if args["event_type"], do: Keyword.put(opts, :event_type, args["event_type"]), else: opts

    records = Arca.AuditEvent.list(opts)
    {:ok, %{events: Enum.map(records, &audit_event_to_map/1)}}
  end

  def handle("audit_log", _ctx, %{"action" => "correlate", "request_id" => request_id}) do
    audit_events = Arca.AuditEvent.list(request_id: request_id, limit: 100)
    |> Enum.map(&audit_event_to_map/1)

    {:ok, %{request_id: request_id, audit_events: audit_events}}
  end

  def handle("audit_log", _ctx, %{"action" => "correlate"}) do
    {:error, "Missing required argument: request_id"}
  end

  def handle("audit_log", _ctx, _args) do
    {:error, "Invalid audit_log action. Use: log, list, get, or correlate"}
  end

  # ============================================================================
  # Storage Tool - List Action
  # ============================================================================

  def handle("storage", %Context{} = ctx, %{"action" => "list", "path" => raw_path}) do
    with :ok <- AccessLevel.authorize(ctx, :list) do
      path = normalize_path(raw_path)

      case Arca.list(ctx, path) do
        {:ok, files} ->
          {:ok, %{path: Enum.join(path, "/"), files: files}}

        {:error, reason} ->
          {:error, "Failed to list path: #{inspect(reason)}"}
      end
    else
      {:error, :unauthorized} ->
        {:error, "Unauthorized: list action requires application-level access or higher"}
    end
  end

  # ============================================================================
  # Storage Tool - Read Action
  # ============================================================================

  def handle("storage", %Context{} = ctx, %{"action" => "read", "path" => raw_path}) do
    with :ok <- AccessLevel.authorize(ctx, :read) do
      path = normalize_path(raw_path)

      case Arca.get(ctx, path) do
        {:ok, content} ->
          {:ok,
           %{
             path: Enum.join(path, "/"),
             content: Base.encode64(content),
             size: byte_size(content),
             encoding: "base64"
           }}

        {:error, :not_found} ->
          {:error, "File not found: #{Enum.join(path, "/")}"}

        {:error, reason} ->
          {:error, "Failed to read file: #{inspect(reason)}"}
      end
    else
      {:error, :unauthorized} ->
        {:error, "Unauthorized: read action requires application-level access or higher"}
    end
  end

  # ============================================================================
  # Storage Tool - Write Action
  # ============================================================================

  def handle("storage", %Context{} = ctx, %{"action" => "write", "path" => raw_path, "content" => b64_content})
      when is_binary(b64_content) do
    with :ok <- AccessLevel.authorize(ctx, :write) do
      path = normalize_path(raw_path)

      case Base.decode64(b64_content) do
        {:ok, content} ->
          case Arca.put(ctx, path, content) do
            :ok ->
              {:ok, %{written: true, path: Enum.join(path, "/"), size: byte_size(content)}}

            {:error, reason} ->
              {:error, "Failed to write file: #{inspect(reason)}"}
          end

        :error ->
          {:error, "Invalid base64 content"}
      end
    else
      {:error, :unauthorized} ->
        {:error, "Unauthorized: write action requires admin-level access"}
    end
  end

  def handle("storage", _ctx, %{"action" => "write", "path" => _path}) do
    {:error, "Missing required argument: content"}
  end

  # ============================================================================
  # Storage Tool - Delete Action
  # ============================================================================

  def handle("storage", %Context{} = ctx, %{"action" => "delete", "path" => raw_path}) do
    with :ok <- AccessLevel.authorize(ctx, :delete) do
      path = normalize_path(raw_path)

      case Arca.delete(ctx, path) do
        :ok ->
          {:ok, %{deleted: true, path: Enum.join(path, "/")}}

        {:error, :not_found} ->
          {:error, "File not found: #{Enum.join(path, "/")}"}

        {:error, reason} ->
          {:error, "Failed to delete file: #{inspect(reason)}"}
      end
    else
      {:error, :unauthorized} ->
        {:error, "Unauthorized: delete action requires admin-level access"}
    end
  end

  # ============================================================================
  # Storage Tool - Retention Action
  # ============================================================================

  def handle("storage", %Context{} = ctx, %{"action" => "retention", "retention_action" => "get"}) do
    settings = Arca.Retention.get_settings(ctx)
    {:ok, %{action: "retention", settings: settings}}
  end

  def handle("storage", %Context{} = ctx, %{"action" => "retention", "retention_action" => "set", "settings" => settings})
      when is_map(settings) do
    with :ok <- AccessLevel.authorize(ctx, :write) do
      case Arca.Retention.set_settings(ctx, settings) do
        :ok ->
          new_settings = Arca.Retention.get_settings(ctx)
          {:ok, %{action: "retention", updated: true, settings: new_settings}}

        {:error, reason} ->
          {:error, "Failed to update retention settings: #{inspect(reason)}"}
      end
    else
      {:error, :unauthorized} ->
        {:error, "Unauthorized: setting retention requires admin-level access"}
    end
  end

  def handle("storage", %Context{} = ctx, %{"action" => "retention", "retention_action" => "cleanup"} = args) do
    with :ok <- AccessLevel.authorize(ctx, :delete) do
      cleanup_type = Map.get(args, "cleanup_type", "executions")
      dry_run = Map.get(args, "dry_run", false)

      result = case cleanup_type do
        "executions" -> Arca.Retention.cleanup_executions(ctx, dry_run: dry_run)
        "builds" -> Arca.Retention.cleanup_builds(ctx, dry_run: dry_run)
        "audit" -> Arca.Retention.cleanup_audit(ctx, dry_run: dry_run)
        _ -> {:error, "Unknown cleanup_type: #{cleanup_type}"}
      end

      case result do
        {:ok, count} when is_integer(count) ->
          {:ok, %{action: "retention", cleanup_type: cleanup_type, deleted: count}}

        {:ok, %{would_delete: ids} = info} ->
          {:ok, %{action: "retention", cleanup_type: cleanup_type, dry_run: true, would_delete: ids, would_keep: info[:would_keep]}}

        {:error, reason} ->
          {:error, "Cleanup failed: #{inspect(reason)}"}
      end
    else
      {:error, :unauthorized} ->
        {:error, "Unauthorized: cleanup requires admin-level access"}
    end
  end

  def handle("storage", _ctx, %{"action" => "retention"}) do
    {:error, "Missing required argument: retention_action (get, set, or cleanup)"}
  end

  # ============================================================================
  # Storage Tool - Error Handlers
  # ============================================================================

  def handle("storage", _ctx, %{"action" => action}) when action in ["list", "read", "write", "delete"] do
    {:error, "Missing required argument: path"}
  end

  def handle("storage", _ctx, %{"action" => action, "path" => _path}) do
    {:error, "Invalid action: #{action}. Use: list, read, write, delete, or retention"}
  end

  def handle("storage", _ctx, %{"path" => _path}) do
    {:error, "Missing required argument: action"}
  end

  def handle("storage", _ctx, _args) do
    {:error, "Missing required arguments: action, path"}
  end

  # ============================================================================
  # Secret Store Tool
  # ============================================================================

  def handle("secret_store", _ctx, %{"action" => "put", "name" => name, "encrypted_value" => b64_value, "scope" => scope} = args) do
    org_id = args["org_id"]
    case Base.decode64(b64_value) do
      {:ok, encrypted} ->
        case Arca.SecretStorage.put_secret(name, encrypted, scope, org_id) do
          :ok -> {:ok, %{stored: true}}
          {:error, reason} -> {:error, "Failed to put secret: #{inspect(reason)}"}
        end
      :error ->
        {:error, "Invalid base64 encrypted_value"}
    end
  end

  def handle("secret_store", _ctx, %{"action" => "put"}) do
    {:error, "Missing required arguments: name, encrypted_value, scope"}
  end

  def handle("secret_store", _ctx, %{"action" => "get", "name" => name, "scope" => scope} = args) do
    org_id = args["org_id"]
    case Arca.SecretStorage.get_secret(name, scope, org_id) do
      {:ok, encrypted} -> {:ok, %{encrypted_value: Base.encode64(encrypted)}}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  def handle("secret_store", _ctx, %{"action" => "get"}) do
    {:error, "Missing required arguments: name, scope"}
  end

  def handle("secret_store", _ctx, %{"action" => "list", "scope" => scope} = args) do
    org_id = args["org_id"]
    case Arca.SecretStorage.list_secrets(scope, org_id) do
      {:ok, names} -> {:ok, %{names: names}}
    end
  end

  def handle("secret_store", _ctx, %{"action" => "list"}) do
    {:error, "Missing required argument: scope"}
  end

  def handle("secret_store", _ctx, %{"action" => "delete", "name" => name, "scope" => scope} = args) do
    org_id = args["org_id"]
    case Arca.SecretStorage.delete_secret(name, scope, org_id) do
      :ok -> {:ok, %{deleted: true}}
      {:error, reason} -> {:error, "Failed to delete secret: #{inspect(reason)}"}
    end
  end

  def handle("secret_store", _ctx, %{"action" => "delete"}) do
    {:error, "Missing required arguments: name, scope"}
  end

  def handle("secret_store", _ctx, %{"action" => "put_grant", "name" => name, "component_ref" => ref, "scope" => scope} = args) do
    ref = normalize_component_ref(ref)
    org_id = args["org_id"]
    case Arca.SecretStorage.put_grant(name, ref, scope, org_id) do
      :ok -> {:ok, %{granted: true}}
      {:error, reason} -> {:error, "Failed to put grant: #{inspect(reason)}"}
    end
  end

  def handle("secret_store", _ctx, %{"action" => "put_grant"}) do
    {:error, "Missing required arguments: name, component_ref, scope"}
  end

  def handle("secret_store", _ctx, %{"action" => "delete_grant", "name" => name, "component_ref" => ref, "scope" => scope} = args) do
    ref = normalize_component_ref(ref)
    org_id = args["org_id"]
    case Arca.SecretStorage.delete_grant(name, ref, scope, org_id) do
      :ok -> {:ok, %{deleted: true}}
      {:error, reason} -> {:error, "Failed to delete grant: #{inspect(reason)}"}
    end
  end

  def handle("secret_store", _ctx, %{"action" => "delete_grant"}) do
    {:error, "Missing required arguments: name, component_ref, scope"}
  end

  def handle("secret_store", _ctx, %{"action" => "list_grants", "name" => name, "scope" => scope} = args) do
    org_id = args["org_id"]
    case Arca.SecretStorage.list_grants(name, scope, org_id) do
      {:ok, grants} -> {:ok, %{grants: grants}}
    end
  end

  def handle("secret_store", _ctx, %{"action" => "list_grants"}) do
    {:error, "Missing required arguments: name, scope"}
  end

  def handle("secret_store", _ctx, %{"action" => "grants_for_component", "component_ref" => ref, "scope" => scope} = args) do
    ref = normalize_component_ref(ref)
    org_id = args["org_id"]
    case Arca.SecretStorage.grants_for_component(ref, scope, org_id) do
      {:ok, secret_names} -> {:ok, %{secret_names: secret_names}}
    end
  end

  def handle("secret_store", _ctx, %{"action" => "grants_for_component"}) do
    {:error, "Missing required arguments: component_ref, scope"}
  end

  def handle("secret_store", _ctx, _args) do
    {:error, "Invalid secret_store action. Use: put, get, list, delete, put_grant, delete_grant, list_grants, or grants_for_component"}
  end

  # ============================================================================
  # Session Store Tool
  # ============================================================================

  def handle("session_store", _ctx, %{"action" => "create", "token_hash" => b64_hash, "attrs" => attrs}) do
    case Base.decode64(b64_hash) do
      {:ok, token_hash} ->
        # Convert string keys to atom keys and parse datetime fields
        parsed_attrs = parse_session_attrs(attrs)
        case Arca.SessionStorage.create_session(token_hash, parsed_attrs) do
          :ok -> {:ok, %{created: true}}
          {:error, reason} -> {:error, "Failed to create session: #{inspect(reason)}"}
        end
      :error ->
        {:error, "Invalid base64 token_hash"}
    end
  end

  def handle("session_store", _ctx, %{"action" => "create"}) do
    {:error, "Missing required arguments: token_hash, attrs"}
  end

  def handle("session_store", _ctx, %{"action" => "get", "token_hash" => b64_hash}) do
    case Base.decode64(b64_hash) do
      {:ok, token_hash} ->
        case Arca.SessionStorage.get_session(token_hash) do
          {:ok, row} -> {:ok, %{session: session_to_map(row)}}
          {:error, :not_found} -> {:error, :not_found}
        end
      :error ->
        {:error, "Invalid base64 token_hash"}
    end
  end

  def handle("session_store", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: token_hash"}
  end

  def handle("session_store", _ctx, %{"action" => "refresh", "token_hash" => b64_hash, "new_expires_at" => expires_iso}) do
    with {:ok, token_hash} <- decode_b64(b64_hash, "token_hash"),
         new_expires_at when not is_nil(new_expires_at) <- parse_datetime(expires_iso) do
      case Arca.SessionStorage.refresh_session(token_hash, new_expires_at) do
        :ok -> {:ok, %{refreshed: true}}
        {:error, :not_found} -> {:error, :not_found}
      end
    else
      {:error, msg} -> {:error, msg}
      nil -> {:error, "Invalid ISO 8601 new_expires_at"}
    end
  end

  def handle("session_store", _ctx, %{"action" => "refresh"}) do
    {:error, "Missing required arguments: token_hash, new_expires_at"}
  end

  def handle("session_store", _ctx, %{"action" => "delete", "token_hash" => b64_hash}) do
    case Base.decode64(b64_hash) do
      {:ok, token_hash} ->
        :ok = Arca.SessionStorage.delete_session(token_hash)
        {:ok, %{deleted: true}}
      :error ->
        {:error, "Invalid base64 token_hash"}
    end
  end

  def handle("session_store", _ctx, %{"action" => "delete"}) do
    {:error, "Missing required argument: token_hash"}
  end

  def handle("session_store", _ctx, %{"action" => "list_active"}) do
    case Arca.SessionStorage.list_active_sessions() do
      {:ok, rows} -> {:ok, %{sessions: Enum.map(rows, &session_to_map/1)}}
    end
  end

  def handle("session_store", _ctx, %{"action" => "cleanup_expired"}) do
    case Arca.SessionStorage.cleanup_expired_sessions() do
      {:ok, count} -> {:ok, %{cleaned: count}}
    end
  end

  def handle("session_store", _ctx, %{"action" => "put_revocation", "session_id" => sid, "revoked_at" => revoked_iso, "expires_at" => expires_iso}) do
    revoked_at = parse_datetime(revoked_iso)
    expires_at = parse_datetime(expires_iso)

    case Arca.SessionStorage.put_revocation(sid, revoked_at, expires_at) do
      :ok -> {:ok, %{revoked: true}}
      {:error, reason} -> {:error, "Failed to put revocation: #{inspect(reason)}"}
    end
  end

  def handle("session_store", _ctx, %{"action" => "put_revocation"}) do
    {:error, "Missing required arguments: session_id, revoked_at, expires_at"}
  end

  def handle("session_store", _ctx, %{"action" => "check_revoked", "session_id" => sid}) do
    case Arca.SessionStorage.revoked?(sid) do
      {:ok, result} -> {:ok, %{revoked: result}}
      {:error, reason} -> {:error, "Failed to check revocation: #{inspect(reason)}"}
    end
  end

  def handle("session_store", _ctx, %{"action" => "check_revoked"}) do
    {:error, "Missing required argument: session_id"}
  end

  def handle("session_store", _ctx, %{"action" => "cleanup_revocations"}) do
    case Arca.SessionStorage.cleanup_revocations() do
      {:ok, count} -> {:ok, %{cleaned: count}}
    end
  end

  def handle("session_store", _ctx, _args) do
    {:error, "Invalid session_store action. Use: create, get, refresh, delete, list_active, cleanup_expired, put_revocation, check_revoked, or cleanup_revocations"}
  end

  # ============================================================================
  # API Key Store Tool
  # ============================================================================

  def handle("api_key_store", _ctx, %{"action" => "create", "attrs" => attrs}) do
    # Decode key_hash from Base64 in attrs
    parsed_attrs = if is_binary(attrs["key_hash"]) do
      case Base.decode64(attrs["key_hash"]) do
        {:ok, hash} -> attrs |> atomize_keys() |> Map.put(:key_hash, hash)
        :error -> atomize_keys(attrs)
      end
    else
      atomize_keys(attrs)
    end

    case Arca.ApiKeyStorage.create_key(parsed_attrs) do
      :ok -> {:ok, %{created: true}}
      {:error, :already_exists} -> {:error, :already_exists}
      {:error, reason} -> {:error, "Failed to create key: #{inspect(reason)}"}
    end
  end

  def handle("api_key_store", _ctx, %{"action" => "create"}) do
    {:error, "Missing required argument: attrs"}
  end

  def handle("api_key_store", _ctx, %{"action" => "get", "name" => name, "scope_type" => scope_type} = args) do
    org_id = args["org_id"]
    case Arca.ApiKeyStorage.get_key(name, scope_type, org_id) do
      {:ok, row} -> {:ok, %{key: api_key_to_map(row)}}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  def handle("api_key_store", _ctx, %{"action" => "get"}) do
    {:error, "Missing required arguments: name, scope_type"}
  end

  def handle("api_key_store", _ctx, %{"action" => "get_by_hash", "key_hash" => b64_hash}) do
    case Base.decode64(b64_hash) do
      {:ok, key_hash} ->
        case Arca.ApiKeyStorage.get_key_by_hash(key_hash) do
          {:ok, row} -> {:ok, %{key: api_key_to_map(row)}}
          {:error, :not_found} -> {:error, :not_found}
        end
      :error ->
        {:error, "Invalid base64 key_hash"}
    end
  end

  def handle("api_key_store", _ctx, %{"action" => "get_by_hash"}) do
    {:error, "Missing required argument: key_hash"}
  end

  def handle("api_key_store", _ctx, %{"action" => "list", "scope_type" => scope_type} = args) do
    org_id = args["org_id"]
    {:ok, rows} = Arca.ApiKeyStorage.list_keys(scope_type, org_id)
    {:ok, %{keys: Enum.map(rows, &api_key_to_map/1)}}
  end

  def handle("api_key_store", _ctx, %{"action" => "list"}) do
    {:error, "Missing required argument: scope_type"}
  end

  def handle("api_key_store", _ctx, %{"action" => "revoke", "name" => name, "scope_type" => scope_type} = args) do
    org_id = args["org_id"]
    case Arca.ApiKeyStorage.revoke_key(name, scope_type, org_id) do
      :ok -> {:ok, %{revoked: true}}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, "Failed to revoke key: #{inspect(reason)}"}
    end
  end

  def handle("api_key_store", _ctx, %{"action" => "revoke"}) do
    {:error, "Missing required arguments: name, scope_type"}
  end

  def handle("api_key_store", _ctx, %{"action" => "rotate", "name" => name, "scope_type" => scope_type, "new_key_hash" => b64_hash, "new_key_prefix" => prefix} = args) do
    org_id = args["org_id"]
    case Base.decode64(b64_hash) do
      {:ok, new_key_hash} ->
        case Arca.ApiKeyStorage.rotate_key(name, scope_type, org_id, new_key_hash, prefix) do
          :ok -> {:ok, %{rotated: true}}
          {:error, :not_found} -> {:error, :not_found}
          {:error, reason} -> {:error, "Failed to rotate key: #{inspect(reason)}"}
        end
      :error ->
        {:error, "Invalid base64 new_key_hash"}
    end
  end

  def handle("api_key_store", _ctx, %{"action" => "rotate"}) do
    {:error, "Missing required arguments: name, scope_type, new_key_hash, new_key_prefix"}
  end

  def handle("api_key_store", _ctx, _args) do
    {:error, "Invalid api_key_store action. Use: create, get, get_by_hash, list, revoke, or rotate"}
  end

  # ============================================================================
  # Permission Store Tool
  # ============================================================================

  def handle("permission_store", _ctx, %{"action" => "get", "subject" => subject, "scope_type" => scope_type} = args) do
    org_id = args["org_id"]
    case Arca.PermissionStorage.get_permissions(subject, scope_type, org_id) do
      {:ok, json} -> {:ok, %{permissions: json}}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  def handle("permission_store", _ctx, %{"action" => "get"}) do
    {:error, "Missing required arguments: subject, scope_type"}
  end

  def handle("permission_store", _ctx, %{"action" => "set", "subject" => subject, "permissions" => perms, "scope_type" => scope_type} = args) do
    org_id = args["org_id"]
    case Arca.PermissionStorage.set_permissions(subject, perms, scope_type, org_id) do
      :ok -> {:ok, %{stored: true}}
      {:error, reason} -> {:error, "Failed to set permissions: #{inspect(reason)}"}
    end
  end

  def handle("permission_store", _ctx, %{"action" => "set"}) do
    {:error, "Missing required arguments: subject, permissions, scope_type"}
  end

  def handle("permission_store", _ctx, %{"action" => "list", "scope_type" => scope_type} = args) do
    org_id = args["org_id"]
    {:ok, rows} = Arca.PermissionStorage.list_permissions(scope_type, org_id)
    entries = Enum.map(rows, fn row -> %{subject: row.subject, permissions: row.permissions} end)
    {:ok, %{entries: entries}}
  end

  def handle("permission_store", _ctx, %{"action" => "list"}) do
    {:error, "Missing required argument: scope_type"}
  end

  def handle("permission_store", _ctx, %{"action" => "delete", "subject" => subject, "scope_type" => scope_type} = args) do
    org_id = args["org_id"]
    case Arca.PermissionStorage.delete_permissions(subject, scope_type, org_id) do
      :ok -> {:ok, %{deleted: true}}
      {:error, reason} -> {:error, "Failed to delete permissions: #{inspect(reason)}"}
    end
  end

  def handle("permission_store", _ctx, %{"action" => "delete"}) do
    {:error, "Missing required arguments: subject, scope_type"}
  end

  def handle("permission_store", _ctx, _args) do
    {:error, "Invalid permission_store action. Use: get, set, list, or delete"}
  end

  # ============================================================================
  # Policy Store Tool
  # ============================================================================

  def handle("policy_store", _ctx, %{"action" => "get", "component_ref" => ref}) do
    ref = normalize_component_ref(ref)
    case Arca.PolicyStorage.get_policy(ref) do
      {:ok, row} -> {:ok, %{policy: row}}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  def handle("policy_store", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle("policy_store", _ctx, %{"action" => "put", "attrs" => attrs}) do
    attrs = if is_binary(attrs["component_ref"]) do
      Map.put(attrs, "component_ref", normalize_component_ref(attrs["component_ref"]))
    else
      attrs
    end
    parsed = atomize_keys(attrs)
    case Arca.PolicyStorage.put_policy(parsed) do
      {:ok, _} -> {:ok, %{stored: true}}
      {:error, reason} -> {:error, "Failed to put policy: #{inspect(reason)}"}
    end
  end

  def handle("policy_store", _ctx, %{"action" => "put"}) do
    {:error, "Missing required argument: attrs"}
  end

  def handle("policy_store", _ctx, %{"action" => "delete", "component_ref" => ref}) do
    ref = normalize_component_ref(ref)
    case Arca.PolicyStorage.delete_policy(ref) do
      :ok -> {:ok, %{deleted: true}}
      {:error, reason} -> {:error, "Failed to delete policy: #{inspect(reason)}"}
    end
  end

  def handle("policy_store", _ctx, %{"action" => "delete"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle("policy_store", _ctx, %{"action" => "list"}) do
    rows = Arca.PolicyStorage.list_policies()
    {:ok, %{policies: rows}}
  end

  def handle("policy_store", _ctx, _args) do
    {:error, "Invalid policy_store action. Use: get, put, delete, or list"}
  end

  # ============================================================================
  # Component Config Store Tool
  # ============================================================================

  def handle("component_config_store", _ctx, %{"action" => "get_all", "component_ref" => ref}) do
    ref = normalize_component_ref(ref)
    case Arca.ComponentConfigStorage.get_all_config(ref) do
      {:ok, config} -> {:ok, %{config: config}}
    end
  end

  def handle("component_config_store", _ctx, %{"action" => "get_all"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle("component_config_store", _ctx, %{"action" => "put", "component_ref" => ref, "key" => key, "value" => value}) do
    ref = normalize_component_ref(ref)
    case Arca.ComponentConfigStorage.put_config(ref, key, value) do
      :ok -> {:ok, %{stored: true}}
      {:error, reason} -> {:error, "Failed to put config: #{inspect(reason)}"}
    end
  end

  def handle("component_config_store", _ctx, %{"action" => "put"}) do
    {:error, "Missing required arguments: component_ref, key, value"}
  end

  def handle("component_config_store", _ctx, %{"action" => "delete", "component_ref" => ref, "key" => key}) do
    ref = normalize_component_ref(ref)
    case Arca.ComponentConfigStorage.delete_config(ref, key) do
      :ok -> {:ok, %{deleted: true}}
      {:error, reason} -> {:error, "Failed to delete config: #{inspect(reason)}"}
    end
  end

  def handle("component_config_store", _ctx, %{"action" => "delete"}) do
    {:error, "Missing required arguments: component_ref, key"}
  end

  def handle("component_config_store", _ctx, %{"action" => "delete_all", "component_ref" => ref}) do
    ref = normalize_component_ref(ref)
    case Arca.ComponentConfigStorage.delete_all_config(ref) do
      :ok -> {:ok, %{deleted: true}}
      {:error, reason} -> {:error, "Failed to delete all config: #{inspect(reason)}"}
    end
  end

  def handle("component_config_store", _ctx, %{"action" => "delete_all"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle("component_config_store", _ctx, %{"action" => "list"}) do
    refs = Arca.ComponentConfigStorage.list_component_refs()
    {:ok, %{component_refs: refs}}
  end

  def handle("component_config_store", _ctx, _args) do
    {:error, "Invalid component_config_store action. Use: get_all, put, delete, delete_all, or list"}
  end

  # ============================================================================
  # Component Store Tool
  # ============================================================================

  def handle("component_store", _ctx, %{"action" => "put", "attrs" => attrs}) do
    parsed = atomize_keys(attrs)
    case Arca.ComponentStorage.put_component(parsed) do
      {:ok, result} -> {:ok, %{stored: true, component: result}}
      {:error, reason} -> {:error, "Failed to put component: #{inspect(reason)}"}
    end
  end

  def handle("component_store", _ctx, %{"action" => "put"}) do
    {:error, "Missing required argument: attrs"}
  end

  def handle("component_store", _ctx, %{"action" => "get", "name" => name, "version" => version} = args) do
    publisher = args["publisher"]
    case Arca.ComponentStorage.get_component(name, version, publisher) do
      {:ok, row} -> {:ok, %{component: row}}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  def handle("component_store", _ctx, %{"action" => "get"}) do
    {:error, "Missing required arguments: name, version"}
  end

  def handle("component_store", _ctx, %{"action" => "list"} = args) do
    opts = []
    opts = if args["name"], do: Keyword.put(opts, :name, args["name"]), else: opts
    opts = if args["component_type"], do: Keyword.put(opts, :component_type, args["component_type"]), else: opts
    opts = if args["query"], do: Keyword.put(opts, :query, args["query"]), else: opts
    opts = if args["category"], do: Keyword.put(opts, :category, args["category"]), else: opts
    opts = if args["source"], do: Keyword.put(opts, :source, args["source"]), else: opts
    opts = if args["publisher"], do: Keyword.put(opts, :publisher, args["publisher"]), else: opts
    opts = if args["limit"], do: Keyword.put(opts, :limit, args["limit"]), else: opts

    components = Arca.ComponentStorage.list_components(opts)
    {:ok, %{components: components}}
  end

  def handle("component_store", _ctx, %{"action" => "delete", "name" => name, "version" => version} = args) do
    publisher = args["publisher"]
    case Arca.ComponentStorage.delete_component(name, version, publisher) do
      :ok -> {:ok, %{deleted: true}}
      {:error, reason} -> {:error, "Failed to delete component: #{inspect(reason)}"}
    end
  end

  def handle("component_store", _ctx, %{"action" => "delete"}) do
    {:error, "Missing required arguments: name, version"}
  end

  def handle("component_store", _ctx, %{"action" => "exists", "name" => name, "version" => version} = args) do
    publisher = args["publisher"]
    {:ok, %{exists: Arca.ComponentStorage.exists?(name, version, publisher)}}
  end

  def handle("component_store", _ctx, %{"action" => "exists"}) do
    {:error, "Missing required arguments: name, version"}
  end

  def handle("component_store", _ctx, _args) do
    {:error, "Invalid component_store action. Use: put, get, list, delete, or exists"}
  end

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end

  # ============================================================================
  # Internal
  # ============================================================================

  @doc false
  defp normalize_path(path) when is_binary(path) do
    path
    |> String.trim_leading("/")
    |> String.split("/")
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_path(path) when is_list(path), do: path

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt
  defp parse_datetime(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp execution_to_map(%Arca.Execution{} = exec) do
    %{
      id: exec.id,
      request_id: exec.request_id,
      reference: exec.reference,
      input_hash: exec.input_hash,
      user_id: exec.user_id,
      component_type: exec.component_type,
      component_digest: exec.component_digest,
      started_at: format_datetime(exec.started_at),
      completed_at: format_datetime(exec.completed_at),
      duration_ms: exec.duration_ms,
      status: exec.status,
      error_message: exec.error_message,
      input: decode_json(exec.input),
      output: decode_json(exec.output),
      host_policy: decode_json(exec.host_policy),
      wasi_trace: decode_json(exec.wasi_trace),
      parent_execution_id: exec.parent_execution_id
    }
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = ndt), do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  defp format_datetime(dt) when is_binary(dt) do
    # SQLite schemaless queries return datetime strings without UTC offset.
    # Append "Z" if no offset is present to ensure valid ISO 8601.
    if String.ends_with?(dt, "Z") or Regex.match?(~r/[+-]\d{2}:\d{2}$/, dt) do
      dt
    else
      dt <> "Z"
    end
  end
  defp format_datetime(dt), do: to_string(dt)

  defp generate_id(prefix) do
    "#{prefix}_#{Ecto.UUID.generate()}"
  end

  defp encode_json(nil), do: nil
  defp encode_json(val) when is_binary(val), do: val
  defp encode_json(val) when is_map(val) or is_list(val), do: Jason.encode!(val)
  defp encode_json(val), do: to_string(val)

  defp encode_if_map(val) when is_map(val), do: Jason.encode!(val)
  defp encode_if_map(val) when is_binary(val), do: val
  defp encode_if_map(nil), do: nil

  defp hash_input(input) when is_map(input), do: Arca.Execution.hash_input(input)
  defp hash_input(_), do: nil

  defp normalize_component_type(nil), do: nil
  defp normalize_component_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalize_component_type(type) when is_binary(type), do: type

  defp parse_json_string(nil), do: nil
  defp parse_json_string(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, map} -> map
      {:error, _} -> str
    end
  end
  defp parse_json_string(other), do: other

  defp decode_b64(b64, field_name) do
    case Base.decode64(b64) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, "Invalid base64 #{field_name}"}
    end
  end

  defp parse_session_attrs(attrs) when is_map(attrs) do
    attrs
    |> atomize_keys()
    |> Map.update(:expires_at, nil, &parse_datetime/1)
    |> Map.update(:inserted_at, nil, &parse_datetime/1)
  end

  defp session_to_map(row) when is_map(row) do
    row
    |> Map.take([:token_prefix, :user_id, :email, :provider, :permissions, :session_id, :expires_at, :inserted_at])
    |> Map.update(:expires_at, nil, &format_datetime/1)
    |> Map.update(:inserted_at, nil, &format_datetime/1)
  end

  defp api_key_to_map(row) when is_map(row) do
    Map.take(row, [:name, :key_prefix, :type, :scope, :rate_limit, :ip_allowlist, :created_by, :scope_type, :org_id, :revoked, :rotated_at, :inserted_at])
  end

  defp mcp_log_to_map(%Arca.McpLog{} = log) do
    %{
      id: log.id,
      session_id: log.session_id,
      user_id: log.user_id,
      timestamp: format_datetime(log.timestamp),
      tool: log.tool,
      action: log.action,
      method: log.method,
      status: log.status,
      duration_ms: log.duration_ms,
      routed_to: log.routed_to,
      error_code: log.error_code,
      input: decode_json(log.input),
      output: decode_json(log.output),
      error: log.error
    }
  end

  defp policy_log_to_map(%Arca.PolicyLog{} = log) do
    %{
      id: log.id,
      request_id: log.request_id,
      execution_id: log.execution_id,
      session_id: log.session_id,
      user_id: log.user_id,
      timestamp: format_datetime(log.timestamp),
      event_type: log.event_type,
      component_ref: log.component_ref,
      component_type: log.component_type,
      decision: log.decision,
      host_policy_snapshot: decode_json(log.host_policy_snapshot),
      decision_reason: log.decision_reason
    }
  end

  defp audit_event_to_map(%Arca.AuditEvent{} = event) do
    %{
      id: event.id,
      request_id: event.request_id,
      session_id: event.session_id,
      user_id: event.user_id,
      timestamp: format_datetime(event.timestamp),
      event_type: event.event_type,
      data: decode_json(event.data)
    }
  end

  defp decode_json(nil), do: nil
  defp decode_json(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, val} -> val
      _ -> str
    end
  end
  defp decode_json(val), do: val

  defp normalize_component_ref(ref) when is_binary(ref) do
    case Sanctum.ComponentRef.normalize(ref) do
      {:ok, normalized} -> normalized
      {:error, _} -> ref
    end
  end
  defp normalize_component_ref(ref), do: ref

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  rescue
    ArgumentError ->
      # If atom doesn't exist, use safe conversion
      Map.new(map, fn
        {k, v} when is_binary(k) -> {String.to_atom(k), v}
        {k, v} when is_atom(k) -> {k, v}
      end)
  end
end
