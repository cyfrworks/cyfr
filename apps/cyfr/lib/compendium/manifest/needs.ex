# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Manifest.Needs do
  @moduledoc """
  The component domain's spelling of the manifest `needs` block: named
  roles a component asks the operator to satisfy with vault entries.

  The block's grammar and its normalization are `Cyfr.Manifest.Needs` —
  the publish path validates a manifest with it and the consent sheet
  reads the declared needs from it, so the two sides read one definition.
  """

  @type error :: Cyfr.Manifest.Needs.error()

  @doc "Validate a decoded manifest's `needs` block. Absent is valid."
  @spec validate(map() | nil) :: :ok | {:error, error()}
  defdelegate validate(manifest), to: Cyfr.Manifest.Needs

  @doc """
  The normalized needs for a decoded manifest: a sorted list of
  `%{name, kind, qualifier, reason, fields, scopes, required}`. Returns
  `nil` when the manifest declares no `needs` block.
  """
  @spec from_manifest(map() | nil) :: [map()] | nil
  defdelegate from_manifest(manifest), to: Cyfr.Manifest.Needs
end
