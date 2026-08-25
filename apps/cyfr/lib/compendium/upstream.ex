# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Upstream do
  @moduledoc """
  Where newer versions of a component come from.

  Every publisher namespace has an upstream. Published namespaces resolve
  against the canonical OCI registry (`Compendium.Pull` — a versionless ref
  pulls the latest published tag). The `local` namespace's upstream is the
  seed bundle: a new release ships new version directories, and
  `Compendium.AthanorSeeder.sync/1` copies the ones an athanor lacks —
  additively, never over the athanor's own. This module is the one place an
  updates surface asks what an upstream holds.
  """

  alias Compendium.Bundle

  @doc """
  The versions the seed bundle ships for a `local` component — a plain
  directory listing, `[]` when the bundle carries none.
  """
  @spec bundle_versions(String.t(), String.t()) :: [String.t()]
  def bundle_versions(type, name) when is_binary(type) and is_binary(name) do
    prefix = Bundle.bundle_prefix() ++ ["#{type}s", Bundle.publisher(), name]

    case Arca.list_typed(Sanctum.system_context(), prefix) do
      {:ok, entries} -> for {version, :dir} <- entries, do: version
      {:error, _} -> []
    end
  end
end
