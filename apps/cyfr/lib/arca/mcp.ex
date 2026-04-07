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

  @behaviour Emissary.MCP.ToolProvider

  require Logger

  alias Sanctum.Context
  alias Arca.TinctureData.Schema

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
    with :ok <- Context.authorize(ctx, :read) do
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
        description: "Query MCP request logs - list, get, correlate, or view stats",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["list", "get", "correlate", "stats"],
              "description" => "Action to perform"
            },
            "id" => %{"type" => "string", "description" => "Request ID"},
            "request_id" => %{"type" => "string", "description" => "Request ID for correlation"},
            "tool" => %{"type" => "string", "description" => "Tool name filter"},
            "since" => %{
              "type" => "string",
              "description" => "ISO8601 timestamp — return logs after this time"
            },
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
        description: "Query policy consultation logs - list, get, or correlate logs",
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
                  "description" => "Number of executions to keep per user"
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
      },
      %{
        name: "local_sqlite",
        title: "Local SQLite",
        description:
          "Manage approved local SQLite files resolved through Arca storage paths. Used by formulas and catalysts to feed data to tinctures.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["write", "clear", "status", "migrate"],
              "description" => "Action to perform"
            },
            "target" => %{
              "type" => "object",
              "description" => "Logical SQLite target resolved through Arca path rules",
              "properties" => %{
                "kind" => %{
                  "type" => "string",
                  "enum" => ["tincture", "path"],
                  "description" => "Target kind"
                },
                "publisher" => %{
                  "type" => "string",
                  "description" => "Publisher namespace (for tincture targets)"
                },
                "name" => %{
                  "type" => "string",
                  "description" => "Tincture name (for tincture targets)"
                },
                "path" => %{
                  "type" => "array",
                  "items" => %{"type" => "string"},
                  "description" => "Logical path segments (for path targets)"
                }
              },
              "required" => ["kind"]
            },
            "table" => %{
              "type" => "string",
              "description" => "Table name (for write/clear actions)"
            },
            "rows" => %{
              "type" => "array",
              "items" => %{"type" => "object"},
              "description" => "Rows to write (for write action)"
            },
            "on_conflict" => %{
              "type" => "string",
              "enum" => ["replace", "ignore", "error"],
              "description" => "Conflict resolution: replace (upsert), ignore, or error (default)"
            }
          },
          "required" => ["action", "target"]
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
    with :ok <- Context.authorize(ctx, :read) do
      case Arca.Execution.get_tenant(ctx, id) do
        nil ->
          {:error, "Execution not found: #{id}"}

        record ->
          if record.user_id == ctx.user_id or admin?(ctx) do
            {:ok, execution_to_map(record)}
          else
            {:error, "Execution not found: #{id}"}
          end
      end
    end
  end

  def handle("record", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: id"}
  end

  def handle("record", ctx, %{"action" => "list"} = args) do
    with :ok <- Context.authorize(ctx, :read) do
      # Non-admin users can only see their own records
      user_id = if admin?(ctx), do: args["user_id"] || ctx.user_id, else: ctx.user_id

      opts =
        [
          limit: min(args["limit"] || 20, 1000),
          org_id: ctx.org_id || "",
          project_id: ctx.project_id || "default"
        ]
        |> maybe_put(:user_id, user_id)
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
    with :ok <- Context.authorize(ctx, :read) do
      case Arca.McpLog.get_tenant(ctx, id) do
        nil ->
          {:error, "MCP log not found: #{id}"}

        record ->
          if record.user_id == ctx.user_id or admin?(ctx) do
            {:ok, mcp_log_to_map(record)}
          else
            {:error, "MCP log not found: #{id}"}
          end
      end
    end
  end

  def handle("mcp_log", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: id"}
  end

  def handle("mcp_log", ctx, %{"action" => "list"} = args) do
    with :ok <- Context.authorize(ctx, :read) do
      # Non-admin users can only see their own logs
      user_id = if admin?(ctx), do: args["user_id"] || ctx.user_id, else: ctx.user_id
      session_id = args["session_id"] || (ctx && ctx.session_id)

      opts =
        [
          limit: min(args["limit"] || 20, 1000),
          org_id: ctx.org_id || "",
          project_id: ctx.project_id || "default"
        ]
        |> maybe_put(:user_id, user_id)
        |> maybe_put(:status, args["status"])
        |> maybe_put(:session_id, session_id)
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

  def handle("mcp_log", ctx, %{"action" => "correlate", "request_id" => request_id}) do
    mcp_logs =
      case Arca.McpLog.get_tenant(ctx, request_id) do
        nil ->
          []

        log ->
          if log.user_id == ctx.user_id or admin?(ctx) do
            [mcp_log_to_map(log)]
          else
            []
          end
      end

    import Ecto.Query
    import Arca.QueryHelpers, only: [where_tenant: 2, maybe_put: 3]

    exec_query =
      from(e in Arca.Execution,
        where: e.request_id == ^request_id,
        order_by: [desc: e.started_at],
        limit: 100
      )

    exec_query =
      if admin?(ctx) and ctx.scope == :platform do
        exec_query
      else
        exec_query
        |> where_tenant(ctx)
        |> then(fn q ->
          if admin?(ctx), do: q, else: from(e in q, where: e.user_id == ^ctx.user_id)
        end)
      end

    executions = Arca.Repo.all(exec_query) |> Enum.map(&execution_to_map/1)

    policy_log_opts =
      [
        request_id: request_id,
        limit: 100,
        org_id: ctx.org_id || "",
        project_id: ctx.project_id || "default"
      ]

    policy_log_opts =
      if admin?(ctx),
        do: policy_log_opts,
        else: Keyword.put(policy_log_opts, :user_id, ctx.user_id)

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

  def handle("mcp_log", _ctx, %{"action" => "correlate"}) do
    {:error, "Missing required argument: request_id"}
  end

  def handle("mcp_log", ctx, %{"action" => "stats"} = args) do
    since_hours = args["since_hours"] || 1

    since = DateTime.utc_now() |> DateTime.add(-since_hours * 3600, :second)

    opts =
      [since: since, org_id: ctx.org_id || "", project_id: ctx.project_id || "default"]

    opts = if admin?(ctx), do: opts, else: Keyword.put(opts, :user_id, ctx.user_id)
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

  def handle("mcp_log", _ctx, _args) do
    {:error, "Invalid mcp_log action. Use: list, get, correlate, or stats"}
  end

  # ============================================================================
  # Policy Log Tool
  # ============================================================================

  # Policy log writing is kernel-only (internal to Opus.PolicyEnforcer)
  # External clients may only read logs via list, get, correlate actions
  def handle("policy_log", _ctx, %{"action" => "log"}) do
    {:error,
     "Policy log writing is not permitted via MCP. Logs are created internally by the policy enforcer."}
  end

  def handle("policy_log", ctx, %{"action" => "get", "id" => id}) do
    with :ok <- Context.authorize(ctx, :read) do
      record =
        Arca.PolicyLog.get_tenant(ctx, id) || Arca.PolicyLog.get_by_request_id_tenant(ctx, id)

      case record do
        nil ->
          {:error, "Policy log not found: #{id}"}

        record ->
          if record.user_id == ctx.user_id or admin?(ctx) do
            {:ok, policy_log_to_map(record)}
          else
            {:error, "Policy log not found: #{id}"}
          end
      end
    end
  end

  def handle("policy_log", _ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: id"}
  end

  def handle("policy_log", ctx, %{"action" => "list"} = args) do
    with :ok <- Context.authorize(ctx, :read) do
      # Non-admin users can only see their own logs
      user_id = if admin?(ctx), do: args["user_id"] || ctx.user_id, else: ctx.user_id

      opts =
        [
          limit: min(args["limit"] || 20, 1000),
          org_id: ctx.org_id || "",
          project_id: ctx.project_id || "default"
        ]
        |> maybe_put(:user_id, user_id)
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

  def handle("policy_log", ctx, %{"action" => "correlate", "request_id" => request_id}) do
    opts =
      [
        request_id: request_id,
        limit: 100,
        org_id: ctx.org_id || "",
        project_id: ctx.project_id || "default"
      ]

    opts = if admin?(ctx), do: opts, else: Keyword.put(opts, :user_id, ctx.user_id)

    policy_logs =
      Arca.PolicyLog.list(opts)
      |> Enum.map(&policy_log_to_map/1)

    {:ok, %{request_id: request_id, policy_logs: policy_logs}}
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
    with :ok <- Context.authorize(ctx, :read) do
      settings = Arca.Retention.get_settings(ctx)
      {:ok, %{action: "get", settings: settings}}
    end
  end

  def handle("retention", %Context{} = ctx, %{"action" => "set", "settings" => settings})
      when is_map(settings) do
    with :ok <- Context.authorize(ctx, :write) do
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
    with :ok <- Context.authorize(ctx, :delete) do
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

  # ============================================================================
  # Local SQLite Tool
  # ============================================================================

  def handle("local_sqlite", %Context{} = ctx, %{"action" => "write"} = args) do
    table = args["table"]
    on_conflict = args["on_conflict"] || "error"

    cond do
      not (is_binary(table) and table != "") ->
        {:error, "Missing required parameter: table"}

      on_conflict not in ["replace", "ignore", "error"] ->
        {:error, "Invalid on_conflict: must be 'replace', 'ignore', or 'error'"}

      true ->
        with :ok <- Context.authorize(ctx, :execute),
             {:ok, target} <- resolve_sqlite_target(ctx, args["target"]),
             :ok <- Arca.TinctureData.DB.check_db_size(target.db_path) do
          rows = args["rows"] || []

          case target.kind do
            :tincture ->
              write_tincture_rows(ctx, target, table, rows, on_conflict)

            :path ->
              write_path_rows(target, table, rows, on_conflict)
          end
        end
    end
  end

  def handle("local_sqlite", %Context{} = ctx, %{"action" => "clear"} = args) do
    with :ok <- Context.authorize(ctx, :execute),
         {:ok, target} <- resolve_sqlite_target(ctx, args["target"]) do
      table = args["table"]

      unless is_binary(table) and table != "" do
        {:error, "Missing required parameter: table"}
      else
        with :ok <- Arca.TinctureData.Schema.validate_identifier(table),
             :ok <- validate_table_in_schema(target, table) do
          quoted_table = Arca.TinctureData.Schema.quote_identifier(table)

          case Arca.TinctureData.DB.with_connection(target.db_path, :readwrite, fn conn ->
                 Arca.TinctureData.DB.execute(conn, "DELETE FROM #{quoted_table}")
               end) do
            {:ok, :ok} ->
              if target.kind == :tincture do
                Arca.TinctureData.QueryCache.invalidate_tincture(
                  ctx,
                  target.publisher,
                  target.name
                )
              end

              {:ok, %{cleared: true, table: table}}

            {:ok, {:error, reason}} ->
              {:error, "clear failed: #{inspect(reason)}"}

            {:error, reason} ->
              {:error, "clear failed: #{inspect(reason)}"}
          end
        end
      end
    end
  end

  def handle("local_sqlite", %Context{} = ctx, %{"action" => "status"} = args) do
    with :ok <- Context.authorize(ctx, :read),
         {:ok, target} <- resolve_sqlite_target(ctx, args["target"]) do
      db_path = target.db_path

      case File.stat(db_path) do
        {:ok, stat} ->
          tables_info =
            case target.kind do
              :tincture ->
                manifest = target.manifest
                schema = manifest["schema"] || %{}
                table_names = Map.keys(schema["tables"] || %{})

                case Arca.TinctureData.DB.with_connection(db_path, :readonly, fn conn ->
                       Enum.map(table_names, fn t ->
                         quoted = Arca.TinctureData.Schema.quote_identifier(t)

                         case Arca.TinctureData.DB.query(conn, "SELECT COUNT(*) FROM #{quoted}") do
                           {:ok, %{rows: [[count]]}} -> {t, count}
                           _ -> {t, 0}
                         end
                       end)
                     end) do
                  {:ok, counts} -> Map.new(counts)
                  _ -> %{}
                end

              :path ->
                %{}
            end

          {:ok,
           %{
             tables: tables_info,
             file_size: stat.size,
             modified_at: stat.mtime |> NaiveDateTime.from_erl!() |> NaiveDateTime.to_iso8601()
           }}

        {:error, :enoent} ->
          {:ok, %{tables: %{}, file_size: 0, modified_at: nil, note: "database not yet created"}}

        {:error, reason} ->
          {:error, "cannot stat database: #{inspect(reason)}"}
      end
    end
  end

  def handle("local_sqlite", %Context{} = ctx, %{"action" => "migrate"} = args) do
    with :ok <- Context.authorize(ctx, :execute),
         {:ok, target} <- resolve_sqlite_target(ctx, args["target"]) do
      if target.kind != :tincture do
        {:error, "migrate action is only available for tincture targets"}
      else
        case Arca.TinctureData.Migrator.migrate(target.version_dir, target.manifest) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, "migration failed: #{reason}"}
        end
      end
    end
  end

  def handle("local_sqlite", _ctx, _args) do
    {:error, "Invalid local_sqlite action. Use: write, clear, status, or migrate"}
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
    # SQLite schemaless queries return datetime strings without UTC offset.
    # Append "Z" if no offset is present to ensure valid ISO 8601.
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

  defp admin?(ctx), do: Context.has_permission?(ctx, :admin)

  defp parse_since_opt(opts, nil), do: {:ok, opts}

  defp parse_since_opt(opts, since_str) do
    case DateTime.from_iso8601(since_str) do
      {:ok, dt, _} -> {:ok, Keyword.put(opts, :since, dt)}
      _ -> {:error, "Invalid ISO8601 timestamp for 'since': #{since_str}"}
    end
  end

  # ============================================================================
  # Local SQLite Helpers
  # ============================================================================

  defp resolve_sqlite_target(ctx, %{"kind" => "tincture", "publisher" => pub, "name" => name})
       when is_binary(pub) and is_binary(name) do
    case Sanctum.TinctureAccess.get_private(ctx, pub, name) do
      {:ok, tincture} ->
        {:ok,
         %{
           kind: :tincture,
           publisher: pub,
           name: name,
           version_dir: tincture.dir,
           db_path: Arca.TinctureData.DB.db_path(tincture.dir),
           manifest: tincture.manifest
         }}

      {:error, _} ->
        {:error, "tincture '#{pub}/#{name}' not found or access denied"}
    end
  end

  defp resolve_sqlite_target(ctx, %{"kind" => "path", "path" => segments})
       when is_list(segments) do
    last = List.last(segments)

    cond do
      segments == [] ->
        {:error, "path segments must not be empty"}

      not is_binary(last) or not String.ends_with?(last, ".db") ->
        {:error, "path target must end with a .db file"}

      hd(segments) != "data" ->
        {:error, "path targets must start with 'data'"}

      Enum.any?(segments, fn s -> s == ".." or String.contains?(s, "/") end) ->
        {:error, "path segments must not contain '..' or '/'"}

      true ->
        db_path = Arca.Adapters.Local.build_path(ctx, segments)

        {:ok,
         %{
           kind: :path,
           db_path: db_path,
           manifest: nil,
           publisher: nil,
           name: nil,
           version_dir: nil
         }}
    end
  end

  defp resolve_sqlite_target(_ctx, %{"kind" => "tincture"}) do
    {:error, "tincture target requires 'publisher' and 'name'"}
  end

  defp resolve_sqlite_target(_ctx, %{"kind" => "path"}) do
    {:error, "path target requires 'path' (array of strings)"}
  end

  defp resolve_sqlite_target(_ctx, _target) do
    {:error, "target must have 'kind' set to 'tincture' or 'path'"}
  end

  defp write_tincture_rows(ctx, target, table, rows, on_conflict) do
    manifest = target.manifest

    with {:ok, schema} <- Arca.TinctureData.Schema.parse_manifest_schema(manifest) do
      table_schema = schema.tables[table]

      if is_nil(table_schema) do
        {:error, "table '#{table}' not declared in tincture schema"}
      else
        # Validate all rows
        validated =
          Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
            case Arca.TinctureData.Schema.validate_row(table_schema, row) do
              {:ok, coerced} -> {:cont, {:ok, acc ++ [coerced]}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)

        case validated do
          {:ok, coerced_rows} ->
            :ok = Arca.TinctureData.Migrator.ensure_migrated(target.version_dir, manifest)
            do_write_rows(target.db_path, table, table_schema, coerced_rows, on_conflict, ctx, target)

          {:error, reason} ->
            {:error, "row validation failed: #{reason}"}
        end
      end
    end
  end

  defp write_path_rows(target, table, rows, on_conflict) do
    db_path = target.db_path
    dir = Path.dirname(db_path)
    File.mkdir_p!(dir)

    with :ok <- Schema.validate_identifier(table),
         :ok <- validate_row_keys(rows) do
      quoted_table = Schema.quote_identifier(table)

      case Arca.TinctureData.DB.with_connection(db_path, :readwrite, fn conn ->
             Arca.TinctureData.DB.transaction(conn, fn c ->
               Enum.each(rows, fn row ->
                 cols = Map.keys(row)
                 vals = Map.values(row)
                 placeholders = Enum.map(cols, fn _ -> "?" end) |> Enum.join(", ")
                 col_list = Enum.map_join(cols, ", ", &Schema.quote_identifier/1)

                 verb = conflict_verb(on_conflict)
                 sql = "INSERT #{verb} INTO #{quoted_table} (#{col_list}) VALUES (#{placeholders})"
                 :ok = Arca.TinctureData.DB.execute(c, sql, vals)
               end)

               length(rows)
             end)
           end) do
        {:ok, {:ok, count}} ->
          {:ok, %{written: count, table: table, target: %{kind: "path"}}}

        {:ok, {:error, reason}} ->
          {:error, "write failed: #{inspect(reason)}"}

        {:error, reason} ->
          {:error, "write failed: #{inspect(reason)}"}
      end
    end
  end

  defp do_write_rows(db_path, table, table_schema, coerced_rows, on_conflict, ctx, target) do
    col_names = Enum.map(table_schema.columns, & &1.name)
    quoted_table = Arca.TinctureData.Schema.quote_identifier(table)

    case Arca.TinctureData.DB.with_connection(db_path, :readwrite, fn conn ->
           Arca.TinctureData.DB.transaction(conn, fn c ->
             Enum.each(coerced_rows, fn row ->
               present_cols = Enum.filter(col_names, fn col -> Map.has_key?(row, col) end)
               present_vals = Enum.map(present_cols, fn col -> Map.get(row, col) end)
               placeholders = Enum.map(present_cols, fn _ -> "?" end) |> Enum.join(", ")

               col_list =
                 Enum.map_join(present_cols, ", ", &Arca.TinctureData.Schema.quote_identifier/1)

               verb = conflict_verb(on_conflict)
               sql = "INSERT #{verb} INTO #{quoted_table} (#{col_list}) VALUES (#{placeholders})"
               :ok = Arca.TinctureData.DB.execute(c, sql, present_vals)
             end)

             length(coerced_rows)
           end)
         end) do
      {:ok, {:ok, count}} ->
        Arca.TinctureData.QueryCache.invalidate_tincture(ctx, target.publisher, target.name)

        {:ok,
         %{
           written: count,
           table: table,
           target: %{kind: "tincture", publisher: target.publisher, name: target.name}
         }}

      {:ok, {:error, reason}} ->
        {:error, "write failed: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "write failed: #{inspect(reason)}"}
    end
  end

  # For tincture targets, validate the table is declared in the manifest schema.
  # Path targets have no schema — skip validation (identifier check is sufficient).
  defp validate_table_in_schema(%{kind: :tincture, manifest: manifest}, table) do
    case Arca.TinctureData.Schema.parse_manifest_schema(manifest) do
      {:ok, schema} ->
        if Map.has_key?(schema.tables, table) do
          :ok
        else
          {:error, "table '#{table}' not declared in tincture schema"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_table_in_schema(%{kind: :path}, _table), do: :ok

  defp conflict_verb("replace"), do: "OR REPLACE"
  defp conflict_verb("ignore"), do: "OR IGNORE"
  defp conflict_verb("error"), do: ""

  defp validate_row_keys(rows) when is_list(rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case Enum.find(Map.keys(row), fn k ->
             Arca.TinctureData.Schema.validate_identifier(k) != :ok
           end) do
        nil -> {:cont, :ok}
        bad -> {:halt, {:error, "invalid column name in row: '#{String.slice(bad, 0, 40)}'"}}
      end
    end)
  end

  defp validate_row_keys(_), do: {:error, "rows must be a list"}
end
