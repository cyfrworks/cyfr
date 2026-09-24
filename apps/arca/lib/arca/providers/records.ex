# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Providers.Records do
  @moduledoc """
  The record tools — `record`, `mcp_log` and `policy_log` — over what Arca
  persists about executions, MCP requests and policy consultations, the
  `retention` tool over what the athanor keeps of them, and the reader
  behind the `arca://files/{path}` resource.

  The provider declares `context_kind: :actor`: the gate authorizes every
  call with the caller's full context and hands these handlers the
  `Cyfr.Actor` it projects, and nothing else. What remains here is the
  residual the annotations cannot express: the stores are tenant-scoped,
  so an actor with no athanor is refused before any row is read (an actor
  of `:platform` scope reads across athanors and is not), and in-chain an
  execution reads its own payload alone, for the attempt the host stamped
  on its lineage and only while that attempt is its current one.

  ## The `retention` tool

  `get` reads the athanor's retention settings, `set` patches them
  (`storage_write`) and answers them as they now stand, and `cleanup`
  runs one kind's policy now (`admin`), `executions` when no
  `cleanup_type` is named (`Arca.Retention`). The settable keys and the
  cleanup vocabulary derive from the retention roster. Settings are an
  athanor's, so an actor with no athanor is refused whatever its scope.

  ## The files resource

  `read/3` answers an `arca://files/{path}` URI with the file's bytes. It
  is reached only after the gate admitted the declaring operation
  (`resource.read`) and projected the actor, and it is given the exact
  roots the admitted caller may read — computed from the admitted context,
  never from the caller's arguments. It intersects them with
  `Arca.Storage.tenant_roots/0`, refuses an actor with no athanor before
  touching a blob, validates the path and refuses a root outside the list.
  It makes no permission decision of its own: the gate made it.
  """

  @behaviour Cyfr.Ops.Provider

  require Logger

  import Arca.QueryHelpers, only: [maybe_put: 3]

  @impl true
  def service, do: "arca"

  @impl true
  def context_kind, do: :actor

  @impl true
  def tools do
    alias Cyfr.Ops.{Arg, Operation}
    # In-chain, an execution reads its own payload alone, for the
    # attempt the host stamped on its lineage.
    [
      Operation.tool(
        [
          Operation.new(
            "record",
            "get",
            "Get record",
            [Arg.new("id", :string, required: true, description: "Execution ID")],
            kind: :read,
            planes: [:external],
            permission: :storage_read
          ),
          Operation.new(
            "record",
            "list",
            "List record",
            [
              Arg.new("user_id", :string, description: "User who initiated execution"),
              Arg.new("status", :string,
                description: "Execution status: running, completed, failed, cancelled"
              ),
              Arg.new("limit", :integer,
                description: "Maximum number of records to return (default: 20)"
              ),
              Arg.new("parent_execution_id", :string,
                description: "Filter by the parent execution ID"
              )
            ],
            kind: :read,
            planes: [:external],
            permission: :storage_read
          ),
          Operation.new(
            "record",
            "payload",
            "Payload record",
            [
              Arg.new("id", :string, required: true, description: "Execution ID"),
              Arg.new("kind", :string,
                description: "payload only: which retained payload (default result)",
                enum: ["input", "result"]
              ),
              Arg.new("attempt", :string,
                description:
                  "payload only: the attempt whose payload to answer (default: the execution's current attempt)"
              )
            ],
            kind: :read,
            planes: [:external, :in_chain],
            permission: :storage_read
          )
        ],
        description: "Query execution records - get or list executions",
        title: "Execution Records"
      ),
      Operation.tool(
        [
          Operation.new(
            "mcp_log",
            "list",
            "List mcp log",
            [
              Arg.new("request_id", :string,
                description:
                  "The ingress request. Groups a whole chain: the call an ingress received and every tool a running component reached beneath it."
              ),
              Arg.new("tool", :string, description: "Tool name filter"),
              Arg.new("since", :string,
                description: "ISO8601 timestamp — return logs after this time"
              ),
              Arg.new("user_id", :string, description: "Filter by user ID"),
              Arg.new("status", :string, description: "Filter by status"),
              Arg.new("limit", :integer, description: "Max results (default: 20)")
            ],
            kind: :read,
            planes: [:external],
            permission: :storage_read
          ),
          Operation.new(
            "mcp_log",
            "get",
            "Get mcp log",
            [Arg.new("id", :string, required: true, description: "Request ID")],
            kind: :read,
            planes: [:external],
            permission: :storage_read
          ),
          Operation.new(
            "mcp_log",
            "correlate",
            "Correlate mcp log",
            [
              Arg.new("request_id", :string,
                required: true,
                description:
                  "The ingress request. Groups a whole chain: the call an ingress received and every tool a running component reached beneath it."
              )
            ],
            kind: :read,
            planes: [:external],
            permission: :storage_read
          ),
          Operation.new(
            "mcp_log",
            "fan_outs",
            "Fan outs mcp log",
            [
              Arg.new("request_ids", {:array, Arg.new(nil, :string)},
                required: true,
                description: "Batch of request IDs for fan_outs action"
              )
            ],
            kind: :read,
            planes: [:external],
            permission: :storage_read
          ),
          Operation.new(
            "mcp_log",
            "stats",
            "Stats mcp log",
            [
              Arg.new("since_hours", :integer,
                description: "Number of hours of request statistics (default: 1)"
              )
            ],
            kind: :read,
            planes: [:external],
            permission: :storage_read
          )
        ],
        description: "Query MCP request logs - list, get, correlate, fan_outs, or view stats",
        title: "MCP Request Logs"
      ),
      Operation.tool(
        [
          Operation.new(
            "policy_log",
            "list",
            "List policy log",
            [
              Arg.new("request_id", :string, description: "Filter by request ID"),
              Arg.new("execution_id", :string, description: "Filter by execution ID"),
              Arg.new("user_id", :string, description: "Filter by user ID"),
              Arg.new("event_type", :string, description: "Filter by event type"),
              Arg.new("limit", :integer, description: "Max results (default: 20)")
            ],
            kind: :read,
            planes: [:external],
            permission: :storage_read
          ),
          Operation.new(
            "policy_log",
            "get",
            "Get policy log",
            [Arg.new("id", :string, required: true, description: "Policy log ID")],
            kind: :read,
            planes: [:external],
            permission: :storage_read
          ),
          Operation.new(
            "policy_log",
            "correlate",
            "Correlate policy log",
            [Arg.new("request_id", :string, required: true, description: "Filter by request ID")],
            kind: :read,
            planes: [:external],
            permission: :storage_read
          )
        ],
        description: "Query policy consultation logs - list, get, or correlate logs",
        title: "Policy Logs"
      ),
      retention_tool()
    ]
  end

  # Both the settable keys and the cleanup vocabulary derive from the
  # roster, so a new kind is on this surface the moment it exists.
  defp retention_tool do
    alias Cyfr.Ops.{Arg, Operation}

    Operation.tool(
      [
        Operation.new("retention", "get", "Get retention", [],
          kind: :read,
          planes: [:external],
          permission: :storage_read
        ),
        Operation.new(
          "retention",
          "set",
          "Set retention",
          [
            Arg.new(
              "settings",
              {:record,
               Enum.map(Arca.Retention.kinds(), fn kind ->
                 Arg.new(kind.key(), :integer, description: setting_description(kind))
               end)},
              required: true,
              description: "Retention settings"
            )
          ],
          kind: :write,
          planes: [:external],
          permission: :storage_write
        ),
        Operation.new(
          "retention",
          "cleanup",
          "Cleanup retention",
          [
            Arg.new("cleanup_type", :string,
              enum: Enum.map(Arca.Retention.kinds(), & &1.key()),
              description: "Kind of records to clean up"
            ),
            Arg.new("dry_run", :boolean,
              description: "If true, show what would be deleted without actually deleting"
            )
          ],
          kind: :destructive,
          planes: [:external],
          permission: :admin
        )
      ],
      description: "Manage data retention policies - get settings, set settings, or run cleanup",
      title: "Retention"
    )
  end

  # The wire description of one retention setting, from its unit — no
  # per-kind prose to keep in step with the roster.
  defp setting_description(kind) do
    case kind.unit() do
      :keep -> "Newest records kept per athanor"
      :days -> "Days of records kept per athanor"
    end
  end

  # ============================================================================
  # Handlers
  # ============================================================================

  @impl true
  def handle("record", %Cyfr.Actor{} = actor, %{"action" => "get", "id" => id}) do
    with :ok <- tenant_ok(actor) do
      case Arca.Execution.get_tenant(actor, id) do
        nil ->
          {:error, {:not_found, "Execution", id}}

        # get_tenant is db-rescued and answers a tuple on an outage;
        # binding it as the row sends a 2-tuple into execution_to_map/1,
        # whose `is_struct or is_map` guard raises — so `get` answered
        # "the tool crashed" where `list` answers the storage refusal.
        {:error, :database_error} ->
          {:error, {:unavailable, "Storage"}}

        record ->
          # Members are interchangeable: get_tenant already scoped to the
          # athanor, so any member of the athanor may read the record.
          {:ok, execution_to_map(record)}
      end
    end
  end

  def handle("record", %Cyfr.Actor{}, %{"action" => "get"}) do
    {:error, {:invalid_argument, "Missing required argument: id"}}
  end

  # A retained payload: the bytes an execution was given or answered,
  # for a member of the athanor that ran it — or, in-chain, for the
  # execution itself: the host-stamped lineage must name it as the
  # caller and the stamped attempt must be its current one.
  def handle("record", %Cyfr.Actor{} = actor, %{"action" => "payload", "id" => id} = args) do
    kind = Map.get(args, "kind", "result")

    with :ok <- tenant_ok(actor),
         :ok <- storage_gate(actor),
         true <-
           kind in ["input", "result"] ||
             {:error, {:invalid_argument, "kind must be input or result"}},
         {:ok, attempt} <- payload_attempt(actor, id, args) do
      case Arca.ExecutionPayloads.get(actor, id, kind, attempt: attempt) do
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

  def handle("record", %Cyfr.Actor{}, %{"action" => "payload"}) do
    {:error, {:invalid_argument, "Missing required argument: id"}}
  end

  def handle("record", %Cyfr.Actor{} = actor, %{"action" => "list"} = args) do
    with :ok <- tenant_ok(actor) do
      opts =
        [
          limit: min(args["limit"] || 20, 1000),
          athanor_id: actor.athanor_id
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
        records -> {:ok, %{executions: Enum.map(records, &execution_to_map/1)}}
      end
    end
  end

  def handle("record", %Cyfr.Actor{}, _args) do
    {:error, Cyfr.Ops.Provider.invalid_action("record", action_enum("record"))}
  end

  # ============================================================================
  # MCP Log Tool
  # ============================================================================

  def handle("mcp_log", %Cyfr.Actor{} = actor, %{"action" => "get", "id" => id}) do
    with :ok <- tenant_ok(actor) do
      case Arca.McpLog.get_tenant(actor, id) do
        nil ->
          {:error, {:not_found, "MCP log", id}}

        # Same outage shape as the execution arm above.
        {:error, :database_error} ->
          {:error, {:unavailable, "Storage"}}

        record ->
          {:ok, mcp_log_to_map(record)}
      end
    end
  end

  def handle("mcp_log", %Cyfr.Actor{}, %{"action" => "get"}) do
    {:error, {:invalid_argument, "Missing required argument: id"}}
  end

  def handle("mcp_log", %Cyfr.Actor{} = actor, %{"action" => "list"} = args) do
    with :ok <- tenant_ok(actor) do
      opts =
        [
          limit: min(args["limit"] || 20, 1000),
          athanor_id: actor.athanor_id
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

  def handle("mcp_log", %Cyfr.Actor{} = actor, %{
        "action" => "correlate",
        "request_id" => request_id
      }) do
    with :ok <- tenant_ok(actor) do
      mcp_logs =
        case Arca.McpLog.list(request_id: request_id, limit: 100, athanor_id: actor.athanor_id) do
          {:ok, rows} -> Enum.map(rows, &mcp_log_to_map/1)
          {:error, _} -> []
        end

      # Correlation is a best-effort join of three sources: a storage
      # outage on one leaves that leg empty, the way the mcp_log leg above
      # already does, rather than raising on the error tuple.
      executions =
        case Arca.Execution.list_by_request(actor, request_id) do
          rows when is_list(rows) -> Enum.map(rows, &execution_to_map/1)
          {:error, _} -> []
        end

      policy_log_opts =
        [
          request_id: request_id,
          limit: 100,
          athanor_id: actor.athanor_id
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

  def handle("mcp_log", %Cyfr.Actor{}, %{"action" => "correlate"}) do
    {:error, {:invalid_argument, "Missing required argument: request_id"}}
  end

  # Batched fan-out counts: for each request_id, how many executions were
  # recorded against it? Used by ActivitiesLive to render the EXECS column
  # for a page of MCP log rows in a single GROUP BY instead of N correlate
  # queries.
  def handle("mcp_log", %Cyfr.Actor{} = actor, %{"action" => "fan_outs", "request_ids" => ids})
      when is_list(ids) do
    with :ok <- tenant_ok(actor) do
      ids = Enum.filter(ids, &is_binary/1)

      # `count_by_request/2` refuses rather than defaulting, so an outage
      # answers `{:error, :database_error}` — which was being wrapped and
      # shipped as `counts: ["error", "database_error"]`, a structured
      # falsehood a client would render as a fan-out count. Same refusal
      # the other arms give.
      case Arca.Execution.count_by_request(actor, ids) do
        counts when is_map(counts) -> {:ok, %{counts: counts}}
        {:error, :database_error} -> {:error, {:unavailable, "Storage"}}
      end
    end
  end

  def handle("mcp_log", %Cyfr.Actor{}, %{"action" => "fan_outs"}) do
    {:error,
     {:invalid_argument, "Missing or invalid argument: request_ids (must be a list of strings)"}}
  end

  def handle("mcp_log", %Cyfr.Actor{} = actor, %{"action" => "stats"} = args) do
    with :ok <- tenant_ok(actor) do
      since_hours = args["since_hours"] || 1

      since = DateTime.utc_now() |> DateTime.add(-since_hours * 3600, :second)

      opts = [since: since, athanor_id: actor.athanor_id]

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

  def handle("mcp_log", %Cyfr.Actor{}, _args) do
    {:error, Cyfr.Ops.Provider.invalid_action("mcp_log", action_enum("mcp_log"))}
  end

  # ============================================================================
  # Policy Log Tool
  # ============================================================================

  def handle("policy_log", %Cyfr.Actor{} = actor, %{"action" => "get", "id" => id}) do
    with :ok <- tenant_ok(actor) do
      record =
        Arca.PolicyLog.get_tenant(actor, id) ||
          Arca.PolicyLog.get_by_request_id_tenant(actor, id)

      case record do
        nil ->
          {:error, {:not_found, "Policy log", id}}

        record ->
          {:ok, policy_log_to_map(record)}
      end
    end
  end

  def handle("policy_log", %Cyfr.Actor{}, %{"action" => "get"}) do
    {:error, {:invalid_argument, "Missing required argument: id"}}
  end

  def handle("policy_log", %Cyfr.Actor{} = actor, %{"action" => "list"} = args) do
    with :ok <- tenant_ok(actor) do
      opts =
        [
          limit: min(args["limit"] || 20, 1000),
          athanor_id: actor.athanor_id
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

  def handle("policy_log", %Cyfr.Actor{} = actor, %{
        "action" => "correlate",
        "request_id" => request_id
      }) do
    with :ok <- tenant_ok(actor) do
      opts =
        [
          request_id: request_id,
          limit: 100,
          athanor_id: actor.athanor_id
        ]

      policy_logs =
        case Arca.PolicyLog.list(opts) do
          {:ok, rows} -> Enum.map(rows, &policy_log_to_map/1)
          {:error, _} -> []
        end

      {:ok, %{request_id: request_id, policy_logs: policy_logs}}
    end
  end

  def handle("policy_log", %Cyfr.Actor{}, %{"action" => "correlate"}) do
    {:error, {:invalid_argument, "Missing required argument: request_id"}}
  end

  def handle("policy_log", %Cyfr.Actor{}, _args) do
    {:error, Cyfr.Ops.Provider.invalid_action("policy_log", action_enum("policy_log"))}
  end

  # ============================================================================
  # Retention Tool
  # ============================================================================

  def handle("retention", %Cyfr.Actor{} = actor, %{"action" => "get"}) do
    with :ok <- athanor_ok(actor) do
      case Arca.Retention.get_settings(actor) do
        {:ok, settings} -> {:ok, %{action: "get", settings: settings}}
        {:error, reason} -> {:error, settings_refusal(reason)}
      end
    end
  end

  def handle("retention", %Cyfr.Actor{} = actor, %{"action" => "set", "settings" => settings})
      when is_map(settings) do
    with :ok <- athanor_ok(actor) do
      case Arca.Retention.set_settings(actor, settings) do
        {:ok, merged} ->
          {:ok, %{action: "set", updated: true, settings: merged}}

        {:error, {:unknown_setting, key}} ->
          {:error, {:invalid_argument, "Unknown retention setting: #{key}"}}

        {:error, {:invalid_setting, key}} ->
          {:error,
           {:invalid_argument,
            "Invalid value for retention setting #{key} — use a positive integer"}}

        {:error, reason} ->
          {:error, settings_refusal(reason)}
      end
    end
  end

  def handle("retention", %Cyfr.Actor{}, %{"action" => "set"}) do
    {:error, {:invalid_argument, "Missing required parameter: settings (must be a JSON object)"}}
  end

  def handle("retention", %Cyfr.Actor{} = actor, %{"action" => "cleanup"} = args) do
    with :ok <- athanor_ok(actor) do
      cleanup_type = Map.get(args, "cleanup_type", "executions")
      dry_run = Map.get(args, "dry_run", false)

      case Arca.Retention.cleanup(actor, cleanup_type, dry_run: dry_run) do
        {:ok, count} when dry_run ->
          {:ok,
           %{action: "cleanup", cleanup_type: cleanup_type, dry_run: true, would_delete: count}}

        {:ok, count} ->
          {:ok, %{action: "cleanup", cleanup_type: cleanup_type, deleted: count}}

        {:error, {:unknown_kind, _}} ->
          {:error, {:invalid_argument, "Unknown cleanup_type: #{cleanup_type}"}}

        {:error, :corrupt} ->
          {:error, {:corrupt, "Retention settings"}}

        {:error, reason} ->
          Logger.error("[Arca.Providers.Records] Retention cleanup failed: #{inspect(reason)}")
          {:error, {:unavailable, "Retention cleanup"}}
      end
    end
  end

  def handle("retention", %Cyfr.Actor{}, _args) do
    {:error, Cyfr.Ops.Provider.invalid_action("retention", action_enum("retention"))}
  end

  def handle(tool, %Cyfr.Actor{}, _args), do: {:error, {:not_found, "tool", tool}}

  # A settings refusal as the wire renders it.
  defp settings_refusal(:corrupt), do: {:corrupt, "Retention settings"}
  defp settings_refusal(:no_athanor), do: :missing_tenant

  defp settings_refusal(reason) do
    Logger.error("[Arca.Providers.Records] Retention settings unavailable: #{inspect(reason)}")
    {:unavailable, "Retention settings"}
  end

  # ============================================================================
  # The files resource
  # ============================================================================

  @doc """
  Read an `arca://files/{path}` resource as `%{content: base64, mimeType:}`
  for `actor`, within `allowed_roots` — the roots the admitted caller may
  read, intersected here with `Arca.Storage.tenant_roots/0`.

  An actor with no athanor refuses as `:missing_tenant` before any blob is
  touched; a path that is empty, unsafe or outside the roots refuses as a
  typed argument error; a URI naming anything but `arca://files/` is an
  unknown resource.
  """
  @spec read(Cyfr.Actor.t(), String.t(), [String.t()]) ::
          {:ok, %{content: String.t(), mimeType: String.t()}} | {:error, term()}
  def read(%Cyfr.Actor{} = actor, uri, allowed_roots)
      when is_binary(uri) and is_list(allowed_roots) do
    roots = Enum.filter(allowed_roots, &(&1 in Arca.Storage.tenant_roots()))

    with :ok <- storage_gate(actor),
         {:ok, path} <- files_path(uri),
         segments = String.split(path, "/", trim: true),
         :ok <- validate_segments(segments),
         :ok <- within(roots, segments) do
      case Arca.get(actor, segments) do
        {:ok, content} ->
          {:ok, %{content: Base.encode64(content), mimeType: Cyfr.MediaType.binary()}}

        {:error, :not_found} ->
          {:error, {:not_found, "File", path}}

        {:error, :forbidden} ->
          {:error, {:invalid_argument, "Forbidden path: #{path}"}}

        {:error, reason} ->
          Logger.error("[Arca.Providers.Records] Failed to read: #{inspect(reason)}")
          {:error, {:unavailable, "Storage"}}
      end
    end
  end

  defp files_path("arca://files/" <> path), do: {:ok, path}

  defp files_path(uri),
    do: {:error, {:invalid_argument, "Unknown resource URI: #{uri}"}}

  defp within(_roots, []), do: {:error, {:invalid_argument, "Forbidden path: /"}}

  defp within(roots, [root | _]) do
    if root in roots,
      do: :ok,
      else: {:error, {:invalid_argument, "Forbidden path: #{root}"}}
  end

  defp validate_segments(segments) do
    case Cyfr.PathSafety.validate_segments(segments) do
      :ok -> :ok
      {:error, {_reason, message}} -> {:error, {:invalid_argument, "Invalid path: #{message}"}}
    end
  end

  # ============================================================================
  # Tenancy
  # ============================================================================

  # The stores below are tenant-scoped: an actor with no athanor is refused
  # before it can reach any athanor's rows. A `:platform` scope actor reads
  # across athanors and needs none.
  defp tenant_ok(%Cyfr.Actor{scope: :platform}), do: :ok
  defp tenant_ok(%Cyfr.Actor{athanor_id: id}) when is_binary(id) and id != "", do: :ok
  defp tenant_ok(%Cyfr.Actor{}), do: {:error, :missing_tenant}

  # Retention settings belong to one athanor, so every actor without one —
  # a `:platform` scope actor included — is refused before they are read.
  defp athanor_ok(%Cyfr.Actor{athanor_id: id}) when is_binary(id) and id != "", do: :ok
  defp athanor_ok(%Cyfr.Actor{}), do: {:error, :missing_tenant}

  # Blob reads are tenant-relative, so even a platform actor must carry the
  # athanor whose bytes it reads.
  defp storage_gate(actor) do
    if Arca.Storage.athanor_ready?(actor),
      do: :ok,
      else: {:error, :missing_tenant}
  end

  defp payload_attempt(%Cyfr.Actor{plane: :guest} = actor, id, args) do
    attempt = args["attempt"]

    cond do
      args["parent_execution_id"] != id ->
        {:error,
         {:invalid_argument,
          "in-chain, record.payload answers the calling execution's own payload"}}

      not is_binary(attempt) ->
        {:error, {:invalid_argument, "in-chain, record.payload needs the caller's attempt"}}

      true ->
        case Arca.Execution.get_tenant(actor, id) do
          %{current_attempt: ^attempt} ->
            {:ok, attempt}

          %{} ->
            {:error, {:invalid_argument, "the attempt is no longer the execution's current one"}}

          nil ->
            {:error, {:not_found, "Execution", id}}

          {:error, _} ->
            {:error, {:unavailable, "Storage"}}
        end
    end
  end

  defp payload_attempt(_actor, _id, args) do
    case args["attempt"] do
      attempt when is_binary(attempt) and attempt != "" -> {:ok, attempt}
      nil -> {:ok, nil}
      _ -> {:error, {:invalid_argument, "attempt must be a string"}}
    end
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
      input: decode_json(Map.get(exec, :input), "input"),
      output: decode_json(Map.get(exec, :output), "output"),
      host_policy: decode_json(Map.get(exec, :host_policy), "host_policy"),
      parent_execution_id: Map.get(exec, :parent_execution_id)
    }
  end

  defp format_datetime(value), do: Cyfr.Time.iso8601(value)

  defp mcp_log_to_map(%{id: _} = log) do
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
      input: decode_json(log.input, "input"),
      output: decode_json(log.output, "output"),
      error: log.error
    }
  end

  defp policy_log_to_map(%{id: _} = log) do
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
      host_policy_snapshot: decode_json(log.host_policy_snapshot, "host_policy_snapshot"),
      decision_reason: log.decision_reason
    }
  end

  defp decode_json(nil, _field), do: nil

  # An audit field: corrupt JSON must read AS corruption, never silently
  # pass through as a string where a map was recorded.
  defp decode_json(str, field) when is_binary(str),
    do: decode_stored(str, %{"_decode_error" => "stored snapshot was not valid JSON"}, field)

  defp decode_json(val, _field), do: val

  # A stored JSON column that does not decode reads as its default. The
  # line names the column and its size, never its bytes. `decode_json/2`
  # answers nil itself.
  defp decode_stored("", default, _field), do: default

  defp decode_stored(json, default, field) when is_binary(json) do
    case Cyfr.Json.decode(json) do
      {:ok, value} ->
        value

      {:error, :invalid_json} ->
        Logger.warning(
          "[Arca.Providers.Records] stored #{field} is not valid JSON (#{byte_size(json)} bytes)"
        )

        default
    end
  end

  defp parse_since_opt(opts, nil), do: {:ok, opts}

  defp parse_since_opt(opts, since_str) do
    case DateTime.from_iso8601(since_str) do
      {:ok, dt, _} -> {:ok, Keyword.put(opts, :since, dt)}
      _ -> {:error, {:invalid_argument, "Invalid ISO8601 timestamp for 'since': #{since_str}"}}
    end
  end

  defp action_enum(tool) do
    [tool_def] = for t <- tools(), t.name == tool, do: t
    get_in(tool_def, [:input_schema, "properties", "action", "enum"])
  end
end
