# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.Tools.RecordsProvider do
  @moduledoc """
  MCP tool provider for execution, MCP and policy records plus retention —
  the observability surface over what Arca persists. Lives in Emissary
  because a tool provider is product surface, not persistence mechanics.

  Exposes Arca operations as MCP tools with action-based dispatch.

  File storage operations (read, write, list, delete, exists) are handled by
  the `cyfr:storage/files@0.1.0` host function for catalysts via
  `Opus.StorageHandler`, not as an MCP tool. The `retention` tool manages
  data retention policies (get, set, cleanup).

  The `arca://files/{path}` resource is read-only (MCP resources have no
  write operation). A person — a session, or a key holding `:admin` —
  reads the athanor's whole tree, every scope in
  `Arca.Storage.tenant_roots/0`, attachment blobs included: the athanor is
  its members' own machine. A narrower credential, a key scoped to
  `:storage_read` alone, reaches `conversations/` and `guest/` — what a
  conversation attached and what an agent could have written — and never
  the estate's components, its assistant tree or its notes. Conversation
  transcripts are rows, never reachable here, and an unknown first
  segment is a typed refusal at the Arca gate.

  ## Retention Tool

  The `retention` tool manages data retention policies:

      # Get current settings
      {"action": "get"}

      # Update settings (admin only)
      {"action": "set", "settings": {"executions": 5, "builds": 3}}

      # Run cleanup (admin only)
      {"action": "cleanup", "cleanup_type": "executions", "dry_run": false}

  ## Architecture Note

  Tool definitions live next to their implementation in this module.
  Emissary discovers this provider via configuration and delegates
  calls here.

  Implements the ToolProvider protocol (tools/0 and handle/3)
  which is validated at runtime by Cyfr.Ops.Catalog.
  """

  @behaviour Cyfr.Ops.Provider

  def service, do: "arca"

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
        description:
          "Read a file in the athanor's storage by path. A person reads every root (" <>
            Enum.map_join(Arca.Storage.tenant_roots(), ", ", &(&1 <> "/")) <>
            "); a key scoped to :storage_read reaches conversations/ and guest/",
        mimeType: Cyfr.MediaType.binary()
      }
    ]
  end

  @doc """
  Read a resource by URI.
  """
  def read(%Context{authenticated: false}, "arca://files/" <> _path) do
    # Typed, so the router renders the one auth prose AND answers with the
    # auth_required code — the bare string used to ride out mislabeled as
    # resource_not_found.
    {:error, :unauthenticated}
  end

  def read(%Context{} = ctx, "arca://files/" <> path) do
    # Resources have no annotation chokepoint — the router delegates
    # authorization to each handler, so the `:storage_read` the template
    # advertises is enforced here. `require_permission/2` fails closed on
    # guest-plane contexts. The path is caller input: validate it (and the
    # context's tenant) totally here — `Arca.get/2` raises on both, which
    # is the fail-loud contract for host code, not for an MCP boundary.
    segments = String.split(path, "/") |> Enum.reject(&(&1 == ""))

    with :ok <- Context.require_permission(ctx, :storage_read),
         :ok <- Context.tenant_ok(ctx),
         :ok <- storage_ctx_gate(ctx),
         :ok <- validate_segments(segments),
         :ok <- within_reach(ctx, segments) do
      case Arca.get(ctx, segments) do
        {:ok, content} ->
          {:ok, %{content: Base.encode64(content), mimeType: Cyfr.MediaType.binary()}}

        {:error, :not_found} ->
          {:error, {:not_found, "File", path}}

        {:error, :forbidden} ->
          {:error, "Forbidden path: #{path}"}

        {:error, reason} ->
          Logger.error("[Emissary.MCP.Tools.RecordsProvider] Failed to read: #{inspect(reason)}")
          {:error, "Failed to read"}
      end
    end
  end

  def read(_ctx, uri) do
    {:error, "Unknown resource URI: #{uri}"}
  end

  # What `:storage_read` opens through this resource: the whole tree for a
  # person (`:admin` — a session holds every permission), and for a
  # narrower key only the roots an agent or a conversation could have
  # filled.
  @key_reach ["conversations", "guest"]

  defp within_reach(ctx, [root | _]) do
    if Context.has_permission?(ctx, :admin) or root in @key_reach,
      do: :ok,
      else: {:error, {:invalid_argument, "Forbidden path: #{root}"}}
  end

  defp within_reach(_ctx, []), do: :ok

  # `tenant_gate/1` exempts platform scope; blob reads are tenant-relative,
  # so a platform context must still carry the athanor whose files it reads.
  defp storage_ctx_gate(ctx) do
    if Arca.Storage.athanor_ready?(ctx),
      do: :ok,
      else: {:error, :missing_tenant}
  end

  defp validate_segments(segments) do
    case Cyfr.PathSafety.validate_segments(segments) do
      :ok -> :ok
      {:error, {_reason, message}} -> {:error, {:invalid_argument, "Invalid path: #{message}"}}
    end
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
            "get" => %{kind: :read, planes: [:external], permission: :storage_read},
            "list" => %{kind: :read, planes: [:external], permission: :storage_read},
            "payload" => %{kind: :read, planes: [:external], permission: :storage_read}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["get", "list", "payload"],
              "description" => "Action to perform"
            },
            "id" => %{
              "type" => "string",
              "description" => "Execution ID"
            },
            "kind" => %{
              "type" => "string",
              "enum" => ["input", "result"],
              "description" => "payload only: which retained payload (default result)"
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
            "list" => %{kind: :read, planes: [:external], permission: :storage_read},
            "get" => %{kind: :read, planes: [:external], permission: :storage_read},
            "correlate" => %{kind: :read, planes: [:external], permission: :storage_read},
            "fan_outs" => %{kind: :read, planes: [:external], permission: :storage_read},
            "stats" => %{kind: :read, planes: [:external], permission: :storage_read}
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
            "list" => %{kind: :read, planes: [:external], permission: :storage_read},
            "get" => %{kind: :read, planes: [:external], permission: :storage_read},
            "correlate" => %{kind: :read, planes: [:external], permission: :storage_read}
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
            "get" => %{kind: :read, planes: [:external], permission: :storage_read},
            "set" => %{kind: :write, planes: [:external], permission: :storage_write},
            "cleanup" => %{kind: :destructive, planes: [:external], permission: :admin}
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
            # Both the settable keys and the cleanup vocabulary derive from
            # the retention roster (`Cyfr.Retention.kinds/0`), so a new kind
            # is on this surface the moment it exists — the enum cannot fall
            # behind the policy module again.
            "settings" => %{
              "type" => "object",
              "properties" =>
                Map.new(Cyfr.Retention.kinds(), fn kind ->
                  {kind.key(), %{"type" => "integer", "description" => setting_description(kind)}}
                end),
              "description" => "Retention settings (for set action)"
            },
            "cleanup_type" => %{
              "type" => "string",
              "enum" => Enum.map(Cyfr.Retention.kinds(), & &1.key()),
              "description" => "Kind of records to clean up (for cleanup action)"
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

  def handle("record", ctx, %{"action" => "get", "id" => id}) do
    with :ok <- Context.tenant_ok(ctx) do
      case Arca.Execution.get_tenant(ctx, id) do
        nil ->
          {:error, {:not_found, "Execution", id}}

        # get_tenant is db-rescued and answers a tuple on an outage;
        # binding it as the row sends a 2-tuple into execution_to_map/1,
        # whose `is_struct or is_map` guard raises — so `get` answered
        # "the tool crashed" where `list` answers the storage refusal.
        {:error, :database_error} ->
          {:error, {:unavailable, "Storage"}}

        {:error, _} = err ->
          err

        record ->
          # Members are interchangeable: get_tenant already scoped to the
          # athanor, so any member of the athanor may read the record.
          {:ok, execution_to_map(record)}
      end
    end
  end

  def handle("record", _ctx, %{"action" => "get"}) do
    {:error, {:invalid_argument, "Missing required argument: id"}}
  end

  # A retained payload: the bytes an execution was given or answered,
  # for a member of the athanor that ran it.
  def handle("record", ctx, %{"action" => "payload", "id" => id} = args) do
    kind = Map.get(args, "kind", "result")

    with :ok <- Context.tenant_ok(ctx),
         :ok <- storage_ctx_gate(ctx),
         true <-
           kind in ["input", "result"] ||
             {:error, {:invalid_argument, "kind must be input or result"}} do
      case Arca.ExecutionPayloads.get(ctx, id, kind) do
        {:ok, row, bytes} ->
          {:ok,
           %{
             execution_id: id,
             kind: kind,
             digest: row.digest,
             bytes: row.bytes,
             retention_class: row.retention_class,
             content: Base.encode64(bytes),
             mimeType: Cyfr.MediaType.binary()
           }}

        {:error, :not_found} ->
          {:error, {:not_found, "Payload", "#{id}/#{kind}"}}

        {:error, :payload_corrupt} ->
          {:error, {:corrupt, "Payload #{id}/#{kind}"}}

        {:error, :database_error} ->
          {:error, {:unavailable, "Storage"}}

        {:error, _} = err ->
          err
      end
    end
  end

  def handle("record", _ctx, %{"action" => "payload"}) do
    {:error, {:invalid_argument, "Missing required argument: id"}}
  end

  def handle("record", ctx, %{"action" => "list"} = args) do
    with :ok <- Context.tenant_ok(ctx) do
      opts =
        [
          limit: min(args["limit"] || 20, 1000),
          athanor_id: ctx.athanor_id
        ]
        # user_id is an optional attribution filter any member may pass; default
        # is athanor-wide (the athanor is the access boundary).
        |> maybe_put(:user_id, args["user_id"])
        |> maybe_put(:status, args["status"])
        |> maybe_put(:parent_execution_id, args["parent_execution_id"])

      # `list/1` answers a tuple on an outage; mapping over it raised a
      # 500 where the sibling log arms answer the storage refusal.
      case Arca.Execution.list(opts) do
        {:error, :database_error} -> {:error, {:unavailable, "Storage"}}
        {:error, _} = err -> err
        records -> {:ok, %{executions: Enum.map(records, &execution_to_map/1)}}
      end
    end
  end

  def handle("record", _ctx, _args) do
    {:error, Cyfr.Ops.Provider.invalid_action("record", action_enum("record"))}
  end

  # ============================================================================
  # MCP Log Tool
  # ============================================================================

  def handle("mcp_log", ctx, %{"action" => "get", "id" => id}) do
    with :ok <- Context.tenant_ok(ctx) do
      case Arca.McpLog.get_tenant(ctx, id) do
        nil ->
          {:error, {:not_found, "MCP log", id}}

        # Same outage shape as the execution arm above.
        {:error, :database_error} ->
          {:error, {:unavailable, "Storage"}}

        {:error, _} = err ->
          err

        record ->
          {:ok, mcp_log_to_map(record)}
      end
    end
  end

  def handle("mcp_log", _ctx, %{"action" => "get"}) do
    {:error, {:invalid_argument, "Missing required argument: id"}}
  end

  def handle("mcp_log", ctx, %{"action" => "list"} = args) do
    with :ok <- Context.tenant_ok(ctx) do
      opts =
        [
          limit: min(args["limit"] || 20, 1000),
          athanor_id: ctx.athanor_id
        ]
        |> maybe_put(:user_id, args["user_id"])
        |> maybe_put(:status, args["status"])
        |> maybe_put(:request_id, args["request_id"])
        |> maybe_put(:tool, args["tool"])

      with {:ok, opts} <- parse_since_opt(opts, args["since"]),
           {:ok, records} <- Arca.McpLog.list(opts) do
        {:ok, %{logs: Enum.map(records, &mcp_log_to_map/1)}}
      else
        {:error, :database_error} -> {:error, {:unavailable, "Storage"}}
        {:error, _} = err -> err
      end
    end
  end

  def handle("mcp_log", %Context{} = ctx, %{"action" => "correlate", "request_id" => request_id}) do
    with :ok <- Context.tenant_ok(ctx) do
      mcp_logs =
        case Arca.McpLog.list(request_id: request_id, limit: 100, athanor_id: ctx.athanor_id) do
          {:ok, rows} -> Enum.map(rows, &mcp_log_to_map/1)
          {:error, _} -> []
        end

      # Correlation is a best-effort join of three sources: a storage
      # outage on one leaves that leg empty, the way the mcp_log leg above
      # already does, rather than raising on the error tuple.
      executions =
        case Arca.Execution.list_by_request(ctx, request_id) do
          rows when is_list(rows) -> Enum.map(rows, &execution_to_map/1)
          {:error, _} -> []
        end

      policy_log_opts =
        [
          request_id: request_id,
          limit: 100,
          athanor_id: ctx.athanor_id
        ]

      policy_logs =
        case Arca.PolicyLog.list(policy_log_opts) do
          {:ok, rows} -> Enum.map(rows, &policy_log_to_map/1)
          {:error, _} -> []
        end

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
    {:error, {:invalid_argument, "Missing required argument: request_id"}}
  end

  # Batched fan-out counts: for each request_id, how many executions were
  # recorded against it? Used by ActivitiesLive to render the EXECS column
  # for a page of MCP log rows in a single GROUP BY instead of N correlate
  # queries.
  def handle("mcp_log", %Context{} = ctx, %{"action" => "fan_outs", "request_ids" => ids})
      when is_list(ids) do
    with :ok <- Context.tenant_ok(ctx) do
      ids = Enum.filter(ids, &is_binary/1)

      # `count_by_request/2` refuses rather than defaulting, so an outage
      # answers `{:error, :database_error}` — which was being wrapped and
      # shipped as `counts: ["error", "database_error"]`, a structured
      # falsehood a client would render as a fan-out count. Same refusal
      # the other arms give.
      case Arca.Execution.count_by_request(ctx, ids) do
        counts when is_map(counts) -> {:ok, %{counts: counts}}
        {:error, :database_error} -> {:error, {:unavailable, "Storage"}}
      end
    end
  end

  def handle("mcp_log", _ctx, %{"action" => "fan_outs"}) do
    {:error,
     {:invalid_argument, "Missing or invalid argument: request_ids (must be a list of strings)"}}
  end

  def handle("mcp_log", ctx, %{"action" => "stats"} = args) do
    with :ok <- Context.tenant_ok(ctx) do
      since_hours = args["since_hours"] || 1

      since = DateTime.utc_now() |> DateTime.add(-since_hours * 3600, :second)

      opts = [since: since, athanor_id: ctx.athanor_id]

      case Arca.McpLog.stats(opts) do
        {:ok, stats} ->
          {:ok,
           %{
             since: DateTime.to_iso8601(since),
             total: stats.total,
             errors: stats.errors,
             avg_duration_ms: stats.avg_duration_ms,
             error_rate:
               if(stats.total > 0,
                 do: Float.round(stats.errors / stats.total * 100, 1),
                 else: 0.0
               )
           }}

        {:error, :database_error} ->
          {:error, {:unavailable, "Storage"}}
      end
    end
  end

  def handle("mcp_log", _ctx, _args) do
    {:error, Cyfr.Ops.Provider.invalid_action("mcp_log", action_enum("mcp_log"))}
  end

  # ============================================================================
  # Policy Log Tool
  # ============================================================================

  def handle("policy_log", ctx, %{"action" => "get", "id" => id}) do
    with :ok <- Context.tenant_ok(ctx) do
      record =
        Arca.PolicyLog.get_tenant(ctx, id) || Arca.PolicyLog.get_by_request_id_tenant(ctx, id)

      case record do
        nil ->
          {:error, {:not_found, "Policy log", id}}

        record ->
          {:ok, policy_log_to_map(record)}
      end
    end
  end

  def handle("policy_log", _ctx, %{"action" => "get"}) do
    {:error, {:invalid_argument, "Missing required argument: id"}}
  end

  def handle("policy_log", ctx, %{"action" => "list"} = args) do
    with :ok <- Context.tenant_ok(ctx) do
      opts =
        [
          limit: min(args["limit"] || 20, 1000),
          athanor_id: ctx.athanor_id
        ]
        |> maybe_put(:user_id, args["user_id"])
        |> maybe_put(:request_id, args["request_id"])
        |> maybe_put(:execution_id, args["execution_id"])
        |> maybe_put(:event_type, args["event_type"])

      case Arca.PolicyLog.list(opts) do
        {:ok, records} -> {:ok, %{logs: Enum.map(records, &policy_log_to_map/1)}}
        {:error, :database_error} -> {:error, {:unavailable, "Storage"}}
      end
    end
  end

  def handle("policy_log", %Context{} = ctx, %{
        "action" => "correlate",
        "request_id" => request_id
      }) do
    with :ok <- Context.tenant_ok(ctx) do
      opts =
        [
          request_id: request_id,
          limit: 100,
          athanor_id: ctx.athanor_id
        ]

      policy_logs =
        case Arca.PolicyLog.list(opts) do
          {:ok, rows} -> Enum.map(rows, &policy_log_to_map/1)
          {:error, _} -> []
        end

      {:ok, %{request_id: request_id, policy_logs: policy_logs}}
    end
  end

  def handle("policy_log", _ctx, %{"action" => "correlate"}) do
    {:error, {:invalid_argument, "Missing required argument: request_id"}}
  end

  def handle("policy_log", _ctx, _args) do
    {:error, Cyfr.Ops.Provider.invalid_action("policy_log", action_enum("policy_log"))}
  end

  # ============================================================================
  # Retention Tool
  # ============================================================================

  def handle("retention", %Context{} = ctx, %{"action" => "get"}) do
    with :ok <- Context.tenant_ok(ctx),
         {:ok, settings} <- Cyfr.Retention.get_settings(ctx) do
      {:ok, %{action: "get", settings: settings}}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("[RecordsProvider] retention settings read failed: #{inspect(reason)}")
        {:error, {:unavailable, "Retention settings"}}
    end
  end

  def handle("retention", %Context{} = ctx, %{"action" => "set", "settings" => settings})
      when is_map(settings) do
    with :ok <- Context.tenant_ok(ctx) do
      case Cyfr.Retention.set_settings(ctx, settings) do
        :ok ->
          {:ok, new_settings} = Cyfr.Retention.get_settings(ctx)
          {:ok, %{action: "set", updated: true, settings: new_settings}}

        {:error, {:unknown_setting, key}} ->
          {:error, {:invalid_argument, "Unknown retention setting: #{key}"}}

        {:error, {:invalid_setting, key}} ->
          {:error,
           {:invalid_argument,
            "Invalid value for retention setting #{key} — use a positive integer"}}

        {:error, reason} ->
          Logger.error(
            "[Emissary.MCP.Tools.RecordsProvider] Failed to update retention settings: #{inspect(reason)}"
          )

          {:error, "Failed to update retention settings"}
      end
    end
  end

  def handle("retention", %Context{} = ctx, %{"action" => "cleanup"} = args) do
    with :ok <- Context.tenant_ok(ctx) do
      cleanup_type = Map.get(args, "cleanup_type", "executions")
      dry_run = Map.get(args, "dry_run", false)

      # One dispatch for every kind — the roster is `Cyfr.Retention`'s.
      case Cyfr.Retention.cleanup(ctx, cleanup_type, dry_run: dry_run) do
        {:ok, count} when dry_run ->
          {:ok,
           %{action: "cleanup", cleanup_type: cleanup_type, dry_run: true, would_delete: count}}

        {:ok, count} ->
          {:ok, %{action: "cleanup", cleanup_type: cleanup_type, deleted: count}}

        {:error, {:unknown_kind, _}} ->
          {:error, {:invalid_argument, "Unknown cleanup_type: #{cleanup_type}"}}

        {:error, reason} ->
          Logger.error("[Emissary.MCP.Tools.RecordsProvider] Cleanup failed: #{inspect(reason)}")
          {:error, "Cleanup failed"}
      end
    else
      # The only clause above is the tenant gate — pass its refusal term
      # through; the dispatcher renders the vocabulary at the wire.
      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle("retention", _ctx, %{"action" => "set"}) do
    {:error, {:invalid_argument, "Missing required parameter: settings (must be a JSON object)"}}
  end

  def handle("retention", _ctx, _args) do
    {:error, Cyfr.Ops.Provider.invalid_action("retention", action_enum("retention"))}
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
      parent_execution_id: Map.get(exec, :parent_execution_id)
    }
  end

  defp format_datetime(value), do: Cyfr.Time.iso8601(value)

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

  # A policy-audit field: corrupt JSON must read AS corruption, never
  # silently pass through as a string where a map was recorded.
  defp decode_json(str) when is_binary(str) do
    Cyfr.Json.decode_or(
      str,
      %{"_decode_error" => "stored snapshot was not valid JSON"},
      "Emissary.MCP.RecordsProvider"
    )
  end

  defp decode_json(val), do: val

  defp parse_since_opt(opts, nil), do: {:ok, opts}

  defp parse_since_opt(opts, since_str) do
    case DateTime.from_iso8601(since_str) do
      {:ok, dt, _} -> {:ok, Keyword.put(opts, :since, dt)}
      _ -> {:error, {:invalid_argument, "Invalid ISO8601 timestamp for 'since': #{since_str}"}}
    end
  end

  # The dispatcher enforces auth + permission from the action annotations;
  # what remains here is the residual it cannot express — these are
  # tenant-scoped stores, so an athanor-less context must be refused before it
  # can reach any athanor's rows (the storage backstop would raise,
  # this answers politely).
  # The wire description of one retention setting, from its unit — no
  # per-kind prose to keep in step with the roster.
  defp setting_description(kind) do
    case kind.unit() do
      :keep -> "Newest records kept per athanor"
      :days -> "Days of records kept per athanor"
    end
  end

  defp action_enum(tool) do
    [tool_def] = for t <- tools(), t.name == tool, do: t
    get_in(tool_def, [:input_schema, "properties", "action", "enum"])
  end
end
