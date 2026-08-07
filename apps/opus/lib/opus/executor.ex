# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Executor do
  @moduledoc """
  High-level execution facade for WASM components.

  This module provides a simplified API for executing WASM components,
  handling reference resolution, signature verification, telemetry,
  and crash-resilient record keeping.

  ## Usage

      ctx = Sanctum.TestContext.local()
      reference = "reagent:local.my-tool:0.1.0"
      input = %{"a" => 5, "b" => 10}

      {:ok, result} = Opus.Executor.run(ctx, reference, input)
      # result contains: output, execution_id, duration_ms, etc.

  ## Component Types

  - `:reagent` (default) - Pure sandboxed compute, no I/O
  - `:catalyst` - WASI enabled with HTTP/filesystem access
  - `:formula` - Composition of other components

  ## References

  Components are resolved by name from the local Compendium registry.
  All components must be registered (`cyfr register`) or pulled
  (`cyfr pull`) before execution.
  """

  require Logger

  alias Sanctum.Context
  alias Sanctum.Policy.Enforcement
  alias Opus.ExecutionRecord
  alias Opus.ExecutionEventBuffer
  alias Opus.ExecutionPipeline

  # Default timeouts per component type
  @default_timeout_ms %{catalyst: 180_000, formula: 300_000, reagent: 60_000}

  @doc """
  Execute a WASM component with the given input.

  ## Parameters

  - `ctx` - Sanctum execution context
  - `reference` - Component reference string (e.g., "catalyst:local.claude:0.2.0")
  - `input` - Input data map to pass to the component
  - `opts` - Execution options

  ## Options

  - `:type` - Component type: `:catalyst`, `:reagent`, or `:formula`. Defaults to `:reagent`.
  - `:verify` - Optional verification requirements: `%{identity: string, issuer: string}`
  - `:max_memory_bytes` - Memory limit for execution. Defaults to 64MB.
  - `:fuel_limit` - Fuel limit for CPU time. Defaults to 100M instructions.

  ## Returns

  - `{:ok, result}` - Execution succeeded with result map
  - `{:error, reason}` - Execution failed with error message
  """
  @spec run(Context.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(%Context{} = ctx, reference, input, opts \\ [])
      when is_binary(reference) and is_map(input) do
    # Ensure request_id exists — MCP callers already have one from ToolRegistry,
    # but direct callers (tincture invoke, cron, etc.) may not.
    ctx = if ctx.request_id, do: ctx, else: %{ctx | request_id: Emissary.UUID7.request_id()}

    # Resolve flexible refs (version-less) to pinned refs before execution.
    # The executor always works with exact-version references.
    case Compendium.Resolver.resolve(ctx, reference) do
      {:ok, pinned, %{was_resolved: true} = meta} ->
        do_execute(
          ctx,
          pinned,
          reference,
          input,
          Keyword.put(opts, :resolver_digest, meta[:digest])
        )

      {:ok, pinned, _metadata} ->
        do_execute(ctx, pinned, nil, input, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_execute(ctx, resolved_reference, resolved_from, input, opts) do
    case inspect_component(ctx, resolved_reference) do
      {:ok, component_ref, extracted_type, component} ->
        raw_type = extracted_type || opts[:type]

        case parse_component_type(raw_type) do
          {:ok, component_type} ->
            opts =
              if resolved_from, do: Keyword.put(opts, :resolved_from, resolved_from), else: opts

            do_run(ctx, resolved_reference, input, opts, component_type, component_ref, component)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_run(ctx, reference, input, opts, component_type, component_ref, component) do
    # Create initial execution record
    record_opts = [
      component_type: component_type,
      parent_execution_id: opts[:parent_execution_id]
    ]

    record_opts =
      if opts[:execution_id],
        do: [{:execution_id, opts[:execution_id]} | record_opts],
        else: record_opts

    record = ExecutionRecord.new(ctx, reference, input, record_opts)

    record =
      if opts[:resolved_from], do: %{record | resolved_from: opts[:resolved_from]}, else: record

    record =
      if opts[:resolver_digest],
        do: %{record | resolver_digest: opts[:resolver_digest]},
        else: record

    record = stamp_activation(record, ctx, component, opts)

    p = %ExecutionPipeline{
      ctx: ctx,
      reference: reference,
      component: component,
      component_ref: component_ref,
      component_type: component_type,
      record: record,
      started_written: :atomics.new(1, signed: false),
      opts: opts
    }

    try do
      with {:ok, p} <- stage_enforce_policy(p, input),
           {:ok, p, wasm_bytes} <- stage_fetch_and_verify(p),
           {:ok, p} <- stage_record_start(p),
           {:ok, p} <- stage_resolve_secrets(p),
           {:ok, p} <- stage_resolve_oauth(p),
           {:ok, p, output, exec_metadata} <- stage_execute(p, wasm_bytes, input) do
        finalize_execution(p, output, exec_metadata)
      else
        {:error, reason} when is_binary(reason) ->
          maybe_emit_setup_event(ctx, reason, opts)
          handle_failure(p.record, reason, p.started_written)

        {:error, reason} ->
          handle_failure(p.record, "Execution failed: #{inspect(reason)}", p.started_written)
      end
    rescue
      e ->
        handle_failure(p.record, "Execution error: #{Exception.message(e)}", p.started_written)
    end
  end

  # Record which code actually ran. Root executions carry the full node ->
  # release-digest map; a child's graph is a subgraph of its root's, so only
  # the digest is worth repeating there — and a child cannot be told its
  # root's activation over a channel the guest controls, so children stamp
  # nothing until the authority chain carries it.
  #
  # Best-effort by construction: an activation that cannot be resolved (a
  # component predating release digests, an uninstalled dependency) records
  # nothing rather than recording a partial graph, and never fails a run.
  defp stamp_activation(record, ctx, component, opts) do
    cond do
      # An authority-rooted execution already resolved and verified its
      # activation in the consent loader; re-resolving here could disagree
      # with what was authorized.
      stamp = opts[:activation_stamp] ->
        case Compendium.Activation.encode_graph(stamp.activation_graph) do
          {:ok, encoded} ->
            %{record | activation_digest: stamp.activation_digest, activation_graph: encoded}

          {:error, _} ->
            record
        end

      # A child under an authority carries its root's digest; its graph is a
      # subgraph of the root's and is not repeated.
      digest = opts[:activation_digest] ->
        %{record | activation_digest: digest}

      is_nil(opts[:parent_execution_id]) ->
        case Compendium.Activation.resolve(ctx, component) do
          {:ok, %{digest: digest, graph: graph}} ->
            case Compendium.Activation.encode_graph(graph) do
              {:ok, encoded} -> %{record | activation_digest: digest, activation_graph: encoded}
              {:error, _} -> record
            end

          {:error, _reason} ->
            record
        end

      true ->
        record
    end
  rescue
    e ->
      Logger.debug("[Opus.Executor] activation not recorded: #{Exception.message(e)}")
      record
  end

  # Stage 1: Policy enforcement, dependency checks, input validation, rate limiting
  defp stage_enforce_policy(%ExecutionPipeline{} = p, input) do
    case p.opts[:authority] do
      nil -> enforce_legacy_policy(p, input)
      %Sanctum.Authority{} = authority -> enforce_authority(p, authority, input)
    end
  end

  # Under an authority, capability was computed once at consent time and
  # frozen into the blob: limits come from the current node, resources from
  # the current edge, and the callee-keyed policy resolver is never
  # consulted. Static-dependency satisfaction was already proven by the
  # loader's all-or-nothing activation resolution.
  defp enforce_authority(%ExecutionPipeline{} = p, authority, input) do
    limits = Sanctum.Authority.limits(authority)
    shim_policy = Opus.AuthorityShim.policy_from_edge(authority)

    timeout_ms =
      case Sanctum.Limits.timeout_ms(limits) do
        {:ok, ms} -> ms
        {:error, _} -> Map.get(@default_timeout_ms, p.component_type, 60_000)
      end

    exec_opts = [
      component_type: p.component_type,
      timeout_ms: timeout_ms,
      max_memory_bytes: limits.max_memory_bytes,
      policy: shim_policy
    ]

    with {:ok, _input_json} <- validate_input_size(input, exec_opts, p.ctx, p.component_ref),
         :ok <- check_authority_rate_limit(p.ctx, p.component_ref, shim_policy) do
      Enforcement.record(%{
        ctx: p.ctx,
        component_ref: p.component_ref,
        component_type: p.component_type,
        event_type: :policy_consultation,
        decision: :allowed,
        execution_id: p.record.id,
        host_policy_snapshot: build_host_policy_snapshot(exec_opts)
      })

      {:ok, %{p | exec_opts: exec_opts, policy: shim_policy}}
    end
  end

  defp enforce_legacy_policy(%ExecutionPipeline{} = p, input) do
    with {:ok, exec_opts} <-
           Opus.PolicyEnforcer.build_execution_opts(p.ctx, p.component_ref, p.component_type),
         :ok <-
           check_dependency_satisfaction(p.ctx, p.component_type, p.component, p.component_ref),
         {:ok, _input_json} <- validate_input_size(input, exec_opts, p.ctx, p.component_ref),
         :ok <- check_rate_limit(p.ctx, p.component_ref, exec_opts) do
      # One consultation row per execution, capturing the policy snapshot that
      # allowed it. The execution row itself is persisted later (stage 3), so
      # execution_id here may not correspond to a stored execution if a later
      # stage fails — it is a plain string, never joined via FK.
      Enforcement.record(%{
        ctx: p.ctx,
        component_ref: p.component_ref,
        component_type: p.component_type,
        event_type: :policy_consultation,
        decision: :allowed,
        execution_id: p.record.id,
        host_policy_snapshot: build_host_policy_snapshot(exec_opts)
      })

      {:ok, %{p | exec_opts: exec_opts, policy: Keyword.get(exec_opts, :policy)}}
    end
  end

  # Stage 2: Fetch WASM bytes, compute digest, verify integrity + signature
  defp stage_fetch_and_verify(%ExecutionPipeline{} = p) do
    with {:ok, wasm_bytes} <- fetch_component_bytes(p.ctx, p.component),
         component_digest = compute_digest(wasm_bytes),
         :ok <- verify_integrity(p.component, component_digest, p.reference),
         host_policy = build_host_policy_snapshot(p.exec_opts),
         record = %{p.record | component_digest: component_digest, host_policy: host_policy},
         :ok <- maybe_verify_signature(p.reference, p.opts[:verify], p.component) do
      {:ok, %{p | record: record, component_digest: component_digest, host_policy: host_policy},
       wasm_bytes}
    end
  end

  # Stage 3: Write execution record and emit telemetry
  defp stage_record_start(%ExecutionPipeline{} = p) do
    with :ok <- ExecutionRecord.write_started(p.record) do
      :atomics.put(p.started_written, 1, 1)
      Opus.Telemetry.execute_start(p.record)
      {:ok, p}
    end
  end

  # Stage 4: Resolve secrets for the component.
  # Under an authority the callee-keyed grant plane is never consulted:
  # credentials come only from the consent edge (the vault reader), and
  # until that reader exists the closure receives nothing — an ungranted
  # secret read denies exactly as an empty resolution does today.
  defp stage_resolve_secrets(%ExecutionPipeline{} = p) do
    if p.opts[:authority] do
      {:ok, %{p | preloaded_secrets: %{}}}
    else
      with {:ok, preloaded_secrets} <- resolve_secrets(p.ctx, p.component_ref) do
        {:ok, %{p | preloaded_secrets: preloaded_secrets}}
      end
    end
  end

  # Stage 5: Resolve OAuth config from manifest (lightweight — no DB/network).
  # Same rule as secrets: authority executions get no callee-keyed OAuth.
  defp stage_resolve_oauth(%ExecutionPipeline{} = p) do
    if p.opts[:authority] do
      {:ok, p}
    else
      manifest = Compendium.Manifest.decode(p.component[:manifest] || p.component["manifest"])
      {:ok, %{p | oauth_config: Map.get(manifest, "oauth", %{})}}
    end
  end

  # Stage 6: Execute WASM with all accumulated state
  defp stage_execute(%ExecutionPipeline{} = p, wasm_bytes, input) do
    digest = p.component[:digest] || p.component["digest"]

    exec_opts_final =
      Keyword.merge(p.exec_opts,
        preloaded_secrets: p.preloaded_secrets,
        oauth_config: p.oauth_config,
        component_ref: p.component_ref,
        policy: p.policy,
        ctx: p.ctx,
        execution_id: p.record.id,
        root_execution_id: p.opts[:root_execution_id],
        reference: p.reference,
        digest: digest
      )

    with {:ok, {output, exec_metadata}} <-
           execute_wasm(wasm_bytes, input, exec_opts_final, p.opts) do
      {:ok, p, output, exec_metadata}
    end
  end

  # ===========================================================================
  # Finalization
  # ===========================================================================

  defp finalize_execution(%ExecutionPipeline{} = p, output, exec_metadata) do
    oauth_tokens = Opus.OAuthHandler.collect_dispensed(p.record.id)
    secret_values = Map.values(p.preloaded_secrets) ++ oauth_tokens
    masked_output = Opus.SecretMasker.mask(output, secret_values)

    with :ok <- check_application_error(p, masked_output),
         :ok <- check_response_size(p, masked_output) do
      completed_record = ExecutionRecord.complete(p.record, masked_output)

      audit_error =
        case ExecutionRecord.write_completed(completed_record) do
          :ok ->
            nil

          {:error, reason} ->
            Logger.error(
              "[Opus.Executor] Failed to write completed record #{completed_record.id}: #{inspect(reason)}. " <>
                "Audit trail is incomplete — this execution will appear as 'running' in logs."
            )

            :telemetry.execute(
              [:cyfr, :opus, :audit_error],
              %{system_time: System.system_time()},
              %{execution_id: completed_record.id, phase: :completed, reason: inspect(reason)}
            )

            inspect(reason)
        end

      Opus.Telemetry.execute_stop(completed_record, exec_metadata)

      Opus.ExecutionEventBuffer.push_terminal(
        completed_record.id,
        "complete",
        %{status: "completed", duration_ms: completed_record.duration_ms},
        999_999_999,
        completed_record
      )

      metadata = %{
        execution_id: completed_record.id,
        duration_ms: completed_record.duration_ms,
        component_type: p.component_type,
        component_digest: p.component_digest,
        user_id: p.ctx.user_id,
        reference: p.reference,
        policy_applied: p.host_policy,
        signature_verified: p.component["signature_verified"] || false
      }

      metadata =
        if completed_record.resolved_from,
          do: Map.put(metadata, :resolved_from, completed_record.resolved_from),
          else: metadata

      metadata =
        if completed_record.resolver_digest,
          do: Map.put(metadata, :resolver_digest, completed_record.resolver_digest),
          else: metadata

      result = %{
        status: :completed,
        output: output,
        metadata: metadata
      }

      result =
        if audit_error, do: put_in(result, [:metadata, :audit_error], audit_error), else: result

      cascade_children_failure(completed_record)

      {:ok, result}
    end
  end

  defp check_application_error(p, masked_output) do
    case detect_application_error(masked_output) do
      nil -> :ok
      error -> handle_failure(p.record, error, p.started_written)
    end
  end

  defp check_response_size(p, masked_output) do
    max_response = if p.policy, do: p.policy.max_response_size, else: 5_242_880

    case Jason.encode(masked_output) do
      {:ok, output_json} ->
        if byte_size(output_json) > max_response do
          handle_failure(
            p.record,
            "Output size (#{byte_size(output_json)} bytes) exceeds maximum (#{max_response} bytes)",
            p.started_written
          )
        else
          :ok
        end

      {:error, _} ->
        handle_failure(p.record, "Output could not be serialized to JSON", p.started_written)
    end
  end

  # Detect application-level errors in component output.
  # Returns error message string if output indicates failure, nil otherwise.
  defp detect_application_error(output) when is_map(output) do
    case output do
      %{"error" => %{"message" => msg}} when is_binary(msg) -> msg
      %{"error" => %{"message" => msg}} -> inspect(msg)
      %{"error" => msg} when is_binary(msg) -> msg
      %{"error" => err} when is_map(err) -> inspect(err)
      _ -> nil
    end
  end

  defp detect_application_error(_), do: nil

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  # Resolve a component reference string via Compendium.
  # Returns {:ok, component_ref, component_type, component_map}.
  # Results are cached for 5 minutes to avoid repeated lookups.
  # Public (undocumented) so Opus.Chain shares the same cache entries.
  @doc false
  def inspect_component(ctx, reference) do
    org_id = ctx.org_id
    project_id = ctx.project_id
    cache_key = {:component_meta, org_id, project_id, reference}

    case Arca.Cache.get(cache_key) do
      {:ok, cached} ->
        {:ok, cached["component_ref"], cached["type"], cached}

      :miss ->
        case Compendium.Component.inspect_component(ctx, reference) do
          {:ok, component} ->
            Arca.Cache.put(cache_key, component, :timer.minutes(5))
            {:ok, component["component_ref"], component["type"], component}

          {:error, reason} ->
            {:error, "Failed to resolve component '#{reference}': #{reason}"}
        end
    end
  end

  # Fetch WASM bytes from Compendium blob store using the digest from inspect.
  # Bytes are content-addressed by digest — immutable, no invalidation needed.
  # Cached for 10 minutes to avoid repeated lookups.
  defp fetch_component_bytes(ctx, component) do
    digest = component[:digest] || component["digest"]

    Logger.debug(
      "[fetch_component_bytes] digest=#{inspect(digest)}, component_keys=#{inspect(Map.keys(component))}"
    )

    cache_key = {:wasm_bytes, digest}

    case Arca.Cache.get(cache_key) do
      {:ok, bytes} ->
        {:ok, bytes}

      :miss ->
        case Compendium.Component.get_blob(ctx, digest) do
          {:ok, bytes} ->
            Arca.Cache.put(cache_key, bytes, :timer.minutes(10))
            {:ok, bytes}

          {:error, reason} ->
            {:error, "Failed to fetch component bytes: #{reason}"}
        end
    end
  end

  # Verify that fetched bytes match the digest from the registry.
  defp verify_integrity(component, actual_digest, reference) do
    expected_digest = component[:digest] || component["digest"]

    cond do
      is_nil(expected_digest) ->
        # No digest in registry — skip integrity check
        :ok

      actual_digest == "sha256:" <> expected_digest ->
        :ok

      actual_digest == expected_digest ->
        :ok

      true ->
        {:error,
         "Integrity check failed for #{reference}. " <>
           "Expected: #{expected_digest}, Got: #{actual_digest}. " <>
           "Component may have been modified. Re-register with `cyfr register`."}
    end
  end

  # Validate input size against policy limits.
  # Returns {:ok, encoded_json} on success so callers can reuse the encoded form.
  defp validate_input_size(input, exec_opts, ctx, component_ref) do
    policy = Keyword.get(exec_opts, :policy)
    max_size = if policy, do: policy.max_request_size, else: 1_048_576

    case Jason.encode(input) do
      {:ok, input_json} ->
        size = byte_size(input_json)

        if size > max_size do
          Enforcement.record(%{
            ctx: ctx,
            component_ref: component_ref,
            event_type: :request_size,
            decision: :denied,
            decision_reason: "input size #{size} bytes exceeds maximum #{max_size} bytes"
          })

          {:error, "Input size (#{size} bytes) exceeds maximum (#{max_size} bytes)"}
        else
          {:ok, input_json}
        end

      {:error, reason} ->
        {:error, "Input encoding failed: #{inspect(reason)}. Input must be JSON-serializable."}
    end
  end

  # Check that all required static dependencies are satisfied for formula components.
  # Non-formula types skip this check. Formulas with no static deps declared also pass
  # (supports dynamic-discovery pattern).
  defp check_dependency_satisfaction(_ctx, component_type, _component, _component_ref)
       when component_type != :formula,
       do: :ok

  defp check_dependency_satisfaction(_ctx, :formula, nil, _component_ref), do: :ok

  defp check_dependency_satisfaction(ctx, :formula, component, component_ref) do
    manifest = Compendium.Manifest.decode(component[:manifest] || component["manifest"])

    case Compendium.DependencyResolver.extract_from_manifest(manifest, component[:id] || "") do
      {:ok, []} ->
        :ok

      {:ok, deps} ->
        availability = Compendium.DependencyResolver.classify_availability(ctx, deps)

        if availability.all_satisfied do
          :ok
        else
          missing_refs = Enum.map(availability.missing, & &1[:dependency_ref])

          Enforcement.record(%{
            ctx: ctx,
            component_ref: component_ref,
            component_type: :formula,
            event_type: :dependency_unsatisfied,
            decision: :denied,
            decision_reason: "missing required dependencies: #{Enum.join(missing_refs, ", ")}"
          })

          {:error,
           "Missing required dependencies: #{Enum.join(missing_refs, ", ")}. " <>
             "Run 'cyfr pull <ref>' to resolve."}
        end

      {:error, reason} ->
        {:error, "Failed to parse formula dependencies: #{inspect(reason)}"}
    end
  end

  # The authority variant never re-resolves: the blob's node limits are the
  # policy. The limiter keys on {org, project, ref} either way, so buckets
  # are continuous across the cutover.
  defp check_authority_rate_limit(ctx, component_ref, shim_policy) do
    case Sanctum.Policy.check_rate_limit(shim_policy, ctx, component_ref) do
      {:ok, _remaining} ->
        :ok

      {:error, :rate_limited, retry_after} ->
        {:error, "Rate limit exceeded. Retry in #{div(retry_after, 1000)}s"}

      {:error, reason} ->
        {:error, "Rate limit check failed for #{component_ref}: #{inspect(reason)}."}
    end
  end

  defp check_rate_limit(ctx, component_ref, _exec_opts) do
    with {:ok, policy, _meta} <- Sanctum.Policy.get_effective(ctx, component_ref) do
      case Sanctum.Policy.check_rate_limit(policy, ctx, component_ref) do
        {:ok, _remaining} ->
          :ok

        {:error, :rate_limited, retry_after} ->
          {:error, "Rate limit exceeded. Retry in #{div(retry_after, 1000)}s"}

        {:error, reason} ->
          {:error,
           "Rate limit check failed for #{component_ref}: #{inspect(reason)}. Check policy configuration."}
      end
    else
      {:error, reason} ->
        {:error,
         "Rate limit check failed for #{component_ref}: #{inspect(reason)}. Check policy configuration."}
    end
  end

  # Resolve all granted secrets for a component into a map,
  # or return empty map if component_ref is unavailable (reagents without secrets).
  defp resolve_secrets(_ctx, nil), do: {:ok, %{}}

  defp resolve_secrets(ctx, component_ref) do
    case Sanctum.Secrets.resolve_granted_secrets(ctx, component_ref) do
      {:ok, %{secrets: secrets}} ->
        {:ok, secrets}

      {:error, {:partial_decrypt, failed}} ->
        {:error,
         "Failed to resolve #{length(failed)} secret(s) for #{component_ref}: #{Enum.join(failed, ", ")}. " <>
           "Grant access with: cyfr secret grant <secret-name> #{component_ref}"}

      {:error, reason} ->
        {:error, "Failed to resolve secrets: #{inspect(reason)}"}
    end
  end

  defp parse_component_type(nil) do
    Logger.warning("[Opus.Executor] No component type specified, defaulting to :reagent")
    {:ok, :reagent}
  end

  defp parse_component_type(type) when is_atom(type) do
    if Opus.ComponentType.valid?(type) do
      {:ok, type}
    else
      {:error,
       "Invalid component type: #{inspect(type)}. Must be one of: catalyst, reagent, formula"}
    end
  end

  defp parse_component_type(type) when is_binary(type) do
    Opus.ComponentType.parse(type)
  end

  defp compute_digest(wasm_bytes) when is_binary(wasm_bytes) do
    hash = :crypto.hash(:sha256, wasm_bytes)
    hex = Base.encode16(hash, case: :lower)
    "sha256:#{hex}"
  end

  defp maybe_verify_signature(_reference, nil, _component), do: :ok

  defp maybe_verify_signature(_reference, verify, component) when is_map(verify) do
    identity = verify["identity"] || verify[:identity]
    issuer = verify["issuer"] || verify[:issuer]

    case Opus.SignatureVerifier.verify(component, identity, issuer) do
      :ok -> :ok
      {:error, reason} -> {:error, "Signature verification failed: #{reason}"}
    end
  end

  defp execute_wasm(wasm_bytes, input, exec_opts, opts) do
    component_type = Keyword.get(exec_opts, :component_type, :reagent)
    priority = if component_type == :catalyst, do: :normal, else: :high

    # An execution that declared it must run under an authority may never fall
    # back to ambient permissions. Checked before the semaphore so nothing is
    # consumed; the pipeline's rescue converts this into a failed execution
    # with the message intact.
    if Keyword.get(opts, :authority_required, Keyword.get(exec_opts, :authority_required, false)) and
         is_nil(Keyword.get(opts, :authority, Keyword.get(exec_opts, :authority))) do
      raise ArgumentError,
            "execution requires an authority but none was provided (reference: " <>
              "#{inspect(Keyword.get(exec_opts, :reference))})"
    end

    type_default = Map.get(@default_timeout_ms, component_type, 60_000)
    timeout_ms = exec_opts[:timeout_ms] || opts[:timeout_ms] || type_default
    semaphore_timeout = min(timeout_ms, 30_000)

    tenant =
      case exec_opts[:ctx] do
        %{org_id: org_id, project_id: project_id} -> {org_id, project_id}
        _ -> nil
      end

    case Opus.ExecutionSemaphore.acquire(semaphore_timeout, priority, tenant) do
      :ok ->
        registered? = register_execution(exec_opts)

        try do
          runtime_opts =
            exec_opts
            |> Keyword.merge(opts)
            |> Keyword.take([
              :component_type,
              :max_memory_bytes,
              :preloaded_secrets,
              :oauth_config,
              :component_ref,
              :policy,
              :ctx,
              :execution_id,
              :root_execution_id,
              :reference,
              :digest,
              # Dropping :authority here would silently strip a chain's granted
              # capabilities and run the guest on ambient permissions; the
              # runtime re-checks :authority_required so a partial drop still
              # fails closed.
              :authority,
              :authority_required
            ])

          # The plane flips exactly at the WASM boundary: pipeline stages ran
          # with the caller's external-plane context, but a context captured
          # into guest closures must never authorize an external-plane call
          # again. One-way; there is no inverse.
          runtime_opts =
            with auth when not is_nil(auth) <- runtime_opts[:authority],
                 %Sanctum.Context{} = c <- runtime_opts[:ctx] do
              Keyword.put(runtime_opts, :ctx, Sanctum.Context.enter_guest(c))
            else
              _ -> runtime_opts
            end

          execute_with_timeout(wasm_bytes, input, runtime_opts, timeout_ms)
        after
          Opus.ExecutionSemaphore.release()
          if registered?, do: Registry.unregister(Opus.ExecutionRegistry, execution_id(exec_opts))
        end

      {:error, :queue_full} ->
        {:error, "Server at maximum concurrent executions. Retry later."}

      {:error, :tenant_limit} ->
        {:error, "Workspace at maximum concurrent executions. Retry later."}
    end
  end

  # Every execution registers its driving process under its execution_id so
  # cancel/2 can actually kill it. run_stream and cron register their task
  # before calling into the executor (same process, so the second register
  # is a no-op here and they keep owning their entry); this covers the paths
  # that previously never registered — synchronous execution.run and every
  # formula child, which cancel could mark in the DB but not terminate.
  defp register_execution(exec_opts) do
    case execution_id(exec_opts) do
      nil ->
        false

      execution_id ->
        case Registry.register(Opus.ExecutionRegistry, execution_id, :running) do
          {:ok, _} -> true
          {:error, {:already_registered, _}} -> false
        end
    end
  end

  defp execution_id(exec_opts), do: Keyword.get(exec_opts, :execution_id)

  # Execute WASM with wall-clock timeout enforcement.
  # This ensures long-running or stuck executions are terminated.
  # Uses spawn-based execution to avoid crashes propagating to caller.
  # Returns {:ok, {output, metadata}} or {:error, reason}
  defp execute_with_timeout(wasm_bytes, input, runtime_opts, timeout_ms) do
    caller = self()
    ref = make_ref()
    start_time = System.monotonic_time(:millisecond)

    # Pass notify_cleanup_refs so Runtime sends us cleanup refs before executing.
    # On timeout kill, we use these to clean up orphaned Agent processes.
    runtime_opts_with_notify = Keyword.put(runtime_opts, :notify_cleanup_refs, {caller, ref})

    # Capture Logger metadata for propagation to spawned process
    logger_metadata = Cyfr.LoggerContext.capture()

    # Timeout mechanism: We use spawn_link (not spawn) deliberately.
    # If the spawned process crashes without sending the ref message,
    # the linked process EXIT signal propagates to the caller, which
    # is caught by the outer try/catch. This prevents indefinite hangs.
    # The outer `receive` has an `after timeout_ms` clause as the
    # primary timeout mechanism.
    pid =
      spawn_link(fn ->
        # Trap exits so that linked-process crashes (e.g. Wasmex GenServer dying
        # from a WASM trap) become messages instead of killing this process.
        # Without this, the `catch :exit` clause below never fires for link exits.
        Process.flag(:trap_exit, true)
        Cyfr.LoggerContext.restore(logger_metadata)

        result =
          try do
            Opus.Runtime.execute_component(wasm_bytes, input, runtime_opts_with_notify)
          rescue
            e -> {:error, Exception.message(e)}
          catch
            :exit, reason -> {:error, "Exit: #{inspect(reason)}"}
            kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
          end

        send(caller, {ref, result})
      end)

    # Collect cleanup_refs sent by Runtime early in setup (before WASM execution starts).
    # Use the full timeout — if setup itself takes this long, we should timeout anyway.
    cleanup_refs =
      receive do
        {:cleanup_refs, ^ref, refs} -> refs
      after
        timeout_ms -> nil
      end

    # Store tracker PID in ExecutionRegistry so cancel can clean up AsyncTracker.
    # Without this, cancelling a formula leaves child catalyst tasks running.
    if cleanup_refs[:formula_tracker_pid] do
      execution_id = Keyword.get(runtime_opts, :execution_id)

      if execution_id do
        Registry.update_value(Opus.ExecutionRegistry, execution_id, fn _ ->
          %{status: :running, tracker_pid: cleanup_refs.formula_tracker_pid}
        end)
      end
    end

    remaining_ms = max(timeout_ms - (System.monotonic_time(:millisecond) - start_time), 0)

    # If we consumed the full timeout waiting for cleanup_refs, kill immediately
    if is_nil(cleanup_refs) do
      # Unlink first so the :killed EXIT signal doesn't propagate back and
      # terminate this process before handle_failure can write the DB record.
      Process.unlink(pid)
      Process.exit(pid, :kill)
      {:error, "Execution timeout after #{timeout_ms}ms"}
    else
      receive do
        # Runtime.execute_component always returns 3-tuple {:ok, output, metadata}
        {^ref, {:ok, output, metadata}} ->
          {:ok, {output, metadata}}

        {^ref, {:error, _} = error} ->
          error
      after
        remaining_ms ->
          Process.unlink(pid)
          Process.exit(pid, :kill)
          # Clean up resources the dead process can't clean up
          if cleanup_refs[:stream_exec_ref],
            do: Opus.HttpStreamHandler.cleanup_registry(cleanup_refs.stream_exec_ref)

          if cleanup_refs[:formula_tracker_pid],
            do: Opus.FormulaHandler.cleanup_registry(cleanup_refs.formula_tracker_pid)

          Opus.OAuthHandler.collect_dispensed(cleanup_refs[:execution_id])

          {:error, "Execution timeout after #{timeout_ms}ms"}
      end
    end
  end

  # Emit a setup_required event on the parent execution's event stream
  # when a sub-execution fails due to a setup issue. This allows Prism/SSE
  # subscribers to see it even if FormulaHandler can't detect it.
  defp maybe_emit_setup_event(ctx, reason, opts) do
    target_id = opts[:root_execution_id] || opts[:parent_execution_id]

    if target_id do
      case Opus.Remediation.analyze(ctx, reason) do
        {:setup_required, remediation} ->
          Opus.ExecutionEventBuffer.push(
            target_id,
            %{
              "kind" => "setup_required",
              "component_ref" => remediation["component_ref"],
              "issues" => remediation["issues"],
              "setup_command" => remediation["setup_command"],
              "message" => reason
            },
            System.unique_integer([:positive]),
            ctx
          )

        :not_setup_error ->
          :ok
      end
    end
  end

  defp handle_failure(record, error_msg, started_written) do
    Opus.OAuthHandler.collect_dispensed(record.id)
    failed_record = ExecutionRecord.fail(record, error_msg)

    if :atomics.get(started_written, 1) == 0 do
      case ExecutionRecord.write_started(record) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "[Opus.Executor] Failed to write started record #{record.id}: #{inspect(reason)}. " <>
              "Audit trail is incomplete — this execution will not appear in logs."
          )
      end

      Opus.Telemetry.execute_start(record)
    end

    case ExecutionRecord.write_failed(failed_record) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Opus.Executor] Failed to write failed record #{record.id}: #{inspect(reason)}. " <>
            "Audit trail is incomplete — this execution will appear as 'running' in logs."
        )
    end

    Opus.Telemetry.execute_exception(failed_record, error_msg)

    # Push terminal error event so SSE/LiveView subscribers know execution failed
    Opus.ExecutionEventBuffer.push_terminal(
      record.id,
      "error",
      %{error: error_msg},
      999_999_999,
      record
    )

    cascade_children_failure(record)

    {:error, error_msg}
  end

  # Build a snapshot of the host policy for forensic replay.
  # This captures the policy that was enforced at execution time.
  @doc """
  Cancel a running execution by killing its process.

  Looks up the task PID in the ExecutionRegistry and kills it. The kill cascades
  to the inner WASM process (via spawn_link) and AsyncTracker (via OTP links).
  The semaphore auto-releases via its :DOWN monitor.
  """
  @spec cancel(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def cancel(%Context{} = ctx, execution_id) do
    # The tenant-scoped record cancel is the single authority for whether this
    # caller may cancel this execution: it enforces tenant ownership, the
    # authorize/3 chokepoint, and the ':running' precondition. It MUST succeed
    # before we touch the global, id-keyed process registry — otherwise a caller
    # could kill another tenant's execution just by knowing its id. (Same
    # authorize-before-act ordering the SSE read path uses.)
    case ExecutionRecord.cancel(ctx, execution_id) do
      {:ok, record} ->
        kill_running_process(execution_id)

        # Route with the record's own tenant coordinates (like every other
        # producer) — an org- or platform-scoped canceller may carry different
        # coordinates than the execution it just cancelled.
        ExecutionEventBuffer.push_terminal(
          execution_id,
          "cancelled",
          %{},
          System.unique_integer([:positive]),
          record
        )

        emit_cancel_telemetry(ctx, execution_id)
        cascade_children_failure_by_id(execution_id)
        {:ok, %{cancelled: true, execution_id: execution_id}}

      error ->
        error
    end
  end

  # Kill the running BEAM process for an execution (if one is still registered)
  # and tear down its async tracker so spawned child tasks die too. Only called
  # after the tenant-scoped cancel above has authorized the operation.
  defp kill_running_process(execution_id) do
    case Registry.lookup(Opus.ExecutionRegistry, execution_id) do
      [{pid, meta}] ->
        # Extract tracker PID before killing — needed to stop child tasks.
        tracker_pid = if is_map(meta), do: meta[:tracker_pid], else: nil

        Process.exit(pid, :kill)

        # Clean up AsyncTracker → stops Task.Supervisor → kills spawned child tasks.
        # Without this, child catalyst executions survive the parent's cancellation
        # because they're spawned via async_nolink (not linked to the parent).
        if is_pid(tracker_pid) and Process.alive?(tracker_pid) do
          Opus.FormulaHandler.cleanup_registry(tracker_pid)
        end

        :ok

      [] ->
        :ok
    end
  end

  defp emit_cancel_telemetry(ctx, execution_id) do
    :telemetry.execute(
      [:cyfr, :opus, :execute, :exception],
      %{duration: 0, system_time: System.system_time()},
      %{execution_id: execution_id, user_id: ctx.user_id, error: "cancelled", status: :cancelled}
    )
  end

  defp build_host_policy_snapshot(exec_opts) do
    case Keyword.get(exec_opts, :policy) do
      nil ->
        nil

      policy ->
        %{
          allowed_domains: policy.allowed_domains,
          rate_limit: policy.rate_limit,
          max_memory_bytes: policy.max_memory_bytes,
          timeout: policy.timeout,
          allowed_tools: policy.allowed_tools,
          allowed_paths: policy.allowed_paths,
          allowed_actions: policy.allowed_actions
        }
    end
  end

  # ===========================================================================
  # Cascade failure to orphaned children
  # ===========================================================================

  # When a formula execution ends (success, failure, or cancel), mark any
  # children still stuck at "running" as failed. This handles the case where
  # :kill signals bypass the child's try/rescue, leaving orphaned DB records.
  defp cascade_children_failure(%ExecutionRecord{component_type: :formula} = record) do
    do_cascade_children(record.id)
  end

  # No-op for non-formula types (catalysts/reagents don't spawn children)
  defp cascade_children_failure(_record), do: :ok

  @doc false
  def cascade_children_failure_by_id(execution_id) do
    children = Arca.Execution.list_running_children(execution_id)

    if children != [] do
      do_cascade_children_list(execution_id, children)
    end

    :ok
  end

  defp do_cascade_children(parent_id) do
    children = Arca.Execution.list_running_children(parent_id)

    if children != [] do
      do_cascade_children_list(parent_id, children)
    end

    :ok
  end

  defp do_cascade_children_list(parent_id, children) do
    for child <- children do
      now = DateTime.utc_now()
      duration_ms = DateTime.diff(now, child.started_at, :millisecond)
      error_msg = "Parent execution (#{parent_id}) terminated"

      {count, _} =
        Arca.Execution.mark_failed_if_running(child.id, %{
          completed_at: now,
          duration_ms: duration_ms,
          error_message: error_msg
        })

      if count > 0 do
        component_type =
          case Opus.ComponentType.parse(child.component_type) do
            {:ok, t} -> t
            _ -> :reagent
          end

        :telemetry.execute(
          [:cyfr, :opus, :execute, :exception],
          %{duration: duration_ms * 1_000_000, system_time: System.system_time()},
          %{
            execution_id: child.id,
            request_id: child.request_id,
            component: child.reference,
            reference: child.reference,
            component_type: component_type,
            user_id: child.user_id,
            org_id: child.org_id,
            project_id: child.project_id,
            outcome: :failure,
            error: error_msg,
            duration_ms: duration_ms
          }
        )

        ExecutionEventBuffer.push_terminal(
          child.id,
          "error",
          %{error: error_msg},
          999_999_999,
          child
        )
      end
    end
  end

  # ===========================================================================
  # Startup sweep for BEAM crash recovery
  # ===========================================================================

  @doc """
  One-time sweep to mark stale "running" executions as failed.

  Called at startup to clean up records from previous BEAM instances that
  crashed without running cleanup code. Only marks records older than 10
  minutes to avoid racing with legitimately running executions.
  """
  def sweep_stale_on_startup do
    cutoff = DateTime.add(DateTime.utc_now(), -600, :second)
    stale = Arca.Execution.list_stale_running(cutoff)

    for record <- stale do
      should_sweep =
        case Registry.lookup(Opus.ExecutionRegistry, record.id) do
          [{pid, _}] -> not Process.alive?(pid)
          _ -> true
        end

      if should_sweep do
        now = DateTime.utc_now()

        {count, _} =
          Arca.Execution.mark_failed_if_running(record.id, %{
            completed_at: now,
            duration_ms: DateTime.diff(now, record.started_at, :millisecond),
            error_message: "Execution terminated: BEAM process exited (startup recovery)"
          })

        if count > 0 do
          Logger.info("[Opus] Startup sweep: marked #{record.id} as failed")
        end
      end
    end

    :ok
  end
end
