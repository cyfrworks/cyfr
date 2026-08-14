# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Executor do
  @moduledoc """
  High-level execution facade for WASM components.

  This module provides a simplified API for executing WASM components,
  handling reference resolution, signature verification, telemetry,
  and crash-resilient record keeping.

  ## Usage

  Every execution roots under a `Sanctum.Authority` — production callers go
  through the `Opus` facade (`run_root`/`run_child`), which derives one from
  the caller's consented profile. Calling the executor directly requires
  passing the authority explicitly:

      ctx = Sanctum.TestContext.local()
      reference = "reagent:local.my-tool:0.1.0"
      input = %{"a" => 5, "b" => 10}

      {:ok, result} = Opus.Executor.run(ctx, reference, input, authority: authority)
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
        case authoritative_type(extracted_type, opts[:type], resolved_reference) do
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

  # The registry's type is authoritative — type selects WASI capabilities, so
  # a caller-supplied :type may assert but never decide. A missing registry
  # type or a mismatched assertion refuses.
  defp authoritative_type(nil, _asserted, reference) do
    {:error, "Component '#{reference}' has no registry type — re-register it"}
  end

  defp authoritative_type(extracted, asserted, reference) do
    with {:ok, component_type} <- parse_component_type(extracted) do
      case asserted && parse_component_type(asserted) do
        nil ->
          {:ok, component_type}

        {:ok, ^component_type} ->
          {:ok, component_type}

        {:ok, other} ->
          {:error,
           "Requested type #{other} does not match the registry type " <>
             "#{component_type} for '#{reference}'"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_run(ctx, reference, input, opts, component_type, component_ref, component) do
    # Create initial execution record
    record_opts = [
      component_type: component_type,
      parent_execution_id: opts[:parent_execution_id],
      root_execution_id: opts[:root_execution_id]
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
           {:ok, p, output, exec_metadata} <- stage_execute(p, wasm_bytes, input) do
        finalize_execution(p, output, exec_metadata)
      else
        {:error, reason} when is_binary(reason) ->
          maybe_emit_setup_event(ctx, reason, opts)
          handle_failure(p.record, reason, p.started_written)

        {:error, {tag, payload} = typed}
        when tag in [:setup_required, :consent_required] and is_map(payload) ->
          # Record and stream the readable message, but return the typed
          # term — the error envelope needs the structural payload, and
          # callers already receive these tuples from consent loading.
          maybe_emit_setup_event(ctx, typed, opts)
          _ = handle_failure(p.record, failure_message(typed), p.started_written)
          {:error, typed}

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

  # Stage 1: capability enforcement. Every execution roots under an
  # authority — a missing one is a caller bug, and the raise names it
  # rather than running with ambient permissions.
  defp stage_enforce_policy(%ExecutionPipeline{} = p, input) do
    case p.opts[:authority] do
      %Sanctum.Authority{} = authority ->
        enforce_authority(p, authority, input)

      other ->
        raise ArgumentError,
              "execution without an authority is not a thing: #{inspect(other)}"
    end
  end

  # Under an authority, capability was computed once at consent time and
  # frozen into the blob: limits come from the current node, resources from
  # the current edge — nothing is re-resolved at execution time.
  # Static-dependency satisfaction was already proven by the loader's
  # all-or-nothing activation resolution.
  defp enforce_authority(%ExecutionPipeline{} = p, authority, input) do
    limits = Sanctum.Authority.limits(authority)
    edge = edge_resources(authority)

    # An unparseable consented timeout fails the execution rather than
    # substituting a default — a fallback here would silently run the node
    # under a ceiling nobody consented to (mirrors Sanctum.Limits.new/1).
    with {:ok, timeout_ms} <- node_timeout_ms(limits, p.component_ref),
         exec_opts = [
           component_type: p.component_type,
           timeout_ms: timeout_ms,
           max_memory_bytes: limits.max_memory_bytes,
           edge: edge,
           limits: limits
         ],
         {:ok, _input_json} <- validate_input_size(input, exec_opts, p.ctx, p.component_ref),
         :ok <- check_authority_rate_limit(p.ctx, p.component_ref, limits),
         :ok <- check_public_rate_buckets(p, authority, limits) do
      Enforcement.record(
        Map.merge(
          %{
            ctx: p.ctx,
            component_ref: p.component_ref,
            component_type: p.component_type,
            event_type: :policy_consultation,
            decision: :allowed,
            execution_id: p.record.id,
            host_policy_snapshot: build_host_policy_snapshot(exec_opts)
          },
          authority_audit(p, authority)
        )
      )

      {:ok, %{p | exec_opts: exec_opts, edge: edge}}
    end
  end

  defp node_timeout_ms(limits, component_ref) do
    case Sanctum.Limits.timeout_ms(limits) do
      {:ok, ms} -> {:ok, ms}
      {:error, reason} -> {:error, "invalid consented timeout for #{component_ref}: #{reason}"}
    end
  end

  # §4.5: what only the running chain knows. Everything attributable —
  # who granted it, when, how — is joined from the immutable consent at
  # read, so this hot-path write stays small.
  defp authority_audit(%ExecutionPipeline{} = p, %Sanctum.Authority{} = authority) do
    %{
      consent_id: authority.consent_id,
      activation_digest: p.opts[:activation_digest],
      dep_ref: p.opts[:dep_ref],
      need: p.opts[:need],
      cursor_state: cursor_state(authority.cursor),
      chain: authority.chain,
      value_source: value_source(authority.resources)
    }
  end

  defp edge_resources(%Sanctum.Authority{resources: %Sanctum.Authority.Blob.Edge{} = edge}),
    do: edge

  defp edge_resources(%Sanctum.Authority{resources: :none}), do: nil

  defp cursor_state({:bound, node}), do: "bound:" <> node
  defp cursor_state(:unbound), do: "unbound"
  defp cursor_state(_), do: nil

  defp value_source(%Sanctum.Authority.Blob.Edge{vault: %{entry_id: entry_id}}),
    do: "vault:" <> entry_id

  defp value_source(_resources), do: nil

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

  # Stage 4: resolve credentials. The callee-keyed grant plane is never
  # consulted: credentials come only from the current edge's vault
  # resource, projected by the vault reader. No vault edge means no
  # secrets — an ungranted read denies exactly as an empty resolution.
  defp stage_resolve_secrets(%ExecutionPipeline{} = p) do
    case p.opts[:authority] do
      %Sanctum.Authority{resources: %Sanctum.Authority.Blob.Edge{vault: %{} = vault}} = authority ->
        case Sanctum.VaultReader.fetch(p.ctx, vault) do
          {:ok, secrets} ->
            {:ok, %{p | preloaded_secrets: secrets}}

          {:error, reason} ->
            # A consented vault edge that cannot produce material is a
            # declared need unmet at run: a typed setup_required, so the
            # error envelope and the parent-stream setup event carry the
            # structural cause instead of flattened prose.
            {:error,
             {:setup_required,
              %{
                profile_id: authority.profile_id,
                node_ref: p.component_ref,
                need: p.opts[:need] || "",
                reason: vault_setup_reason(reason)
              }}}
        end

      _ ->
        {:ok, %{p | preloaded_secrets: %{}}}
    end
  end

  # Stage 6: Execute WASM with all accumulated state
  defp stage_execute(%ExecutionPipeline{} = p, wasm_bytes, input) do
    digest = p.component[:digest] || p.component["digest"]

    exec_opts_final =
      Keyword.merge(p.exec_opts,
        preloaded_secrets: p.preloaded_secrets,
        component_ref: p.component_ref,
        ctx: p.ctx,
        execution_id: p.record.id,
        root_execution_id: p.opts[:root_execution_id],
        reference: p.reference,
        digest: digest,
        # Resolver-supplied transition inputs for this node's own onward
        # invocations — from the manifest the host fetched, never from the
        # guest.
        declared_needs: declared_needs(p),
        activation_digest: p.opts[:activation_digest] || p.record.activation_digest
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
    # Limits ride exec_opts from enforce_authority; their absence here means
    # the pipeline was bypassed — refuse rather than substitute a ceiling.
    %Sanctum.Limits{max_response_size: max_response} = Keyword.fetch!(p.exec_opts, :limits)

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
        # The registry column is NOT NULL, so a missing digest here means the
        # cached component map lost its shape or bypassed registration — bytes
        # without a pinned digest never reach the runtime.
        {:error,
         "No registry digest for #{reference} — refusing to execute unverified bytes. " <>
           "Re-register the component."}

      # Cyfr.Digest is the only producer, so both sides carry the same
      # sha256:-prefixed spelling — one comparison, no format guessing.
      actual_digest == expected_digest ->
        :ok

      true ->
        {:error,
         "Integrity check failed for #{reference}. " <>
           "Expected: #{expected_digest}, Got: #{actual_digest}. " <>
           "Component may have been modified. Re-register with `cyfr register`."}
    end
  end

  # Validate input size against the node's limits.
  # Returns {:ok, encoded_json} on success so callers can reuse the encoded form.
  defp validate_input_size(input, exec_opts, ctx, component_ref) do
    # Same posture as check_response_size: no limits, no execution.
    %Sanctum.Limits{max_request_size: max_size} = Keyword.fetch!(exec_opts, :limits)

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

  # Public profiles enforce both buckets: per caller IP for fairness, and
  # per (profile, node) so an address-hopping crowd cannot multiply the
  # credential and spend exposure. The transport per-IP plug stays beneath
  # both. Owner profiles use the ordinary node bucket alone.
  defp check_public_rate_buckets(%ExecutionPipeline{} = p, authority, limits) do
    if authority.profile_kind == :public do
      node = p.component_ref
      ip = p.opts[:client_ip] || "unknown"
      profile_bucket = "pub:#{authority.profile_id}:#{node}"
      ip_bucket = "pub:#{authority.profile_id}:#{node}:#{ip}"

      with :ok <- check_authority_rate_limit(p.ctx, profile_bucket, limits) do
        check_authority_rate_limit(p.ctx, ip_bucket, limits)
      end
    else
      :ok
    end
  end

  # The authority variant never re-resolves: the blob's node limits are the
  # policy. The limiter keys on {org, project, ref} either way, so buckets
  # are continuous across the cutover.
  defp check_authority_rate_limit(ctx, component_ref, %Sanctum.Limits{} = limits) do
    case check_rate_limit(ctx, component_ref, limits) do
      {:ok, _remaining} ->
        :ok

      {:error, :rate_limited, retry_after} ->
        {:error, "Rate limit exceeded. Retry in #{div(retry_after, 1000)}s"}

      {:error, reason} ->
        {:error, "Rate limit check failed for #{component_ref}: #{inspect(reason)}."}
    end
  end

  # The rate-limit chokepoint every authority execution goes through
  # (node bucket and both public-profile buckets). Buckets key on the
  # tenant-normalized {org, project, ref} triple so a not-yet-resolved
  # org/project never reaches the limiter as "" (rejected as
  # :missing_tenant) and members of a project share the budget. A dead or
  # unreachable limiter fails CLOSED — a configured limit must be
  # enforceable, so unavailability denies rather than silently allowing
  # unbounded requests. Every denial is audited here, after the try/catch,
  # keeping the audit write's own failures out of the fail-closed handling.
  defp check_rate_limit(ctx, component_ref, %Sanctum.Limits{} = limits) do
    org_id = Arca.QueryHelpers.normalize_org_id(ctx.org_id)
    project_id = Arca.QueryHelpers.normalize_project_id(ctx.project_id)

    result =
      try do
        Opus.RateLimiter.check(org_id, project_id, component_ref, %{
          rate_limit: limits.rate_limit
        })
      catch
        :exit, reason ->
          Logger.error(
            "[Opus.Executor] Opus.RateLimiter unavailable (#{inspect(reason)}) — " <>
              "failing CLOSED (denying) for #{component_ref}."
          )

          {:error, :rate_limited}
      end

    case result do
      {:error, :rate_limited, retry_ms} ->
        record_rate_limit_denial(
          ctx,
          component_ref,
          "rate limit exceeded (retry in #{retry_ms}ms)"
        )

      {:error, :rate_limited} ->
        record_rate_limit_denial(ctx, component_ref, "rate limiter unavailable (fail closed)")

      _ ->
        :ok
    end

    result
  end

  defp record_rate_limit_denial(ctx, component_ref, reason) do
    Enforcement.record(%{
      ctx: ctx,
      component_ref: component_ref,
      event_type: :rate_limit,
      decision: :denied,
      decision_reason: reason
    })
  end

  defp parse_component_type(type) when is_atom(type) and not is_nil(type) do
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
    Cyfr.Digest.sha256(wasm_bytes)
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
    if Keyword.get(opts, :authority_required, Keyword.get(exec_opts, :authority_required, true)) and
         is_nil(Keyword.get(opts, :authority, Keyword.get(exec_opts, :authority))) do
      raise ArgumentError,
            "execution requires an authority but none was provided (reference: " <>
              "#{inspect(Keyword.get(exec_opts, :reference))})"
    end

    # The pipeline always derives timeout_ms from the consented limits; a
    # missing value means an opts filter dropped it — refuse rather than
    # substitute a ceiling nobody consented to.
    timeout_ms =
      exec_opts[:timeout_ms] || opts[:timeout_ms] ||
        raise(ArgumentError, "execution reached the runtime without a timeout — limits dropped")

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
              :component_ref,
              :edge,
              :limits,
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
              :authority_required,
              :declared_needs,
              :activation_digest
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

  # The needs a manifest declares name the component's own dependency roles
  # — the caller's vocabulary, never the callee's. Sorted for stability.
  defp declared_needs(%ExecutionPipeline{} = p) do
    if p.opts[:authority] do
      p.component[:manifest]
      |> Kernel.||(p.component["manifest"])
      |> Compendium.Manifest.decode()
      |> Map.get("needs", %{})
      |> Map.keys()
      |> Enum.sort()
    end
  end

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
              "message" => failure_message(reason)
            },
            System.unique_integer([:positive]),
            ctx
          )

        :not_setup_error ->
          :ok
      end
    end
  end

  defp failure_message({:setup_required, %{node_ref: node_ref, reason: reason}}),
    do: "Setup required for #{node_ref}: #{inspect(reason)}"

  defp failure_message(reason), do: "Execution failed: #{inspect(reason)}"

  # The typed payload crosses the JSON error envelope, so its reason must
  # be JSON-encodable — vault loader tuples are flattened here.
  defp vault_setup_reason({:entry_unavailable, status}), do: "vault_entry_#{status}"
  defp vault_setup_reason(reason) when is_atom(reason), do: reason
  defp vault_setup_reason(reason), do: inspect(reason)

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
  @spec cancel(Context.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def cancel(ctx, execution_id, opts \\ [])

  def cancel(%Context{} = ctx, execution_id, opts) do
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
        {event_type, event_data} = cancel_event(opts)

        ExecutionEventBuffer.push_terminal(
          execution_id,
          event_type,
          event_data,
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

  @doc """
  Terminate a running execution because its consent changed underneath it.

  A delta revision commits for FUTURE roots; it must never re-bind the
  execution already in flight, which may have taken side effects under
  the authority it started with (§4.4). The running one ends carrying the
  typed `restart_required` payload — the surface says "approved, re-run
  to continue" — and the re-run picks up the new revision.
  """
  @spec cancel_for_restart(Context.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def cancel_for_restart(%Context{} = ctx, execution_id, payload) when is_map(payload) do
    cancel(ctx, execution_id, restart_required: payload)
  end

  # A restart-required cancellation reports itself as such, so a surface
  # can say "approved — re-run to continue" instead of "cancelled".
  defp cancel_event(opts) do
    case Keyword.get(opts, :restart_required) do
      nil -> {"cancelled", %{}}
      payload when is_map(payload) -> {"restart_required", payload}
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

  # Serialize the enforced edge + limits for forensic replay. The key names
  # are stable serialization labels — audit consumers and tests pin them.
  defp build_host_policy_snapshot(exec_opts) do
    case Keyword.get(exec_opts, :limits) do
      nil ->
        nil

      %Sanctum.Limits{} = limits ->
        edge = Keyword.get(exec_opts, :edge)

        %{
          allowed_domains: Opus.EdgeGuard.domains(edge),
          rate_limit: limits.rate_limit,
          max_memory_bytes: limits.max_memory_bytes,
          timeout: limits.timeout,
          allowed_tools: Opus.EdgeGuard.tools(edge),
          allowed_paths: Opus.EdgeGuard.paths(edge),
          allowed_actions: Opus.EdgeGuard.actions(edge)
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
