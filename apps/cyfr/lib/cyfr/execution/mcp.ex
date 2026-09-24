# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.MCP do
  @moduledoc """
  MCP tool provider for executions.

  Provides a single `execution` tool with action-based dispatch:
  - `run` - Execute a Catalyst, Reagent, or Formula
  - `run_stream` - Start one in the background and answer its event stream
  - `list` - List execution instances
  - `logs` - Retrieve execution record and logs
  - `cancel` - Cancel a running execution
  - `status` - Execution slot diagnostics
  - `force_release` - Release every athanor's execution slots (operator only)
  - `read_resource` - Read an `opus://executions/…` resource

  Runs and cancels go through `Cyfr.Execution`; reads
  come from the execution records (`Cyfr.Execution.Record`). Its service
  name is `"opus"` and its resources are `opus://executions/…`.

  Implements the ToolProvider protocol (tools/0 and handle/3)
  which is validated at runtime by Grimoire.Catalog.

  ## Simplified Lifecycle

  Components must be registered before execution. The workflow is:

      Develop in components/ → Register via `cyfr register` → Execute by name
  """

  @behaviour Prima.Provider

  def service, do: "opus"

  require Logger

  alias Cyfr.Execution.Record
  alias Sanctum.Context

  @slots Cyfr.Execution.Slots

  # ============================================================================
  # Resources
  # ============================================================================

  def resources do
    []
  end

  @doc """
  Returns the execution resource templates (RFC 6570 URI templates). A
  read of either is the `execution.read_resource` operation, admitted by
  the gate under `:storage_read`.
  """
  def resource_templates do
    [
      %{
        uriTemplate: "opus://executions/{id}",
        name: "Execution State",
        description: "Get execution state by ID",
        mimeType: Prima.MediaType.json()
      },
      %{
        uriTemplate: "opus://executions/{id}/logs",
        name: "Execution Logs",
        description: "Get execution logs by ID",
        mimeType: "text/plain"
      }
    ]
  end

  # The gate admitted the read (authenticated, `:storage_read`, the
  # external plane); `Cyfr.Execution.Record.get/2` supplies the tenant
  # scoping under the caller's own context.
  defp read_resource(%Context{} = ctx, "opus://executions/" <> rest) do
    case parse_execution_uri(rest) do
      {:execution, exec_id} ->
        get_execution_resource(ctx, exec_id)

      {:execution_logs, exec_id} ->
        get_execution_logs_resource(ctx, exec_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_resource(_ctx, uri),
    do: {:error, {:invalid_argument, "Unknown resource URI: #{uri}"}}

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
         {:invalid_argument,
          "Invalid execution URI format. Expected: opus://executions/{id} or opus://executions/{id}/logs"}}
    end
  end

  # Get execution state as JSON resource
  defp get_execution_resource(ctx, exec_id) do
    case Record.get(ctx, exec_id) do
      {:ok, record} ->
        content = %{
          execution_id: record.id,
          request_id: record.request_id,
          status: Atom.to_string(record.status),
          reference: record.reference,
          component_type: Atom.to_string(record.component_type),
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
            {:ok, %{content: json, mimeType: Prima.MediaType.json()}}

          {:error, err} ->
            Logger.error(
              "[Cyfr.Execution.MCP] Failed to encode execution record: #{inspect(err)}"
            )

            {:error, "Failed to encode execution record"}
        end

      {:error, :not_found} ->
        {:error, {:not_found, "Execution", exec_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Get execution logs as text resource
  defp get_execution_logs_resource(ctx, exec_id) do
    case Record.get(ctx, exec_id) do
      {:ok, record} ->
        # Format execution record as logs.
        # In the future, this will also include component-emitted debug
        # output via the planned `cyfr:debug/log` WIT interface.
        logs = format_execution_logs(record)
        {:ok, %{content: logs, mimeType: "text/plain"}}

      {:error, :not_found} ->
        {:error, {:not_found, "Execution", exec_id}}

      {:error, reason} ->
        {:error, reason}
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
        case Record.get(ctx, execution_id) do
          {:ok, record} ->
            if in_caller_chain?(record, args),
              do: :ok,
              else: chain_scoped_refusal(execution_id)

          # A missing row reports as missing; the caller learns nothing
          # about executions outside its chain either way.
          {:error, :not_found} ->
            {:error, {:not_found, "Execution", execution_id}}
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
      "Component Type: #{record.component_type}",
      "Component Digest: #{record.component_digest || "unknown"}",
      "Started: #{Prima.Time.iso8601(record.started_at) || "N/A"}",
      "Completed: #{Prima.Time.iso8601(record.completed_at) || "N/A"}",
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

  # ============================================================================
  # ToolProvider Protocol (validated at runtime)
  # ============================================================================

  def tools do
    alias Prima.{Arg, Operation}
    # External-plane only, and `host: :intercepted`: a running
    # component's execution request never reaches the catalog — the
    # formula host intercepts it and runs it as a CHILD of the
    # chain's authority (`Cyfr.Execution.run_child/5`), and an approved
    # card's is run the same way by the assistant. The annotation
    # says so, and every surface that offers actions to a chain
    # reads it from here.
    # Slot diagnostics are tenant-operational: global counters
    # with no chain grain to scope them to. Classify it out of the
    # in-chain plane rather than serve a number that means nothing
    # to the caller.
    # Releasing every athanor's slots is the operator's lever
    # alone. Until the in-flight executions it released drain, the
    # node runs OVER-admitted by that many slots — the recovery
    # trades wedged slots for a temporary over-cap.
    # run action params
    # list action params
    # logs/cancel action params
    # verify block (optional signer validation)
    [
      Operation.tool(
        [
          Operation.new(
            "execution",
            "run",
            "Run execution",
            [
              Arg.new("reference", :string,
                required: true,
                description: "Component reference string (e.g., 'catalyst:local.claude:0.2.0')"
              ),
              Arg.new("input", {:map, Arg.new(nil, :json)},
                description: "Input data to pass to the component (run action)"
              ),
              Arg.new("type", :string,
                description:
                  "Asserted component type — must match the registry's type, which is authoritative (run action)",
                enum: Prima.ComponentRef.executable_types()
              ),
              Arg.new(
                "verify",
                {:record,
                 [
                   Arg.new("identity", :string,
                     description: "Required signer identity (e.g., 'alice@example.com')"
                   ),
                   Arg.new("issuer", :string,
                     description: "Required OIDC issuer (e.g., 'https://github.com/login/oauth')"
                   )
                 ]},
                description: "Optional signature verification requirements (run action)"
              ),
              Arg.new("profile", :string,
                description:
                  "The owner profile ID or label; omitted selects the default owner profile"
              )
            ],
            host: :intercepted,
            kind: :execute,
            planes: [:external],
            permission: :execute
          ),
          Operation.new(
            "execution",
            "run_stream",
            "Run stream execution",
            [
              Arg.new("reference", :string,
                required: true,
                description: "Component reference string (e.g., 'catalyst:local.claude:0.2.0')"
              ),
              Arg.new("input", {:map, Arg.new(nil, :json)},
                description: "Input data to pass to the component (run action)"
              ),
              Arg.new("type", :string,
                description:
                  "Asserted component type — must match the registry's type, which is authoritative (run action)",
                enum: Prima.ComponentRef.executable_types()
              ),
              Arg.new(
                "verify",
                {:record,
                 [
                   Arg.new("identity", :string,
                     description: "Required signer identity (e.g., 'alice@example.com')"
                   ),
                   Arg.new("issuer", :string,
                     description: "Required OIDC issuer (e.g., 'https://github.com/login/oauth')"
                   )
                 ]},
                description: "Optional signature verification requirements (run action)"
              ),
              Arg.new("profile", :string,
                description:
                  "The owner profile ID or label; omitted selects the default owner profile"
              )
            ],
            host: :intercepted,
            kind: :execute,
            planes: [:external],
            permission: :execute
          ),
          Operation.new(
            "execution",
            "list",
            "List execution",
            [
              Arg.new("limit", :integer,
                description: "Maximum results to return (list action)",
                default: 20
              ),
              Arg.new("status", :string,
                description: "Filter by status (list action)",
                enum: ["running", "completed", "failed", "cancelled", "all"],
                default: "all"
              )
            ],
            kind: :read,
            planes: [:external, :in_chain],
            permission: :execute
          ),
          Operation.new(
            "execution",
            "logs",
            "Logs execution",
            [
              Arg.new("execution_id", :string,
                required: true,
                description: "Execution ID (logs/cancel actions)"
              )
            ],
            kind: :read,
            planes: [:external, :in_chain],
            permission: :execute
          ),
          Operation.new(
            "execution",
            "cancel",
            "Cancel execution",
            [
              Arg.new("execution_id", :string,
                required: true,
                description: "Execution ID (logs/cancel actions)"
              )
            ],
            kind: :write,
            planes: [:external, :in_chain],
            permission: :execute
          ),
          Operation.new("execution", "status", "Status execution", [],
            kind: :read,
            planes: [:external],
            permission: :execute
          ),
          Operation.new("execution", "force_release", "Force release execution", [],
            scope: :platform,
            kind: :destructive,
            planes: [:external]
          ),
          # The admission of an MCP `resources/read` of an opus:// URI
          # (`resource_templates/0`).
          Operation.new(
            "execution",
            "read_resource",
            "Read an opus://executions/ resource",
            [
              Arg.new("uri", :string,
                required: true,
                description:
                  "opus://executions/{id} for an execution's state, or opus://executions/{id}/logs for its logs"
              )
            ],
            kind: :read,
            planes: [:external],
            permission: :storage_read,
            recovery: :replay_safe,
            resource_schemes: ["opus"]
          )
        ],
        description: "Execute WASM components and manage execution instances",
        title: "Execution"
      )
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

  # An agent is addressed in a thread (`thread.send`) and runs
  # under the turn that claims its root; it is never rooted from here,
  # whatever the caller's grants, so the harness and the console start a
  # turn one way.
  def handle("execution", %Context{} = ctx, %{"action" => action} = args)
      when action in ["run", "run_stream"] do
    reference = args["reference"] || ""

    if Compendium.AgentSource.agent_ref?(reference) do
      {:error,
       {:invalid_argument,
        "#{reference} is an agent: it is addressed in a thread (thread.send), never run"}}
    else
      start_root(action, ctx, args)
    end
  end

  # List action - list execution instances
  def handle("execution", %Context{} = ctx, %{"action" => "list"} = args) do
    limit = min(args["limit"] || 20, 1000)
    status_filter = parse_status_filter(args["status"])

    {:ok, records} = Record.list(ctx, limit: limit, status: status_filter)

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
    case Record.get(ctx, execution_id) do
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
             component_type: Atom.to_string(record.component_type),
             component_digest: record.component_digest,
             reference: record.reference,
             input: record.input,
             output: record.output,
             logs: logs
           }}
        end

      {:error, :not_found} ->
        {:error, {:not_found, "Execution", execution_id}}
    end
  end

  def handle("execution", _ctx, %{"action" => "logs"}) do
    {:error, {:invalid_argument, "Missing required argument: execution_id"}}
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
    with :ok <- check_chain_scope(ctx, execution_id, args) do
      case Cyfr.Execution.cancel(ctx, execution_id) do
        {:ok, result} ->
          {:ok, result}

        {:error, :not_found} ->
          {:error, {:not_found, "Execution", execution_id}}

        {:error, :not_cancellable} ->
          {:error, "Execution already completed, failed, or cancelled"}

        {:error, reason} ->
          Logger.error("[Cyfr.Execution.MCP] Failed to cancel execution: #{inspect(reason)}")
          {:error, "Failed to cancel execution"}
      end
    end
  end

  def handle("execution", _ctx, %{"action" => "cancel"}) do
    {:error, {:invalid_argument, "Missing required argument: execution_id"}}
  end

  # Status action - execution slot diagnostics
  def handle("execution", %Context{} = ctx, %{"action" => "status"}) do
    {:ok, scoped_slot_status(ctx, slot_status())}
  end

  # Force release action - emergency slot recovery. Releasing EVERY
  # athanor's slots is a server-wide side effect; the `scope: :platform`
  # annotation admits operators alone before this arm is reached.
  def handle("execution", %Context{} = ctx, %{"action" => "force_release"}) do
    Logger.warning("[Cyfr.Execution.MCP] Force release triggered by user=#{ctx.user_id}")

    :telemetry.execute(
      [:cyfr, :opus, :force_release],
      %{system_time: System.system_time()},
      %{user_id: ctx.user_id, auth_method: ctx.auth_method}
    )

    case Prima.Slots.force_release_all(@slots) do
      {:error, :unavailable} ->
        {:error, "Execution slots are not running — nothing was released"}

      {:ok, _released} ->
        {:ok, Map.put(scoped_slot_status(ctx, slot_status()), :force_released, true)}
    end
  end

  def handle("execution", %Context{} = ctx, %{"action" => "read_resource", "uri" => uri})
      when is_binary(uri),
      do: read_resource(ctx, uri)

  def handle("execution", _ctx, %{"action" => "read_resource"}) do
    {:error, {:invalid_argument, "Missing required argument: uri"}}
  end

  # Invalid action
  def handle("execution", _ctx, %{"action" => action}) do
    {:error, {:invalid_argument, "Invalid execution action: #{action}"}}
  end

  # Missing action
  def handle("execution", _ctx, _args) do
    {:error, {:invalid_argument, "Missing required argument: action"}}
  end

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end

  # Start the execution in the background and answer its id and stream URL;
  # the caller follows the SSE endpoint for intermediate events.
  defp start_root("run_stream", ctx, args) do
    reference = args["reference"] || ""
    input = args["input"] || %{}

    execution_id = Record.generate_id()

    opts = build_run_opts(args)
    opts = [{:execution_id, execution_id} | opts]
    # This execution IS the root — its emit target is itself
    opts = [{:root_execution_id, execution_id} | opts]

    # Spawn execution in background, registering PID for cancellation
    logger_metadata = Prima.LoggerContext.capture()

    case Task.Supervisor.start_child(Cyfr.Execution.TaskSupervisor, fn ->
           Prima.LoggerContext.restore(logger_metadata)

           case Registry.register(Cyfr.Execution.Registry, execution_id, :running) do
             {:ok, _} ->
               run_root_formatted(ctx, reference, input, opts, args)

             {:error, reason} ->
               Logger.error(
                 "[Cyfr.Execution.MCP] Failed to register execution #{execution_id}, aborting: #{inspect(reason)}"
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
        Logger.error(
          "[Cyfr.Execution.MCP] Failed to spawn execution #{execution_id}: #{inspect(reason)}"
        )

        {:error, "execution_spawn_failed"}
    end
  end

  # Run the component to completion as a root.
  defp start_root("run", ctx, args) do
    reference = args["reference"] || ""
    input = args["input"] || %{}

    # Build options for the root run
    opts = build_run_opts(args)

    case run_root_formatted(ctx, reference, input, opts, args) do
      {:ok, result} ->
        # Format response for MCP (convert atoms to strings for JSON)
        {:ok, format_run_result(result, reference)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Execution requires a profile; return a typed setup error when none is selected.
  defp run_root_formatted(ctx, reference, input, opts, args) do
    selector = profile_selector(args)

    case Cyfr.Execution.run_root(ctx, selector, reference, input, opts) do
      {:error, :no_profile} when selector == :default ->
        {:error,
         {:consent_required,
          %{
            "ref" => reference,
            "detail" => "no profile — grant it first (profile.plan, or cyfr profile grant)"
          }}}

      other ->
        format_root_result(other)
    end
  end

  # The one place a caller-supplied string becomes a selector. `"profile"`
  # takes an id or a label because a person naming their own grant should
  # not have to know which of the two they are holding;
  # `RootSelect.decode/1` owns the discrimination, and the label grammar
  # is what keeps it from being a guess.
  defp profile_selector(args), do: Prima.Authority.RootSelect.decode(args["profile"])

  # Keep consent signals typed for protocol codes, structured data and shared rendering.
  defp format_root_result({:error, {tag, payload}})
       when tag in [:setup_required, :consent_required, :consent_conflict, :restart_required] and
              is_map(payload) do
    {:error, {tag, payload}}
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

  # The chain wraps a ref-grammar refusal (`Prima.ComponentRef`'s crafted
  # prose) — client-safe by construction.
  defp format_root_result({:error, {:invalid_reference, reason}}) when is_binary(reason) do
    {:error, "invalid_reference: #{reason}"}
  end

  defp format_root_result({:error, reason}) when not is_binary(reason) do
    # Render typed refusals through the shared seam. Log internal terms
    # without returning them to the client.
    case Grimoire.Error.render(reason) do
      nil ->
        Logger.warning("[Cyfr.Execution.MCP] unrenderable authority error: #{inspect(reason)}")
        {:error, "authority_error: the request could not be authorized"}

      msg ->
        {:error, "authority_error: #{msg}"}
    end
  end

  defp format_root_result(other), do: other

  # The execution slots' status (`Prima.Slots.status/1`) in the operator's
  # vocabulary: its keys are athanors, so the per-key cap and counts are
  # presented as the per-tenant ones this tool has always shown.
  defp slot_status do
    {keys, status} = Map.pop!(Prima.Slots.status(@slots), :keys)
    {key_max, status} = Map.pop!(status, :key_max)
    Map.merge(status, %{tenant_max: key_max, tenants: keys})
  end

  # The status is global: every athanor currently executing, with live
  # counts and holder pids. The operator (and the server's own contexts)
  # keep the full diagnostic; a member gets the shared totals plus their
  # own athanor's count — other athanors' identifiers and activity levels
  # are not theirs to enumerate.
  defp scoped_slot_status(%Context{scope: :platform}, status), do: status
  defp scoped_slot_status(%Context{platform_admin: true}, status), do: status

  defp scoped_slot_status(%Context{} = ctx, status) do
    status
    |> Map.drop([:holders, :tenants])
    |> Map.put(:tenant_active, Map.get(status.tenants, ctx.athanor_id, 0))
  end

  # Build the root run's options from MCP args
  defp build_run_opts(args) do
    opts = []

    # Add component type if specified
    opts = if args["type"], do: [{:type, args["type"]} | opts], else: opts

    # Add verify block if specified
    opts = if args["verify"], do: [{:verify, args["verify"]} | opts], else: opts

    opts
  end

  # Format the root run's result for the MCP response
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
