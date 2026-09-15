# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.FormulaHandler do
  @moduledoc """
  Host function handler for Formula component composition.

  Provides the `cyfr:formula/invoke@0.1.0` WASI host function import that
  enables Formula components to call MCP tools and invoke sub-components
  from within WASM execution.

  ## Unified MCP Dispatch

  All formula capabilities go through `Cyfr.Ops.Catalog`. Component
  execution, registry search, build, aqua — everything is an MCP tool call.
  Tool access is decided by the authority's transition relation over the
  consent edge's granted tools.

  ## Concurrency Model — Unbundled Promise Pattern

  WASM is single-threaded. Parallelism lives on the Elixir/BEAM host side
  via `Opus.AsyncTracker`, a per-formula GenServer backed by `Task.Supervisor`.

  Host functions exposed to WASM:

  | Function | Behavior |
  |----------|----------|
  | `call` | Synchronous — blocks until MCP tool returns |
  | `spawn` | Async — launches task, returns task_id immediately |
  | `await` | Blocks until specific task completes |
  | `await-all` | Blocks until ALL tasks complete |
  | `await-any` | Blocks until FIRST task completes |
  | `poll` | Non-blocking status check |
  | `cancel` | Cancel a spawned task |
  | `emit` | Push a progress/UI event through the formula's attempt, a `push_deltas` host call (`Opus.Runtime.emit/2`) |

  ## Architecture

  When a Formula starts executing, the handler spawns:

      Formula Execution
      ├── Task.Supervisor    (owns all spawned sub-tasks)
      └── AsyncTracker       (GenServer — manages task state)

  On completion or timeout, stopping the tracker kills the Task.Supervisor,
  which kills all orphaned tasks. Zero resource leaks.

  ## Request Format (JSON string from WASM)

      {
        "tool": "execution",
        "action": "run",
        "args": {"reference": "...", "input": {...}, "type": "catalyst"}
      }

  ## Response Format (JSON string returned to WASM)

  On success:
      {"status": "completed", "output": {...}}

  On error:
      {"error": {"type": "...", "message": "..."}}

  ## Usage

      {imports, tracker_pid} = Opus.FormulaHandler.build_formula_imports(ctx, parent_execution_id,
        host: host, root_execution_id: root_execution_id, limits: limits, authority: authority)
      # Merge imports and pass to Wasmex.Components.start_link
      # After execution: Opus.FormulaHandler.cleanup_registry(tracker_pid)
  """

  require Logger

  alias Sanctum.Context
  alias Cyfr.Limits

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Build Wasmex import map for the `cyfr:formula/invoke@0.1.0` host function.

  Returns a `{imports_map, tracker_pid}` tuple. The imports map contains the
  `"cyfr:formula/invoke@0.1.0"` namespace with all eight invoke functions.

  ## Parameters

  - `ctx` - The execution `Sanctum.Context` (shared with sub-executions)
  - `parent_execution_id` - The formula's own execution ID for lineage
    tracking

  ## Options

  - `:host` - The attached `Opus.HostClient` of the formula's attempt:
    `emit` is its `push_deltas` host call, on the stream the attempt was
    opened on. Without one, `emit` answers a `dispatch_error`.
  - `:root_execution_id` - The top-level execution ID: the root of the lineage the formula's calls carry, and the stream a setup refusal is announced on (falls back to `parent_execution_id`)
  - `:limits` - The node's `Cyfr.Limits` (batch timeout, max concurrent tasks)
  - `:authority` - The `Cyfr.Authority` the chain runs under (required).
    Execution dispatch goes through `Opus.Chain` and every other tool through
    `Cyfr.Ops.Catalog.call_in_chain/5`. A formula run always carries one —
    admission raises before reaching here (`Cyfr.Execution.Admission.admit/4`),
    and this fetch keeps a direct caller honest too.
  - `:declared_needs` / `:activation_digest` - host-derived transition inputs
    for this node's onward invocations
  - `:attempt` - the attempt that owns this formula's row, stamped on the
    lineage of every call it makes
  """
  @spec build_formula_imports(Context.t(), String.t(), keyword()) :: {map(), pid()}
  def build_formula_imports(%Context{} = ctx, parent_execution_id, opts \\ []) do
    authority = Keyword.fetch!(opts, :authority)
    host = Keyword.get(opts, :host)
    root_execution_id = opts[:root_execution_id] || parent_execution_id
    limits = opts[:limits]

    batch_timeout_ms =
      case limits && Limits.batch_timeout_ms(limits) do
        {:ok, ms} -> ms
        _ -> 300_000
      end

    max_tasks = if limits, do: limits.max_concurrent_tasks, else: 10

    tracker =
      case Opus.AsyncTracker.start_link(
             parent_execution_id: parent_execution_id,
             max_tasks: max_tasks,
             batch_timeout_ms: batch_timeout_ms
           ) do
        {:ok, pid} ->
          pid

        {:error, reason} ->
          # The executor's boundary rescues this into a failed execution; a
          # bare MatchError here read as a host bug rather than the capacity
          # condition it is.
          raise "async tracker could not start: #{inspect(reason)}"
      end

    authority_opts = [
      authority: authority,
      declared_needs: opts[:declared_needs],
      activation_digest: opts[:activation_digest]
    ]

    exec_opts =
      [
        parent_execution_id: parent_execution_id,
        root_execution_id: root_execution_id,
        attempt: opts[:attempt],
        limits: limits,
        parent_reference: opts[:parent_reference],
        parent_roster: opts[:parent_roster] || []
      ] ++ authority_opts

    spawn_opts =
      [
        parent_execution_id: parent_execution_id,
        root_execution_id: root_execution_id,
        attempt: opts[:attempt],
        limits: limits
      ] ++ authority_opts

    imports = %{
      "cyfr:formula/invoke@0.1.0" => %{
        "call" =>
          {:fn,
           fn json_request ->
             guarded(parent_execution_id, "call", fn ->
               execute(json_request, ctx, exec_opts)
             end)
           end},
        "spawn" =>
          {:fn,
           fn json_request ->
             guarded(parent_execution_id, "spawn", fn ->
               handle_spawn(json_request, ctx, tracker, spawn_opts)
             end)
           end},
        "await" =>
          {:fn,
           fn task_id ->
             guarded(parent_execution_id, "await", fn ->
               handle_await(task_id, tracker, batch_timeout_ms)
             end)
           end},
        "await-all" =>
          {:fn,
           fn json_request ->
             guarded(parent_execution_id, "await-all", fn ->
               handle_await_all(
                 json_request,
                 tracker,
                 batch_timeout_ms,
                 parent_execution_id,
                 max_tasks,
                 limits
               )
             end)
           end},
        "await-any" =>
          {:fn,
           fn json_request ->
             guarded(parent_execution_id, "await-any", fn ->
               handle_await_any(
                 json_request,
                 tracker,
                 batch_timeout_ms,
                 parent_execution_id,
                 max_tasks,
                 limits
               )
             end)
           end},
        "poll" =>
          {:fn,
           fn task_id ->
             guarded(parent_execution_id, "poll", fn ->
               handle_poll(task_id, tracker)
             end)
           end},
        "cancel" =>
          {:fn,
           fn task_id ->
             guarded(parent_execution_id, "cancel", fn ->
               handle_cancel(task_id, tracker, parent_execution_id)
             end)
           end},
        "emit" =>
          {:fn,
           fn json_event ->
             guarded(parent_execution_id, "emit", fn ->
               if host,
                 do: Opus.Runtime.emit(host, json_event),
                 else: encode_error(:dispatch_error, "The emit call failed.")
             end)
           end}
      }
    }

    {imports, tracker}
  end

  # Catch host-function raises and exits, including tracker call failures.
  # Return a generic typed error to the guest and log fault details on the host.
  defp guarded(parent_execution_id, name, fun) do
    fun.()
  rescue
    exception ->
      Logger.error(
        "[FormulaHandler] #{parent_execution_id} #{name} raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      encode_error(:dispatch_error, "The #{name} call failed.")
  catch
    :exit, reason ->
      Logger.error("[FormulaHandler] #{parent_execution_id} #{name} exited: #{inspect(reason)}")

      encode_error(:dispatch_error, "The #{name} call failed.")
  end

  @doc """
  Clean up async tracker for a formula execution.

  Stops the tracker GenServer, which stops the Task.Supervisor,
  killing all orphaned tasks.
  """
  # How long a graceful tracker stop may take before escalating. The
  # tracker blocks inside its own handle_call for the whole await window
  # (`Task.yield_many` up to the consented batch timeout, ceiling 30 min),
  # and `GenServer.stop/2`'s default `:infinity` parked the CALLER behind
  # it — on the cancel path, the exact moment the tracker is most likely
  # to be mid-await.
  @cleanup_stop_timeout_ms 5_000

  @spec cleanup_registry(pid()) :: :ok
  def cleanup_registry(tracker_pid) when is_pid(tracker_pid) do
    GenServer.stop(tracker_pid, :normal, @cleanup_stop_timeout_ms)
    :ok
  rescue
    e in [ArgumentError, RuntimeError] ->
      Logger.warning("[FormulaHandler] cleanup_registry failed: #{inspect(e)}")
      :ok
  catch
    # `GenServer.stop/2` EXITS for a dead pid (`:noproc`) — it does not raise,
    # so the rescue above never saw the commonest case. Every caller gets here
    # after a check-then-act window, and the cancel path has just killed the
    # process this tracker is linked to, so the tracker is routinely gone
    # already. Letting that exit through unwound the caller mid-teardown:
    # cancel skipped its terminal event, its telemetry and its child cascade
    # (leaving SSE subscribers with no final frame and children `running`),
    # the timeout path skipped writing the failed record, and a successful
    # formula run turned into an error from its own `after`. The tracker being
    # gone is the outcome this function wanted; it is not a failure.
    :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] ->
      :ok

    :exit, :noproc ->
      :ok

    :exit, {:timeout, _} ->
      # Still blocked in an await after the grace: a graceful stop cannot
      # land, so kill it — the link tears down its Task.Supervisor and the
      # spawned children with it, which is what stopping was for.
      Process.exit(tracker_pid, :kill)
      :ok

    :exit, reason ->
      Logger.warning("[FormulaHandler] cleanup_registry exited: #{inspect(reason)}")
      :ok
  end

  def cleanup_registry(_), do: :ok

  @doc """
  Execute an MCP tool call from a formula (synchronous).

  Parses the JSON request, dispatches through the in-chain chokepoint (or
  `Opus.Chain` for execution verbs), and returns a JSON response string.

  When a sub-component call fails due to a setup issue (missing consent,
  missing vault entry), the error is enriched with a `remediation` field
  and a `setup_required` event is pushed on the root's event stream.

  ## Options

  - `:parent_execution_id` (required) - The formula's own execution ID for lineage tracking
  - `:root_execution_id` - The top-level execution ID for routing emit events (falls back to `parent_execution_id`)
  """
  @spec execute(String.t(), Context.t(), keyword()) :: String.t()
  def execute(json_request, %Context{} = ctx, opts \\ []) do
    case authority_execution_request(json_request, opts) do
      {:intercept, action, args} -> dispatch_child_call(action, args, ctx, opts)
      :registry -> dispatch_via_registry(json_request, ctx, opts)
    end
  end

  # Execution dispatch never rides the tool registry: the invocation is
  # decided by the transition relation and executed by Opus.Chain with
  # host-threaded lineage. Which actions that is, the catalog says — the
  # ones annotated `host: :intercepted` — so the host and the annotation
  # cannot drift apart. Everything else — including a parse failure —
  # goes to the in-chain registry chokepoint.
  defp authority_execution_request(json_request, opts) do
    with authority when not is_nil(authority) <- opts[:authority],
         {:ok, %{tool: "execution", action: action, args: args}} <-
           parse_mcp_request(json_request, opts[:limits]),
         true <- Opus.Host.host_intercepted?("execution", action) do
      {:intercept, action, args}
    else
      _ -> :registry
    end
  end

  @doc false
  # The host's arm for an action the catalog annotates `host: :intercepted`.
  # An intercepted action the host has no arm for is a typed refusal, never
  # a crash; a test pins that every intercepted action has one.
  @spec child_runner(String.t()) :: {:ok, function()} | :error
  def child_runner("run"), do: {:ok, &Opus.Chain.run_child/5}
  def child_runner("run_stream"), do: {:ok, &Opus.Chain.run_child_stream/5}
  def child_runner(_action), do: :error

  defp dispatch_child_call(action, args, ctx, opts) do
    authority = Keyword.fetch!(opts, :authority)
    parent_execution_id = Keyword.fetch!(opts, :parent_execution_id)
    start_time = System.monotonic_time(:millisecond)

    with reference when is_binary(reference) and reference != "" <- Map.get(args, "reference"),
         {:ok, input} <- delegated_input(reference, Map.get(args, "input") || %{}, opts) do
      # Guest-supplied lineage keys never survive: the child's parent and
      # root ids come from this closure, and the input is only what the
      # request's own "input" carried — or, for a delegate of the same
      # formula, what the parent's roster holds for it.
      child_opts = child_opts(ctx, opts)
      need = Map.get(args, "need")

      result =
        case child_runner(action) do
          {:ok, run} -> run.(authority, reference, need, input, child_opts)
          :error -> {:error, {:invalid_argument, "execution.#{action} has no host dispatch"}}
        end

      case result do
        {:ok, output} ->
          emit_telemetry(parent_execution_id, "execution.#{action}", :ok, start_time)
          encode_success(normalize_keys(output))

        {:error, reason} ->
          emit_telemetry(parent_execution_id, "execution.#{action}", :error, start_time)
          encode_child_error(reason)
      end
    else
      {:error, {:delegation_refused, why}} ->
        emit_telemetry(parent_execution_id, "execution.#{action}", :error, start_time)
        encode_error(:tool_denied, "Invocation denied: #{why}")

      _ ->
        encode_error(:invalid_request, "execution.#{action} requires a 'reference'")
    end
  end

  @doc """
  The delegation roster a formula's input carries — its `sub_agents`, each
  a map with a `name` — or `[]`. What a child of the same formula is held
  to.
  """
  @spec roster_of(term()) :: [map()]
  def roster_of(%{"sub_agents" => roster}) when is_list(roster),
    do: Enum.filter(roster, &(is_map(&1) and is_binary(&1["name"])))

  def roster_of(_input), do: []

  # A formula invoking ITSELF is delegation when there is a roster to
  # delegate from, and the parent's roster is then the only source of what
  # a delegate may be: the child must name a `role` the roster lists; its
  # `tool_policy`, `system` and roster are then the roster entry's — the
  # host supplies them, whatever the guest's request carried, so a
  # model-written child input can never widen the policy the host
  # composed. A parent with no roster (itself a delegate, or a formula
  # that recurses plainly) delegates to nobody: a child that names a role
  # or carries a policy or a roster is refused, and one that carries none
  # of those is the ordinary recursion it looks like. Any other reference
  # is an ordinary child, its input its own.
  @host_controlled ~w(role tool_policy sub_agents)

  @doc false
  @spec delegated_input(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, {:delegation_refused, String.t()}}
  def delegated_input(reference, input, opts) do
    parent = opts[:parent_reference]
    roster = opts[:parent_roster] || []

    cond do
      not (is_binary(parent) and same_component?(reference, parent)) ->
        {:ok, input}

      roster != [] ->
        delegate_from(roster, input)

      Enum.any?(@host_controlled, &Map.has_key?(input, &1)) ->
        {:error,
         {:delegation_refused,
          "this formula has no roster to delegate from — a child of it names no role and carries no policy"}}

      true ->
        {:ok, input}
    end
  end

  defp delegate_from(roster, input) do
    role = input["role"]

    case Enum.find(roster, &(&1["name"] == role)) do
      nil when is_binary(role) and role != "" ->
        {:error, {:delegation_refused, "the roster lists no role #{inspect(role)}"}}

      nil ->
        {:error,
         {:delegation_refused, "a delegate of the same formula must name a role its roster lists"}}

      entry ->
        {:ok,
         input
         |> Map.put("tool_policy", entry["tool_policy"] || %{})
         |> Map.put("system", entry["prompt"] || "")
         |> Map.put("sub_agents", [])
         |> put_if_binary("catalyst_ref", entry["catalyst_ref"])
         |> put_if_binary("model", entry["model"])}
    end
  end

  defp put_if_binary(input, key, value) when is_binary(value) and value != "",
    do: Map.put(input, key, value)

  defp put_if_binary(input, _key, _value), do: input

  defp same_component?(a, b) do
    case {Cyfr.ComponentRef.to_name_ref(a), Cyfr.ComponentRef.to_name_ref(b)} do
      {{:ok, name_a}, {:ok, name_b}} -> name_a == name_b
      _ -> false
    end
  end

  defp child_opts(ctx, opts) do
    [
      ctx: ctx,
      parent_execution_id: Keyword.fetch!(opts, :parent_execution_id),
      root_execution_id: opts[:root_execution_id],
      # This formula's own attempt authorizes its children's charges.
      attempt: opts[:attempt],
      declared_needs: opts[:declared_needs] || [],
      activation_digest: opts[:activation_digest],
      # Who invoked the child — this formula — for what its row keeps of
      # its output: a model call the assistant made is kept as a digest
      # and its usage, never the provider's reply.
      parent_reference: opts[:parent_reference]
    ]
  end

  # Deny reasons map onto the guest error vocabulary, so guests need
  # no second taxonomy.
  defp encode_child_error({:invoke_denied, reason})
       when reason in [:depth_cap, :invoke_budget_exhausted],
       do: encode_error(:resource_limit, "Invocation denied: #{reason}")

  defp encode_child_error({:invoke_denied, {:need, why}}),
    do: encode_error(:invalid_request, "Invocation denied: need #{why}")

  defp encode_child_error({:invoke_denied, reason}),
    do: encode_error(:tool_denied, "Invocation denied: #{guest_reason(reason)}")

  defp encode_child_error({:invoke_invalid, reason}),
    do: encode_error(:invalid_request, "Invalid invocation: #{guest_reason(reason)}")

  defp encode_child_error({:invalid_need, need}),
    do: encode_error(:invalid_request, "Invalid need: #{guest_reason(need)}")

  defp encode_child_error({:invalid_reference, reason}),
    do: encode_error(:invalid_request, "Invalid reference: #{guest_reason(reason)}")

  defp encode_child_error({:setup_required, payload} = reason) do
    # Build the shared remediation payload through Cyfr.Remediation.
    case Cyfr.Remediation.analyze(reason) do
      {:setup_required, remediation} ->
        encode_error_with_remediation(
          :setup_required,
          "Dependency cannot be satisfied: #{payload.node_ref}",
          remediation
        )

      :not_setup_error ->
        encode_error(:dispatch_error, stringify_reason(reason))
    end
  end

  defp encode_child_error(reason),
    do: encode_error(:dispatch_error, stringify_reason(reason))

  defp dispatch_via_registry(json_request, %Context{} = ctx, opts) do
    parent_execution_id = Keyword.fetch!(opts, :parent_execution_id)
    root_execution_id = opts[:root_execution_id] || parent_execution_id

    start_time = System.monotonic_time(:millisecond)

    case parse_mcp_request(json_request, opts[:limits]) do
      {:ok, %{tool: tool, action: action, args: args}} ->
        tool_action =
          if String.contains?(tool, ":"), do: "external.call", else: "#{tool}.#{action}"

        args_with_action = Map.put(args, "action", action)

        case dispatch_tool(tool, ctx, args_with_action, opts, :call) do
          {:ok, result} ->
            emit_telemetry(parent_execution_id, tool_action, :ok, start_time)
            encode_success(normalize_keys(result))

          {:error, reason} ->
            emit_telemetry(parent_execution_id, tool_action, :error, start_time)
            reason_str = stringify_reason(reason)

            # Analyze the raw term: the typed setup/consent tuples carry the
            # structural cause, and stringifying first would hide it.
            case Cyfr.Remediation.analyze(reason) do
              {:setup_required, remediation} ->
                maybe_emit_setup_event(root_execution_id, remediation, reason_str, ctx)

                encode_error_with_remediation(:setup_required, reason_str, remediation)

              :not_setup_error ->
                encode_error(:dispatch_error, reason_str)
            end
        end

      {:error, type, message} ->
        emit_telemetry(parent_execution_id, "unknown", :error, start_time)
        encode_error(type, message)
    end
  end

  # ============================================================================
  # Host Function Implementations
  # ============================================================================

  defp handle_spawn(json_request, ctx, tracker, opts) do
    case authority_execution_request(json_request, opts) do
      {:intercept, "run", args} ->
        spawn_child_async(args, ctx, tracker, opts)

      # There is no async shape for run_stream: dispatched here it ran
      # synchronously and handed the guest a stream envelope where spawn
      # promises {"task_id": ...}.
      {:intercept, "run_stream", _args} ->
        encode_error(
          :invalid_request,
          "run_stream cannot be spawned — spawn execution.run, or call run_stream directly"
        )

      {:intercept, action, _args} ->
        encode_error(:invalid_request, "execution.#{action} cannot be spawned")

      :registry ->
        spawn_via_registry(json_request, ctx, tracker, opts)
    end
  end

  # An async spawn of a child: the transition decision (and its budget
  # charge) happens before the tracker task exists, so a denial consumes
  # no task slot; a tracker refusal after the charge releases it, and the
  # task's own after releases it on completion.
  defp spawn_child_async(args, ctx, tracker, opts) do
    authority = Keyword.fetch!(opts, :authority)
    parent_execution_id = Keyword.fetch!(opts, :parent_execution_id)

    case Map.get(args, "reference") do
      reference when is_binary(reference) and reference != "" ->
        child_opts =
          ctx
          |> child_opts(opts)
          |> Keyword.put(:guest_fn, :spawn)
          |> Cyfr.Execution.Charge.identify()

        need = Map.get(args, "need")
        input = Map.get(args, "input") || %{}

        with {:ok, decision} <-
               Cyfr.Execution.Admission.step_invoke(authority, reference, need, child_opts),
             :ok <- Cyfr.Execution.Charge.take(decision.authority, child_opts) do
          fun = fn ->
            # The task holds the charged slot under the guard until the
            # child's attempt takes it over, with the charge row; the
            # attempt gives both back when it stops, and a child refused
            # before its attempt opens gives them back at once.
            Sanctum.Authority.guard_invoke(decision.authority)
            start_time = System.monotonic_time(:millisecond)

            case Opus.Chain.execute_child(decision, input, child_opts) do
              {:ok, output} ->
                emit_telemetry(parent_execution_id, "execution.run", :ok, start_time)

                {encode_success(normalize_keys(output)), %{tool: "execution", action: "run"}}

              {:error, reason} ->
                emit_telemetry(parent_execution_id, "execution.run", :error, start_time)
                {encode_child_error(reason), %{tool: "execution", action: "run"}}
            end
          end

          # The budget is already charged; an exit from the tracker call
          # (dead tracker, call timeout) would bypass the release arms
          # below and leak the slot for the root's remaining life. A
          # timed-out call has still landed in the tracker's mailbox —
          # the task will run and its child gives the charge back, so
          # releasing here too would free a concurrent sibling's slot
          # (mirrors Sanctum.Authority.BudgetGuard.release_after_exit/2);
          # any other exit means the spawn never landed.
          spawn_result =
            try do
              Opus.AsyncTracker.spawn_task(tracker, fun, "execution.run")
            catch
              :exit, reason ->
                unless match?({:timeout, _}, reason) do
                  Sanctum.Authority.release_invoke(decision.authority)
                  Cyfr.Execution.Charge.give_back(decision.authority, child_opts)
                end

                Logger.warning(
                  "[Opus.FormulaHandler] spawn tracker unreachable: #{inspect(reason)}"
                )

                :tracker_unreachable
            end

          case spawn_result do
            {:ok, task_id} ->
              Opus.Telemetry.formula_spawn(parent_execution_id, task_id, "execution.run")
              safe_encode(%{"task_id" => task_id})

            {:error, :max_tasks_exceeded} ->
              Sanctum.Authority.release_invoke(decision.authority)
              Cyfr.Execution.Charge.give_back(decision.authority, child_opts)
              encode_error(:resource_limit, "Maximum concurrent tasks exceeded")

            {:error, reason} ->
              Sanctum.Authority.release_invoke(decision.authority)
              Cyfr.Execution.Charge.give_back(decision.authority, child_opts)
              encode_error(:spawn_failed, guest_reason(reason))

            :tracker_unreachable ->
              encode_error(:spawn_failed, "task tracker unavailable")
          end
        else
          {:error, reason} ->
            encode_child_error(reason)
        end

      _ ->
        encode_error(:invalid_request, "execution.run requires a 'reference'")
    end
  end

  # Non-execution tools go through the in-chain chokepoint: plane
  # annotation + transition step + identity conjunct. The authority is
  # required — every execution roots under one.
  defp dispatch_tool(tool, ctx, args, opts, guest_fn) do
    authority = Keyword.fetch!(opts, :authority)

    # Lineage rides the opts channel, never the guest's args — the
    # in-chain entry strips guest-supplied lineage keys before it
    # re-injects these, so a guest cannot claim another chain's root.
    lineage = %{
      parent_execution_id: opts[:parent_execution_id],
      root_execution_id: opts[:root_execution_id] || opts[:parent_execution_id],
      attempt: opts[:attempt]
    }

    Opus.Host.tool_call(tool, ctx, args, authority, guest_fn: guest_fn, lineage: lineage)
  end

  defp spawn_via_registry(json_request, ctx, tracker, opts) do
    parent_execution_id = Keyword.fetch!(opts, :parent_execution_id)

    case parse_mcp_request(json_request, opts[:limits]) do
      {:ok, %{tool: tool, action: action, args: args}} ->
        tool_action =
          if String.contains?(tool, ":"), do: "external.call", else: "#{tool}.#{action}"

        args_with_action = Map.put(args, "action", action)

        # Rescued in the task, the way the synchronous `execute/3` path is
        # wrapped by `guarded/3`. Without this a raise here became an exit
        # reason that `Opus.AsyncTracker` stringified into the guest's
        # response, which is the one route around the renderers that keep
        # internal terms out of guest hands.
        fun = fn ->
          start_time = System.monotonic_time(:millisecond)

          try do
            case dispatch_tool(tool, ctx, args_with_action, opts, :spawn) do
              {:ok, result} ->
                emit_telemetry(parent_execution_id, tool_action, :ok, start_time)
                {encode_success(normalize_keys(result)), %{tool: tool, action: action}}

              {:error, reason} ->
                emit_telemetry(parent_execution_id, tool_action, :error, start_time)

                {encode_error(:dispatch_error, stringify_reason(reason)),
                 %{tool: tool, action: action}}
            end
          rescue
            e ->
              emit_telemetry(parent_execution_id, tool_action, :error, start_time)

              Logger.error(
                "[Opus.FormulaHandler] spawned #{tool_action} raised: " <>
                  Exception.format(:error, e, __STACKTRACE__)
              )

              {encode_error(:dispatch_error, "The call failed."), %{tool: tool, action: action}}
          end
        end

        case Opus.AsyncTracker.spawn_task(tracker, fun, tool_action) do
          {:ok, task_id} ->
            Opus.Telemetry.formula_spawn(parent_execution_id, task_id, tool_action)
            safe_encode(%{"task_id" => task_id})

          {:error, :max_tasks_exceeded} ->
            encode_error(:resource_limit, "Maximum concurrent tasks exceeded")

          {:error, reason} ->
            encode_error(:spawn_failed, guest_reason(reason))
        end

      {:error, type, message} ->
        encode_error(type, message)
    end
  end

  defp handle_await(task_id, tracker, timeout_ms) do
    start = System.monotonic_time(:millisecond)

    case Opus.AsyncTracker.await_task(tracker, task_id, timeout_ms) do
      {:ok, {json_result, metadata}} ->
        duration_ms = System.monotonic_time(:millisecond) - start
        Opus.Telemetry.formula_await(task_id, :completed, duration_ms)
        build_await_response(task_id, json_result, metadata)

      {:ok, result} when is_binary(result) ->
        # Direct string result (no metadata wrapper)
        duration_ms = System.monotonic_time(:millisecond) - start
        Opus.Telemetry.formula_await(task_id, :completed, duration_ms)
        build_await_response(task_id, result, %{})

      {:error, :timeout} ->
        duration_ms = System.monotonic_time(:millisecond) - start
        Opus.Telemetry.formula_await(task_id, :timeout, duration_ms)

        safe_encode(%{
          "status" => "error",
          "error" => %{"type" => "timeout", "message" => "Task timed out"},
          "task_id" => task_id,
          "duration_ms" => duration_ms
        })

      {:error, :unknown_task} ->
        encode_error(:invalid_request, "Unknown task_id: #{task_id}")

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start
        Opus.Telemetry.formula_await(task_id, :error, duration_ms)

        safe_encode(%{
          "status" => "error",
          "error" => %{"type" => "task_failed", "message" => stringify_reason(reason)},
          "task_id" => task_id,
          "duration_ms" => duration_ms
        })
    end
  end

  defp handle_await_all(json_request, tracker, timeout_ms, parent_execution_id, max_tasks, limits) do
    with :ok <- envelope_bound(json_request, limits) do
      await_all_decoded(json_request, tracker, timeout_ms, parent_execution_id, max_tasks)
    else
      {:error, type, message} -> encode_error(type, message)
    end
  end

  defp await_all_decoded(json_request, tracker, timeout_ms, parent_execution_id, max_tasks) do
    case Jason.decode(json_request) do
      # The spawn cap bounds live-plus-undrained entries at max_tasks, so no
      # honest await list is longer; a fabricated one would burn quadratic
      # time in the tracker (which serializes every guest async op) for a
      # list of :unknown_task errors.
      {:ok, %{"task_ids" => task_ids}}
      when is_list(task_ids) and length(task_ids) > max_tasks ->
        encode_error(
          :invalid_request,
          "task_ids exceeds the concurrent-task limit (#{max_tasks})"
        )

      {:ok, %{"task_ids" => task_ids}} when is_list(task_ids) and task_ids != [] ->
        # Deduped where the guest's ids enter, so the tracker (which answers
        # once per distinct id) and this envelope's "count" agree.
        task_ids = Enum.uniq(task_ids)
        start = System.monotonic_time(:millisecond)

        case Opus.AsyncTracker.await_all(tracker, task_ids, timeout_ms) do
          {:ok, results} ->
            duration_ms = System.monotonic_time(:millisecond) - start

            timed_out =
              Enum.count(results, fn {_id, result} ->
                result == {:error, :timeout}
              end)

            Opus.Telemetry.formula_await_all(
              parent_execution_id,
              length(task_ids),
              timed_out,
              duration_ms
            )

            formatted =
              Enum.map(results, fn {task_id, result} ->
                format_task_result(task_id, result)
              end)

            safe_encode(%{"results" => formatted, "count" => length(task_ids)})
        end

      {:ok, %{"task_ids" => []}} ->
        safe_encode(%{"results" => [], "count" => 0})

      {:ok, _} ->
        encode_error(:invalid_request, "Request must include 'task_ids' array")

      {:error, _} ->
        encode_error(:invalid_json, "Invalid JSON request")
    end
  end

  defp handle_await_any(json_request, tracker, timeout_ms, parent_execution_id, max_tasks, limits) do
    with :ok <- envelope_bound(json_request, limits) do
      await_any_decoded(json_request, tracker, timeout_ms, parent_execution_id, max_tasks)
    else
      {:error, type, message} -> encode_error(type, message)
    end
  end

  defp await_any_decoded(json_request, tracker, timeout_ms, parent_execution_id, max_tasks) do
    case Jason.decode(json_request) do
      # Same bound as await-all, for the same reason.
      {:ok, %{"task_ids" => task_ids}}
      when is_list(task_ids) and length(task_ids) > max_tasks ->
        encode_error(
          :invalid_request,
          "task_ids exceeds the concurrent-task limit (#{max_tasks})"
        )

      {:ok, %{"task_ids" => task_ids}} when is_list(task_ids) and task_ids != [] ->
        # Same dedupe as await-all, and the timeout arm's "pending" echo
        # then lists each task once.
        task_ids = Enum.uniq(task_ids)
        start = System.monotonic_time(:millisecond)

        case Opus.AsyncTracker.await_any(tracker, task_ids, timeout_ms) do
          {:ok, winner_id, result, pending} ->
            duration_ms = System.monotonic_time(:millisecond) - start
            Opus.Telemetry.formula_await_any(parent_execution_id, winner_id, duration_ms)

            formatted_result = format_task_result(winner_id, result)

            safe_encode(%{
              "result" => formatted_result,
              "task_id" => winner_id,
              "pending" => pending
            })

          {:error, :timeout} ->
            duration_ms = System.monotonic_time(:millisecond) - start
            Opus.Telemetry.formula_await_any(parent_execution_id, nil, duration_ms)

            safe_encode(%{
              "status" => "error",
              "error" => %{"type" => "timeout", "message" => "All tasks timed out"},
              "pending" => task_ids
            })
        end

      {:ok, %{"task_ids" => []}} ->
        encode_error(:invalid_request, "task_ids array must be non-empty")

      {:ok, _} ->
        encode_error(:invalid_request, "Request must include 'task_ids' array")

      {:error, _} ->
        encode_error(:invalid_json, "Invalid JSON request")
    end
  end

  defp handle_poll(task_id, tracker) do
    case Opus.AsyncTracker.poll(tracker, task_id) do
      {:ok, :pending} ->
        safe_encode(%{"status" => "pending"})

      {:ok, {json_result, metadata}} ->
        build_await_response(task_id, json_result, metadata)

      {:ok, result} when is_binary(result) ->
        build_await_response(task_id, result, %{})

      {:error, :unknown_task} ->
        encode_error(:invalid_request, "Unknown task_id: #{task_id}")

      {:error, reason} ->
        safe_encode(%{
          "status" => "error",
          "error" => %{"type" => "task_failed", "message" => stringify_reason(reason)},
          "task_id" => task_id
        })
    end
  end

  defp handle_cancel(task_id, tracker, parent_execution_id) do
    case Opus.AsyncTracker.cancel_task(tracker, task_id) do
      :ok ->
        Opus.Telemetry.formula_cancel(parent_execution_id, task_id)
        safe_encode(%{"cancelled" => true, "task_id" => task_id})

      {:error, :already_completed} ->
        encode_error(:invalid_request, "Task #{task_id} already completed")

      {:error, :unknown_task} ->
        encode_error(:invalid_request, "Unknown task_id: #{task_id}")

      {:error, reason} ->
        encode_error(:cancel_failed, guest_reason(reason))
    end
  end

  # ============================================================================
  # Private: Request Parsing (MCP format)
  # ============================================================================

  defp parse_mcp_request(json_string, limits) do
    with :ok <- envelope_bound(json_string, limits) do
      case Jason.decode(json_string) do
        {:ok, %{"tool" => tool, "action" => action} = req}
        when is_binary(tool) and is_binary(action) ->
          args = Map.get(req, "args", %{})

          if is_map(args) do
            {:ok, %{tool: tool, action: action, args: args}}
          else
            {:error, :invalid_request, "args must be a map"}
          end

        {:ok, _} ->
          {:error, :invalid_request, "Request must include 'tool' (string) and 'action' (string)"}

        {:error, _} ->
          {:error, :invalid_json, "Invalid JSON request"}
      end
    end
  end

  # Enforce the request size cap before JSON decoding.
  defp envelope_bound(json_string, %Limits{} = limits) do
    case Opus.EdgeGuard.check_envelope_size(limits, json_string) do
      :ok ->
        :ok

      {:error, :request_too_large} ->
        {:error, :request_too_large,
         "Request exceeds the consented max_request_size for this component."}
    end
  end

  defp envelope_bound(_json_string, _limits), do: :ok

  # ============================================================================
  # Private: Response Encoding
  # ============================================================================

  defp safe_encode(data), do: Cyfr.WitResponse.safe_encode(data)

  defp encode_success(output) do
    safe_encode(%{
      "status" => "completed",
      "output" => output
    })
  end

  @doc false
  def encode_error(type, message),
    do: Cyfr.WitResponse.encode_error(type, stringify_reason(message))

  defp encode_error_with_remediation(type, message, remediation) do
    safe_encode(%{
      "error" => %{
        "type" => to_string(type),
        "message" => stringify_reason(message),
        "remediation" => remediation
      }
    })
  end

  defp maybe_emit_setup_event(target_id, remediation, message, ctx) do
    _ =
      Cyfr.Execution.Events.push(
        target_id,
        %{
          "kind" => "setup_required",
          "component_ref" => remediation["component_ref"],
          "issues" => remediation["issues"],
          "setup_command" => remediation["setup_command"],
          "message" => message
        },
        ctx,
        origin: "host"
      )

    :ok
  end

  defp build_await_response(task_id, json_result, metadata) do
    # Parse the invocation result to extract status/output/error
    base =
      case Jason.decode(json_result) do
        {:ok, %{"status" => "completed", "output" => output}} ->
          %{"status" => "completed", "output" => output}

        {:ok, %{"error" => error}} ->
          %{"status" => "error", "error" => error}

        _ ->
          %{
            "status" => "error",
            "error" => %{"type" => "unknown", "message" => "Unexpected result format"}
          }
      end

    base
    |> Map.put("task_id", task_id)
    |> Map.merge(format_metadata(metadata))
    |> safe_encode()
  end

  defp format_metadata(%{execution_id: eid, duration_ms: ms}) do
    result = %{"duration_ms" => ms}
    if eid, do: Map.put(result, "execution_id", eid), else: result
  end

  defp format_metadata(_), do: %{}

  defp format_task_result(task_id, {:ok, {json_result, metadata}}) do
    case Jason.decode(json_result) do
      {:ok, %{"status" => "completed", "output" => output}} ->
        %{"status" => "completed", "output" => output, "task_id" => task_id}
        |> Map.merge(format_metadata(metadata))

      {:ok, %{"error" => error}} ->
        %{"status" => "error", "error" => error, "task_id" => task_id}
        |> Map.merge(format_metadata(metadata))

      _ ->
        %{
          "status" => "error",
          "error" => %{"type" => "unknown", "message" => "Unexpected result"},
          "task_id" => task_id
        }
    end
  end

  defp format_task_result(task_id, {:ok, result}) when is_binary(result) do
    format_task_result(task_id, {:ok, {result, %{}}})
  end

  defp format_task_result(task_id, {:error, :timeout}) do
    %{
      "status" => "error",
      "error" => %{"type" => "timeout", "message" => "Task timed out"},
      "task_id" => task_id
    }
  end

  defp format_task_result(task_id, {:error, reason}) when is_binary(reason) do
    %{
      "status" => "error",
      "error" => %{"type" => "task_failed", "message" => reason},
      "task_id" => task_id
    }
  end

  defp format_task_result(task_id, {:error, reason}) do
    %{
      "status" => "error",
      "error" => %{"type" => "task_failed", "message" => guest_reason(reason)},
      "task_id" => task_id
    }
  end

  # ============================================================================
  # Private: Telemetry
  # ============================================================================

  defp emit_telemetry(execution_id, tool_action, status, start_time) do
    duration_ms = System.monotonic_time(:millisecond) - start_time
    Opus.Telemetry.mcp_tool_call(execution_id, tool_action, status, duration_ms)
  end

  # ============================================================================
  # Private: Key Normalization
  # ============================================================================

  # Normalize atom keys to strings for JSON encoding back to WASM
  # Structs (DateTime, URI, etc.) must pass through unchanged — they are not
  # plain maps and don't implement Enumerable.
  defp normalize_keys(%_{} = struct), do: struct

  defp normalize_keys(data) when is_map(data) do
    data
    |> Enum.map(fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), normalize_keys(v)}
      {k, v} -> {k, normalize_keys(v)}
    end)
    |> Map.new()
  end

  defp normalize_keys(data) when is_list(data) do
    Enum.map(data, &normalize_keys/1)
  end

  defp normalize_keys(data), do: data

  defp stringify_reason(reason), do: render_reason(reason)

  # Guest-facing reason text for terms below the `Cyfr.Ops.Error` vocabulary: a
  # crafted binary passes, a bare reason atom names itself verbatim (the
  # "edge_only"/"depth_cap" class of transition denials is a token guests
  # branch on), and anything structured renders through the shared seam or
  # is logged and generalized — never `inspect/1`, which handed the guest
  # whatever the term carried.
  defp guest_reason(reason) when is_binary(reason), do: reason

  defp guest_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp guest_reason(reason) do
    case Cyfr.Ops.Error.render(reason) do
      nil ->
        Logger.warning("[FormulaHandler] unrenderable guest reason: #{inspect(reason)}")
        "the call failed"

      msg ->
        msg
    end
  end

  @doc """
  The guest's view of a refusal: the same sentence the wire and the console
  render, and never an internal term.

  Render recognized typed errors consistently; unknown internal terms must not reach the guest.
  """
  @spec render_reason(term()) :: String.t()
  def render_reason(reason) do
    # `nil` means the term is internal — logged where it was produced, never
    # handed to the guest.
    Cyfr.Ops.Error.render(reason) || "The call failed."
  end
end
