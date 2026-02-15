defmodule Opus.Runtime do
  @moduledoc """
  WASM execution runtime using Wasmex (Wasmtime).

  Provides low-level WASM execution with sandboxing. This module wraps
  Wasmex's GenServer-based API to provide a consistent interface for Opus.

  ## Execution Model

  All components are executed via **WASI Preview 2 (Component Model)** using
  `Wasmex.Components.start_link/1` with `WasiP2Options`. Components must be
  compiled as WASI P2 Component Model binaries.

  ## Usage

      # Execute a raw WASM function
      {:ok, [42]} = Opus.Runtime.call_function(wasm_bytes, "sum", [20, 22])

      # Execute a component with JSON input/output
      {:ok, result} = Opus.Runtime.execute_component(wasm_bytes, %{"x" => 5})

  ## Sandboxing

  All executions run in isolated Wasmex instances with:
  - Memory limits (configurable, default 64MB)
  - Fuel consumption for CPU limits (configurable, default 100M instructions)
  - No network access (Reagents) unless explicitly granted (Catalysts)

  ## Resource Limits

  Configure via options:

      Opus.Runtime.execute_component(wasm, input,
        max_memory_bytes: 32 * 1024 * 1024,  # 32MB
        fuel_limit: 50_000_000               # 50M instructions
      )

  ## WASI Trace Capture (Future Enhancement)

  The ExecutionRecord struct includes a `wasi_trace` field for forensic replay.
  Currently, Wasmex does not provide automatic WASI call tracing. However,
  tracing could be implemented by:

  1. Using `Wasmex.Pipe` to capture stdout/stderr output
  2. Overwriting WASI functions with tracing wrappers via imports
  3. Using a tracing agent to collect calls during execution

  For now, the `wasi_trace` field remains nil. Reagents and Formulas never
  produce traces (no WASI access). Catalyst traces will be populated when
  tracing infrastructure is implemented.

  See: https://github.com/tessi/wasmex
  """

  require Logger

  # Default resource limits for sandboxed execution
  @default_max_memory_bytes 64 * 1024 * 1024  # 64MB
  @default_fuel_limit 100_000_000              # 100M instructions (most execute in <1M)
  # Note: timeout functionality would require Task.async with timeout - reserved for future

  @doc """
  Execute a raw WASM function by name with the given arguments.

  Returns `{:ok, results}` where results is a list of return values,
  or `{:error, reason}` on failure.

  ## Examples

      iex> wasm_bytes = File.read!("sum.wasm")
      iex> Opus.Runtime.call_function(wasm_bytes, "sum", [5, 3])
      {:ok, [8]}

  """
  @spec call_function(binary(), String.t(), list(), keyword()) :: {:ok, list()} | {:error, term()}
  def call_function(wasm_bytes, function_name, args, _opts \\ []) when is_binary(wasm_bytes) do
    # Start a Wasmex instance for this execution
    try do
      case Wasmex.start_link(%{bytes: wasm_bytes}) do
        {:ok, pid} ->
          try do
            result = Wasmex.call_function(pid, function_name, args)
            GenServer.stop(pid, :normal)
            result
          rescue
            e ->
              GenServer.stop(pid, :normal)
              {:error, Exception.message(e)}
          end

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @doc """
  Execute a WASM component with JSON input, returning JSON output.

  This is the high-level API for component execution. It:
  1. Starts a Wasmex instance with appropriate WASI configuration
  2. Detects available exported functions
  3. Calls with appropriate convention

  ## Options

  - `:component_type` - One of `:reagent`, `:catalyst`, `:formula`. Defaults to `:reagent`.
    - `:reagent` - No WASI (pure sandboxed compute, no I/O)
    - `:catalyst` - WASI enabled (HTTP, filesystem access per Host Policy)
    - `:formula` - No WASI (composition happens at Opus level)

  ## Input/Output Convention

  Components should export one of:
  - `sum(a, b) -> result` - Simple arithmetic (for testing)
  - `process(x) -> y` - Single value transformation
  - `run(ptr, len) -> ptr` - JSON input/output (advanced)

  ## Examples

      iex> {:ok, result} = Opus.Runtime.execute_component(wasm_bytes, %{"a" => 5, "b" => 3})
      iex> result
      %{"sum" => 8}

      iex> {:ok, result} = Opus.Runtime.execute_component(wasm_bytes, %{}, component_type: :catalyst)

  """
  @spec execute_component(binary(), map(), keyword()) :: {:ok, map()} | {:ok, map(), map()} | {:error, term()}
  def execute_component(wasm_bytes, input, opts \\ []) when is_binary(wasm_bytes) and is_map(input) do
    component_type = Keyword.get(opts, :component_type, :reagent)
    wasi_env = Keyword.get(opts, :wasi_env, %{})
    wasi_opts = Opus.ComponentType.wasi_options(component_type, wasi_env)

    # Extract pre-resolved secrets map and component ref for WASI host function
    preloaded_secrets = Keyword.get(opts, :preloaded_secrets, %{})
    component_ref = Keyword.get(opts, :component_ref)

    # Extract policy and context for HTTP host function imports
    policy = Keyword.get(opts, :policy)
    ctx = Keyword.get(opts, :ctx)

    # Extract execution_id for formula handler
    execution_id = Keyword.get(opts, :execution_id)

    # Extract resource limits from options
    max_memory = Keyword.get(opts, :max_memory_bytes, @default_max_memory_bytes)
    fuel_limit = Keyword.get(opts, :fuel_limit, @default_fuel_limit)

    # Build engine with fuel consumption enabled
    engine_result = build_engine_with_fuel(fuel_limit > 0)

    case engine_result do
      {:ok, engine} ->
        # Build start opts with limits, secrets imports, HTTP imports, and formula imports
        start_opts = build_start_opts_with_limits(wasm_bytes, wasi_opts, engine, max_memory, fuel_limit, preloaded_secrets, component_ref, policy, ctx, component_type, execution_id)

        # Try Component Model first (WASI P2)
        case Wasmex.Components.start_link(start_opts) do
          {:ok, pid} ->
            try do
              result = execute_with_convention(pid, input, component_type: component_type)
              GenServer.stop(pid, :normal)
              # Component Model doesn't expose memory size, return 0
              add_execution_metadata(result, %{memory_bytes: 0})
            rescue
              e ->
                GenServer.stop(pid, :normal)
                {:error, Exception.message(e)}
            end

          {:error, reason} ->
            {:error, "Component Model load failed: #{inspect(reason)}. " <>
              "Ensure the component is compiled as a WASI P2 Component Model binary."}
        end

      {:error, reason} ->
        {:error, "Failed to create WASM engine: #{inspect(reason)}"}
    end
  end

  # Deprecated: Core module execution is a backwards-compatibility fallback.
  # New components should use the WASI P2 Component Model path via
  # execute_component/3, which tries Component Model first and falls back
  # to this function automatically.
  @doc false
  @spec execute_core_module(binary(), map(), keyword()) :: {:ok, map()} | {:ok, map(), map()} | {:error, term()}
  def execute_core_module(wasm_bytes, input, opts \\ []) when is_binary(wasm_bytes) and is_map(input) do
    # Extract resource limits from options
    max_memory = Keyword.get(opts, :max_memory_bytes, @default_max_memory_bytes)
    fuel_limit = Keyword.get(opts, :fuel_limit, @default_fuel_limit)

    # Build store limits
    store_limits = %Wasmex.StoreLimits{
      memory_size: max_memory,
      instances: 10,
      tables: 100,
      memories: 10
    }

    # Build engine with fuel consumption enabled (same as Component Model path)
    case build_engine_with_fuel(fuel_limit > 0) do
      {:ok, engine} ->
        start_opts = %{
          bytes: wasm_bytes,
          engine: engine,
          store_limits: store_limits
        }

        case Wasmex.start_link(start_opts) do
          {:ok, pid} ->
            try do
              # Set fuel limit on the store to enforce CPU bounds
              if fuel_limit > 0 do
                {:ok, store} = Wasmex.store(pid)
                Wasmex.StoreOrCaller.set_fuel(store, fuel_limit)
              end

              result = execute_core_with_convention(pid, input)
              # Get memory usage for core modules where available
              memory_bytes = get_memory_size(pid)
              GenServer.stop(pid, :normal)
              add_execution_metadata(result, %{memory_bytes: memory_bytes})
            rescue
              e ->
                GenServer.stop(pid, :normal)
                {:error, Exception.message(e)}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, "Failed to create WASM engine: #{inspect(reason)}"}
    end
  end

  # Build Engine with fuel consumption enabled
  defp build_engine_with_fuel(true) do
    config = %Wasmex.EngineConfig{consume_fuel: true}
    Wasmex.Engine.new(config)
  end
  
  defp build_engine_with_fuel(false) do
    # No fuel - use default engine
    Wasmex.Engine.new(%Wasmex.EngineConfig{})
  end

  # Build Wasmex start options for Component Model execution with limits
  defp build_start_opts_with_limits(wasm_bytes, wasi_opts, engine, max_memory, _fuel_limit, preloaded_secrets, component_ref, policy, ctx, component_type, execution_id) do
    # Build secrets imports from pre-resolved map — only for Catalysts.
    # Reagents and Formulas are pure compute and never receive secrets imports.
    secrets_imports = if component_type == :catalyst do
      build_secrets_imports(preloaded_secrets, component_ref)
    else
      %{}
    end

    # Build HTTP host function imports — only for Catalysts with policy
    http_imports = if component_type == :catalyst && policy && ctx do
      Opus.HttpHandler.build_http_imports(policy, ctx, component_ref)
    else
      %{}
    end

    # Build streaming HTTP imports — only for Catalysts with policy
    stream_imports = if component_type == :catalyst && policy && ctx do
      Opus.HttpStreamHandler.build_stream_imports(policy, ctx, component_ref)
    else
      %{}
    end

    # Build formula invoke imports — only for Formulas with context
    formula_imports = if component_type == :formula && ctx && execution_id do
      Opus.FormulaHandler.build_formula_imports(ctx, execution_id)
    else
      %{}
    end

    # Build MCP tool imports — only for Formulas with non-empty allowed_tools
    mcp_imports = if component_type == :formula && policy && ctx && execution_id &&
                       policy.allowed_tools != [] do
      Opus.McpHandler.build_mcp_imports(policy, ctx, execution_id)
    else
      %{}
    end

    # Merge all imports
    all_imports = secrets_imports |> Map.merge(http_imports) |> Map.merge(stream_imports) |> Map.merge(formula_imports) |> Map.merge(mcp_imports)

    store_limits = %Wasmex.StoreLimits{
      memory_size: max_memory,
      instances: 10,
      tables: 100,
      memories: 10
    }

    base_opts = %{
      bytes: wasm_bytes,
      engine: engine,
      store_limits: store_limits
    }

    # Add imports if we have any host functions configured
    base_opts = if map_size(all_imports) > 0 do
      Map.put(base_opts, :imports, all_imports)
    else
      base_opts
    end

    # Add WASI options if provided (for Catalysts)
    case wasi_opts do
      nil -> base_opts
      %Wasmex.Wasi.WasiP2Options{} = wasi -> Map.put(base_opts, :wasi, wasi)
    end
  end

  # Build secrets host functions for WASI import from pre-resolved secrets map.
  # The map is built once per execution by the Executor, so each get() is a
  # simple Map.get with no file I/O or PBKDF2 derivation.
  defp build_secrets_imports(preloaded, component_ref) when is_map(preloaded) do
    %{
      "cyfr:secrets/read@0.1.0" => %{
        "get" => {:fn, fn name ->
          case Map.fetch(preloaded, name) do
            {:ok, value} ->
              :telemetry.execute(
                [:cyfr, :opus, :secret, :accessed],
                %{system_time: System.system_time()},
                %{secret_name: name, component_ref: component_ref}
              )
              {:ok, value}
            :error ->
              :telemetry.execute(
                [:cyfr, :opus, :secret, :denied],
                %{system_time: System.system_time()},
                %{secret_name: name, component_ref: component_ref}
              )
              Logger.warning("Secret '#{name}' not granted to component '#{component_ref}'. Grant with: cyfr secret grant #{component_ref} #{name}")
              {:error, "access-denied: #{name} not granted to #{component_ref}"}
          end
        end}
      }
    }
  end

  @doc """
  List exported functions from a WASM module.

  Useful for introspection and validation.
  """
  @spec list_exports(binary()) :: {:ok, [String.t()]} | {:error, term()}
  def list_exports(wasm_bytes) when is_binary(wasm_bytes) do
    try do
      case Wasmex.start_link(%{bytes: wasm_bytes}) do
        {:ok, pid} ->
          try do
            # Check for known functions
            known_functions = ["sum", "add", "multiply", "process", "run", "main", "alloc", "dealloc"]
            
            exports =
              known_functions
              |> Enum.filter(fn name -> Wasmex.function_exists(pid, name) end)
            
            GenServer.stop(pid, :normal)
            {:ok, exports}
          rescue
            e ->
              GenServer.stop(pid, :normal)
              {:error, Exception.message(e)}
          end

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @doc """
  Validate that a WASM binary is well-formed.

  Returns `:ok` if valid, `{:error, reason}` otherwise.
  """
  @spec validate(binary()) :: :ok | {:error, term()}
  def validate(wasm_bytes) when is_binary(wasm_bytes) do
    try do
      case Wasmex.start_link(%{bytes: wasm_bytes}) do
        {:ok, pid} ->
          GenServer.stop(pid, :normal)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
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
    json_input = Jason.encode!(input)

    # Components (especially Catalysts) can make HTTP calls that take much longer
    # than the default 5s GenServer.call timeout. The Executor enforces its own
    # wall-clock timeout, so we use :infinity here to avoid double-timeout races.
    case Wasmex.Components.call_function(pid, call_name, [json_input], :infinity) do
      {:ok, json_output} when is_binary(json_output) ->
        # Parse JSON output
        case Jason.decode(json_output) do
          {:ok, result} -> {:ok, result}
          {:error, _} -> {:ok, %{"raw" => json_output}}
        end

      {:ok, result} ->
        {:ok, %{"result" => result}}

      {:error, reason} ->
        # If JSON convention fails, fallback to simple convention.
        # WARNING: simple convention strips all non-integer arguments.
        function_name = List.last(call_name)
        Logger.warning("[Opus.Runtime] JSON convention failed for #{inspect(call_name)}: #{inspect(reason)}. " <>
          "Falling back to simple convention (non-integer arguments will be dropped). " <>
          "If unexpected, ensure the component exports the correct WIT interface.")
        execute_simple_convention(pid, function_name, input)
    end
  end

  # Convention for core WASM modules (non-Component)
  #
  # DEPRECATED: Heuristic function dispatch based on input key names.
  # The {a,b}->sum, {x,y}->multiply conventions are kept for backwards compatibility
  # with test WASM modules. New components should use the Component Model with
  # `run(string) -> string` JSON convention.
  #
  # Note: The fallback branch uses Enum.sort on Map.keys to ensure deterministic
  # argument ordering (Map.values/1 has non-deterministic order in Elixir).
  defp execute_core_with_convention(pid, input) do
    cond do
      # If we have "a" and "b" keys with integers, try sum/add
      has_numeric_keys?(input, ["a", "b"]) ->
        a = get_numeric(input, "a", 0)
        b = get_numeric(input, "b", 0)

        if Wasmex.function_exists(pid, "sum") do
          call_and_wrap(pid, "sum", [a, b])
        else
          call_and_wrap(pid, "add", [a, b])
        end

      # If we have "x" and "y" keys, try multiply or add
      has_numeric_keys?(input, ["x", "y"]) ->
        x = get_numeric(input, "x", 0)
        y = get_numeric(input, "y", 0)

        if Wasmex.function_exists(pid, "multiply") do
          call_and_wrap(pid, "multiply", [x, y])
        else
          call_and_wrap(pid, "add", [x, y])
        end

      # Try "run" or "main" with integer values sorted by key name (deterministic)
      true ->
        args = input
               |> Enum.sort_by(fn {k, _v} -> k end)
               |> Enum.map(fn {_k, v} -> v end)
               |> Enum.filter(&is_integer/1)
               |> Enum.take(10)

        if Wasmex.function_exists(pid, "run") do
          call_and_wrap(pid, "run", args)
        else
          call_and_wrap(pid, "main", args)
        end
    end
  end

  defp has_numeric_keys?(input, keys) do
    Enum.all?(keys, fn key ->
      case Map.get(input, key) do
        val when is_integer(val) -> true
        val when is_float(val) -> true
        _ -> false
      end
    end)
  end

  defp get_numeric(input, key, default) do
    case Map.get(input, key) do
      val when is_integer(val) -> val
      val when is_float(val) -> trunc(val)
      _ -> default
    end
  end

  defp call_and_wrap(pid, function_name, args) do
    case Wasmex.call_function(pid, function_name, args) do
      {:ok, [result]} ->
        {:ok, %{"result" => result}}

      {:ok, results} when is_list(results) ->
        {:ok, %{"result" => List.first(results)}}

      {:ok, result} ->
        {:ok, %{"result" => result}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Simple convention for Components: pass integer values from input map
  # Values are sorted by key name for deterministic argument ordering.
  defp execute_simple_convention(pid, function_name, input) do
    args =
      input
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map(fn {_k, v} -> v end)
      |> Enum.filter(&is_integer/1)
      |> Enum.take(10)

    case Wasmex.Components.call_function(pid, function_name, args) do
      {:ok, [result]} ->
        {:ok, %{"result" => result}}

      {:ok, results} when is_list(results) ->
        {:ok, %{"result" => List.first(results) || results}}

      # Components return result on success, or raises
      {:ok, result} ->
        {:ok, %{"result" => result}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ===========================================================================
  # Execution Metadata Helpers
  # ===========================================================================

  # Get memory size from a running Wasmex instance (core modules only)
  defp get_memory_size(pid) do
    try do
      case Wasmex.Memory.from_instance(pid, "memory") do
        {:ok, memory} ->
          case Wasmex.Memory.size(pid, memory) do
            {:ok, size} -> size
            _ -> 0
          end
        _ -> 0
      end
    rescue
      e ->
        Logger.debug("[Opus.Runtime] Could not read WASM memory size: #{Exception.message(e)}. " <>
          "Component Model binaries do not expose linear memory; reporting 0.")
        0
    end
  end

  # Add execution metadata to a successful result
  # Returns {:ok, output, metadata} format for callers that want metrics
  defp add_execution_metadata({:ok, output}, metadata) when is_map(metadata) do
    {:ok, output, metadata}
  end

  defp add_execution_metadata({:error, _} = error, _metadata), do: error

  # ===========================================================================
  # Test Helper — exposes import-building logic for testing secret gating
  # ===========================================================================

  defmodule TestHelper do
    @moduledoc false

    @doc """
    Build the imports map for a given component type, exposing the
    secret-gating logic for test assertions.
    """
    def build_imports(component_type, preloaded_secrets, component_ref) do
      secrets_imports = if component_type == :catalyst do
        Opus.Runtime.build_secrets_imports_for_test(preloaded_secrets, component_ref)
      else
        %{}
      end

      secrets_imports
    end
  end

  @doc false
  def build_secrets_imports_for_test(preloaded, component_ref) do
    build_secrets_imports(preloaded, component_ref)
  end
end
