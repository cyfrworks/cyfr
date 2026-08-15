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

  Configure via options:

      Opus.Runtime.execute_component(wasm, input,
        max_memory_bytes: 32 * 1024 * 1024  # 32MB
      )

  See: https://github.com/tessi/wasmex
  """

  require Logger

  # Default resource limits for sandboxed execution. Spelled the same way as
  # every other statement of this cap (Sanctum.Limits, Sanctum.Authority), so
  # grepping the number finds all of them.
  # 64 MiB
  @default_max_memory_bytes 67_108_864

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
  - `:authority` - The `Sanctum.Authority` this execution runs under
  - `:authority_required` - Defaults to true: a nil `:authority` raises instead
    of executing (a WASM run always carries one; this is the final invariant
    guard). Pass `false` only for authority-free harness runs in tests.

  ## Examples

      iex> {:ok, result} =
      ...>   Opus.Runtime.execute_component(wasm_bytes, %{"a" => 5, "b" => 3},
      ...>     authority: authority
      ...>   )
      iex> result
      %{"sum" => 8}

  """
  @spec execute_component(binary(), map(), keyword()) ::
          {:ok, map()} | {:ok, map(), map()} | {:error, term()}
  def execute_component(wasm_bytes, input, opts \\ [])
      when is_binary(wasm_bytes) and is_map(input) do
    component_type = Keyword.get(opts, :component_type, :reagent)
    wasi_opts = Opus.ComponentType.wasi_options(component_type)

    preloaded_fields = Keyword.get(opts, :preloaded_fields, %{})
    component_ref = Keyword.get(opts, :component_ref)
    edge = Keyword.get(opts, :edge)
    limits = Keyword.get(opts, :limits)
    ctx = Keyword.get(opts, :ctx)
    execution_id = Keyword.get(opts, :execution_id)
    root_execution_id = Keyword.get(opts, :root_execution_id)
    reference = Keyword.get(opts, :reference)
    digest = Keyword.get(opts, :digest)
    authority = Keyword.get(opts, :authority)
    declared_needs = Keyword.get(opts, :declared_needs)
    activation_digest = Keyword.get(opts, :activation_digest)

    # Second line of defense behind the executor's own check: if an opts
    # filter between the caller and here dropped :authority but kept the
    # requirement flag, the execution must die rather than run on ambient
    # permissions.
    if Keyword.get(opts, :authority_required, true) and is_nil(authority) do
      raise ArgumentError,
            "execution requires an authority but none reached the runtime " <>
              "(reference: #{inspect(reference)}) — an opts filter dropped it"
    end

    if authority do
      :telemetry.execute(
        [:opus, :runtime, :authority_entered],
        %{},
        %{
          authority: authority,
          execution_id: execution_id,
          reference: reference,
          plane: ctx && ctx.plane
        }
      )
    end

    max_memory = Keyword.get(opts, :max_memory_bytes, @default_max_memory_bytes)

    engine = Opus.SharedEngine.get()

    authority_info = %{
      authority: authority,
      declared_needs: declared_needs,
      activation_digest: activation_digest
    }

    # Build imports and collect cleanup refs
    {imports, cleanup_refs} =
      build_imports_and_cleanup(
        component_type,
        preloaded_fields,
        component_ref,
        edge,
        limits,
        ctx,
        execution_id,
        root_execution_id,
        authority_info
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
          component_result =
            if reference && digest do
              tenant_opts =
                if ctx,
                  do: [org_id: ctx.org_id, project_id: ctx.project_id],
                  else: []

              Opus.ComponentCache.get_or_compile(
                reference,
                digest,
                wasm_bytes,
                store,
                tenant_opts
              )
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
                    add_execution_metadata(result, %{})
                  rescue
                    e ->
                      GenServer.stop(pid, :normal)
                      {:error, Exception.message(e)}
                  end

                {:error, reason} ->
                  {:error, "Component instantiation failed: #{inspect(reason)}"}
              end

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

  # Build all host function imports and collect cleanup refs. The node's
  # limits are the presence signal for capability-scoped imports: they are
  # always carried under an authority, while the edge itself may be nil
  # (resources :none) — a nil edge builds the same imports with deny-all
  # resource lists, so a guest's host call fails with a denial instead of
  # a missing import.
  defp build_imports_and_cleanup(
         component_type,
         preloaded_fields,
         component_ref,
         edge,
         limits,
         ctx,
         execution_id,
         root_execution_id,
         authority_info
       ) do
    vault_imports =
      if component_type == :catalyst do
        build_vault_imports(preloaded_fields, component_ref)
      else
        %{}
      end

    http_imports =
      if component_type == :catalyst && limits && ctx do
        Opus.HttpHandler.build_http_imports(edge, limits, ctx, component_ref)
      else
        %{}
      end

    {stream_imports, stream_exec_ref} =
      if component_type == :catalyst && limits && ctx do
        Opus.HttpStreamHandler.build_stream_imports(edge, limits, ctx, component_ref)
      else
        {%{}, nil}
      end

    storage_imports =
      if component_type == :catalyst && limits && ctx do
        Opus.StorageHandler.build_storage_imports(
          edge,
          limits,
          ctx,
          component_ref,
          public_storage_opts(authority_info.authority)
        )
      else
        %{}
      end

    oauth_imports =
      if component_type == :catalyst && ctx do
        Opus.OAuthHandler.build_oauth_imports(
          ctx,
          component_ref,
          execution_id,
          oauth_resolver_opts(authority_info.authority, ctx)
        )
      else
        %{}
      end

    # Route emits to root execution's event buffer so nested formula events
    # reach the top-level SSE stream the UI is subscribed to
    root_execution_id = root_execution_id || execution_id

    {formula_imports, formula_tracker_pid} =
      if component_type == :formula && ctx && execution_id do
        Opus.FormulaHandler.build_formula_imports(ctx, execution_id,
          root_execution_id: root_execution_id,
          limits: limits,
          authority: authority_info.authority,
          declared_needs: authority_info.declared_needs,
          activation_digest: authority_info.activation_digest
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
      |> Map.merge(formula_imports)

    cleanup_refs = %{
      stream_exec_ref: stream_exec_ref,
      formula_tracker_pid: formula_tracker_pid,
      execution_id: execution_id
    }

    {all_imports, cleanup_refs}
  end

  # Under an authority, tokens come from the consent edge's vault resource
  # through the vault reader — the callee-keyed lookup is unreachable. An
  # authority execution without a vault edge resolves nothing, fail closed.
  # Public-profile storage rides explicit opts derived from the authority's
  # profile kind — never a flag a guest could influence.
  defp public_storage_opts(%Sanctum.Authority{profile_kind: :public}), do: [public?: true]
  defp public_storage_opts(_authority), do: []

  defp oauth_resolver_opts(%Sanctum.Authority{resources: resources}, ctx) do
    case resources do
      %Sanctum.Authority.Blob.Edge{vault: %{} = vault} ->
        [resolver: fn provider -> Sanctum.VaultReader.oauth_token(ctx, vault, provider) end]

      _ ->
        [resolver: fn _provider -> {:error, "no vault resource granted on this edge"} end]
    end
  end

  # Build secrets host functions for WASI import from pre-resolved secrets map.
  # The map is built once per execution by the Executor, so each get() is a
  # simple Map.get with no file I/O or PBKDF2 derivation.
  defp build_vault_imports(preloaded, component_ref) when is_map(preloaded) do
    %{
      "cyfr:vault/read@0.1.0" => %{
        "get" =>
          {:fn,
           fn name ->
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

                 Logger.warning(
                   "Field '#{name}' is outside the consent's projection for " <>
                     "'#{component_ref}'. Re-grant via the consent walk: " <>
                     "cyfr profile grant #{component_ref}"
                 )

                 {:error, "access-denied: #{name} not granted to #{component_ref}"}
             end
           end}
      }
    }
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
        # Components (especially Catalysts) can make HTTP calls that take much longer
        # than the default 5s GenServer.call timeout. The Executor enforces its own
        # wall-clock timeout, so we use :infinity here to avoid double-timeout races.
        case Wasmex.Components.call_function(pid, call_name, [json_input], :infinity) do
          {:ok, json_output} when is_binary(json_output) ->
            # Parse JSON output
            case Jason.decode(json_output) do
              {:ok, result} ->
                {:ok, result}

              {:error, decode_error} ->
                Logger.warning(
                  "[Opus.Runtime] Component output is not valid JSON: #{inspect(decode_error)}"
                )

                {:error,
                 "Component returned invalid JSON output: #{inspect(decode_error)}. Raw output (first 200 chars): #{String.slice(json_output, 0, 200)}"}
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

  # ===========================================================================
  # Execution Metadata Helpers
  # ===========================================================================

  # Wrap a successful result in the {:ok, output, metadata} shape the
  # executor consumes. The metadata map is currently empty — it is the seam
  # where real per-execution metrics ride when the engine can report them;
  # nothing is fabricated here.
  defp add_execution_metadata({:ok, output}, metadata) when is_map(metadata) do
    {:ok, output, metadata}
  end

  defp add_execution_metadata({:error, _} = error, _metadata), do: error
end
