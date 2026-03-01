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

  Configure via options:

      Opus.Runtime.execute_component(wasm, input,
        max_memory_bytes: 32 * 1024 * 1024  # 32MB
      )

  See: https://github.com/tessi/wasmex
  """

  require Logger

  # Default resource limits for sandboxed execution
  @default_max_memory_bytes 64 * 1024 * 1024  # 64MB

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

  Uses the shared engine from `Opus.SharedEngine` and caches compiled
  components via `Opus.ComponentCache`. Stores are built explicitly with
  the shared engine.

  ## Options

  - `:component_type` - One of `:reagent`, `:catalyst`, `:formula`. Defaults to `:reagent`.
  - `:reference` - Component reference string (for cache keying)
  - `:digest` - Content digest (for cache validation)
  - `:max_memory_bytes` - Memory limit. Defaults to 64MB.

  ## Examples

      iex> {:ok, result} = Opus.Runtime.execute_component(wasm_bytes, %{"a" => 5, "b" => 3})
      iex> result
      %{"sum" => 8}

  """
  @spec execute_component(binary(), map(), keyword()) :: {:ok, map()} | {:ok, map(), map()} | {:error, term()}
  def execute_component(wasm_bytes, input, opts \\ []) when is_binary(wasm_bytes) and is_map(input) do
    component_type = Keyword.get(opts, :component_type, :reagent)
    wasi_env = Keyword.get(opts, :wasi_env, %{})
    wasi_opts = Opus.ComponentType.wasi_options(component_type, wasi_env)

    preloaded_secrets = Keyword.get(opts, :preloaded_secrets, %{})
    component_ref = Keyword.get(opts, :component_ref)
    policy = Keyword.get(opts, :policy)
    ctx = Keyword.get(opts, :ctx)
    execution_id = Keyword.get(opts, :execution_id)
    reference = Keyword.get(opts, :reference)
    digest = Keyword.get(opts, :digest)

    max_memory = Keyword.get(opts, :max_memory_bytes, @default_max_memory_bytes)

    engine = Opus.SharedEngine.get()

    # Build imports and collect cleanup refs
    {imports, cleanup_refs} = build_imports_and_cleanup(
      component_type, preloaded_secrets, component_ref, policy, ctx, execution_id
    )

    # Notify caller of cleanup_refs so they can clean up on timeout kill
    case Keyword.get(opts, :notify_cleanup_refs) do
      {pid, ref} -> send(pid, {:cleanup_refs, ref, cleanup_refs})
      nil -> :ok
    end

    try do
      # Build store explicitly with our shared engine (fixes fuel bug)
      store_limits = %Wasmex.StoreLimits{
        memory_size: max_memory,
        instances: 10,
        tables: 100,
        memories: 10
      }

      store_result = case wasi_opts do
        nil -> Wasmex.Components.Store.new(store_limits, engine)
        %Wasmex.Wasi.WasiP2Options{} = wasi -> Wasmex.Components.Store.new_wasi(wasi, store_limits, engine)
      end

      case store_result do
        {:ok, store} ->
          # Get or compile the component (cache hit skips JIT)
          component_result = if reference && digest do
            Opus.ComponentCache.get_or_compile(reference, digest, wasm_bytes, store)
          else
            Wasmex.Components.Component.new(store, wasm_bytes)
          end

          case component_result do
            {:ok, component} ->
              # Start GenServer directly with pre-built store + component
              case GenServer.start_link(
                Wasmex.Components,
                %{store: store, component: component, imports: imports}
              ) do
                {:ok, pid} ->
                  try do
                    result = execute_with_convention(pid, input, component_type: component_type)
                    GenServer.stop(pid, :normal)
                    add_execution_metadata(result, %{memory_bytes: 0})
                  rescue
                    e ->
                      GenServer.stop(pid, :normal)
                      {:error, Exception.message(e)}
                  end

                {:error, reason} ->
                  {:error, "Component instantiation failed: #{inspect(reason)}"}
              end

            {:error, reason} ->
              {:error, "Component compilation failed: #{inspect(reason)}. " <>
                "Ensure the component is compiled as a WASI P2 Component Model binary."}
          end

        {:error, reason} ->
          {:error, "Failed to create WASM store: #{inspect(reason)}"}
      end
    after
      if cleanup_refs.stream_exec_ref, do: Opus.HttpStreamHandler.cleanup_registry(cleanup_refs.stream_exec_ref)
      if cleanup_refs.formula_tracker_pid, do: Opus.FormulaHandler.cleanup_registry(cleanup_refs.formula_tracker_pid)
    end
  end

  # Build all host function imports and collect cleanup refs
  defp build_imports_and_cleanup(component_type, preloaded_secrets, component_ref, policy, ctx, execution_id) do
    secrets_imports = if component_type == :catalyst do
      build_secrets_imports(preloaded_secrets, component_ref)
    else
      %{}
    end

    http_imports = if component_type == :catalyst && policy && ctx do
      Opus.HttpHandler.build_http_imports(policy, ctx, component_ref)
    else
      %{}
    end

    {stream_imports, stream_exec_ref} = if component_type == :catalyst && policy && ctx do
      Opus.HttpStreamHandler.build_stream_imports(policy, ctx, component_ref)
    else
      {%{}, nil}
    end

    {formula_imports, formula_tracker_pid} = if component_type == :formula && ctx && execution_id do
      Opus.FormulaHandler.build_formula_imports(ctx, execution_id, policy)
    else
      {%{}, nil}
    end

    mcp_imports = if component_type == :formula && ctx && execution_id do
      policy_or_default = policy || %Sanctum.Policy{}
      Opus.McpHandler.build_mcp_imports(policy_or_default, ctx, execution_id)
    else
      %{}
    end

    all_imports = secrets_imports
      |> Map.merge(http_imports)
      |> Map.merge(stream_imports)
      |> Map.merge(formula_imports)
      |> Map.merge(mcp_imports)

    cleanup_refs = %{stream_exec_ref: stream_exec_ref, formula_tracker_pid: formula_tracker_pid}
    {all_imports, cleanup_refs}
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
