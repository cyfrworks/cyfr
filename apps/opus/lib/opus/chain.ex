# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Opus.Chain do
  @moduledoc """
  Root and child execution under an authority.

  `run_root/5` is the external-ingress entry: it selects a profile, loads
  the head consent into a `Sanctum.Authority` (fail-closed), and hands the
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

  alias Sanctum.Authority
  alias Sanctum.Authority.RootSelect
  alias Sanctum.Authority.Transition
  alias Sanctum.Consent.Loader
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

  ## Options

  - `:profile` is the explicit selector (id or label); nil selects the
    single active owner profile and fails on ambiguity.
  - `:route` — `:public` or `:protected` for routed ingresses; public
    selection ignores authentication entirely.
  - `:consent_source`, `:ceiling`, `:live_shape_digest` — see
    `Sanctum.Consent.Loader`.

  Remaining options pass through to `Opus.Executor.run/4`.
  """
  @spec run_root(Context.t(), String.t() | nil, String.t(), map(), keyword()) ::
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
          activation_digest: stamp.activation_digest
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
    with {:ok, decision} <- step_invoke(authority, reference, need, opts) do
      execute_child(decision, input, opts)
    end
  end

  @doc """
  Root at a profile's source and immediately traverse one edge — the
  routed-ingress shape: a tincture (whose profile owns the authority)
  invoking one of its dependencies. The dependency executes as the root
  WASM execution, bound to the tincture→dependency edge's resources, or
  inert/denied exactly as the transition relation decides.

  `:route` (`:public` | `:protected`) selects the profile public-first —
  authentication never upgrades a public route.
  """
  @spec run_root_edge(Context.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_root_edge(%Context{} = ctx, source_ref, reference, input, opts) do
    source = Keyword.get(opts, :consent_source, Source.impl())

    with {:ok, source_name_ref} <- name_level(source_ref),
         {:ok, candidates} <- source.profiles(ctx, source_name_ref),
         {:ok, profile} <-
           select_profile(ctx, candidates, Keyword.get(opts, :profile), opts),
         {:ok, _ref, _type, source_component} <-
           Opus.Executor.inspect_component(ctx, source_ref),
         {:ok, authority, stamp} <-
           load_authority(ctx, profile, source_component, source, opts),
         {:ok, decision} <-
           step_invoke(authority, reference, Keyword.get(opts, :need), ctx: ctx) do
      exec_opts =
        opts
        |> Keyword.drop([:consent_source, :route, :ceiling, :live_shape_digest, :need, :profile])
        |> Keyword.merge(ctx: ctx, activation_stamp: stamp)

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

      start =
        Task.Supervisor.start_child(Opus.TaskSupervisor, fn ->
          Registry.register(Opus.ExecutionRegistry, execution_id, :running)

          try do
            execute_child(decision, input, opts)
          after
            Authority.release_invoke(decision.authority)
          end
        end)

      case start do
        {:ok, _pid} ->
          {:ok,
           %{execution_id: execution_id, stream_url: "/api/executions/#{execution_id}/events"}}

        {:error, reason} ->
          Authority.release_invoke(decision.authority)
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
           activation_digest: component && Map.get(component, :release_digest),
           declared_needs: Keyword.get(opts, :declared_needs, [])
         }}

      case Transition.step(authority, guest_fn, target) do
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
  *unbound* target proceeds to the executor and fails there exactly as the
  legacy path does, so dynamic dispatch to a bad ref keeps its error shape.
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
        |> put_present(:parent_execution_id, Keyword.get(opts, :parent_execution_id))
        |> put_present(:root_execution_id, Keyword.get(opts, :root_execution_id))
        |> put_present(:activation_digest, Keyword.get(opts, :activation_digest))
        |> put_present(:activation_stamp, Keyword.get(opts, :activation_stamp))
        |> put_present(:client_ip, Keyword.get(opts, :client_ip))
        |> put_present(:execution_id, Keyword.get(opts, :execution_id))
        |> put_present(:type, decision.component && Map.get(decision.component, "type"))
        # Which edge authorized this hop, for the §4.5 audit line.
        |> put_present(:dep_ref, decision.reference)
        |> put_present(:need, decision.need)

      Opus.Executor.run(ctx, decision.reference, input, exec_opts)
    end
  end

  defp name_level(reference) do
    case Compendium.Activation.key_for_ref(reference) do
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

    # The live shape lets a versionless consent survive a release whose
    # shape did not change (§2.6 allow-and-record). Derivation failure
    # leaves it nil, which the loader treats as unknown — fail closed to
    # needs_consent, never fail open.
    opts =
      Keyword.put_new_lazy(opts, :live_shape_digest, fn ->
        case Sanctum.Consent.ShapeDerivation.live_digest(ctx, profile.source_ref) do
          {:ok, digest} -> digest
          {:error, _} -> nil
        end
      end)

    Loader.load_root(
      ctx,
      profile,
      [live: live, source: source, shape_diff: shape_diff_fn(ctx, profile, source)] ++
        Keyword.take(opts, [:ceiling, :live_shape_digest])
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

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  Load the root authority a reference would execute under, without
  executing anything — the shape an approval flow needs: a human decision
  may only unblock a call, never supply authority, so the approved call
  runs under the same consented authority the conversation's executions
  do.
  """
  @spec authority_for(Context.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, Authority.t()} | {:error, term()}
  def authority_for(%Context{} = ctx, profile_selector, reference, opts \\ []) do
    source = Keyword.get(opts, :consent_source, Source.impl())

    with {:ok, name_ref} <- name_level(reference),
         {:ok, candidates} <- source.profiles(ctx, name_ref),
         {:ok, profile} <- select_profile(ctx, candidates, profile_selector, opts),
         {:ok, _ref, _type, component} <- Opus.Executor.inspect_component(ctx, reference),
         {:ok, authority, _stamp} <- load_authority(ctx, profile, component, source, opts) do
      {:ok, authority}
    end
  end
end
