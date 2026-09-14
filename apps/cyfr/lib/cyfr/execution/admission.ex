# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Admission do
  @moduledoc """
  The authority an execution runs under, decided before anything runs.

  A root selects a profile for its reference and loads that profile's head
  consent into a `Cyfr.Authority`, fail-closed (`authority_for/4`,
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

  @typedoc "A loaded root: its authority, the activation stamp the loader verified and the profile selected."
  @type root :: %{authority: Authority.t(), stamp: map() | nil, profile: map()}

  @doc """
  Load the root authority a reference would execute under, without
  executing anything.

  `profile_selector` is a `t:Cyfr.Authority.RootSelect.selector/0`:
  `{:id, _}` or `{:label, _}` to pin, `:default` for the single active
  owner profile — which fails on ambiguity rather than choosing.

  An approval runs under this authority, so a human decision unblocks a
  call and never supplies authority. A turn starts here: `Aqua.Loop`
  resolves and pins the profile, composes the system prompt from what the
  authority grants, and only then dispatches under `{:id, pinned}`.

  ## Options

  - `:route` — `:public` or `:protected` for routed ingresses; public
    selection ignores authentication entirely and the selector is unused.
  - `:consent_source`, `:ceiling`, `:live_shape_digest`, `:budget_id` —
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
    select =
      case Keyword.get(opts, :route) do
        nil -> &RootSelect.select(&1, profile_selector)
        route -> &RootSelect.select_for_route(&1, route, ctx.authenticated)
      end

    load(ctx, reference, select, opts)
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
           load(ctx, source_ref, &RootSelect.select_for_route(&1, route, ctx.authenticated), opts),
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
  reference; an unresolvable reference answers `{:error, sentence}`.
  """
  @spec inspect_component(Context.t(), String.t()) ::
          {:ok, String.t(), term(), map()} | {:error, String.t()}
  def inspect_component(%Context{} = ctx, reference) do
    cache_key = Arca.Cache.Keys.component_meta(ctx.athanor_id, reference)

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

  defp load(ctx, reference, select, opts) do
    source = Keyword.get(opts, :consent_source, Source.impl())

    with {:ok, name_ref} <- name_level(reference),
         {:ok, candidates} <- source.profiles(ctx, name_ref),
         {:ok, profile} <- select.(candidates),
         {:ok, _ref, _type, component} <- inspect_component(ctx, reference),
         {:ok, authority, stamp} <- load_authority(ctx, profile, component, source, opts) do
      {:ok, %{authority: authority, stamp: stamp, profile: profile}}
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

    Sanctum.Consent.Loader.load_root(
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
end
