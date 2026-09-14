# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Opus.Chain do
  @moduledoc """
  Root and child execution under an authority.

  `run_root/5` is the external-ingress entry: it selects a profile, loads
  the head consent into a `Cyfr.Authority` (fail-closed), and hands the
  executor an execution that must run under it. `run_child/5` is the
  in-chain entry: it advances the caller's authority through the transition
  relation and executes the target under the child authority that falls
  out — bound, or zero.

  A child **never** selects or loads a profile. The two functions sharing
  an entry point is precisely the confused-deputy surface this split
  removes; keeping profile resolution structurally unreachable from
  `run_child` is the point, not an optimization.

  Every resolver-supplied transition input — the target's activation
  digest, the calling node's declared needs — is derived host-side here or
  passed in by the host-owned closure. Nothing in a guest request can
  influence them.
  """

  alias Cyfr.Authority
  alias Cyfr.Authority.RootSelect
  alias Sanctum.Consent.Source
  alias Sanctum.Context

  @typedoc "The decision produced for one in-chain invocation."
  @type child_decision :: %{
          authority: Authority.t(),
          component: map() | nil,
          reference: String.t(),
          need: String.t() | nil,
          bound?: boolean()
        }

  @doc """
  Root an execution chain under a profile's consent.

  `profile_selector` is a `t:Cyfr.Authority.RootSelect.selector/0`:
  `{:id, _}` or `{:label, _}` to pin, `:default` for the single active
  owner profile — which fails on ambiguity rather than choosing.

  ## Options

  - `:route` — `:public` or `:protected` for routed ingresses; public
    selection ignores authentication entirely and the selector is unused.
  - `:consent_source`, `:ceiling`, `:live_shape_digest` — see
    `Sanctum.Consent.Loader`.

  Remaining options pass through to `Opus.Executor.run/4`.
  """
  @spec run_root(Context.t(), RootSelect.selector(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_root(%Context{} = ctx, profile_selector, reference, input, opts \\ []) do
    source = Keyword.get(opts, :consent_source, Source.impl())

    with {:ok, name_ref} <- name_level(reference),
         {:ok, candidates} <- source.profiles(ctx, name_ref),
         {:ok, profile} <- select_profile(ctx, candidates, profile_selector, opts),
         {:ok, _ref, _type, component} <- Opus.Executor.inspect_component(ctx, reference),
         {:ok, authority, stamp} <- load_authority(ctx, profile, component, source, opts) do
      exec_opts =
        opts
        |> Keyword.drop([:consent_source, :route, :ceiling, :live_shape_digest])
        |> Keyword.merge(
          authority: authority,
          authority_required: true,
          activation_stamp: stamp,
          # The flat digest also rides along so the formula closure can
          # thread the chain's activation identity to every descendant row.
          activation_digest: stamp.activation_digest,
          # And the profile this root resolved to, so the row records which
          # consent it ran under instead of leaving a later caller to
          # re-select one — a selection that is only unambiguous while the
          # ref has a single owner profile.
          profile_id: profile.id
        )

      Opus.Executor.run(ctx, reference, input, exec_opts)
    end
  end

  @doc """
  Advance the caller's authority through one in-chain invocation and run
  the target synchronously under the resulting child authority.

  Required options: `:ctx` (the closure's context), `:parent_execution_id`.
  `:guest_fn` (`:call` | `:spawn`), `:root_execution_id`,
  `:declared_needs`, `:activation_digest` (the root's, for the child row
  stamp) are host-threaded by the formula closure.
  """
  @spec run_child(Authority.t(), String.t(), String.t() | nil, map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_child(%Authority{} = authority, reference, need, input, opts) do
    opts = Opus.Chain.Charge.identify(opts)

    with {:ok, decision} <- step_invoke(authority, reference, need, opts) do
      if Keyword.get(opts, :guest_fn) == :spawn do
        # A spawn-shaped step charged the invoke budget; this process holds
        # the slot for the call and the guard's :DOWN releases it if the
        # process dies inside. The hold is a row too
        # (`Arca.BudgetReservations`), released with the slot.
        with :ok <- Opus.Chain.Charge.take(decision.authority, opts) do
          Sanctum.Authority.guard_invoke(decision.authority)

          try do
            execute_child(decision, input, opts)
          after
            Sanctum.Authority.release_invoke(decision.authority)
            Opus.Chain.Charge.give_back(decision.authority, opts)
          end
        end
      else
        execute_child(decision, input, opts)
      end
    end
  end

  @doc """
  Root at a profile's source and immediately traverse one edge — the
  routed-ingress shape: a tincture (whose profile owns the authority)
  invoking one of its dependencies. The dependency executes as the root
  WASM execution, bound to the tincture→dependency edge's resources, or
  inert/denied exactly as the transition relation decides.

  `:route` is required — `:public` | `:protected` — and IS the profile
  selection, public-first: authentication never upgrades a public route.
  There is no selector to fall back to, so a call without a route raises
  rather than reaching a default that would guess.
  """
  @spec run_root_edge(Context.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_root_edge(%Context{} = ctx, source_ref, reference, input, opts) do
    source = Keyword.get(opts, :consent_source, Source.impl())
    route = Keyword.fetch!(opts, :route)

    with {:ok, source_name_ref} <- name_level(source_ref),
         {:ok, candidates} <- source.profiles(ctx, source_name_ref),
         {:ok, profile} <- RootSelect.select_for_route(candidates, route, ctx.authenticated),
         {:ok, _ref, _type, source_component} <-
           Opus.Executor.inspect_component(ctx, source_ref),
         {:ok, authority, stamp} <-
           load_authority(ctx, profile, source_component, source, opts),
         {:ok, decision} <-
           step_invoke(authority, reference, Keyword.get(opts, :need), ctx: ctx) do
      exec_opts =
        opts
        # `:profile` is not an option any more; a caller still setting it
        # must not see it forwarded to the child as if it meant something.
        |> Keyword.drop([:consent_source, :route, :ceiling, :live_shape_digest, :need, :profile])
        # A routed root records the profile it resolved to exactly as
        # `run_root/5` does — the row is the SSOT for which consent the
        # turn ran under.
        |> Keyword.merge(ctx: ctx, activation_stamp: stamp, profile_id: profile.id)

      execute_child(decision, input, exec_opts)
    end
  end

  @doc """
  Start an in-chain streamed execution: decide, then run the child under
  the process supervisor with its id pre-registered, returning immediately.

  A guest call of `execution.run_stream` returns while work continues, so
  it is spawn-shaped: the decision charges the root invoke budget and the
  task's `after` releases it. A denial charges nothing.
  """
  @spec run_child_stream(Authority.t(), String.t(), String.t() | nil, map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_child_stream(%Authority{} = authority, reference, need, input, opts) do
    opts = Keyword.put(opts, :guest_fn, :spawn)

    with {:ok, decision} <- step_invoke(authority, reference, need, opts) do
      execution_id = Keyword.get(opts, :execution_id) || Opus.ExecutionRecord.generate_id()
      opts = Keyword.put(opts, :execution_id, execution_id)

      logger_metadata = Cyfr.LoggerContext.capture()

      start =
        Task.Supervisor.start_child(Opus.TaskSupervisor, fn ->
          Cyfr.LoggerContext.restore(logger_metadata)
          # The task holds the charged slot: a kill through the registry
          # (execution.cancel) skips the `after`, so the guard's :DOWN
          # compensation releases it instead. Guard BEFORE registering —
          # the registry is what cancel kills through, so the compensation
          # must exist before the pid is findable, or a kill in the gap
          # leaked the slot step_invoke charged.
          Sanctum.Authority.guard_invoke(decision.authority)
          Registry.register(Cyfr.Execution.Registry, execution_id, :running)

          try do
            execute_child(decision, input, opts)
          after
            Sanctum.Authority.release_invoke(decision.authority)
          end
        end)

      case start do
        {:ok, _pid} ->
          {:ok,
           %{execution_id: execution_id, stream_url: "/api/executions/#{execution_id}/events"}}

        {:error, reason} ->
          Sanctum.Authority.release_invoke(decision.authority)
          {:error, {:stream_start_failed, reason}}
      end
    end
  end

  @doc """
  The decision half of `run_child/5` — resolve the target host-side, step
  the transition relation, return the child authority without executing.

  The async spawn path uses this before handing the execution half to the
  tracker, so a denial never consumes a task slot.
  """
  @spec step_invoke(Authority.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, child_decision()} | {:error, term()}
  def step_invoke(%Authority{} = authority, reference, need, opts) do
    ctx = Keyword.fetch!(opts, :ctx)
    guest_fn = Keyword.get(opts, :guest_fn, :call)

    with {:ok, name_ref} <- name_level(reference),
         {:ok, need} <- validate_need(need) do
      component =
        case Opus.Executor.inspect_component(ctx, reference) do
          {:ok, _ref, _type, component} -> component
          {:error, _} -> nil
        end

      target =
        {:invoke,
         %{
           reference: name_ref,
           need: need,
           # `inspect_component` answers string keys; an atom-only read
           # here once made every child's digest nil, silently dropping
           # bound children to zero authority.
           activation_digest: component && component["release_digest"],
           declared_needs: Keyword.get(opts, :declared_needs, [])
         }}

      case Sanctum.Authority.step(authority, guest_fn, target) do
        {:child, child} ->
          {:ok,
           %{
             authority: child,
             component: component,
             reference: reference,
             need: need,
             bound?: true
           }}

        {:child_zero, zero} ->
          {:ok,
           %{
             authority: zero,
             component: component,
             reference: reference,
             need: need,
             bound?: false
           }}

        {:deny, reason} ->
          {:error, {:invoke_denied, reason}}

        {:invalid, reason} ->
          {:error, {:invoke_invalid, reason}}
      end
    end
  end

  @doc """
  Execute a stepped invocation under its child authority.

  A bound target that no longer resolves is `setup_required` — the consent
  names a dependency the installed world cannot satisfy. An unresolvable
  *unbound* target proceeds to the executor and fails there, so dynamic
  dispatch to a bad ref keeps the executor's error shape.
  """
  @spec execute_child(child_decision(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute_child(decision, input, opts) do
    ctx = Keyword.fetch!(opts, :ctx)

    if decision.bound? and is_nil(decision.component) do
      {:error,
       {:setup_required,
        %{
          profile_id: decision.authority.profile_id,
          node_ref: decision.reference,
          need: decision.need || "",
          reason: :unresolvable_target
        }}}
    else
      exec_opts =
        [authority: decision.authority, authority_required: true]
        |> Arca.QueryHelpers.maybe_put(
          :parent_execution_id,
          Keyword.get(opts, :parent_execution_id)
        )
        |> Arca.QueryHelpers.maybe_put(:root_execution_id, Keyword.get(opts, :root_execution_id))
        |> Arca.QueryHelpers.maybe_put(:activation_digest, Keyword.get(opts, :activation_digest))
        |> Arca.QueryHelpers.maybe_put(:activation_stamp, Keyword.get(opts, :activation_stamp))
        |> Arca.QueryHelpers.maybe_put(:client_ip, Keyword.get(opts, :client_ip))
        |> Arca.QueryHelpers.maybe_put(:execution_id, Keyword.get(opts, :execution_id))
        # Only a root carries one; an in-chain child walks its parent's
        # authority and leaves the column nil.
        |> Arca.QueryHelpers.maybe_put(:profile_id, Keyword.get(opts, :profile_id))
        |> Arca.QueryHelpers.maybe_put(
          :type,
          decision.component && Map.get(decision.component, "type")
        )
        # Record the edge authorizing this hop for audit attribution.
        |> Arca.QueryHelpers.maybe_put(:dep_ref, decision.reference)
        |> Arca.QueryHelpers.maybe_put(:need, decision.need)
        # Who invoked this child, for a formula's own roster and lineage.
        |> Arca.QueryHelpers.maybe_put(:parent_reference, Keyword.get(opts, :parent_reference))
        |> Arca.QueryHelpers.maybe_put(:retention_class, Keyword.get(opts, :retention_class))
        |> Arca.QueryHelpers.maybe_put(:retained_input, Keyword.get(opts, :retained_input))
        # The barriers admission performs for a loop-dispatched child: the
        # hold row its charge names, and the step on its generation.
        |> Arca.QueryHelpers.maybe_put(:charge, hold_of(decision.authority, opts))
        |> Arca.QueryHelpers.maybe_put(:step, step_of(opts))
        # The port's clock (`Cyfr.Execution.StepSpans`), marked by the run.
        |> Arca.QueryHelpers.maybe_put(:step_spans, Keyword.get(opts, :step_spans))

      Opus.Executor.run(ctx, decision.reference, input, exec_opts)
    end
  end

  defp hold_of(%Authority{budget: budget}, opts) do
    case Keyword.get(opts, :charge) do
      %{id: id} -> %{reservation_id: budget.id, id: id}
      _ -> nil
    end
  end

  defp step_of(opts) do
    with step_id when is_binary(step_id) <- Keyword.get(opts, :step_id),
         %{generation: generation} <- Keyword.get(opts, :charge) do
      %{id: step_id, generation: generation}
    else
      _ -> nil
    end
  end

  defp name_level(reference) do
    case Cyfr.ComponentRef.to_name_ref(reference) do
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

  defp select_profile(ctx, candidates, selector, opts) do
    case Keyword.get(opts, :route) do
      nil -> RootSelect.select(candidates, selector)
      route -> RootSelect.select_for_route(candidates, route, ctx.authenticated)
    end
  end

  defp load_authority(ctx, profile, component, source, opts) do
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

    Opus.Host.load_root(
      ctx,
      profile,
      [live: live, source: source, shape_diff: shape_diff_fn(ctx, profile, source)] ++
        Keyword.take(opts, [:ceiling, :live_shape_digest, :budget_id])
    )
  end

  # Only called when the loader has already decided re-consent is needed,
  # so the delta sheet can show what changed rather than the whole grant.
  defp shape_diff_fn(ctx, profile, source) do
    fn ->
      with {:ok, consent} <- source.head_consent(ctx, profile.id) do
        Sanctum.Consent.ShapeDiff.compute(ctx, profile.source_ref, consent.resolved_policy)
      else
        _ -> []
      end
    end
  end

  @doc """
  Load the root authority a reference would execute under, without
  executing anything — the shape an approval flow needs: a human decision
  may only unblock a call, never supply authority, so the approved call
  runs under the same consented authority the thread's executions
  do.

  It is also the *first* step of a turn: `Aqua.Loop` resolves and pins the
  profile here, composes the system prompt from what the authority
  actually grants, and only then calls `run_root/5` with `{:id, pinned}`.
  A prompt composed before the authority is known is a prompt that can
  advertise tools the edge does not grant.
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
  A turn root (`Opus.TurnRoot`) is admitted from this, so its row carries
  the same activation a WASM root would.
  """
  @spec authority_and_stamp_for(Context.t(), RootSelect.selector(), String.t(), keyword()) ::
          {:ok, %{authority: Authority.t(), stamp: map() | nil, profile: map()}}
          | {:error, term()}
  def authority_and_stamp_for(%Context{} = ctx, profile_selector, reference, opts \\ []) do
    source = Keyword.get(opts, :consent_source, Source.impl())

    with {:ok, name_ref} <- name_level(reference),
         {:ok, candidates} <- source.profiles(ctx, name_ref),
         {:ok, profile} <- select_profile(ctx, candidates, profile_selector, opts),
         {:ok, _ref, _type, component} <- Opus.Executor.inspect_component(ctx, reference),
         {:ok, authority, stamp} <- load_authority(ctx, profile, component, source, opts) do
      {:ok, %{authority: authority, stamp: stamp, profile: profile}}
    end
  end
end
