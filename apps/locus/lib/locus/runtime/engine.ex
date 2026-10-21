# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.Engine do
  @moduledoc """
  WASM execution runtime using Wasmex (Wasmtime).

  Provides low-level WASM execution with sandboxing. This module wraps
  Wasmex's GenServer-based API to provide a consistent interface for the runtime.

  ## Execution Model

  All components are executed via **WASI Preview 2 (Component Model)**.
  Components must be compiled as WASI P2 Component Model binaries.

  A single shared `Wasmex.Engine` is used for all executions (see
  `Locus.Runtime.SharedEngine`). Stores are built explicitly with this engine.
  Compiled components are cached by `Locus.Runtime.ComponentCache` to skip JIT
  recompilation on repeat executions of the same component.

  ## Sandboxing

  All executions run in isolated Wasmex instances with:
  - Memory limits (the node's consented `max_memory_bytes`)
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

  See: https://github.com/tessi/wasmex
  """

  require Logger

  alias Prima.Authority.Blob.Edge

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

  Uses the shared engine from `Locus.Runtime.SharedEngine` and caches compiled
  components via `Locus.Runtime.ComponentCache`. Stores are built explicitly with
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
  - `:authority` - The `Prima.Authority` this execution runs under; required:
    a run without one, or with anything else in its place, raises
    `ArgumentError` before anything compiles
  - `:limits` - The node's `Prima.Limits`; required. Its `max_memory_bytes`
    bounds the run's store (`store_limits/1`)
  - `:execution_id` - The admitted execution
  - `:host` - The attached `Locus.Runtime.HostClient` of the execution's
    attempt; required. The guest's `emit`, OAuth tokens, storage, HTTP rate
    checks and egress denials, and a formula's children and catalog tool
    calls, are its host calls
  - `:intercepted` - The `tool.action` names a formula's host runs rather
    than the catalog, as its assignment carries them

  ## Examples

      iex> {:ok, result} =
      ...>   Locus.Runtime.Engine.execute_component(wasm_bytes, %{"a" => 5, "b" => 3},
      ...>     authority: authority,
      ...>     limits: Prima.Authority.limits(authority),
      ...>     host: host
      ...>   )
      iex> result
      %{"sum" => 8}
  """
  @spec execute_component(
          binary() | (-> {:ok, binary()} | {:error, {:artifact, String.t()}}),
          map(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def execute_component(wasm, input, opts \\ [])
      when (is_binary(wasm) or is_function(wasm, 0)) and is_map(input) do
    component_type = Keyword.get(opts, :component_type, :reagent)
    wasi_opts = Locus.Runtime.ComponentType.wasi_options(component_type)

    preloaded_fields = Keyword.get(opts, :preloaded_fields, %{})
    component_ref = Keyword.get(opts, :component_ref)
    edge = Keyword.get(opts, :edge)
    execution_id = Keyword.get(opts, :execution_id)
    reference = Keyword.get(opts, :reference)
    digest = Keyword.get(opts, :digest)
    authority = Keyword.get(opts, :authority)

    # Admission refuses a run without an authority; this is the last guard:
    # a runtime reached without one dies rather than run on ambient
    # permissions.
    if not match?(%Prima.Authority{}, authority) do
      raise ArgumentError,
            "execution requires an authority but none reached the runtime " <>
              "— an opts filter dropped it"
    end

    %Prima.Limits{} = limits = Keyword.fetch!(opts, :limits)
    %Locus.Runtime.HostClient{} = host = Keyword.fetch!(opts, :host)

    :telemetry.execute(
      [:cyfr, :locus, :runtime, :engine, :authority_entered],
      %{},
      %{
        authority: authority,
        execution_id: execution_id,
        reference: reference
      }
    )

    engine = Locus.Runtime.SharedEngine.get()

    # The actions a formula's host runs rather than the catalog.
    intercepted = Keyword.get(opts, :intercepted, [])

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
        intercepted
      )

    # Notify caller of cleanup_refs so they can clean up on timeout kill
    case Keyword.get(opts, :notify_cleanup_refs) do
      {pid, ref} -> send(pid, {:cleanup_refs, ref, cleanup_refs})
      nil -> :ok
    end

    try do
      # The store is built on the shared engine, so every run shares its
      # configuration and its compiled-component cache.
      store_limits = store_limits(limits.max_memory_bytes)

      case Wasmex.Components.Store.new_wasi(wasi_opts, store_limits, engine) do
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
                    result
                  rescue
                    e ->
                      stop_instance(pid)
                      {:error, Prima.LogFilter.exception_message(e)}
                  end

                {:error, reason} ->
                  {:error, instantiation_failure(reason)}
              end

            {:error, {:artifact, sentence}} ->
              {:error, sentence}

            {:error, reason} ->
              {:error,
               "Component compilation failed: #{engine_words(reason)}. " <>
                 "Ensure the component is compiled as a WASI P2 Component Model binary."}
          end

        {:error, reason} ->
          {:error, "Failed to create WASM store: #{engine_words(reason)}"}
      end
    after
      if cleanup_refs.stream_exec_ref,
        do: Locus.Runtime.HttpStreamHandler.cleanup_registry(cleanup_refs.stream_exec_ref)

      if cleanup_refs.formula_tracker_pid,
        do: Locus.Runtime.FormulaHandler.cleanup_registry(cleanup_refs.formula_tracker_pid)
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
        "Component instantiation failed: #{reason}"
    end
  end

  defp instantiation_failure(reason),
    do: "Component instantiation failed: #{engine_words(reason)}"

  # The engine answers its refusals as its own sentences; anything else is
  # logged and named generically, never spelled onto the failure the
  # control plane records.
  defp engine_words(reason) when is_binary(reason), do: reason

  defp engine_words(reason) do
    Logger.warning(
      "[Locus.Runtime.Engine] the engine refused with a non-sentence: #{inspect(reason)}"
    )

    "the engine refused the component"
  end

  # Build all host function imports and collect cleanup refs. A catalyst
  # gets every capability-scoped import and a formula its invoke import,
  # whatever its edge: the edge may be nil (resources :none), and a nil
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
         intercepted
       ) do
    vault_imports =
      if component_type == :catalyst do
        build_vault_imports(preloaded_fields, component_ref, host, edge)
      else
        %{}
      end

    http_imports =
      if component_type == :catalyst do
        Locus.Runtime.HttpHandler.build_http_imports(edge, limits, host, component_ref)
      else
        %{}
      end

    {stream_imports, stream_exec_ref} =
      if component_type == :catalyst do
        Locus.Runtime.HttpStreamHandler.build_stream_imports(edge, limits, host, component_ref)
      else
        {%{}, nil}
      end

    storage_imports =
      if component_type == :catalyst do
        Locus.Runtime.StorageHandler.build_storage_imports(limits, host, component_ref)
      else
        %{}
      end

    # The execution's attempt dispenses every token, so each one is in its
    # masking set before the guest has it.
    oauth_imports =
      if component_type == :catalyst do
        Locus.Runtime.OAuthHandler.build_oauth_imports(host)
      else
        %{}
      end

    emit_imports =
      if component_type == :catalyst do
        build_emit_imports(host, limits)
      else
        %{}
      end

    {formula_imports, formula_tracker_pid} =
      if component_type == :formula do
        Locus.Runtime.FormulaHandler.build_formula_imports(host,
          limits: limits,
          intercepted: intercepted
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
  `max_request_size` is refused here as a `resource_limit`, before it
  crosses the wire that would refuse its body; a refused host call answers
  a `dispatch_error`.
  """
  @spec emit(Locus.Runtime.HostClient.t(), Prima.Limits.t(), String.t()) :: String.t()
  def emit(%Locus.Runtime.HostClient{} = host, %Prima.Limits{} = limits, json_event)
      when is_binary(json_event) do
    case Locus.Runtime.EdgeGuard.check_event_size(limits, json_event) do
      :ok ->
        push_event(host, json_event)

      {:error, :request_too_large, message} ->
        Prima.WitResponse.encode_error(:resource_limit, message)
    end
  end

  defp push_event(host, json_event) do
    case Locus.Runtime.HostClient.push_deltas(host, [json_event]) do
      {:ok, [reply]} ->
        reply

      {:error, refusal} ->
        Logger.warning(
          "[Locus.Runtime.Engine] #{host.execution_id} emit refused by the host: #{inspect(refusal)}"
        )

        Prima.WitResponse.encode_error(:dispatch_error, "The emit call failed.")
    end
  end

  defp compile(store, wasm, digest) when is_binary(digest) and digest != "",
    do: Locus.Runtime.ComponentCache.get_or_compile(digest, fn -> artifact(wasm) end, store)

  defp compile(store, wasm, _digest) do
    with {:ok, bytes} <- artifact(wasm),
         :ok <- Locus.Runtime.ComponentCache.admitted(bytes),
         do: Wasmex.Components.Component.new(store, bytes)
  end

  defp artifact(bytes) when is_binary(bytes), do: {:ok, bytes}
  defp artifact(fetch) when is_function(fetch, 0), do: fetch.()

  # A catalyst's `cyfr:vault/read` import, answered from the fields its
  # attach was handed: a disclosed entry's consented projection and a
  # publisher's provided values, which CYFR audited as it dispensed them.
  # A field of an entry the node's edge binds but CYFR attaches to its
  # requests and never hands over is refused as such
  # (`disclosure_refused`); any other read outside them is refused as
  # outside the projection (`secret_denied`). Either is reported to CYFR
  # through the attempt's host client (`record_denial`), which audits it
  # for the attempt the call key names. The name is the guest's: one the
  # contract bounds out (`Prima.HostAPI.valid_field_name?/1`) is refused
  # unreported, and logged without the name.
  defp build_vault_imports(preloaded, component_ref, host, edge) when is_map(preloaded) do
    attached = attached_fields(edge)

    %{
      "cyfr:vault/read@0.1.0" => %{
        "get" =>
          {:fn,
           fn name ->
             case Map.fetch(preloaded, name) do
               {:ok, value} ->
                 {:ok, value}

               :error ->
                 if MapSet.member?(attached, name) do
                   report_denied(host, name, component_ref, "disclosure_refused")

                   {:error,
                    "disclosure_refused: #{name} is attached to requests by CYFR and never " <>
                      "handed to #{component_ref}"}
                 else
                   report_denied(host, name, component_ref, "secret_denied")
                   {:error, "access-denied: #{name} not granted to #{component_ref}"}
                 end
             end
           end}
      }
    }
  end

  # The fields the node's edge projects from the entries it binds: the
  # default binding's and each named account's. Those the attempt was not
  # handed are attached by CYFR, never disclosed.
  defp attached_fields(%Edge{vault: %{entry_id: _entry} = vault}) do
    named = vault |> Map.get(:named, %{}) |> Map.values()
    MapSet.new(Enum.flat_map([vault | named], &projected_fields/1))
  end

  defp attached_fields(_edge), do: MapSet.new()

  defp projected_fields(%{projection: %{fields: fields}}) when is_list(fields), do: fields
  defp projected_fields(_vault), do: []

  defp report_denied(host, name, component_ref, reason) do
    if Prima.HostAPI.valid_field_name?(name) do
      Logger.warning(denied_line(reason, name, component_ref))
      _ = Locus.Runtime.HostClient.record_denial(host, reason, name)
    else
      Logger.warning(
        "[Locus.Runtime.Engine] '#{component_ref}' asked its vault for a name that is no field name"
      )
    end

    :ok
  end

  defp denied_line("disclosure_refused", name, component_ref),
    do:
      "[Locus.Runtime.Engine] Field '#{name}' is attached to requests by CYFR and never handed to " <>
        "'#{component_ref}'"

  defp denied_line("secret_denied", name, component_ref),
    do:
      "[Locus.Runtime.Engine] Field '#{name}' is outside the consent's projection for " <>
        "'#{component_ref}'. Re-grant via the consent walk: " <>
        "cyfr profile grant #{component_ref}"

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
      # The encoder's own message can quote the value it refused.
      {:error, _err} ->
        {:error, "Failed to encode input as JSON"}

      {:ok, json_input} ->
        case call_function(pid, call_name, json_input) do
          {:trapped, message} ->
            Logger.warning(
              "[Locus.Runtime.Engine] the call of #{inspect(call_name)} trapped: #{message}"
            )

            {:error, "Component call failed for #{inspect(call_name)}: #{message}"}

          {:failed, message} ->
            Logger.warning(
              "[Locus.Runtime.Engine] the call of #{inspect(call_name)} failed as it ran: #{message}"
            )

            {:error, "Component call failed for #{inspect(call_name)}: #{message}"}

          :instance_ended ->
            Logger.warning(
              "[Locus.Runtime.Engine] the instance ended under #{inspect(call_name)}"
            )

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

                Logger.warning(
                  "[Locus.Runtime.Engine] Component output is not valid JSON: #{detail}"
                )

                {:error, "Component returned invalid JSON output: #{detail}"}
            end

          {:ok, result} ->
            {:ok, %{"result" => result}}

          {:error, reason} ->
            Logger.warning(
              "[Locus.Runtime.Engine] JSON convention failed for #{inspect(call_name)}: #{inspect(reason)}"
            )

            {:error,
             "Component call failed for #{inspect(call_name)}: #{engine_words(reason)}. " <>
               "Ensure the component exports the correct WIT interface (cyfr:reagent/compute@0.1.0, cyfr:catalyst/run@0.1.0, or cyfr:formula/run@0.1.0)."}
        end
    end
  end

  # The instance's server answers a call that failed as it ran, a trap or
  # anything else (an import that failed, a result it could not convert),
  # as one sentence and no structure: the library's words, "Error during
  # function excecution", then the trap in parentheses when it trapped,
  # then wasmtime's message and the guest's backtrace (function names and
  # offsets). Either is the call's failure in those words; any other
  # error, a missing export or a parameter the interface does not take, is
  # the component's interface. The server outlives all of them, and
  # `Locus.Runtime.TrapTest` holds the match to the library's exact words.
  # An exit of the call is the server ending under it (a kill, a crash);
  # it carries the call beside the reason, the guest's input with it, so
  # it leaves only as the fact that the instance ended.
  defp call_function(pid, call_name, json_input) do
    # Components (especially Catalysts) can make HTTP calls that take much longer
    # than the default 5s GenServer.call timeout. The runner enforces its own
    # wall-clock timeout, so we use :infinity here to avoid double-timeout races.
    case Wasmex.Components.call_function(pid, call_name, [json_input], :infinity) do
      {:error, "Error during function excecution (" <> _ = message} -> {:trapped, message}
      {:error, "Error during function excecution: " <> _ = message} -> {:failed, message}
      answer -> answer
    end
  catch
    :exit, _reason ->
      :instance_ended
  end

  # The instance's server is gone already when it ended under its call.
  defp stop_instance(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end
end
