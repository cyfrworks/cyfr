# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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

  Tool definitions live next to their implementation under `lib/arca`.
  Emissary discovers this provider via configuration and delegates
  calls here.

  Implements the ToolProvider protocol (tools/0 and handle/3)
  which is validated at runtime by Emissary.MCP.ToolRegistry.
  """

  @behaviour Emissary.MCP.ToolProvider

  require Logger

  alias Sanctum.Context

  import Arca.QueryHelpers, only: [maybe_put: 3]

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
  def read(%Context{authenticated: false}, "arca://files/" <> _path) do
    {:error, "Authentication required to read storage"}
  end

  def read(%Context{} = ctx, "arca://files/" <> path) do
    with :ok <- authorize(ctx, :read) do
      segments = String.split(path, "/") |> Enum.reject(&(&1 == ""))

      case Arca.get(ctx, segments) do
        {:ok, content} ->
          {:ok, %{content: Base.encode64(content), mimeType: "application/octet-stream"}}

        {:error, :not_found} ->
          {:error, "File not found: #{path}"}

        {:error, reason} ->
          Logger.error("[Arca.MCP] Failed to read: #{inspect(reason)}")
          {:error, "Failed to read"}
      end
    end
  end

  def read(_ctx, uri) do
    {:error, "Unknown resource URI: #{uri}"}
  end

  def tools do
    [
      %{
        name: "record",
        title: "Execution Records",
        description: "Query execution records - get or list executions",
        annotations: %{
          readOnlyHint: true,
          destructiveHint: false,
          actions: %{
            "get" => %{kind: :read, planes: [:external]},
            "list" => %{kind: :read, planes: [:external]}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["get", "list"],
              "description" => "Action to perform"
            },
            "id" => %{
              "type" => "string",
              "description" => "Execution ID"
            },
            "user_id" => %{
              "type" => "string",
              "description" => "User who initiated execution"
            },
            "component_type" => %{
              "type" => "string",
              "description" => "Component type: catalyst, reagent, or formula"
            },
            "status" => %{
              "type" => "string",
              "description" => "Execution status: running, completed, failed, cancelled"
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
        description: "Query MCP request logs - list, get, correlate, fan_outs, or view stats",
        annotations: %{
          readOnlyHint: true,
          destructiveHint: false,
          actions: %{
            "list" => %{kind: :read, planes: [:external]},
            "get" => %{kind: :read, planes: [:external]},
            "correlate" => %{kind: :read, planes: [:external]},
            "fan_outs" => %{kind: :read, planes: [:external]},
            "stats" => %{kind: :read, planes: [:external]}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["list", "get", "correlate", "fan_outs", "stats"],
              "description" => "Action to perform"
            },
            "id" => %{"type" => "string", "description" => "Request ID"},
            "request_id" => %{
              "type" => "string",
              "description" =>
                "The ingress request. Groups a whole chain: the call an ingress " <>
                  "received and every tool a running component reached beneath it."
            },
            "request_ids" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Batch of request IDs for fan_outs action"
            },
            "tool" => %{"type" => "string", "description" => "Tool name filter"},
            "since" => %{
              "type" => "string",
              "description" => "ISO8601 timestamp — return logs after this time"
            },
            "user_id" => %{"type" => "string", "description" => "Filter by user ID"},
            "status" => %{"type" => "string", "description" => "Filter by status"},
            "limit" => %{"type" => "integer", "description" => "Max results (default: 20)"}
          },
          "required" => ["action"]
        }
      },
      %{
        name: "policy_log",
        title: "Policy Logs",
        description: "Query policy consultation logs - list, get, or correlate logs",
        annotations: %{
          readOnlyHint: true,
          destructiveHint: false,
          actions: %{
            "list" => %{kind: :read, planes: [:external]},
            "get" => %{kind: :read, planes: [:external]},
            "correlate" => %{kind: :read, planes: [:external]}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["list", "get", "correlate"],
              "description" => "Action to perform"
            },
            "id" => %{"type" => "string", "description" => "Policy log ID"},
            "request_id" => %{"type" => "string", "description" => "Filter by request ID"},
            "execution_id" => %{"type" => "string", "description" => "Filter by execution ID"},
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
        description:
          "Manage data retention policies - get settings, set settings, or run cleanup",
        annotations: %{
          readOnlyHint: false,
          destructiveHint: true,
          actions: %{
            "get" => %{kind: :read, planes: [:external]},
            "set" => %{kind: :write, planes: [:external]},
            "cleanup" => %{kind: :destructive, planes: [:external]}
          }
        },
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
                "executions" => %{
                  "type" => "integer",
                  "description" => "Number of executions to keep per project"
                },
                "builds" => %{
                  "type" => "integer",
                  "description" => "Number of builds to keep per user"
                }
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
      }
    ]
  end

  # ============================================================================
  # Health Check (ping) — must be before tool-specific catch-all clauses
  # ============================================================================

  # ============================================================================
  # Execution Tool
  # ============================================================================

  # Execution record writing is kernel-only (internal to Opus.Executor)
  # External clients may only read records via get/list actions
  def handle("record", _ctx, %{"action" => "record_start"}) do
    {:error,
     "Execution record writing is not permitted via MCP. Records are created internally by the execution engine."}
  end

  def handle("record", _ctx, %{"action" => "record_complete"}) do
    {:error,
     "Execution record writing is not permitted via MCP. Records are created internally by the execution engine."}
  end

  def handle("record", ctx, %{"action" => "get", "id" => id}) do
    with :ok <- authorize(ctx, :read) do
      case Arca.Execution.get_tenant(ctx, id) do
        nil ->
          {:error, "Execution not found: #{id}"}

        record ->
          # Project members are interchangeable: get_tenant already scoped to
          # org/project, so any member of the tenant may read the record.
          {:ok, execution_to_map(record)}
      end
    end
  end

  def handle("record", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: id"}
  end

  def handle("record", ctx, %{"action" => "list"} = args) do
    with :ok <- authorize(ctx, :read) do
      opts =
        [
          limit: min(args["limit"] || 20, 1000),
          org_id: ctx.org_id,
          project_id: ctx.project_id
        ]
        # user_id is an optional attribution filter any member may pass; default
        # is project-wide (org/project is the access boundary).
        |> maybe_put(:user_id, args["user_id"])
        |> maybe_put(:status, args["status"])
        |> maybe_put(:parent_execution_id, args["parent_execution_id"])

      records = Arca.Execution.list(opts)
      {:ok, %{executions: Enum.map(records, &execution_to_map/1)}}
    end
  end

  def handle("record", _ctx, _args) do
    {:error, "Invalid record action. Use: get or list"}
  end

  # ============================================================================
  # MCP Log Tool
  # ============================================================================

  # MCP log writing is kernel-only (internal to Emissary.MCP.RequestLog)
  # External clients may only read logs via list, get, correlate, stats actions
  def handle("mcp_log", _ctx, %{"action" => "log_started"}) do
    {:error,
     "MCP log writing is not permitted via MCP. Logs are created internally by the request pipeline."}
  end

  def handle("mcp_log", _ctx, %{"action" => "log_completed"}) do
    {:error,
     "MCP log writing is not permitted via MCP. Logs are created internally by the request pipeline."}
  end

  def handle("mcp_log", _ctx, %{"action" => "log_failed"}) do
    {:error,
     "MCP log writing is not permitted via MCP. Logs are created internally by the request pipeline."}
  end

  def handle("mcp_log", ctx, %{"action" => "get", "id" => id}) do
    with :ok <- authorize(ctx, :read) do
      case Arca.McpLog.get_tenant(ctx, id) do
        nil ->
          {:error, "MCP log not found: #{id}"}

        record ->
          {:ok, mcp_log_to_map(record)}
      end
    end
  end

  def handle("mcp_log", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: id"}
  end

  def handle("mcp_log", ctx, %{"action" => "list"} = args) do
    with :ok <- authorize(ctx, :read) do
      opts =
        [
          limit: min(args["limit"] || 20, 1000),
          org_id: ctx.org_id,
          project_id: ctx.project_id
        ]
        |> maybe_put(:user_id, args["user_id"])
        |> maybe_put(:status, args["status"])
        |> maybe_put(:request_id, args["request_id"])
        |> maybe_put(:tool, args["tool"])

      with {:ok, opts} <- parse_since_opt(opts, args["since"]) do
        records = Arca.McpLog.list(opts)
        {:ok, %{logs: Enum.map(records, &mcp_log_to_map/1)}}
      end
    end
  end

  # Audit logs are append-only — deletion is not permitted to preserve non-repudiation
  def handle("mcp_log", _ctx, %{"action" => "delete"}) do
    {:error, "Audit log deletion is not permitted. MCP logs are append-only."}
  end

  def handle("mcp_log", %Context{} = ctx, %{"action" => "correlate", "request_id" => request_id}) do
    with :ok <- authorize(ctx, :read) do
      mcp_logs =
        [request_id: request_id, limit: 100, org_id: ctx.org_id, project_id: ctx.project_id]
        |> Arca.McpLog.list()
        |> Enum.map(&mcp_log_to_map/1)

      import Ecto.Query
      import Arca.QueryHelpers, only: [where_tenant: 2, maybe_put: 3]

      exec_query =
        from(e in Arca.Execution,
          where: e.request_id == ^request_id,
          order_by: [desc: e.started_at],
          limit: 100
        )

      # Platform admins correlate across tenants; everyone else is scoped to their
      # org/project — no per-user narrowing (members are interchangeable).
      exec_query =
        if admin?(ctx) and ctx.scope == :platform do
          exec_query
        else
          where_tenant(exec_query, ctx)
        end

      executions = Arca.Repo.all(exec_query) |> Enum.map(&execution_to_map/1)

      policy_log_opts =
        [
          request_id: request_id,
          limit: 100,
          org_id: ctx.org_id,
          project_id: ctx.project_id
        ]

      policy_logs =
        Arca.PolicyLog.list(policy_log_opts)
        |> Enum.map(&policy_log_to_map/1)

      {:ok,
       %{
         request_id: request_id,
         mcp_logs: mcp_logs,
         executions: executions,
         policy_logs: policy_logs
       }}
    end
  end

  def handle("mcp_log", _ctx, %{"action" => "correlate"}) do
    {:error, "Missing required argument: request_id"}
  end

  # Batched fan-out counts: for each request_id, how many executions were
  # recorded against it? Used by ActivitiesLive to render the EXECS column
  # for a page of MCP log rows in a single GROUP BY instead of N correlate
  # queries.
  def handle("mcp_log", %Context{} = ctx, %{"action" => "fan_outs", "request_ids" => ids})
      when is_list(ids) do
    with :ok <- authorize(ctx, :read) do
      ids = Enum.filter(ids, &is_binary/1)

      counts =
        case ids do
          [] ->
            %{}

          _ ->
            import Ecto.Query
            import Arca.QueryHelpers, only: [where_tenant: 2]

            query =
              from(e in Arca.Execution,
                where: e.request_id in ^ids,
                group_by: e.request_id,
                select: {e.request_id, count(e.id)}
              )

            query =
              if admin?(ctx) and ctx.scope == :platform do
                query
              else
                where_tenant(query, ctx)
              end

            query |> Arca.Repo.all() |> Map.new()
        end

      {:ok, %{counts: counts}}
    end
  end

  def handle("mcp_log", _ctx, %{"action" => "fan_outs"}) do
    {:error, "Missing or invalid argument: request_ids (must be a list of strings)"}
  end

  def handle("mcp_log", ctx, %{"action" => "stats"} = args) do
    with :ok <- authorize(ctx, :read) do
      since_hours = args["since_hours"] || 1

      since = DateTime.utc_now() |> DateTime.add(-since_hours * 3600, :second)

      opts = [since: since, org_id: ctx.org_id, project_id: ctx.project_id]
      stats = Arca.McpLog.stats(opts)

      {:ok,
       %{
         since: DateTime.to_iso8601(since),
         total: stats.total,
         errors: stats.errors,
         avg_duration_ms: stats.avg_duration_ms,
         error_rate:
           if(stats.total > 0, do: Float.round(stats.errors / stats.total * 100, 1), else: 0.0)
       }}
    end
  end

  def handle("mcp_log", _ctx, _args) do
    {:error, "Invalid mcp_log action. Use: list, get, correlate, fan_outs, or stats"}
  end

  # ============================================================================
  # Policy Log Tool
  # ============================================================================

  # Policy-log writing is kernel-only (`Sanctum.Policy.Enforcement`).
  # External clients may only read logs via list, get, correlate actions
  def handle("policy_log", _ctx, %{"action" => "log"}) do
    {:error,
     "Policy log writing is not permitted via MCP. Logs are created internally by the policy enforcer."}
  end

  def handle("policy_log", ctx, %{"action" => "get", "id" => id}) do
    with :ok <- authorize(ctx, :read) do
      record =
        Arca.PolicyLog.get_tenant(ctx, id) || Arca.PolicyLog.get_by_request_id_tenant(ctx, id)

      case record do
        nil ->
          {:error, "Policy log not found: #{id}"}

        record ->
          {:ok, policy_log_to_map(record)}
      end
    end
  end

  def handle("policy_log", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: id"}
  end

  def handle("policy_log", ctx, %{"action" => "list"} = args) do
    with :ok <- authorize(ctx, :read) do
      opts =
        [
          limit: min(args["limit"] || 20, 1000),
          org_id: ctx.org_id,
          project_id: ctx.project_id
        ]
        |> maybe_put(:user_id, args["user_id"])
        |> maybe_put(:request_id, args["request_id"])
        |> maybe_put(:execution_id, args["execution_id"])
        |> maybe_put(:event_type, args["event_type"])

      records = Arca.PolicyLog.list(opts)
      {:ok, %{logs: Enum.map(records, &policy_log_to_map/1)}}
    end
  end

  # Audit logs are append-only — deletion is not permitted to preserve non-repudiation
  def handle("policy_log", _ctx, %{"action" => "delete"}) do
    {:error, "Audit log deletion is not permitted. Policy logs are append-only."}
  end

  def handle("policy_log", %Context{} = ctx, %{
        "action" => "correlate",
        "request_id" => request_id
      }) do
    with :ok <- authorize(ctx, :read) do
      opts =
        [
          request_id: request_id,
          limit: 100,
          org_id: ctx.org_id,
          project_id: ctx.project_id
        ]

      policy_logs =
        Arca.PolicyLog.list(opts)
        |> Enum.map(&policy_log_to_map/1)

      {:ok, %{request_id: request_id, policy_logs: policy_logs}}
    end
  end

  def handle("policy_log", _ctx, %{"action" => "correlate"}) do
    {:error, "Missing required argument: request_id"}
  end

  def handle("policy_log", _ctx, _args) do
    {:error, "Invalid policy_log action. Use: list, get, or correlate"}
  end

  # ============================================================================
  # Retention Tool
  # ============================================================================

  def handle("retention", %Context{} = ctx, %{"action" => "get"}) do
    with :ok <- authorize(ctx, :read) do
      settings = Arca.Retention.get_settings(ctx)
      {:ok, %{action: "get", settings: settings}}
    end
  end

  def handle("retention", %Context{} = ctx, %{"action" => "set", "settings" => settings})
      when is_map(settings) do
    with :ok <- authorize(ctx, :write) do
      case Arca.Retention.set_settings(ctx, settings) do
        :ok ->
          new_settings = Arca.Retention.get_settings(ctx)
          {:ok, %{action: "set", updated: true, settings: new_settings}}

        {:error, reason} ->
          Logger.error("[Arca.MCP] Failed to update retention settings: #{inspect(reason)}")
          {:error, "Failed to update retention settings"}
      end
    else
      {:error, _reason} ->
        {:error, "Unauthorized: setting retention requires admin-level access"}
    end
  end

  def handle("retention", %Context{} = ctx, %{"action" => "cleanup"} = args) do
    with :ok <- authorize(ctx, :delete) do
      cleanup_type = Map.get(args, "cleanup_type", "executions")
      dry_run = Map.get(args, "dry_run", false)

      result =
        case cleanup_type do
          "executions" -> Arca.Retention.cleanup_executions(ctx, dry_run: dry_run)
          "builds" -> Arca.Retention.cleanup_builds(ctx, dry_run: dry_run)
          "mcp_logs" -> Arca.Retention.cleanup_mcp_logs(ctx, dry_run: dry_run)
          _ -> {:error, "Unknown cleanup_type: #{cleanup_type}"}
        end

      case result do
        {:ok, count} when is_integer(count) ->
          {:ok, %{action: "cleanup", cleanup_type: cleanup_type, deleted: count}}

        {:ok, %{would_delete: ids} = info} ->
          {:ok,
           %{
             action: "cleanup",
             cleanup_type: cleanup_type,
             dry_run: true,
             would_delete: ids,
             would_keep: info[:would_keep]
           }}

        {:error, reason} ->
          Logger.error("[Arca.MCP] Cleanup failed: #{inspect(reason)}")
          {:error, "Cleanup failed"}
      end
    else
      {:error, _reason} ->
        {:error, "Unauthorized: cleanup requires admin-level access"}
    end
  end

  def handle("retention", _ctx, %{"action" => "set"}) do
    {:error, "Missing required parameter: settings (must be a JSON object)"}
  end

  def handle("retention", _ctx, _args) do
    {:error, "Invalid retention action. Use: get, set, or cleanup"}
  end

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp execution_to_map(exec) when is_struct(exec) or is_map(exec) do
    %{
      id: Map.get(exec, :id),
      request_id: Map.get(exec, :request_id),
      reference: Map.get(exec, :reference),
      input_hash: Map.get(exec, :input_hash),
      user_id: Map.get(exec, :user_id),
      component_type: Map.get(exec, :component_type),
      component_digest: Map.get(exec, :component_digest),
      started_at: format_datetime(Map.get(exec, :started_at)),
      completed_at: format_datetime(Map.get(exec, :completed_at)),
      duration_ms: Map.get(exec, :duration_ms),
      status: Map.get(exec, :status),
      error_message: Map.get(exec, :error_message),
      input: decode_json(Map.get(exec, :input)),
      output: decode_json(Map.get(exec, :output)),
      host_policy: decode_json(Map.get(exec, :host_policy)),
      wasi_trace: decode_json(Map.get(exec, :wasi_trace)),
      parent_execution_id: Map.get(exec, :parent_execution_id)
    }
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp format_datetime(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp format_datetime(dt) when is_binary(dt) do
    # Defensive: if a datetime ever arrives as a string without an offset,
    # append "Z" to ensure valid ISO 8601.
    if String.ends_with?(dt, "Z") or Regex.match?(~r/[+-]\d{2}:\d{2}$/, dt) do
      dt
    else
      dt <> "Z"
    end
  end

  defp format_datetime(dt), do: to_string(dt)

  defp mcp_log_to_map(%Arca.McpLog{} = log) do
    %{
      id: log.id,
      request_id: log.request_id,
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

  defp admin?(ctx), do: Context.has_permission?(ctx, :admin)

  defp parse_since_opt(opts, nil), do: {:ok, opts}

  defp parse_since_opt(opts, since_str) do
    case DateTime.from_iso8601(since_str) do
      {:ok, dt, _} -> {:ok, Keyword.put(opts, :since, dt)}
      _ -> {:error, "Invalid ISO8601 timestamp for 'since': #{since_str}"}
    end
  end

  # In-chain callers arrive guest-planed with the authority conjunct already
  # applied at the dispatch chokepoint; the provider supplies the identity
  # conjunct. External callers keep the fail-closed plane gate.
  defp authorize(%Context{plane: :guest} = ctx, permission) do
    with :ok <- Context.require_identity_permission(ctx, permission) do
      Context.tenant_ok(ctx)
    end
  end

  defp authorize(ctx, permission), do: Context.authorize(ctx, permission)
end
