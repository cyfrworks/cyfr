# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Policy.Resolver do
  @moduledoc """
  Effective-policy resolution for a component reference.

  Separated from `Sanctum.Policy` (which owns the policy *type*, its
  predicates, and conversions): this module owns the *orchestration* —
  the exact-ref → name-level → manifest → type-default → hardcoded-default
  cascade, the ceiling clamp at the read boundary, and the manifest
  tool-merge. It is the only policy code that reaches into component
  discovery (`Sanctum.Policy.ManifestPolicy`) and storage
  (`Sanctum.PolicyStore`), keeping the `Sanctum.Policy` struct module free
  of those concerns.

  `Sanctum.Policy.get_effective/3` delegates here; the public API is
  unchanged.
  """

  require Logger

  alias Sanctum.Context

  @type policy_source ::
          :exact_ref | :name_level | :manifest_setup | :type_default | :hardcoded_default

  @spec get_effective(Context.t(), String.t(), keyword()) ::
          {:ok, Sanctum.Policy.t(), %{source: policy_source()}} | {:error, term()}
  def get_effective(%Context{} = ctx, component_ref, opts \\ [])
      when is_binary(component_ref) do
    ctx
    |> resolve_effective(component_ref)
    |> maybe_clamp(ctx, opts)
  end

  # Clamp the resolved policy down to the effective ceiling (platform, plus
  # the org plan when a plan resolver is configured) unless the caller opts out for a
  # display-only read. Clamping only lowers values that exceed the ceiling —
  # a policy already within limits is returned unchanged, and allow-lists are
  # never clamped. This makes ceiling enforcement the default at the read
  # boundary instead of relying on individual consumers to clamp.
  defp maybe_clamp({:ok, policy, meta}, ctx, opts) do
    if Keyword.get(opts, :clamp, true) do
      ceiling = Sanctum.Policy.Ceiling.effective_ceiling(ctx)
      {:ok, Sanctum.Policy.Ceiling.clamp(policy, ceiling), meta}
    else
      {:ok, policy, meta}
    end
  end

  defp maybe_clamp(other, _ctx, _opts), do: other

  defp resolve_effective(%Context{} = ctx, component_ref) when is_binary(component_ref) do
    # 1. Try exact ref lookup
    case Sanctum.PolicyStore.get(ctx, component_ref) do
      {:ok, policy} ->
        {:ok, merge_manifest_tools(policy, ctx, component_ref), %{source: :exact_ref}}

      {:error, :not_found} ->
        # 2. Try name-level lookup (type:namespace.name without version)
        name_level_result = try_name_level_lookup(ctx, component_ref)

        case name_level_result do
          {:ok, policy} ->
            maybe_warn_non_local(component_ref)
            policy = merge_manifest_tools(policy, ctx, component_ref)
            meta = %{source: :name_level}
            meta = maybe_add_uncovered_capabilities(meta, ctx, component_ref, policy)
            {:ok, policy, meta}

          :not_found ->
            # 3. Try manifest setup.policy, then type default
            {policy, source} = default_for_ref(ctx, component_ref)
            {:ok, merge_manifest_tools(policy, ctx, component_ref), %{source: source}}
        end

      {:error, reason} when is_binary(reason) ->
        # A non-normalizable component_ref (missing type prefix / version) is a
        # caller bug, not a missing policy. Fail closed instead of silently
        # substituting a type-default policy — that masked the bug and could
        # hand back a different policy than was asked for. `:store_error` /
        # `:corrupt_policy` already fail closed below; `:not_found` (a resolved
        # ref with no stored policy) stays deny-by-default by design.
        Logger.warning(
          "[Sanctum.Policy] Ref normalization failed for #{component_ref}: #{reason}"
        )

        Sanctum.Telemetry.policy_resolve_error(:invalid_ref, component_ref)
        {:error, {:invalid_ref, reason}}

      {:error, {:store_error, reason}} ->
        Logger.error(
          "[Sanctum.Policy] Storage error looking up policy for #{component_ref}: #{inspect(reason)}"
        )

        {:error, {:store_error, reason}}

      {:error, {:corrupt_policy, reason}} ->
        Logger.error("[Sanctum.Policy] Corrupt policy for #{component_ref}: #{inspect(reason)}")
        {:error, {:corrupt_policy, reason}}

      {:error, reason} ->
        Logger.error("[Sanctum.Policy] Unexpected error for #{component_ref}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Try looking up a name-level policy (type:namespace.name without version).
  defp try_name_level_lookup(ctx, component_ref) do
    case Sanctum.ComponentRef.to_name_ref(component_ref) do
      {:ok, name_ref} ->
        # Name-level refs are stored directly as "type:namespace.name"
        case Sanctum.PolicyStore.get_name_level(ctx, name_ref) do
          {:ok, policy} ->
            {:ok, policy}

          {:error, :not_found} ->
            :not_found

          {:error, reason} ->
            Logger.warning(
              "[Sanctum.Policy] Name-level lookup failed for #{name_ref}: #{inspect(reason)}"
            )

            :not_found
        end

      {:error, reason} ->
        Logger.debug(
          "[Sanctum.Policy] Could not derive name ref from #{component_ref}: #{inspect(reason)}"
        )

        :not_found
    end
  end

  # Emit telemetry warning for non-local components using name-level policies
  defp maybe_warn_non_local(component_ref) do
    case Sanctum.ComponentRef.parse(component_ref) do
      {:ok, %{namespace: ns}} when ns != "local" ->
        :telemetry.execute(
          [:cyfr, :sanctum, :policy, :name_level_warning],
          %{system_time: System.system_time()},
          %{
            component_ref: component_ref,
            warning: "name-level policy applied to non-local component"
          }
        )

      _ ->
        :ok
    end
  end

  defp default_for_ref(ctx, component_ref) do
    case Sanctum.ComponentRef.parse(component_ref) do
      {:ok, %{type: type}} when type in ["catalyst", "formula", "reagent", "tincture"] ->
        type_atom = String.to_existing_atom(type)

        case Sanctum.PolicyStore.get_type_default(ctx, type_atom) do
          {:ok, policy} -> {policy, :type_default}
          {:error, :not_found} -> {Sanctum.Policy.default(type_atom), :hardcoded_default}
        end

      _ ->
        {Sanctum.Policy.default(), :hardcoded_default}
    end
  end

  # Check if the latest version's manifest declares capabilities not covered
  # by the stored name-level policy. Adds :uncovered_capabilities to meta if any.
  defp maybe_add_uncovered_capabilities(meta, ctx, component_ref, policy) do
    case Sanctum.Policy.ManifestPolicy.fetch(ctx, component_ref, resolve: :latest) do
      {:ok, setup_policy} when map_size(setup_policy) > 0 ->
        declared_keys = setup_policy |> Map.keys() |> MapSet.new()
        policy_map = Sanctum.Policy.to_map(policy)

        # Capability fields from setup.policy that have no non-default value in stored policy
        uncovered =
          declared_keys
          |> Enum.filter(fn key ->
            key in Sanctum.Policy.FieldSchema.all_capability_fields() and
              is_default_value?(policy_map, key)
          end)
          |> Enum.sort()

        if uncovered != [] do
          Map.put(meta, :uncovered_capabilities, uncovered)
        else
          meta
        end

      _ ->
        meta
    end
  end

  defp is_default_value?(policy_map, key) do
    # `String.to_existing_atom/1` raises on an unknown key. A crafted manifest
    # `setup.policy` with an arbitrary key would otherwise crash this read
    # path (a DoS). If no atom exists for the key, the map cannot hold it
    # under an atom key either — treat as absent.
    atom_value =
      try do
        Map.get(policy_map, String.to_existing_atom(key))
      rescue
        ArgumentError -> nil
      end

    value = Map.get(policy_map, key) || atom_value

    case value do
      nil -> true
      [] -> true
      _ -> false
    end
  end

  # Merge manifest's setup.policy.allowed_tools into the effective policy.
  # This ensures components always have access to the tools their manifest declares,
  # even when the stored policy predates new tool additions.
  # RestrictedTools still hard-blocks dangerous tools at runtime regardless.
  defp merge_manifest_tools(policy, ctx, component_ref) do
    case fetch_manifest_allowed_tools(ctx, component_ref) do
      {:ok, manifest_tools} when manifest_tools != [] ->
        %{policy | allowed_tools: Enum.uniq(policy.allowed_tools ++ manifest_tools)}

      _ ->
        policy
    end
  end

  defp fetch_manifest_allowed_tools(ctx, component_ref) do
    case Sanctum.Policy.ManifestPolicy.fetch(ctx, component_ref, resolve: :latest) do
      {:ok, setup_policy} -> {:ok, setup_policy["allowed_tools"] || []}
      {:error, _} -> {:ok, []}
    end
  end
end
