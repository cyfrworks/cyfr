# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Policy.ManifestPolicy do
  @moduledoc """
  Single source of truth for resolving a component's `setup.policy` map from
  its registered manifest.

  Collapses the previously-duplicated "parse ref → resolve component →
  `Compendium.Manifest.decode` → walk to `setup.policy`" block.

  The `:resolve` mode is load-bearing — the two consumers need different
  manifest versions and a single naive helper would silently change policy
  resolution semantics:

    * `:latest` — always the latest version's manifest. Host-policy
      tool-merge / uncovered-capability detection must give a component the
      tools its newest manifest declares, even if the stored policy predates
      them.
    * `:exact_or_latest` — the exact version's manifest for a versioned ref,
      latest for a name-level ref. Policy save-time validation must validate
      against the manifest of the precise ref being configured.

  Returns `{:ok, setup_policy_map}` (the map is `%{}` when the manifest has no
  `setup.policy`), `{:error, :not_found}` when the component is unregistered,
  or `{:error, term()}` for a ref-parse / registry failure.
  """

  alias Sanctum.Context

  @type resolve :: :latest | :exact_or_latest

  @spec fetch(Context.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def fetch(%Context{} = ctx, component_ref, opts \\ []) when is_binary(component_ref) do
    resolve = Keyword.get(opts, :resolve, :latest)

    with {:ok, ref} <- Sanctum.ComponentRef.parse(component_ref),
         {:ok, component} <- resolve_component(ctx, ref, resolve) do
      {:ok, setup_policy(component)}
    end
  end

  defp resolve_component(%Context{} = ctx, %{version: version} = ref, :exact_or_latest)
       when not is_nil(version) do
    Compendium.Registry.get(ctx, ref.name, version, nil, ref.type)
  end

  defp resolve_component(%Context{} = ctx, ref, _resolve) do
    Compendium.Registry.get_latest(ctx, ref.name, nil, ref.type)
  end

  defp setup_policy(component) do
    manifest_raw = component[:manifest] || component["manifest"]
    manifest = Compendium.Manifest.decode(manifest_raw)
    setup = manifest["setup"] || %{}
    setup["policy"] || %{}
  end
end
