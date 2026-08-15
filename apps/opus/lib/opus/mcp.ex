# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.MCP do
  @moduledoc """
  MCP tool provider for Opus execution engine.

  Provides a single `execution` tool with action-based dispatch:
  - `run` - Execute a Catalyst, Reagent, or Formula
  - `list` - List execution instances
  - `logs` - Retrieve execution record and logs
  - `cancel` - Cancel a running execution

  ## Architecture Note

  This module lives in the `opus` app, keeping tool definitions
  close to their implementation. WASM execution is implemented
  via Wasmex (Wasmtime backend).

  Implements the ToolProvider protocol (tools/0 and handle/3)
  which is validated at runtime by Emissary.MCP.ToolRegistry.

  ## Simplified Lifecycle

  Components must be registered before execution. The workflow is:

      Develop in components/ → Register via `cyfr register` → Execute by name
  """

  @behaviour Emissary.MCP.ToolProvider

  require Logger

  alias Sanctum.Context

  # ============================================================================
  # ResourceProvider Protocol
  # ============================================================================

  def resources do
    []
  end

  @doc """
  Returns Opus resource templates (RFC 6570 URI templates).
  """
  def resource_templates do
    [
      %{
        uriTemplate: "opus://executions/{id}",
        name: "Execution State",
        description: "Get execution state by ID",
        mimeType: "application/json"
      },
      %{
        uriTemplate: "opus://executions/{id}/logs",
        name: "Execution Logs",
        description: "Get execution logs by ID",
        mimeType: "text/plain"
      }
    ]
  end

  def read(%Context{} = ctx, "opus://executions/" <> rest) do
    case parse_execution_uri(rest) do
      {:execution, exec_id} ->
        get_execution_resource(ctx, exec_id)

      {:execution_logs, exec_id} ->
        get_execution_logs_resource(ctx, exec_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def read(_ctx, uri) do
    {:error, "Unknown resource URI: #{uri}"}
  end

  # Parse the URI path after "opus://executions/"
  # Supports: {id} -> execution state, {id}/logs -> execution logs
  defp parse_execution_uri(path) do
    case String.split(path, "/", parts: 2) do
      [exec_id, "logs"] when byte_size(exec_id) > 0 ->
        {:execution_logs, exec_id}

      [exec_id] when byte_size(exec_id) > 0 ->
        {:execution, exec_id}

      _ ->
        {:error,
         "Invalid execution URI format. Expected: opus://executions/{id} or opus://executions/{id}/logs"}
    end
  end

  # Get execution state as JSON resource
  defp get_execution_resource(ctx, exec_id) do
    case Opus.ExecutionRecord.get(ctx, exec_id) do
      {:ok, record} ->
        content = %{
          execution_id: record.id,
          request_id: record.request_id,
          status: Atom.to_string(record.status),
          reference: record.reference,
          component_type: Atom.to_string(record.component_type || :reagent),
          component_digest: record.component_digest,
          started_at: record.started_at && DateTime.to_iso8601(record.started_at),
          completed_at: record.completed_at && DateTime.to_iso8601(record.completed_at),
          duration_ms: record.duration_ms,
          error: record.error,
          input: record.input,
          output: record.output
        }

        case Jason.encode(content, pretty: true) do
          {:ok, json} ->
            {:ok, json}

          {:error, err} ->
            Logger.error("[Opus.MCP] Failed to encode execution record: #{inspect(err)}")
            {:error, "Failed to encode execution record"}
        end

      {:error, :not_found} ->
        {:error, "Execution not found: #{exec_id}"}
    end
  end

  # Get execution logs as text resource
  defp get_execution_logs_resource(ctx, exec_id) do
    case Opus.ExecutionRecord.get(ctx, exec_id) do
      {:ok, record} ->
        # Format execution record as logs.
        # In the future, this will also include component-emitted debug
        # output via the planned `cyfr:debug/log` WIT interface.
        logs = format_execution_logs(record)
        {:ok, logs}

      {:error, :not_found} ->
        {:error, "Execution not found: #{exec_id}"}
    end
  end

  # In-chain callers see only their own subtree. `root_execution_id`
  # arrives on args, but only ever host-injected: `call_in_chain` drops
  # the guest's copy before re-adding the lineage it was told. Absent
  # means an external-plane call, which keeps the tenant-wide view.
  #
  # A legacy row with no root stamped fails closed for in-chain callers —
  # unattributable lineage is not permission to reach across chains.
  defp in_caller_chain?(record, args) do
    case args["root_execution_id"] do
      root when is_binary(root) and root != "" ->
        record.id == root or Map.get(record, :root_execution_id) == root

      _ ->
        true
    end
  end

  defp check_chain_scope(ctx, execution_id, args) do
    case args["root_execution_id"] do
      root when is_binary(root) and root != "" ->
        case Opus.ExecutionRecord.get(ctx, execution_id) do
          {:ok, record} ->
            if in_caller_chain?(record, args),
              do: :ok,
              else: chain_scoped_refusal(execution_id)

          # A missing row reports as missing; the caller learns nothing
          # about executions outside its chain either way.
          {:error, :not_found} ->
            {:error, "Execution not found: #{execution_id}"}
        end

      _ ->
        :ok
    end
  end

  defp chain_scoped_refusal(execution_id) do
    {:error, "Execution not found in this chain: #{execution_id}"}
  end

  # Format execution record as human-readable logs
  defp format_execution_logs(record) do
    lines = [
      "=== Execution #{record.id} ===",
      "Status: #{record.status}",
      "Component Type: #{record.component_type || :reagent}",
      "Component Digest: #{record.component_digest || "unknown"}",
      "Started: #{format_datetime(record.started_at)}",
      "Completed: #{format_datetime(record.completed_at)}",
      "Duration: #{record.duration_ms || 0}ms",
      "",
      "Reference: #{inspect(record.reference)}",
      "",
      "Input:",
      inspect(record.input, pretty: true),
      ""
    ]

    lines =
      if record.status == :completed do
        lines ++
          [
            "Output:",
            inspect(record.output, pretty: true),
            ""
          ]
      else
        lines
      end

    lines =
      if record.error do
        lines ++
          [
            "Error:",
            record.error,
            ""
          ]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  defp format_datetime(nil), do: "N/A"
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # ============================================================================
  # ToolProvider Protocol (validated at runtime)
  # ============================================================================

  def tools do
    [
      %{
        name: "execution",
        title: "Execution",
        description: "Execute WASM components and manage execution instances",
        annotations: %{
          readOnlyHint: false,
          destructiveHint: true,
          actions: %{
            "run" => %{kind: :execute, planes: [:external, :in_chain]},
            "run_stream" => %{kind: :execute, planes: [:external, :in_chain]},
            "list" => %{kind: :read, planes: [:external, :in_chain]},
            "logs" => %{kind: :read, planes: [:external, :in_chain]},
            "cancel" => %{kind: :write, planes: [:external, :in_chain]},
            # Semaphore diagnostics are tenant-operational: global counters
            # with no chain grain to scope them to. Classify it out of the
            # in-chain plane rather than serve a number that means nothing
            # to the caller.
            "status" => %{kind: :read, planes: [:external]},
            "force_release" => %{kind: :destructive, planes: [:external]}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["run", "run_stream", "list", "logs", "cancel", "status", "force_release"],
              "description" => "Action to perform"
            },
            # run action params
            "reference" => %{
              "type" => "string",
              "description" => "Component reference string (e.g., 'catalyst:local.claude:0.2.0')"
            },
            "input" => %{
              "type" => "object",
              "description" => "Input data to pass to the component (run action)"
            },
            "type" => %{
              "type" => "string",
              "enum" => Sanctum.ComponentRef.executable_types(),
              "default" => "reagent",
              "description" =>
                "Asserted component type — must match the registry's type, " <>
                  "which is authoritative (run action)"
            },
            # list action params
            "status" => %{
              "type" => "string",
              "enum" => ["running", "completed", "failed", "cancelled", "all"],
              "default" => "all",
              "description" => "Filter by status (list action)"
            },
            "limit" => %{
              "type" => "integer",
              "default" => 20,
              "description" => "Maximum results to return (list action)"
            },
            # logs/cancel action params
            "execution_id" => %{
              "type" => "string",
              "description" => "Execution ID (logs/cancel actions)"
            },
            # verify block (optional signer validation)
            "verify" => %{
              "type" => "object",
              "description" => "Optional signature verification requirements (run action)",
              "properties" => %{
                "identity" => %{
                  "type" => "string",
                  "description" => "Required signer identity (e.g., 'alice@example.com')"
                },
                "issuer" => %{
                  "type" => "string",
                  "description" => "Required OIDC issuer (e.g., 'https://github.com/login/oauth')"
                }
              }
            }
          },
          "required" => ["action"]
        }
      }
    ]
  end

  # ============================================================================
  # Tool Handlers - Action-based dispatch
  # ============================================================================

  # A guest-planed context reaching run/run_stream would re-root a fresh
  # Authority from an in-chain call — the confused-deputy shape run_child
  # exists to prevent. Components invoke children through the formula host,
  # which intercepts these actions before dispatch; nothing legitimate arrives
  # here guest-planed. Fail closed regardless of the identity's permissions.
  def handle("execution", %Context{plane: :guest}, %{"action" => action})
      when action in ["run", "run_stream"] do
    {:error,
     "execution.#{action} cannot be invoked in-chain; a component runs children through the formula host, not by re-rooting"}
  end

  # Run stream action - start execution in background and return execution_id + stream URL
  # The caller can connect to the SSE endpoint to receive intermediate events.
  def handle("execution", %Context{} = ctx, %{"action" => "run_stream"} = args) do
    with :ok <- Context.require_permission_for_plane(ctx, :execute) do
      reference = args["reference"] || ""
      input = args["input"] || %{}

      execution_id = Opus.ExecutionRecord.generate_id()

      opts = build_run_opts(args)
      opts = [{:execution_id, execution_id} | opts]
      # This execution IS the root — its emit target is itself
      opts = [{:root_execution_id, execution_id} | opts]

      opts =
        case args["parent_execution_id"] do
          pid when is_binary(pid) and pid != "" -> [{:parent_execution_id, pid} | opts]
          _ -> opts
        end

      # Spawn execution in background, registering PID for cancellation
      case Task.Supervisor.start_child(Opus.TaskSupervisor, fn ->
             case Registry.register(Opus.ExecutionRegistry, execution_id, :running) do
               {:ok, _} ->
                 run_root_formatted(ctx, reference, input, opts, args)

               {:error, reason} ->
                 Logger.error(
                   "[Opus.MCP] Failed to register execution #{execution_id}, aborting: #{inspect(reason)}"
                 )
             end
           end) do
        {:ok, _pid} ->
          {:ok,
           %{
             execution_id: execution_id,
             stream_url: "/api/executions/#{execution_id}/events"
           }}

        {:error, reason} ->
          Logger.error("[Opus.MCP] Failed to spawn execution #{execution_id}: #{inspect(reason)}")
          {:error, "execution_spawn_failed"}
      end
    end
  end

  # Run action - execute a WASM component
  # Delegates to Opus.run/4 (via Opus.Executor) to avoid duplication
  # Accepts optional parent_execution_id for formula lineage tracking
  def handle("execution", %Context{} = ctx, %{"action" => "run"} = args) do
    with :ok <- Context.require_permission_for_plane(ctx, :execute) do
      reference = args["reference"] || ""
      input = args["input"] || %{}

      # Build options for Opus.run/4
      opts = build_run_opts(args)

      # Thread parent_execution_id for formula→component lineage
      opts =
        case args["parent_execution_id"] do
          pid when is_binary(pid) and pid != "" -> [{:parent_execution_id, pid} | opts]
          _ -> opts
        end

      # Thread root_execution_id so nested emits route to the root stream
      opts =
        case args["root_execution_id"] do
          rid when is_binary(rid) and rid != "" -> [{:root_execution_id, rid} | opts]
          _ -> opts
        end

      case run_root_formatted(ctx, reference, input, opts, args) do
        {:ok, result} ->
          # Format response for MCP (convert atoms to strings for JSON)
          {:ok, format_run_result(result, reference)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # List action - list execution instances
  def handle("execution", %Context{} = ctx, %{"action" => "list"} = args) do
    with :ok <- Context.require_permission_for_plane(ctx, :execute) do
      limit = min(args["limit"] || 20, 1000)
      status_filter = parse_status_filter(args["status"])

      {:ok, records} = Opus.ExecutionRecord.list(ctx, limit: limit, status: status_filter)

      # In-chain listings are subtree-scoped for the same reason cancel
      # and logs are: the caller has no business enumerating the tenant.
      records = Enum.filter(records, &in_caller_chain?(&1, args))

      executions =
        Enum.map(records, fn record ->
          %{
            execution_id: record.id,
            request_id: record.request_id,
            parent_execution_id: Map.get(record, :parent_execution_id),
            status: Atom.to_string(record.status),
            reference: record.reference,
            component_type: record.component_type && to_string(record.component_type),
            started_at: DateTime.to_iso8601(record.started_at),
            completed_at: record.completed_at && DateTime.to_iso8601(record.completed_at),
            duration_ms: record.duration_ms,
            error: record.error
          }
        end)

      {:ok, %{executions: executions, count: length(executions), user_id: ctx.user_id}}
    end
  end

  # Logs action — retrieve execution record and a text rendering of it.
  # Today the `logs` field is a synthesized prose dump of the record's
  # metadata. In the future, component-emitted debug output (via the
  # planned `cyfr:debug/log` WIT interface, scoped per component world)
  # will be appended to that field.
  def handle(
        "execution",
        %Context{} = ctx,
        %{"action" => "logs", "execution_id" => execution_id} = args
      ) do
    with :ok <- Context.require_permission_for_plane(ctx, :execute) do
      case Opus.ExecutionRecord.get(ctx, execution_id) do
        {:ok, record} ->
          if not in_caller_chain?(record, args) do
            chain_scoped_refusal(execution_id)
          else
            logs = format_execution_logs(record)

            {:ok,
             %{
               execution_id: record.id,
               request_id: record.request_id,
               user_id: record.user_id,
               status: Atom.to_string(record.status),
               started_at: DateTime.to_iso8601(record.started_at),
               completed_at: record.completed_at && DateTime.to_iso8601(record.completed_at),
               duration_ms: record.duration_ms,
               error: record.error,
               component_type: Atom.to_string(record.component_type || :reagent),
               component_digest: record.component_digest,
               reference: record.reference,
               input: record.input,
               output: record.output,
               logs: logs
             }}
          end

        {:error, :not_found} ->
          {:error, "Execution not found: #{execution_id}"}
      end
    end
  end

  def handle("execution", _ctx, %{"action" => "logs"}) do
    {:error, "Missing required argument: execution_id"}
  end

  # Cancel action - cancel a running execution (kills process + updates record)
  def handle(
        "execution",
        %Context{} = ctx,
        %{
          "action" => "cancel",
          "execution_id" => execution_id
        } = args
      ) do
    with :ok <- Context.require_permission_for_plane(ctx, :execute),
         :ok <- check_chain_scope(ctx, execution_id, args) do
      case Opus.Executor.cancel(ctx, execution_id) do
        {:ok, result} ->
          {:ok, result}

        {:error, :not_found} ->
          {:error, "Execution not found: #{execution_id}"}

        {:error, :not_cancellable} ->
          {:error, "Execution already completed, failed, or cancelled"}

        {:error, reason} ->
          Logger.error("[Opus.MCP] Failed to cancel execution: #{inspect(reason)}")
          {:error, "Failed to cancel execution"}
      end
    end
  end

  def handle("execution", _ctx, %{"action" => "cancel"}) do
    {:error, "Missing required argument: execution_id"}
  end

  # Status action - execution semaphore diagnostics
  def handle("execution", %Context{} = ctx, %{"action" => "status"}) do
    with :ok <- Context.require_permission_for_plane(ctx, :execute) do
      {:ok, scoped_semaphore_status(ctx, Opus.ExecutionSemaphore.status())}
    end
  end

  # Force release action - emergency semaphore recovery. Releasing EVERY
  # tenant's slots is a platform-wide side effect, so a tenant-scoped :admin
  # is not enough — only the operator (platform scope) may pull this lever.
  def handle("execution", %Context{scope: :platform} = ctx, %{"action" => "force_release"}) do
    with :ok <- Context.require_permission_for_plane(ctx, :admin) do
      Logger.warning("[Opus.MCP] Force release triggered by user=#{ctx.user_id}")

      :telemetry.execute(
        [:cyfr, :opus, :force_release],
        %{system_time: System.system_time()},
        %{user_id: ctx.user_id, auth_method: ctx.auth_method}
      )

      case Opus.ExecutionSemaphore.force_release_all() do
        {:error, :semaphore_unavailable} ->
          {:error, "Execution semaphore is not running — nothing was released"}

        _released ->
          status = scoped_semaphore_status(ctx, Opus.ExecutionSemaphore.status())
          {:ok, Map.put(status, :force_released, true)}
      end
    end
  end

  def handle("execution", %Context{}, %{"action" => "force_release"}) do
    {:error, "force_release is a platform-operator action (releases every tenant's slots)"}
  end

  # Invalid action
  def handle("execution", _ctx, %{"action" => action}) do
    {:error, "Invalid execution action: #{action}"}
  end

  # Missing action
  def handle("execution", _ctx, _args) do
    {:error, "Missing required argument: action"}
  end

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Every execution roots under a profile's consent — there is no other
  # path. No profile means nothing was granted: the §4.3 vocabulary names
  # the fix instead of running with the caller's ambient authority.
  defp run_root_formatted(ctx, reference, input, opts, args) do
    selector = profile_selector(args)

    case Opus.run_root(ctx, selector, reference, input, opts) do
      {:error, :no_profile} when is_nil(selector) ->
        {:error,
         "consent_required: " <>
           Jason.encode!(%{
             "ref" => reference,
             "detail" => "no profile — grant it first (profile.plan, or cyfr profile grant)"
           })}

      other ->
        format_root_result(other)
    end
  end

  defp profile_selector(args) do
    case args["profile"] do
      selector when is_binary(selector) and selector != "" -> selector
      _ -> nil
    end
  end

  # Authority errors are tuples; the MCP boundary speaks strings. The tag
  # prefix is stable and the payload rides as JSON for callers that parse.
  defp format_root_result({:error, {tag, payload}})
       when tag in [:setup_required, :consent_required, :consent_conflict, :restart_required] and
              is_map(payload) do
    {:error, "#{tag}: #{Jason.encode!(payload)}"}
  end

  defp format_root_result({:error, {:ambiguous, ids}}) do
    {:error, "profile_ambiguous: pass a 'profile' selector; candidates: #{Enum.join(ids, ", ")}"}
  end

  defp format_root_result({:error, {:not_found, selector}}) do
    {:error, "profile_not_found: #{selector}"}
  end

  defp format_root_result({:error, {:profile_unavailable, status}}) do
    {:error, "profile_unavailable: #{status}"}
  end

  defp format_root_result({:error, reason}) when not is_binary(reason) do
    {:error, "authority_error: #{inspect(reason)}"}
  end

  defp format_root_result(other), do: other

  # The semaphore map is global: every {org, project} currently executing,
  # with live counts and holder pids. Platform scope keeps the full
  # diagnostic; a tenant member gets the shared totals plus their own
  # tenant's count — other orgs' identifiers and activity levels are not
  # theirs to enumerate.
  defp scoped_semaphore_status(%Context{scope: :platform}, status), do: status

  defp scoped_semaphore_status(%Context{} = ctx, status) do
    status
    |> Map.drop([:holders, :tenants])
    |> Map.put(:tenant_active, Map.get(status.tenants, {ctx.org_id, ctx.project_id}, 0))
  end

  # Build options for Opus.run/4 from MCP args
  defp build_run_opts(args) do
    opts = []

    # Add component type if specified
    opts = if args["type"], do: [{:type, args["type"]} | opts], else: opts

    # Add verify block if specified
    opts = if args["verify"], do: [{:verify, args["verify"]} | opts], else: opts

    opts
  end

  # Format the result from Opus.run/4 for MCP response
  # Converts atoms to strings for JSON serialization
  defp format_run_result(result, reference) do
    meta = result.metadata

    %{
      status: to_string(result.status),
      execution_id: meta.execution_id,
      result: result.output,
      duration_ms: meta.duration_ms,
      component_type: to_string(meta.component_type),
      component_digest: meta.component_digest,
      user_id: meta.user_id,
      reference: reference,
      policy_applied: meta.policy_applied
    }
  end

  defp parse_status_filter(nil), do: :all
  defp parse_status_filter("all"), do: :all
  defp parse_status_filter("running"), do: :running
  defp parse_status_filter("completed"), do: :completed
  defp parse_status_filter("failed"), do: :failed
  defp parse_status_filter("cancelled"), do: :cancelled
  defp parse_status_filter(_), do: :all
end
