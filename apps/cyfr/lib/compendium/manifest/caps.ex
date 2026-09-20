# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Manifest.Caps do
  @moduledoc """
  The component domain's spelling of the manifest `caps` block: what a
  component *asks* to be allowed to do.

  The block's grammar and its normalization are `Cyfr.Manifest.Caps`,
  which both the publish path and the consent derivation read, so a cap
  the publish path admits and a cap consent renders cannot drift.

  What this module adds is the storage-path check the grammar takes as an
  argument: a declared `caps.storage.paths` entry must name a guest scope
  (`Arca.Storage.valid_guest_path?/1` — the predicate
  `Cyfr.Execution.GuestStorage` gates requests with), so a grant no
  runtime would honor is refused at parse.
  """

  @type error :: Cyfr.Manifest.Caps.error()

  @doc "Validate a decoded manifest's `caps` block. Absent is valid."
  @spec validate(map() | nil) :: :ok | {:error, error()}
  def validate(manifest), do: Cyfr.Manifest.Caps.validate(manifest, &storage_path_ok?/1)

  @doc """
  The normalized caps for a decoded manifest: string sets sorted and
  deduplicated, every key present with its empty default. Returns `nil`
  when the manifest declares no `caps` block — callers branch on that for
  source priority.
  """
  @spec from_manifest(map() | nil) :: map() | nil
  def from_manifest(manifest),
    do: Cyfr.Manifest.Caps.from_manifest(manifest, &storage_path_ok?/1)

  defp storage_path_ok?(path), do: Arca.Storage.valid_guest_path?(path)
end
