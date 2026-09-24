# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Runtime do
  @moduledoc """
  WASM execution runtime using Wasmex (Wasmtime).

  Provides low-level WASM execution with sandboxing. This module wraps
  Wasmex's GenServer-based API to provide a consistent interface for Opus.

  ## Execution Model

  All components are executed via **WASI Preview 2 (Component Model)**.
  Components must be compiled as WASI P2 Component Model binaries.

  A single shared `Wasmex.Engine` is used for all executions (see
  `Opus.SharedEngine`). Stores are built explicitly with this engine.
  Compiled components are cached by `Opus.ComponentCache` to skip JIT
  recompilation on repeat executions of the same component.

  ## Sandboxing

  All executions run in isolated Wasmex instances with:
  - Memory limits (configurable, default 64MB)
  - No network access (Reagents) unless explicitly granted (Catalysts)

  ## Resource Limits

  The node's consented `max_memory_bytes` bounds a run's linear memory in
  total (`store_limits/1`): its store holds one linear memory, which grows
  no further than that, and a bounded number of tables of a bounded number
  of elements. An instantiation the store refuses (a second memory, more
  tables or instances than it holds, or one declared larger than its
  bound) ends the run as a `resource_limit` sentence; a `memory.grow` or
  `table.grow` past the bound answers the guest `-1`, as WebAssembly
  specifies a refused growth, and the guest goes on or traps as it
  chooses. Either way the engine refuses before the runner's own memory
  bound is reached.

      Opus.Runtime.execute_component(wasm, input,
        max_memory_bytes: 32 * 1024 * 1024  # 32MB
      )

  See: https://github.com/tessi/wasmex
  """

  require Logger

  # Default memory ceiling for sandboxed execution — the shared 64 MiB
  # bound, read from its owner rather than re-spelled here.
  @default_max_memory_bytes Prima.Limits.default_max_memory_bytes()

  # What a run's store holds besides its one linear memory. Every shipped
  # component instantiates three core modules with two funcref tables, the
  # larger of 159 elements; these bounds leave room for other toolchains
  # while every table a run can make holds at most 200,000 eight-byte
  # elements in all. The per-table element bound is wasmtime's own default
  # for a pooled instance.
  @max_instances 10
  @max_tables 10
  @max_table_elements 20_000

  # wasmtime's words for an instantiation its store limits refused: a count
  # past its bound, or a memory or table declared larger than its bound.
  @limit_refusals [
    ~r/\Aresource limit exceeded: (?<what>[a-z]+ count too high at \d+)\z/,
    ~r/\A(?<what>(memory|table) minimum size of \d+ (pages|elements) exceeds (memory|table) limits)\z/
  ]

  @doc """
  Execute a WASM component with JSON input, returning JSON output.

  Uses the shared engine from `Opus.SharedEngine` and caches compiled
  components via `Opus.ComponentCache`. Stores are built explicitly with
  the shared engine.

  `wasm` is the component's bytes, or a function answering them
  (`{:ok, bytes}` or `{:error, {:artifact, sentence}}`), called only when
  no compiled component for `:digest` is cached; a refusal it answers is
  the run's error sentence.

  ## Options

  - `:component_type` - One of `:reagent`, `:catalyst`, `:formula`. Defaults to `:reagent`.
  - `:reference` - Component reference string (for telemetry and errors)
  - `:digest` - Content digest (the compiled-component cache key); required
    when `wasm` is a function
  - `:max_memory_bytes` - Memory limit. Defaults to 64MB.
  - `:authority` - The `Prima.Authority` this execution runs under
  - `:authority_required` - Defaults to true: a nil `:authority` raises instead
    of executing (a WASM run always carries one; this is the final invariant
    guard). Pass `false` only for authority-free harness runs in tests.
  - `:execution_id` - The admitted execution
  - `:host` - The attached `Opus.HostClient` of the execution's attempt:
    the guest's `emit`, OAuth tokens, storage, HTTP rate checks and egress
    denials, and a formula's children and catalog tool calls, are its host
    calls
  - `:intercepted` - The `tool.action` names a formula's host runs rather
    than the catalog, as its assignment carries them

  ## Examples

      iex> {:ok, result} =
      ...>   Opus.Runtime.execute_component(wasm_bytes, %{"a" => 5, "b" => 3},
      ...>     authority: authority
      ...>   )
      iex> result
      %{"sum" => 8}
  """
  @spec execute_component(
          binary() | (-> {:ok, binary()} | {:error, {:artifact, String.t()}}),
          map(),
          keyword()
        ) :: {:ok, map()} | {:ok, map(), map()} | {:error, term()}
  def execute_component(wasm, input, opts \\ [])
      when (is_binary(wasm) or is_function(wasm, 0)) and is_map(input) do
    component_type = Keyword.get(opts, :component_type, :reagent)
    wasi_opts = Opus.ComponentType.wasi_options(component_type)

    preloaded_fields = Keyword.get(opts, :preloaded_fields, %{})
    component_ref = Keyword.get(opts, :component_ref)
    edge = Keyword.get(opts, :edge)
    limits = Keyword.get(opts, :limits)
    execution_id = Keyword.get(opts, :execution_id)
    reference = Keyword.get(opts, :reference)
    digest = Keyword.get(opts, :digest)
    authority = Keyword.get(opts, :authority)
    host = Keyword.get(opts, :host)

    # Admission refuses a run without an authority; this is the last guard:
    # a runtime reached without one dies rather than run on ambient
    # permissions.
    if Keyword.get(opts, :authority_required, true) and is_nil(authority) do
      raise ArgumentError,
            "execution requires an authority but none reached the runtime " <>
              "(reference: #{inspect(reference)}) — an opts filter dropped it"
    end

    if authority do
      :telemetry.execute(
        [:cyfr, :opus, :runtime, :authority_entered],
        %{},
        %{
          authority: authority,
          execution_id: execution_id,
          reference: reference
        }
      )
    end

    max_memory = Keyword.get(opts, :max_memory_bytes, @default_max_memory_bytes)

    engine = Opus.SharedEngine.get()

    authority_info = %{
      authority: authority,
      # The actions a formula's host runs rather than the catalog.
      intercepted: Keyword.get(opts, :intercepted, [])
    }

    # Build imports and collect cleanup refs
    {imports, cleanup_refs} =
      build_imports_and_cleanup(
        component_type,
        preloaded_fields,
        component_ref,
        edge,
        limits,
        host,
        execution_id,
        authority_info
      )

    # Notify caller of cleanup_refs so they can clean up on timeout kill
    case Keyword.get(opts, :notify_cleanup_refs) do
      {pid, ref} -> send(pid, {:cleanup_refs, ref, cleanup_refs})
      nil -> :ok
    end

    try do
      # Build store explicitly with our shared engine (fixes fuel bug)
      store_limits = store_limits(max_memory)

      store_result =
        case wasi_opts do
          nil ->
            Wasmex.Components.Store.new(store_limits, engine)

          %Wasmex.Wasi.WasiP2Options{} = wasi ->
            Wasmex.Components.Store.new_wasi(wasi, store_limits, engine)
        end

      case store_result do
        {:ok, store} ->
          # Get or compile the component (cache hit skips JIT)
          case compile(store, wasm, digest) do
            {:ok, component} ->
              # Start GenServer directly with pre-built store + component
              case GenServer.start_link(
                     Wasmex.Components,
                     %{store: store, component: component, imports: imports}
                   ) do
                {:ok, pid} ->
                  try do
                    result = execute_with_convention(pid, input, component_type: component_type)
                    stop_instance(pid)
                    add_execution_metadata(result, %{})
                  rescue
                    e ->
                      stop_instance(pid)
                      {:error, Exception.message(e)}
                  end

                {:error, reason} ->
                  {:error, instantiation_failure(reason)}
              end

            {:error, {:artifact, sentence}} ->
              {:error, sentence}

            {:error, reason} ->
              {:error,
               "Component compilation failed: #{inspect(reason)}. " <>
                 "Ensure the component is compiled as a WASI P2 Component Model binary."}
          end

        {:error, reason} ->
          {:error, "Failed to create WASM store: #{inspect(reason)}"}
      end
    after
      if cleanup_refs.stream_exec_ref,
        do: Opus.HttpStreamHandler.cleanup_registry(cleanup_refs.stream_exec_ref)

      if cleanup_refs.formula_tracker_pid,
        do: Opus.FormulaHandler.cleanup_registry(cleanup_refs.formula_tracker_pid)
    end
  end

  @doc """
  The limits of a run's store under the node's consented
  `max_memory_bytes`: one linear memory of at most that many bytes, so the
  run's linear memory in total is bounded by it, at most #{@max_tables}
  tables of at most #{@max_table_elements} elements each, and at most
  #{@max_instances} instances.
  """
  @spec store_limits(pos_integer()) :: Wasmex.StoreLimits.t()
  def store_limits(max_memory_bytes) when is_integer(max_memory_bytes) and max_memory_bytes > 0 do
    %Wasmex.StoreLimits{
      memory_size: max_memory_bytes,
      memories: 1,
      tables: @max_tables,
      table_elements: @max_table_elements,
      instances: @max_instances
    }
  end

  # An instantiation the store limits refused is the run's `resource_limit`,
  # in the engine's own words, which name counts and sizes and nothing of
  # the guest's; any other failure is reported as it was.
  defp instantiation_failure(reason) when is_binary(reason) do
    case Enum.find_value(@limit_refusals, &Regex.named_captures(&1, reason)) do
      %{"what" => what} ->
        "resource_limit: the engine refused the component's memory or tables (#{what})"

      nil ->
        "Component instantiation failed: #{inspect(reason)}"
    end
  end

  defp instantiation_failure(reason), do: "Component instantiation failed: #{inspect(reason)}"

  # Build all host function imports and collect cleanup refs. The node's
  # limits and the attempt's host client are the presence signal for
  # capability-scoped imports: they are always carried under an admitted
  # authority, while the edge itself may be nil (resources :none) — a nil
  # edge builds the same imports with deny-all resource lists, so a guest's
  # host call fails with a denial instead of a missing import.
  defp build_imports_and_cleanup(
         component_type,
         preloaded_fields,
         component_ref,
         edge,
         limits,
         host,
         execution_id,
         authority_info
       ) do
    vault_imports =
      if component_type == :catalyst do
        build_vault_imports(preloaded_fields, component_ref, host)
      else
        %{}
      end

    http_imports =
      if component_type == :catalyst && limits && host do
        Opus.HttpHandler.build_http_imports(edge, limits, host, component_ref)
      else
        %{}
      end

    {stream_imports, stream_exec_ref} =
      if component_type == :catalyst && limits && host do
        Opus.HttpStreamHandler.build_stream_imports(edge, limits, host, component_ref)
      else
        {%{}, nil}
      end

    storage_imports =
      if component_type == :catalyst && limits && host do
        Opus.StorageHandler.build_storage_imports(limits, host, component_ref)
      else
        %{}
      end

    # The execution's attempt dispenses every token, so each one is in its
    # masking set before the guest has it.
    oauth_imports =
      if component_type == :catalyst && host do
        Opus.OAuthHandler.build_oauth_imports(host)
      else
        %{}
      end

    emit_imports =
      if component_type == :catalyst && host && authority_info.authority do
        build_emit_imports(host, limits)
      else
        %{}
      end

    {formula_imports, formula_tracker_pid} =
      if component_type == :formula && host do
        Opus.FormulaHandler.build_formula_imports(host,
          limits: limits,
          intercepted: authority_info.intercepted
        )
      else
        {%{}, nil}
      end

    all_imports =
      vault_imports
      |> Map.merge(http_imports)
      |> Map.merge(stream_imports)
      |> Map.merge(storage_imports)
      |> Map.merge(oauth_imports)
      |> Map.merge(emit_imports)
      |> Map.merge(formula_imports)

    cleanup_refs = %{
      stream_exec_ref: stream_exec_ref,
      formula_tracker_pid: formula_tracker_pid,
      execution_id: execution_id
    }

    {all_imports, cleanup_refs}
  end

  # A catalyst's `cyfr:emit/events` import: each event is a `push_deltas`
  # host call, and CYFR checks, masks and pushes it on the stream the
  # attempt was opened on.
  defp build_emit_imports(host, limits) do
    %{
      "cyfr:emit/events@0.1.0" => %{
        "emit" => {:fn, fn json_event -> emit(host, limits, json_event) end}
      }
    }
  end

  @doc """
  Deliver one guest event through the attempt's host client, answering the
  JSON the guest's `emit` returns. An event over the node's
  `max_request_size` (`limits`, when the node has them) is refused here as
  a `resource_limit`, before it crosses the wire that would refuse its
  body; a refused host call answers a `dispatch_error`.
  """
  @spec emit(Opus.HostClient.t(), Prima.Limits.t() | nil, String.t()) :: String.t()
  def emit(%Opus.HostClient{} = host, limits, json_event) when is_binary(json_event) do
    case Opus.EdgeGuard.check_event_size(limits, json_event) do
      :ok ->
        push_event(host, json_event)

      {:error, :request_too_large, message} ->
        Prima.WitResponse.encode_error(:resource_limit, message)
    end
  end

  defp push_event(host, json_event) do
    case Opus.HostClient.push_deltas(host, [json_event]) do
      {:ok, [reply]} ->
        reply

      {:error, refusal} ->
        Logger.warning(
          "[Opus.Runtime] #{host.execution_id} emit refused by the host: #{inspect(refusal)}"
        )

        Prima.WitResponse.encode_error(:dispatch_error, "The emit call failed.")
    end
  end

  defp compile(store, wasm, digest) when is_binary(digest) and digest != "",
    do: Opus.ComponentCache.get_or_compile(digest, fn -> artifact(wasm) end, store)

  defp compile(store, wasm, _digest) do
    with {:ok, bytes} <- artifact(wasm), do: Wasmex.Components.Component.new(store, bytes)
  end

  defp artifact(bytes) when is_binary(bytes), do: {:ok, bytes}
  defp artifact(fetch) when is_function(fetch, 0), do: fetch.()

  # A catalyst's `cyfr:vault/read` import, answered from the fields its
  # attach was handed (the consented projection, which CYFR audited as it
  # dispensed them). A read outside them is refused, and reported to CYFR
  # through the attempt's host client (`record_denial`, `secret_denied`),
  # which audits it for the attempt the call key names. The name is the
  # guest's: one the contract bounds out (`Prima.HostAPI.valid_field_name?/1`)
  # is refused unreported, and logged without the name.
  defp build_vault_imports(preloaded, component_ref, host) when is_map(preloaded) do
    %{
      "cyfr:vault/read@0.1.0" => %{
        "get" =>
          {:fn,
           fn name ->
             case Map.fetch(preloaded, name) do
               {:ok, value} ->
                 {:ok, value}

               :error ->
                 report_denied(host, name, component_ref)
                 {:error, "access-denied: #{name} not granted to #{component_ref}"}
             end
           end}
      }
    }
  end

  defp report_denied(host, name, component_ref) do
    if Prima.HostAPI.valid_field_name?(name) do
      Logger.warning(
        "[Opus.Runtime] Field '#{name}' is outside the consent's projection for " <>
          "'#{component_ref}'. Re-grant via the consent walk: " <>
          "cyfr profile grant #{component_ref}"
      )

      if host, do: _ = Opus.HostClient.record_denial(host, "secret_denied", name)
    else
      Logger.warning(
        "[Opus.Runtime] '#{component_ref}' asked its vault for a name that is no field name"
      )
    end

    :ok
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  # Convention for Component Model binaries.
  # All component types use the JSON string convention with interface-scoped exports.
  defp execute_with_convention(pid, input, opts) do
    component_type = Keyword.get(opts, :component_type, :reagent)

    case component_type do
      :catalyst ->
        execute_json_convention(pid, ["cyfr:catalyst/run@0.1.0", "run"], input)

      :reagent ->
        execute_json_convention(pid, ["cyfr:reagent/compute@0.1.0", "compute"], input)

      :formula ->
        execute_json_convention(pid, ["cyfr:formula/run@0.1.0", "run"], input)
    end
  end

  # JSON convention: pass JSON string input, parse JSON string output.
  # Components export via standardized interface-scoped functions (e.g.
  # `cyfr:catalyst/run@0.1.0`), addressed with Wasmex list notation.
  defp execute_json_convention(pid, call_name, input) do
    # Serialize input to JSON string
    case Jason.encode(input) do
      {:error, err} ->
        {:error, "Failed to encode input as JSON: #{inspect(err)}"}

      {:ok, json_input} ->
        case call_function(pid, call_name, json_input) do
          {:trapped, message} ->
            Logger.warning("[Opus.Runtime] the call of #{inspect(call_name)} trapped: #{message}")
            {:error, "Component call failed for #{inspect(call_name)}: #{message}"}

          :instance_ended ->
            Logger.warning("[Opus.Runtime] the instance ended under #{inspect(call_name)}")

            {:error,
             "Component call failed for #{inspect(call_name)}: the component's instance ended"}

          {:ok, json_output} when is_binary(json_output) ->
            # Parse JSON output
            case Jason.decode(json_output) do
              {:ok, result} ->
                {:ok, result}

              {:error, decode_error} ->
                # Report the JSON error position without echoing the component's raw output.
                detail = Exception.message(decode_error)

                Logger.warning("[Opus.Runtime] Component output is not valid JSON: #{detail}")

                {:error, "Component returned invalid JSON output: #{detail}"}
            end

          {:ok, result} ->
            {:ok, %{"result" => result}}

          {:error, reason} ->
            Logger.warning(
              "[Opus.Runtime] JSON convention failed for #{inspect(call_name)}: #{inspect(reason)}"
            )

            {:error,
             "Component call failed for #{inspect(call_name)}: #{inspect(reason)}. " <>
               "Ensure the component exports the correct WIT interface (cyfr:reagent/compute@0.1.0, cyfr:catalyst/run@0.1.0, or cyfr:formula/run@0.1.0)."}
        end
    end
  end

  # A guest's trap ends the instance's server with the trap as its exception,
  # and the exit of the call waiting on it carries that call beside the
  # reason: `{reason, {GenServer, :call, [pid, {:call_function, name,
  # [json_input]}, timeout]}}`. The guest's input is never part of the run's
  # error, so only the trap's own message leaves here, and an exit of any
  # other shape leaves as the fact that the instance ended.
  defp call_function(pid, call_name, json_input) do
    # Components (especially Catalysts) can make HTTP calls that take much longer
    # than the default 5s GenServer.call timeout. The runner enforces its own
    # wall-clock timeout, so we use :infinity here to avoid double-timeout races.
    Wasmex.Components.call_function(pid, call_name, [json_input], :infinity)
  catch
    :exit, {{%RuntimeError{message: message}, _stacktrace}, _call} when is_binary(message) ->
      {:trapped, message}

    :exit, _reason ->
      :instance_ended
  end

  # The instance's server is gone already when the call it ran trapped.
  defp stop_instance(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  # ===========================================================================
  # Execution Metadata Helpers
  # ===========================================================================

  # Wrap a successful result in the {:ok, output, metadata} shape the
  # runner consumes. The metadata map is currently empty — it is the seam
  # where real per-execution metrics ride when the engine can report them;
  # nothing is fabricated here.
  defp add_execution_metadata({:ok, output}, metadata) when is_map(metadata) do
    {:ok, output, metadata}
  end

  defp add_execution_metadata({:error, _} = error, _metadata), do: error
end
