# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Admission do
  @moduledoc """
  Whether and how an execution runs, decided before anything runs: the
  authority it runs under, and the admission of one run under it.

  A root selects a profile for its reference and loads that profile's head
  consent into a `Prima.Authority`, fail-closed (`authority_for/4`,
  `authority_and_stamp_for/4`, `root_edge/4`). A child advances its
  caller's authority through the transition relation and runs under the
  child authority that falls out — bound, or zero (`step_invoke/4`).

  A child never selects or loads a profile: profile resolution is
  unreachable from `step_invoke/4`, so a running chain cannot root a
  fresh authority of its own choosing.

  Every resolver-supplied transition input — the target's activation
  digest, the calling node's declared needs — is derived here or passed in
  by the host-owned closure. Nothing in a guest request can influence
  them.

  A run is admitted by `admit/4`: its reference resolved and typed, its
  consented limits, rates and policy enforced, its bytes fetched and their
  attestation checked, its row admitted for the worker service it is
  dispatched to and its `Crucible.Attempt` opened. A refusal at any
  stage after the row is built closes the row failed
  (`Crucible.Close`) before it answers. `Crucible.Dispatch`
  signs the run's assignment and starts it on the worker service, or claims
  it for a runner that already runs; the run's vault edge is unsealed when
  its runner attaches.
  """

  require Logger

  alias Prima.Authority
  alias Prima.Authority.Blob.Edge
  alias Prima.Authority.RootSelect
  alias Crucible.{Artifacts, Assignments, Attempt, Attestation, Close, Delegation}
  alias Crucible.{Record, Telemetry}
  alias Sanctum.Context

  @typedoc "The decision produced for one in-chain invocation."
  @type child_decision :: %{
          authority: Authority.t(),
          component: map() | nil,
          reference: String.t(),
          need: String.t() | nil,
          bound?: boolean()
        }

  @typedoc "A loaded root: its authority, the activation stamp the loader verified and the profile selected."
  @type root :: %{authority: Authority.t(), stamp: map() | nil, profile: map()}

  @typedoc """
  An admitted run: its execution id, its open attempt, what its assignment
  is signed from (`t:Crucible.Assignments.admitted/0`), its
  consented timeout and the state its waiter closes it lost with
  (`Crucible.Dispatch.await/2`).
  """
  @type admitted :: %{
          execution_id: String.t(),
          attempt: pid(),
          assignment: Assignments.admitted(),
          timeout_ms: pos_integer(),
          close: Close.t()
        }

  @doc """
  Load the root authority a reference would execute under, without
  executing anything.

  `profile_selector` is a `t:Prima.Authority.RootSelect.selector/0`:
  `{:id, _}` or `{:label, _}` to pin, `:default` for the single active
  owner profile — which fails on ambiguity rather than choosing.

  An approval runs under this authority, so a human decision unblocks a
  call and never supplies authority. A turn starts here: `Aqua.Loop`
  resolves and pins the profile, composes the system prompt from what the
  authority grants, and only then dispatches under `{:id, pinned}`.

  ## Options

  - `:route` — `:public` or `:protected` for routed ingresses; public
    selection ignores authentication entirely and the selector is unused.
  - `:ceiling`, `:live_shape_digest`, `:budget_id` —
    see `Sanctum.Consent.Loader.load_root/3`.
  """
  @spec authority_for(Context.t(), RootSelect.selector(), String.t(), keyword()) ::
          {:ok, Authority.t()} | {:error, term()}
  def authority_for(%Context{} = ctx, profile_selector, reference, opts \\ []) do
    with {:ok, %{authority: authority}} <-
           authority_and_stamp_for(ctx, profile_selector, reference, opts) do
      {:ok, authority}
    end
  end

  @doc """
  `authority_for/4` with what a root row records beside the authority:
  the activation stamp the loader verified and the profile selected.
  """
  @spec authority_and_stamp_for(Context.t(), RootSelect.selector(), String.t(), keyword()) ::
          {:ok, root()} | {:error, term()}
  def authority_and_stamp_for(%Context{} = ctx, profile_selector, reference, opts \\ []) do
    {select, pinned} =
      case {Keyword.get(opts, :route), profile_selector} do
        {nil, {:id, id}} -> {&RootSelect.select(&1, profile_selector), id}
        {nil, _selector} -> {&RootSelect.select(&1, profile_selector), nil}
        {route, _selector} -> {&RootSelect.select_for_route(&1, route, ctx.authenticated), nil}
      end

    load(ctx, reference, select, pinned, opts)
  end

  @doc """
  Root at a profile's source and step one edge from it — the routed
  ingress shape: a tincture, whose profile owns the authority, invoking
  one of its dependencies. Answers the root and the decision for
  `reference` under it: bound to the source→dependency edge, inert, or
  denied exactly as the transition relation decides.

  `opts[:route]` is required — `:public` | `:protected` — and is the
  profile selection, public-first: authentication never upgrades a public
  route. There is no selector to fall back to, so a call without a route
  raises. `opts[:need]` names the edge's need; the other options are
  `authority_for/4`'s.
  """
  @spec root_edge(Context.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{root: root(), decision: child_decision()}} | {:error, term()}
  def root_edge(%Context{} = ctx, source_ref, reference, opts) do
    route = Keyword.fetch!(opts, :route)

    with {:ok, root} <-
           load(
             ctx,
             source_ref,
             &RootSelect.select_for_route(&1, route, ctx.authenticated),
             nil,
             opts
           ),
         {:ok, decision} <-
           step_invoke(root.authority, reference, Keyword.get(opts, :need), ctx: ctx) do
      {:ok, %{root: root, decision: decision}}
    end
  end

  @doc """
  Advance `authority` through one in-chain invocation of `reference`:
  resolve the target, step the transition relation and answer the child
  authority without executing.

  Required option: `:ctx`. `:guest_fn` (`:call`, the default, or `:spawn`)
  and `:declared_needs` are host-threaded by the formula closure. A
  spawn-shaped step charges the root's invoke budget; the caller releases
  it (`Sanctum.Authority.release_invoke/1`). A denial charges nothing.
  """
  @spec step_invoke(Authority.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, child_decision()} | {:error, term()}
  def step_invoke(%Authority{} = authority, reference, need, opts) do
    ctx = Keyword.fetch!(opts, :ctx)
    guest_fn = Keyword.get(opts, :guest_fn, :call)

    with {:ok, name_ref} <- name_level(reference),
         {:ok, need} <- validate_need(need) do
      component =
        case inspect_component(ctx, reference) do
          {:ok, _ref, _type, component} -> component
          {:error, _} -> nil
        end

      target =
        {:invoke,
         %{
           reference: name_ref,
           need: need,
           # `inspect_component/2` answers string keys; a nil digest drops
           # a bound child to zero authority.
           activation_digest: component && component["release_digest"],
           declared_needs: Keyword.get(opts, :declared_needs, [])
         }}

      decision = %{component: component, reference: reference, need: need}

      case Sanctum.Authority.step(authority, guest_fn, target) do
        {:child, child} -> {:ok, Map.merge(decision, %{authority: child, bound?: true})}
        {:child_zero, zero} -> {:ok, Map.merge(decision, %{authority: zero, bound?: false})}
        {:deny, reason} -> {:error, {:invoke_denied, reason}}
        {:invalid, reason} -> {:error, {:invoke_invalid, reason}}
      end
    end
  end

  @doc """
  The registry row for `reference` in the context's athanor, with string
  keys: `{:ok, component_ref, type, component}`. A row read from the
  registry is cached for five minutes under the athanor and the
  reference; an unresolvable reference answers Compendium's own refusal
  (`{:not_found, {:component, reference}}` for one the registry does not
  hold).
  """
  @spec inspect_component(Context.t(), String.t()) ::
          {:ok, String.t(), term(), map()} | {:error, term()}
  def inspect_component(%Context{} = ctx, reference) do
    cache_key = Arca.Cache.Keys.component_meta(Sanctum.Context.actor(ctx), reference)

    case Arca.Cache.get(cache_key) do
      {:ok, cached} ->
        {:ok, cached["component_ref"], cached["type"], cached}

      :miss ->
        case Compendium.Component.inspect_component(ctx, reference) do
          {:ok, component} ->
            Arca.Cache.put(cache_key, component, :timer.minutes(5))
            {:ok, component["component_ref"], component["type"], component}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Admit one run of `reference` with `input` in `ctx`, under
  `opts[:authority]`.

  In order: this boot must own the control plane; the run's grant is read
  — a root's estate standing now, a child's its parent's stored stamp —
  and one that does not stand refuses with no row
  (`{:error, :not_standing}`); a version-less reference is resolved to
  the pinned one; the registry row must type the
  component, and a caller's `:type` may assert that type but never choose
  it; the node's consented timeout must parse; the input must fit the
  node's `max_request_size`; the node's rate bucket (and, for a public
  profile, the profile's and the caller's address buckets) must have room;
  the policy consultation is recorded; the bytes must match the registry
  digest and their attestation must satisfy `opts[:verify]` and the
  signed-pulls setting; the row is admitted with its barriers; and the
  attempt opens, owned by the calling process.

  Options: `:authority` (required — admitting without one raises, and the
  raise closes the row failed), `:type`, `:verify`, `:execution_id`,
  `:parent_execution_id`, `:child_key` (the key the parent's runner minted
  for this child, which the row carries), `:root_execution_id`,
  `:profile_id`, `:retention_class`, `:retained_input`, `:schedule_id`,
  `:activation_stamp`, `:activation_digest`, `:dep_ref`, `:need`,
  `:client_ip`, the barriers `:charge`, `:step`, `:occurrence_id` and
  `:parent_attempt` (the attempt of `:parent_execution_id` a child is
  admitted under), `:step_spans`, `:envelope` (true when the caller reads
  the component's answer as its catalyst envelope, whose error is a refusal
  the run completes with: `Crucible.Close.complete/4`), and what the
  attempt is opened with
  (`Crucible.Attempt.open/1`): `:service_id` and `:boot_id` (the
  worker service the run is dispatched to and the boot of it dispatch
  selected, which are also the row's and the assignment's), `:worker`
  (that worker service's `Prima.WorkerAPI` module) and `:held_invoke` (true
  when the calling
  process holds the charged invoke-budget slot of a spawned child, with
  `:charge` naming its row).

  Answers `{:ok, admitted}`. A reference that cannot be resolved or typed
  answers `{:error, reason}` with no row. A row an admission barrier
  refuses (`Arca.Execution.barrier_refusal?/1`) — an expired hold, a
  superseded step, an occurrence not claimed, or a child whose parent
  attempt no longer owns its running parent — is not written, and the
  refusal is answered (`Crucible.Close.barred/1`) with no lifecycle
  telemetry: nothing may run, or be recorded, past a barrier. A child
  whose `child_key` another child of the same parent already carries is
  refused the same way, `{:error, :duplicate_child_key}`, for the caller
  to answer with that child (`Arca.Execution.child_by_key/3`). Any other
  later refusal closes the row failed first and answers what
  `Crucible.Close.fail/3` answers.
  """
  @spec admit(Context.t(), String.t(), map(), keyword()) :: {:ok, admitted()} | {:error, term()}
  def admit(%Context{} = ctx, reference, input, opts)
      when is_binary(reference) and is_map(input) and is_list(opts) do
    # Every road into the engine — root, child, cron, webhook — is admitted
    # here, so a member that holds no slot in the cell admits nothing.
    if Arca.ControlPlane.held?() do
      ctx = if ctx.request_id, do: ctx, else: %{ctx | request_id: Prima.UUID7.request_id()}
      admit_owned(ctx, reference, input, opts)
    else
      {:error, :control_plane_lost}
    end
  end

  defp admit_owned(ctx, reference, input, opts) do
    with {:ok, grant} <- grant(ctx, opts),
         {:ok, pinned, resolution} <- resolve(ctx, reference),
         {:ok, component_ref, extracted_type, component} <- inspect_component(ctx, pinned),
         {:ok, component_type} <- authoritative_type(extracted_type, opts[:type], pinned) do
      record =
        ctx
        |> new_record(pinned, input, opts, component_type, component, resolution)
        |> Map.put(:grant, grant)

      Prima.LoggerContext.set_execution_id(record.id)

      run = %{
        ctx: ctx,
        reference: pinned,
        component: component,
        component_ref: component_ref,
        component_type: component_type,
        opts: opts,
        close: %Close{
          ctx: ctx,
          record: record,
          step_spans: opts[:step_spans],
          setup_stream: opts[:root_execution_id] || opts[:parent_execution_id],
          signature_verified: component["signature_verified"] || false,
          envelope: opts[:envelope] == true,
          admission:
            Keyword.take(opts, [
              :charge,
              :step,
              :parent_attempt,
              :occurrence_id,
              :service_id,
              :boot_id
            ])
        }
      }

      with {:ok, run} <- stage(run, &enforce_policy(&1, input)),
           {:ok, run} <- stage(run, &fetch_and_verify/1),
           {:ok, run} <- stage(run, &admit_row/1),
           {:ok, admitted} <- stage(run, &open_attempt(&1, input)) do
        {:ok, admitted}
      else
        {:error, run, reason} ->
          if reason == :duplicate_child_key or Arca.Execution.barrier_refusal?(reason),
            do: Close.barred(reason),
            else: Close.fail(run.close, [], reason)
      end
    end
  end

  # The standing the run is admitted under, before anything is resolved: a
  # root's estate as it stands now, a child's parent's stored stamp
  # (`Crucible.Record.grant/1`). The admission transaction checks
  # it again under the estate's lock.
  defp grant(ctx, opts) do
    case opts[:parent_execution_id] do
      nil -> Sanctum.ExecutionStanding.capture(ctx)
      parent -> Record.inherited_grant(ctx.athanor_id, parent)
    end
  end

  # Each stage answers its refusal with the run it was given, a raise
  # included, so a refusal closes the row as far as the run got: admitted
  # or not.
  defp stage(run, fun) do
    case fun.(run) do
      {:error, reason} -> {:error, run, reason}
      ok -> ok
    end
  rescue
    exception -> {:error, run, Close.exception_message(exception, __STACKTRACE__)}
  end

  defp resolve(ctx, reference) do
    case Compendium.Resolver.resolve(ctx, reference) do
      {:ok, pinned, %{was_resolved: true} = meta} ->
        {:ok, pinned, %{resolved_from: reference, resolver_digest: meta[:digest]}}

      {:ok, pinned, _metadata} ->
        {:ok, pinned, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The registry's type is authoritative — type selects WASI capabilities, so
  # a caller-supplied :type may assert but never decide. A missing registry
  # type or a mismatched assertion refuses.
  defp authoritative_type(nil, _asserted, _reference) do
    {:error, {:setup_required, :registry_binding}}
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

  defp parse_component_type(type) do
    name = if is_atom(type), do: Atom.to_string(type), else: type

    case is_binary(name) && Record.executable_type(name) do
      {:ok, component_type} ->
        {:ok, component_type}

      _ ->
        {:error,
         "Invalid component type: #{inspect(type)}. " <>
           "Must be one of: #{Enum.join(Prima.ComponentRef.executable_types(), ", ")}"}
    end
  end

  defp new_record(ctx, reference, input, opts, component_type, component, resolution) do
    record_opts =
      [
        component_type: component_type,
        parent_execution_id: opts[:parent_execution_id],
        child_key: opts[:child_key],
        root_execution_id: opts[:root_execution_id],
        # A child walks its parent's authority and roots no profile of its
        # own, so it records none.
        profile_id: opts[:profile_id],
        retention_class: opts[:retention_class],
        retained_input: opts[:retained_input],
        schedule_id: opts[:schedule_id]
      ]
      |> Arca.QueryHelpers.maybe_put(:execution_id, opts[:execution_id])
      |> Arca.QueryHelpers.maybe_put(:reservation, reservation(opts))

    ctx
    |> Record.new(reference, input, record_opts)
    |> Map.merge(resolution)
    |> stamp_activation(ctx, component, opts)
  end

  # A root mints its invocation reservation at admission, from the budget
  # its authority was minted with; a child charges its root's.
  defp reservation(opts) do
    case {opts[:root_execution_id], opts[:authority]} do
      {nil, %Authority{budget: %Authority.Budget{id: id, cap: cap}}} -> %{budget_id: id, cap: cap}
      _ -> nil
    end
  end

  # The code that actually ran. A root records the full node ->
  # release-digest map; a child's graph is a subgraph of its root's, so a
  # child under an authority records only its root's digest, and any other
  # child records nothing. An activation that cannot be resolved or encoded
  # records nothing and never fails the run.
  defp stamp_activation(record, ctx, component, opts) do
    cond do
      # An authority-rooted execution resolved and verified its activation
      # in the consent loader; the row records what was authorized.
      stamp = opts[:activation_stamp] ->
        case Compendium.Activation.encode_graph(stamp.activation_graph) do
          {:ok, encoded} ->
            %{record | activation_digest: stamp.activation_digest, activation_graph: encoded}

          {:error, _} ->
            record
        end

      digest = opts[:activation_digest] ->
        %{record | activation_digest: digest}

      is_nil(opts[:parent_execution_id]) ->
        with {:ok, %{digest: digest, graph: graph}} <-
               Compendium.Activation.resolve(ctx, component),
             {:ok, encoded} <- Compendium.Activation.encode_graph(graph) do
          %{record | activation_digest: digest, activation_graph: encoded}
        else
          {:error, _reason} -> record
        end

      true ->
        record
    end
  rescue
    e ->
      Logger.debug("[Crucible.Admission] activation not recorded: #{Exception.message(e)}")
      record
  end

  # Capability was computed once at consent time and frozen into the
  # authority: limits come from the current node, resources from the
  # current edge, and nothing is re-resolved here. A missing authority is
  # a caller bug and raises rather than running with ambient permissions.
  defp enforce_policy(run, input) do
    case run.opts[:authority] do
      %Authority{} = authority ->
        enforce_authority(run, authority, input)

      other ->
        raise ArgumentError, "execution without an authority is not a thing: #{inspect(other)}"
    end
  end

  defp enforce_authority(run, authority, input) do
    limits = Authority.limits(authority)
    edge = edge_resources(authority)

    # An unparseable consented timeout refuses the run: a default would run
    # the node under a ceiling nobody consented to.
    with {:ok, timeout_ms} <- node_timeout_ms(limits, run.component_ref, authority),
         {:ok, timeout_ms, deadline} <- within_parent_deadline(run, timeout_ms),
         :ok <- check_input_size(run, input, limits),
         :ok <- check_rate(run.ctx, run.component_ref, limits),
         :ok <- check_public_rate_buckets(run, authority, limits) do
      Sanctum.Policy.Enforcement.record(
        Map.merge(
          %{
            ctx: run.ctx,
            component_ref: run.component_ref,
            component_type: run.component_type,
            event_type: :policy_consultation,
            decision: :allowed,
            execution_id: run.close.record.id,
            host_policy_snapshot: host_policy(edge, limits)
          },
          authority_audit(run, authority)
        )
      )

      {:ok,
       run
       |> Map.merge(%{limits: limits, edge: edge, timeout_ms: timeout_ms, deadline: deadline})
       |> put_in([:close, Access.key!(:limits)], limits)}
    end
  end

  # A consented timeout that does not parse is a damaged profile row:
  # nothing the caller can change, and no default stands in for it.
  defp node_timeout_ms(limits, component_ref, authority) do
    case Prima.Limits.timeout_ms(limits) do
      {:ok, ms} ->
        {:ok, ms}

      {:error, reason} ->
        Logger.error(
          "[Crucible.Admission] the consented timeout for #{component_ref} does not parse: " <>
            reason
        )

        {:error, {:corrupt, {:profile, authority.profile_id}}}
    end
  end

  # A child's timeout is the smaller of its own consented timeout and what
  # remains of its parent's subtree deadline, and its deadline is the
  # parent's at most, so no descendant outlives the subtree; a parent whose
  # deadline has passed admits nothing. One clock read decides both.
  defp within_parent_deadline(run, timeout_ms) do
    now = System.system_time(:millisecond)

    case run.opts[:parent_deadline] do
      nil ->
        {:ok, timeout_ms, now + timeout_ms}

      parent_deadline when is_integer(parent_deadline) ->
        remaining = parent_deadline - now

        if remaining > 0,
          do: {:ok, min(timeout_ms, remaining), min(now + timeout_ms, parent_deadline)},
          else: {:error, {:timeout, :parent_deadline}}
    end
  end

  # Runtime facts; attribution is joined from the immutable consent rows on
  # read.
  defp authority_audit(run, %Authority{} = authority) do
    %{
      consent_id: authority.consent_id,
      activation_digest: run.opts[:activation_digest],
      dep_ref: run.opts[:dep_ref],
      need: run.opts[:need],
      cursor_state: cursor_state(authority.cursor),
      chain: authority.chain,
      value_source: value_source(authority.resources)
    }
  end

  defp edge_resources(%Authority{resources: %Edge{} = edge}), do: edge
  defp edge_resources(%Authority{resources: :none}), do: nil

  defp cursor_state({:bound, node}), do: "bound:" <> node
  defp cursor_state(:unbound), do: "unbound"

  defp value_source(%Edge{vault: %{entry_id: entry_id}}),
    do: Prima.VaultRef.build(entry_id)

  defp value_source(_resources), do: nil

  # The enforced edge and limits, for forensic replay of what a run was
  # allowed to do. The key names are stable serialization labels that audit
  # consumers read.
  defp host_policy(edge, %Prima.Limits{} = limits) do
    %{
      allowed_domains: Edge.domains(edge),
      rate_limit: limits.rate_limit,
      max_memory_bytes: limits.max_memory_bytes,
      timeout: limits.timeout,
      allowed_tools: Edge.tools(edge),
      allowed_paths: Edge.paths(edge),
      allowed_actions: Edge.actions(edge)
    }
  end

  defp check_input_size(run, input, %Prima.Limits{max_request_size: max_size}) do
    case Jason.encode(input) do
      {:ok, input_json} when byte_size(input_json) > max_size ->
        size = byte_size(input_json)

        Sanctum.Policy.Enforcement.record(%{
          ctx: run.ctx,
          component_ref: run.component_ref,
          event_type: :request_size,
          decision: :denied,
          decision_reason: "input size #{size} bytes exceeds maximum #{max_size} bytes"
        })

        {:error,
         {:invalid_argument, "Input size (#{size} bytes) exceeds maximum (#{max_size} bytes)"}}

      {:ok, _input_json} ->
        :ok

      # The encoder's own message can quote the value it refused.
      {:error, _reason} ->
        {:error, {:invalid_argument, "Input must be JSON-serializable"}}
    end
  end

  # A public profile's run draws on two more buckets: per caller address for
  # fairness, and per (profile, node) so an address-hopping crowd cannot
  # multiply the credential and spend exposure. An owner profile's run
  # draws on the node bucket alone.
  defp check_public_rate_buckets(run, %Authority{profile_kind: :public} = authority, limits) do
    node = run.component_ref
    ip = run.opts[:client_ip] || "unknown"

    with :ok <- check_rate(run.ctx, "pub:#{authority.profile_id}:#{node}", limits) do
      check_rate(run.ctx, "pub:#{authority.profile_id}:#{node}:#{ip}", limits)
    end
  end

  defp check_public_rate_buckets(_run, _authority, _limits), do: :ok

  # Buckets key on the {athanor, bucket} pair, so members of an athanor
  # share them — and so do the members of the cell, which is where the
  # count lives. A rate authority that cannot answer refuses: a configured
  # limit must be enforceable. A refusal of the limit is recorded as a
  # policy denial.
  defp check_rate(ctx, bucket, %Prima.Limits{} = limits) do
    case Crucible.Rates.check(Context.actor(ctx), bucket, %{rate_limit: limits.rate_limit}) do
      {:ok, _remaining} ->
        :ok

      {:error, :rate_limited, retry_after} ->
        record_rate_denial(ctx, bucket, "rate limit exceeded (retry in #{retry_after}ms)")
        {:error, {:rate_limited, div(retry_after, 1000)}}

      {:error, :unavailable} ->
        Logger.error(
          "[Crucible.Admission] the rate authority could not answer — " <>
            "failing CLOSED (denying) for #{bucket}."
        )

        record_rate_denial(ctx, bucket, "rate authority unavailable (fail closed)")
        {:error, :unavailable}

      {:error, reason} ->
        Logger.error(
          "[Crucible.Admission] the rate check for #{bucket} failed: #{inspect(reason)} — " <>
            "failing CLOSED (denying)."
        )

        {:error, :unavailable}
    end
  end

  defp record_rate_denial(ctx, bucket, reason) do
    Sanctum.Policy.Enforcement.record(%{
      ctx: ctx,
      component_ref: bucket,
      event_type: :rate_limit,
      decision: :denied,
      decision_reason: reason
    })
  end

  # The bytes are fetched by the registry digest and verified on their way
  # into the cache (`Crucible.Artifacts`), then their attestation is
  # checked. The runner fetches them again by the same digest.
  defp fetch_and_verify(run) do
    digest = run.component["digest"]

    with :ok <- artifact(run, digest),
         :ok <- verify_attestation(run) do
      record = %{
        run.close.record
        | component_digest: digest,
          host_policy: host_policy(run.edge, run.limits)
      }

      {:ok, put_in(run, [:close, Access.key!(:record)], record)}
    end
  end

  defp artifact(run, digest) do
    case Artifacts.fetch(run.ctx, digest, run.reference) do
      {:ok, _bytes} ->
        :ok

      {:error, :blob_not_found} ->
        {:error, {:not_found, {:blob, digest}}}

      {:error, {:integrity, sentence}} ->
        {:error, sentence}

      {:error, reason} ->
        Logger.error(
          "[Crucible.Admission] the bytes of #{run.reference} could not be fetched: " <>
            inspect(reason)
        )

        {:error, :unavailable}
    end
  end

  # Every run's recorded attestation is checked. The signed-pulls setting
  # decides whether unsigned OCI code runs; a signer mismatch and an
  # unclassifiable source always refuse.
  defp verify_attestation(run) do
    {identity, issuer} = pinned_signer(run.opts[:verify])

    case Attestation.attestation(run.component) do
      :unsigned when not is_nil(identity) or not is_nil(issuer) ->
        attestation_failed(
          run,
          :pinned_signer_unverified,
          "a signer was pinned, but the component was pulled without signature verification"
        )

      :unsigned ->
        if Cyfr.RuntimeConfig.require_signed_pulls?() do
          attestation_failed(
            run,
            :signed_pulls_required,
            "it was pulled without signature verification and this server requires " <>
              "signed pulls (CYFR_REQUIRE_SIGNED_PULLS)"
          )
        else
          note_unsigned_execution(run)
        end

      attested when attested in [:trusted, :signed] ->
        verify_signer(run, identity, issuer)

      {:unknown_source, _} ->
        verify_signer(run, identity, issuer)
    end
  end

  defp verify_signer(run, identity, issuer) do
    case Attestation.verify(run.component, identity, issuer) do
      :ok -> :ok
      {:error, reason} -> attestation_failed(run, :signer_mismatch, reason)
    end
  end

  # The caller reads the table's one sentence; the operator reads which
  # check refused and why, here.
  defp attestation_failed(run, what, detail) do
    Logger.warning(
      "[Crucible.Admission] signature verification of #{run.reference} failed: #{detail}"
    )

    {:error, {:attestation_failed, what}}
  end

  defp pinned_signer(verify) when is_map(verify),
    do: {verify["identity"] || verify[:identity], verify["issuer"] || verify[:issuer]}

  defp pinned_signer(_), do: {nil, nil}

  # Running unsigned code is the operator's posture, made visible where a
  # refusal would have been.
  defp note_unsigned_execution(run) do
    Logger.warning(
      "[Crucible.Admission] executing #{run.reference} with no verified signature " <>
        "(CYFR_REQUIRE_SIGNED_PULLS is off)"
    )

    :telemetry.execute(
      [:cyfr, :opus, :execution, :unsigned],
      %{count: 1},
      %{reference: run.reference, athanor_id: run.ctx.athanor_id}
    )

    :ok
  end

  defp admit_row(run) do
    with :ok <- Record.write_started(run.close.record, run.close.admission) do
      Telemetry.execute_start(run.close.record)
      {:ok, put_in(run, [:close, Access.key!(:started)], true)}
    end
  end

  # The attempt opens last, once nothing after it can refuse the run.
  defp open_attempt(run, input) do
    record = run.close.record
    root_execution_id = run.opts[:root_execution_id] || record.id

    opened =
      Attempt.open(
        execution_id: record.id,
        attempt: record.attempt,
        call_id: record.call_id,
        ctx: run.ctx,
        authority: run.opts[:authority],
        component_ref: run.component_ref,
        need: run.opts[:need],
        limits: run.limits,
        close: run.close,
        grant: record.grant,
        # A formula's events go on its root's stream, which the caller
        # watching the whole run subscribes to; any other component's go on
        # its own.
        stream_id: if(run.component_type == :formula, do: root_execution_id, else: record.id),
        budget_id: root_execution_id,
        root_execution_id: root_execution_id,
        declared_needs: declared_needs(run),
        activation_digest: activation_digest(run),
        roster: if(run.component_type == :formula, do: Delegation.roster(input), else: []),
        step_spans: run.opts[:step_spans],
        worker: run.opts[:worker],
        service_id: run.opts[:service_id],
        boot_id: run.opts[:boot_id] || Record.boot_id(),
        deadline: run.deadline,
        digest: run.component["digest"],
        held_invoke: run.opts[:held_invoke] == true,
        charge: if(run.opts[:held_invoke] == true, do: run.opts[:charge]),
        # What the attempt's assignment is signed from, kept so a child
        # admitted under a key can be handed to its runner again.
        assignment: assignment(run, input)
      )

    case opened do
      {:ok, pid} ->
        {:ok,
         %{
           execution_id: record.id,
           attempt: pid,
           assignment: assignment(run, input),
           timeout_ms: run.timeout_ms,
           close: run.close
         }}

      {:error, reason} ->
        Logger.error(
          "[Crucible.Admission] attempt of #{record.id} did not open: #{inspect(reason)}"
        )

        {:error, if(reason == :outcome_unknown, do: :outcome_unknown, else: :unavailable)}
    end
  end

  # What the run's assignment is signed from. The declared needs and the
  # activation digest are the resolver's, from the manifest the host
  # fetched, never the guest's.
  defp assignment(run, input) do
    %{
      ctx: run.ctx,
      record: run.close.record,
      authority: run.opts[:authority],
      component: %{
        ref: run.component_ref,
        type: Atom.to_string(run.component_type),
        digest: run.component["digest"],
        declared_needs: declared_needs(run),
        activation_digest: activation_digest(run)
      },
      input: input,
      timeout_ms: run.timeout_ms,
      deadline: run.deadline,
      step: run.opts[:step],
      service: run.opts[:service_id],
      boot: run.opts[:boot_id] || Record.boot_id()
    }
  end

  defp activation_digest(run),
    do: run.opts[:activation_digest] || run.close.record.activation_digest

  # The needs a manifest declares name the component's own dependency roles
  # — the caller's vocabulary, never the callee's. Sorted for stability.
  defp declared_needs(run) do
    run
    |> manifest()
    |> Map.get("needs", %{})
    |> Map.keys()
    |> Enum.sort()
  end

  # A manifest that does not decode declares no needs. The line names the
  # component, never the manifest's bytes.
  defp manifest(run) do
    case Prima.Manifest.decode_strict(run.component["manifest"]) do
      {:ok, manifest} ->
        manifest

      {:error, :malformed_manifest} ->
        Logger.warning("[Crucible.Admission] manifest malformed: #{run.component_ref}")
        %{}
    end
  end

  defp load(ctx, reference, select, pinned, opts) do
    with {:ok, name_ref} <- name_level(reference),
         {:ok, entries} <- read_profiles(ctx, name_ref),
         {:ok, candidates} <- decoded(entries, pinned),
         {:ok, profile} <- select.(candidates),
         {:ok, _ref, _type, component} <- inspect_component(ctx, reference),
         {:ok, authority, stamp} <- load_authority(ctx, profile, component, opts) do
      {:ok, %{authority: authority, stamp: stamp, profile: profile}}
    end
  end

  defp read_profiles(ctx, name_ref) do
    case Sanctum.Consent.profiles(ctx, name_ref) do
      {:ok, entries} -> {:ok, entries}
      {:error, :unavailable} -> {:error, {:unavailable, "Consent profiles"}}
      {:error, _no_tenant} = refusal -> refusal
    end
  end

  # A profile row that cannot be decoded is unavailable, never skipped: a
  # selection by kind or label could be the one it would have answered, so
  # it refuses every selection but a pinned id that names another profile.
  defp decoded(entries, pinned) do
    case Enum.filter(entries, &(&1.status == :corrupt)) do
      [] ->
        {:ok, entries}

      damaged ->
        bearing =
          if is_binary(pinned),
            do: Enum.find(damaged, &(&1.id == pinned)),
            else: hd(damaged)

        case bearing do
          nil -> {:ok, entries -- damaged}
          %{id: id} -> {:error, {:corrupt, {:profile, id}}}
        end
    end
  end

  defp name_level(reference) do
    case Prima.ComponentRef.to_name_ref(reference) do
      {:ok, name_ref} -> {:ok, name_ref}
      {:error, reason} -> {:error, {:invalid_reference, reason}}
    end
  end

  # The need travels in a guest request, so its grammar is checked before it
  # touches edge-key composition: non-empty, no separator. nil stays nil —
  # the transition relation owns the omission rules.
  defp validate_need(nil), do: {:ok, nil}
  defp validate_need(""), do: {:ok, nil}

  defp validate_need(need) when is_binary(need) do
    if String.contains?(need, "|") do
      {:error, {:invalid_need, need}}
    else
      {:ok, need}
    end
  end

  defp validate_need(other), do: {:error, {:invalid_need, other}}

  defp load_authority(ctx, profile, component, opts) do
    live =
      case Compendium.Activation.resolve_verified(ctx, component) do
        {:ok, _} = ok -> ok
        {:error, {:incomplete, _}} = incomplete -> incomplete
        {:error, _other} -> {:error, {:incomplete, :invalid_graph}}
      end

    # An unchanged live shape permits versionless consent. Derivation failure
    # leaves the shape unknown and requires fresh consent.
    opts =
      Keyword.put_new_lazy(opts, :live_shape_digest, fn ->
        case Sanctum.Consent.ShapeDerivation.live_digest(ctx, profile.source_ref) do
          {:ok, digest} -> digest
          {:error, _} -> nil
        end
      end)

    Sanctum.Consent.Loader.load_root(
      ctx,
      profile,
      [live: live, shape_diff: shape_diff_fn(ctx, profile)] ++
        Keyword.take(opts, [:ceiling, :live_shape_digest, :budget_id])
    )
  end

  # Only called when the loader has already decided re-consent is needed,
  # so the delta sheet can show what changed rather than the whole grant.
  defp shape_diff_fn(ctx, profile) do
    fn ->
      with {:ok, consent} <- Sanctum.Consent.head_consent(ctx, profile.id) do
        Sanctum.Consent.ShapeDiff.compute(ctx, profile.source_ref, consent.resolved_policy)
      else
        _ -> []
      end
    end
  end
end
