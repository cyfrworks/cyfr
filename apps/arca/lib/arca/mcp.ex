defmodule Arca.MCP do
  @moduledoc """
  MCP tool provider for Arca services.

  Exposes Arca operations as MCP tools with action-based dispatch.

  File storage operations (read, write, list, delete, exists) are handled by
  the `cyfr:storage/files@0.1.0` host function for catalysts via
  `Opus.StorageHandler`, not as an MCP tool. The `retention` tool manages
  data retention policies (get, set, cleanup).

  ## Retention Tool

  The `retention` tool manages data retention policies:

      # Get current settings
      {"action": "get"}

      # Update settings (admin only)
      {"action": "set", "settings": {"executions": 5, "builds": 3}}

      # Run cleanup (admin only)
      {"action": "cleanup", "cleanup_type": "executions", "dry_run": false}

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

  # ============================================================================
  # ResourceProvider Protocol
  # ============================================================================

  @doc """
  Returns available Arca resources (concrete URIs only).
  """
  def resources do
    []
  end

  @doc """
  Returns Arca resource templates (RFC 6570 URI templates).
  """
  def resource_templates do
    [
      %{
        uriTemplate: "arca://files/{path}",
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
              "enum" => ["put", "get", "list", "delete", "put_grant", "delete_grant", "list_grants", "grants_for_component", "delete_grants_for_component"],
              "description" => "Action to perform"
            },
            "name" => %{"type" => "string", "description" => "Secret name"},
            "encrypted_value" => %{"type" => "string", "description" => "Base64-encoded encrypted value"},
            "scope" => %{"type" => "string", "description" => "Scope (personal or org)"},
            "org_id" => %{"type" => "string", "description" => "Organization ID"},
            "component_ref" => %{"type" => "string", "description" => "Component reference: type:namespace.name:version (required, e.g., 'catalyst:local.my-tool:1.0.0')"}
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
            "component_ref" => %{"type" => "string", "description" => "Component reference: type:namespace.name:version (required, e.g., 'catalyst:local.my-tool:1.0.0')"},
            "attrs" => %{"type" => "object", "description" => "Policy attributes for put"}
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
        name: "record",
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
            "tool" => %{"type" => "string", "description" => "Tool name (for log_started or list filter)"},
            "since" => %{"type" => "string", "description" => "ISO8601 timestamp — return logs after this time"},
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
            "component_ref" => %{"type" => "string", "description" => "Component reference: type:namespace.name:version (required, e.g., 'catalyst:local.my-tool:1.0.0')"},
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
        name: "retention",
        title: "Retention",
        description: "Manage data retention policies - get settings, set settings, or run cleanup",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["get", "set", "cleanup"],
              "description" => "Action to perform"
            },
            "settings" => %{
              "type" => "object",
              "properties" => %{
                "executions" => %{"type" => "integer", "description" => "Number of executions to keep per user"},
                "builds" => %{"type" => "integer", "description" => "Number of builds to keep per user"}
              },
              "description" => "Retention settings (for set action)"
            },
            "cleanup_type" => %{
              "type" => "string",
              "enum" => ["executions", "builds"],
              "description" => "Type of data to clean up (for cleanup action)"
            },
            "dry_run" => %{
              "type" => "boolean",
              "description" => "If true, show what would be deleted without actually deleting"
            }
          },
          "required" => ["action"]
        }
      },
      %{
        name: "dependency_store",
        title: "Dependency Storage",
        description: "Manage component dependency metadata - put, get, reverse lookup, delete",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["put", "get", "reverse", "delete"],
              "description" => "Action to perform"
            },
            "component_id" => %{
              "type" => "string",
              "description" => "Component ID (required for put, get, delete)"
            },
            "dependencies" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "dependency_ref" => %{"type" => "string", "description" => "Canonical component ref (type:namespace.name:version)"},
                  "dep_type" => %{"type" => "string", "description" => "Dependency component type"},
                  "dep_namespace" => %{"type" => "string", "description" => "Dependency namespace"},
                  "dep_name" => %{"type" => "string", "description" => "Dependency name"},
                  "dep_version" => %{"type" => "string", "description" => "Dependency version"},
                  "optional" => %{"type" => "integer", "description" => "0 = required, 1 = optional"},
                  "reason" => %{"type" => "string", "description" => "Human-readable reason for dependency"}
                },
                "required" => ["dependency_ref", "dep_type", "dep_namespace", "dep_name", "dep_version"]
              },
              "description" => "List of dependency entries (required for put)"
            },
            "name" => %{
              "type" => "string",
              "description" => "Dependency name (required for reverse action)"
            },
            "version" => %{
              "type" => "string",
              "description" => "Dependency version (required for reverse action)"
            }
          },
          "required" => ["action"]
        }
      }
    ]
  end

  # ============================================================================
  # Health Check (ping) — must be before tool-specific catch-all clauses
  # ============================================================================

  def handle(_tool, _ctx, %{"action" => "ping"}), do: {:ok, %{status: "ok"}}

  # ============================================================================
  # Execution Tool
  # ============================================================================

  def handle("record", ctx, %{"action" => "record_start"} = args) do
    user_id = args["user_id"] || ctx.user_id
    started_at_str = args["started_at"] || DateTime.to_iso8601(DateTime.utc_now())
    reference = args["reference"]

    case Arca.Execution.record_start(%{
      id: args["id"],
      request_id: args["request_id"],
      reference: reference,
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

  def handle("record", _ctx, %{"action" => "record_complete", "id" => id} = args) do
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

  def handle("record", _ctx, %{"action" => "record_complete"}) do
    {:error, "Missing required argument: id"}
  end

  def handle("record", _ctx, %{"action" => "get", "id" => id}) do
    case Arca.Execution.get(id) do
      nil -> {:error, "Execution not found: #{id}"}
      record -> {:ok, execution_to_map(record)}
    end
  end

  def handle("record", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: id"}
  end

  def handle("record", ctx, %{"action" => "list"} = args) do
    opts = [limit: args["limit"] || 20]
    user_id = args["user_id"] || (ctx && ctx.user_id)
    opts = if user_id, do: Keyword.put(opts, :user_id, user_id), else: opts
    opts = if args["status"], do: Keyword.put(opts, :status, args["status"]), else: opts
    opts = if args["parent_execution_id"], do: Keyword.put(opts, :parent_execution_id, args["parent_execution_id"]), else: opts

    records = Arca.Execution.list(opts)
    {:ok, %{executions: Enum.map(records, &execution_to_map/1)}}
  end

  def handle("record", _ctx, _args) do
    {:error, "Invalid record action. Use: record_start, record_complete, get, or list"}
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
      error: args["error"],
      routed_to: args["routed_to"]
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
    opts = if args["tool"], do: Keyword.put(opts, :tool, args["tool"]), else: opts

    opts =
      if args["since"] do
        case DateTime.from_iso8601(args["since"]) do
          {:ok, dt, _} -> Keyword.put(opts, :since, dt)
          _ -> throw({:error, "Invalid ISO8601 timestamp for 'since': #{args["since"]}"})
        end
      else
        opts
      end

    records = Arca.McpLog.list(opts)
    {:ok, %{logs: Enum.map(records, &mcp_log_to_map/1)}}
  catch
    {:error, msg} -> {:error, msg}
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

    {:ok, %{
      request_id: request_id,
      mcp_logs: mcp_logs,
      executions: executions,
      policy_logs: policy_logs
    }}
  end

  def handle("mcp_log", _ctx, %{"action" => "correlate"}) do
    {:error, "Missing required argument: request_id"}
  end

  def handle("mcp_log", _ctx, %{"action" => "stats"} = args) do
    since_hours = args["since_hours"] || 1

    since = DateTime.utc_now() |> DateTime.add(-since_hours * 3600, :second)
    stats = Arca.McpLog.stats(since: since)

    {:ok, %{
      since: DateTime.to_iso8601(since),
      total: stats.total,
      errors: stats.errors,
      avg_duration_ms: stats.avg_duration_ms,
      error_rate: if(stats.total > 0, do: Float.round(stats.errors / stats.total * 100, 1), else: 0.0)
    }}
  end

  def handle("mcp_log", _ctx, _args) do
    {:error, "Invalid mcp_log action. Use: log_started, log_completed, log_failed, list, get, delete, correlate, or stats"}
  end

  # ============================================================================
  # Policy Log Tool
  # ============================================================================

  def handle("policy_log", ctx, %{"action" => "log"} = args) do
    with {:ok, component_ref} <- normalize_component_ref(args["component_ref"]) do
    request_id = (ctx && ctx.request_id) || generate_id("req")
    now = DateTime.utc_now()

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
  # Retention Tool
  # ============================================================================

  def handle("retention", %Context{} = ctx, %{"action" => "get"}) do
    settings = Arca.Retention.get_settings(ctx)
    {:ok, %{action: "get", settings: settings}}
  end

  def handle("retention", %Context{} = ctx, %{"action" => "set", "settings" => settings})
      when is_map(settings) do
    with :ok <- AccessLevel.authorize(ctx, :write) do
      case Arca.Retention.set_settings(ctx, settings) do
        :ok ->
          new_settings = Arca.Retention.get_settings(ctx)
          {:ok, %{action: "set", updated: true, settings: new_settings}}

        {:error, reason} ->
          {:error, "Failed to update retention settings: #{inspect(reason)}"}
      end
    else
      {:error, :unauthorized} ->
        {:error, "Unauthorized: setting retention requires admin-level access"}
    end
  end

  def handle("retention", %Context{} = ctx, %{"action" => "cleanup"} = args) do
    with :ok <- AccessLevel.authorize(ctx, :delete) do
      cleanup_type = Map.get(args, "cleanup_type", "executions")
      dry_run = Map.get(args, "dry_run", false)

      result = case cleanup_type do
        "executions" -> Arca.Retention.cleanup_executions(ctx, dry_run: dry_run)
        "builds" -> Arca.Retention.cleanup_builds(ctx, dry_run: dry_run)
        "mcp_logs" -> Arca.Retention.cleanup_mcp_logs(ctx, dry_run: dry_run)
        _ -> {:error, "Unknown cleanup_type: #{cleanup_type}"}
      end

      case result do
        {:ok, count} when is_integer(count) ->
          {:ok, %{action: "cleanup", cleanup_type: cleanup_type, deleted: count}}

        {:ok, %{would_delete: ids} = info} ->
          {:ok, %{action: "cleanup", cleanup_type: cleanup_type, dry_run: true, would_delete: ids, would_keep: info[:would_keep]}}

        {:error, reason} ->
          {:error, "Cleanup failed: #{inspect(reason)}"}
      end
    else
      {:error, :unauthorized} ->
        {:error, "Unauthorized: cleanup requires admin-level access"}
    end
  end

  def handle("retention", _ctx, _args) do
    {:error, "Invalid retention action. Use: get, set, or cleanup"}
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
    with {:ok, ref} <- normalize_component_ref(ref) do
      org_id = args["org_id"]
      case Arca.SecretStorage.put_grant(name, ref, scope, org_id) do
        :ok -> {:ok, %{granted: true}}
        {:error, reason} -> {:error, "Failed to put grant: #{inspect(reason)}"}
      end
    end
  end

  def handle("secret_store", _ctx, %{"action" => "put_grant"}) do
    {:error, "Missing required arguments: name, component_ref, scope"}
  end

  def handle("secret_store", _ctx, %{"action" => "delete_grant", "name" => name, "component_ref" => ref, "scope" => scope} = args) do
    with {:ok, ref} <- normalize_component_ref(ref) do
      org_id = args["org_id"]
      case Arca.SecretStorage.delete_grant(name, ref, scope, org_id) do
        :ok -> {:ok, %{deleted: true}}
        {:error, reason} -> {:error, "Failed to delete grant: #{inspect(reason)}"}
      end
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
    with {:ok, ref} <- normalize_component_ref(ref) do
      org_id = args["org_id"]
      case Arca.SecretStorage.grants_for_component(ref, scope, org_id) do
        {:ok, secret_names} -> {:ok, %{secret_names: secret_names}}
      end
    end
  end

  def handle("secret_store", _ctx, %{"action" => "grants_for_component"}) do
    {:error, "Missing required arguments: component_ref, scope"}
  end

  def handle("secret_store", _ctx, %{"action" => "delete_grants_for_component", "component_ref" => ref}) do
    with {:ok, ref} <- normalize_component_ref(ref) do
      case Arca.SecretStorage.delete_grants_for_component(ref) do
        :ok -> {:ok, %{deleted: true}}
        {:error, reason} -> {:error, "Failed to delete grants: #{inspect(reason)}"}
      end
    end
  end

  def handle("secret_store", _ctx, %{"action" => "delete_grants_for_component"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle("secret_store", _ctx, _args) do
    {:error, "Invalid secret_store action. Use: put, get, list, delete, put_grant, delete_grant, list_grants, grants_for_component, or delete_grants_for_component"}
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
          {:error, reason} -> {:error, reason}
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
    with {:ok, ref} <- normalize_component_ref(ref) do
      case Arca.PolicyStorage.get_policy(ref) do
        {:ok, row} -> {:ok, %{policy: row}}
        {:error, :not_found} -> {:error, :not_found}
      end
    end
  end

  def handle("policy_store", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle("policy_store", _ctx, %{"action" => "put", "attrs" => attrs}) do
    with {:ok, attrs} <- normalize_attrs_ref(attrs) do
      parsed = atomize_keys(attrs)
      case Arca.PolicyStorage.put_policy(parsed) do
        {:ok, _} -> {:ok, %{stored: true}}
        {:error, reason} -> {:error, "Failed to put policy: #{inspect(reason)}"}
      end
    end
  end

  def handle("policy_store", _ctx, %{"action" => "put"}) do
    {:error, "Missing required argument: attrs"}
  end

  def handle("policy_store", _ctx, %{"action" => "delete", "component_ref" => ref}) do
    with {:ok, ref} <- normalize_component_ref(ref) do
      case Arca.PolicyStorage.delete_policy(ref) do
        :ok -> {:ok, %{deleted: true}}
        {:error, reason} -> {:error, "Failed to delete policy: #{inspect(reason)}"}
      end
    end
  end

  def handle("policy_store", _ctx, %{"action" => "delete"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle("policy_store", _ctx, %{"action" => "list"}) do
    case Arca.PolicyStorage.list_policies() do
      {:error, reason} -> {:error, "Failed to list policies: #{inspect(reason)}"}
      rows when is_list(rows) -> {:ok, %{policies: rows}}
    end
  end

  def handle("policy_store", _ctx, _args) do
    {:error, "Invalid policy_store action. Use: get, put, delete, or list"}
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
    component_type = args["component_type"]
    case Arca.ComponentStorage.get_component(name, version, publisher, component_type) do
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

    case Arca.ComponentStorage.list_components(opts) do
      {:error, reason} -> {:error, "Failed to list components: #{inspect(reason)}"}
      components when is_list(components) -> {:ok, %{components: components}}
    end
  end

  def handle("component_store", _ctx, %{"action" => "delete", "name" => name, "version" => version} = args) do
    publisher = args["publisher"]
    component_type = args["component_type"]
    case Arca.ComponentStorage.delete_component(name, version, publisher, component_type) do
      :ok -> {:ok, %{deleted: true}}
      {:error, reason} -> {:error, "Failed to delete component: #{inspect(reason)}"}
    end
  end

  def handle("component_store", _ctx, %{"action" => "delete"}) do
    {:error, "Missing required arguments: name, version"}
  end

  def handle("component_store", _ctx, %{"action" => "exists", "name" => name, "version" => version} = args) do
    publisher = args["publisher"]
    component_type = args["component_type"]
    {:ok, %{exists: Arca.ComponentStorage.exists?(name, version, publisher, component_type)}}
  end

  def handle("component_store", _ctx, %{"action" => "exists"}) do
    {:error, "Missing required arguments: name, version"}
  end

  def handle("component_store", _ctx, _args) do
    {:error, "Invalid component_store action. Use: put, get, list, delete, or exists"}
  end

  # ============================================================================
  # Dependency Store Tool
  # ============================================================================

  def handle("dependency_store", _ctx, %{"action" => "put", "component_id" => component_id, "dependencies" => deps})
      when is_binary(component_id) and is_list(deps) do
    parsed = Enum.map(deps, &atomize_keys/1)
    case Arca.DependencyStorage.put_dependencies(component_id, parsed) do
      {:ok, count} -> {:ok, %{stored: true, count: count}}
      {:error, reason} -> {:error, "Failed to put dependencies: #{inspect(reason)}"}
    end
  end

  def handle("dependency_store", _ctx, %{"action" => "put"}) do
    {:error, "Missing required arguments: component_id, dependencies"}
  end

  def handle("dependency_store", _ctx, %{"action" => "get", "component_id" => component_id})
      when is_binary(component_id) do
    case Arca.DependencyStorage.get_dependencies(component_id) do
      {:ok, deps} -> {:ok, %{dependencies: deps}}
      {:error, reason} -> {:error, "Failed to get dependencies: #{inspect(reason)}"}
    end
  end

  def handle("dependency_store", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: component_id"}
  end

  def handle("dependency_store", _ctx, %{"action" => "reverse", "name" => name, "version" => version})
      when is_binary(name) and is_binary(version) do
    case Arca.DependencyStorage.get_reverse_dependencies(name, version) do
      {:ok, deps} -> {:ok, %{dependents: deps}}
      {:error, reason} -> {:error, "Failed to get reverse dependencies: #{inspect(reason)}"}
    end
  end

  def handle("dependency_store", _ctx, %{"action" => "reverse"}) do
    {:error, "Missing required arguments: name, version"}
  end

  def handle("dependency_store", _ctx, %{"action" => "delete", "component_id" => component_id})
      when is_binary(component_id) do
    case Arca.DependencyStorage.delete_dependencies(component_id) do
      :ok -> {:ok, %{deleted: true}}
      {:error, reason} -> {:error, "Failed to delete dependencies: #{inspect(reason)}"}
    end
  end

  def handle("dependency_store", _ctx, %{"action" => "delete"}) do
    {:error, "Missing required argument: component_id"}
  end

  def handle("dependency_store", _ctx, _args) do
    {:error, "Invalid dependency_store action. Use: put, get, reverse, or delete"}
  end

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end

  # ============================================================================
  # Internal
  # ============================================================================

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

  defp hash_input(input) when is_map(input), do: Arca.Execution.hash_input(input)
  defp hash_input(_), do: nil

  defp normalize_component_type(nil), do: nil
  defp normalize_component_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalize_component_type(type) when is_binary(type), do: type

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

  defp decode_json(nil), do: nil
  defp decode_json(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, val} -> val
      _ -> str
    end
  end
  defp decode_json(val), do: val

  defp normalize_component_ref(nil), do: {:ok, nil}
  defp normalize_component_ref("__type_default__:" <> _ = ref), do: {:ok, ref}
  defp normalize_component_ref(ref) when is_binary(ref) do
    Sanctum.ComponentRef.normalize_or_name_ref(ref)
  end
  defp normalize_component_ref(_ref), do: {:error, "component_ref must be a string"}

  defp normalize_attrs_ref(attrs) when is_map(attrs) do
    if is_binary(attrs["component_ref"]) do
      with {:ok, ref} <- normalize_component_ref(attrs["component_ref"]) do
        {:ok, Map.put(attrs, "component_ref", ref)}
      end
    else
      {:ok, attrs}
    end
  end

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
