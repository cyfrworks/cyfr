# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Atoms do
  @moduledoc """
  Safe string→atom conversion against an allowlist of known values.

  Membership is checked FIRST, then converted — every allowlisted string
  has its atom guaranteed at compile time by the module attributes below,
  so `String.to_atom/1` never mints anything new. The old order (try
  `String.to_existing_atom/1`, fall back to the list) meant any string
  whose atom happened to exist anywhere in the VM converted — the
  "allowlist" was really "the whole atom table", and retired permission
  names kept round-tripping as long as some module or test mentioned them.

  Unknown strings are returned as-is; they won't match permission checks,
  so a stored grant in a retired vocabulary silently drops rather than
  resolving to a phantom atom.

  Non-MCP-surface permissions: `:execution_write` (granted to internal
  contexts for execution-record writes) and `:vault_read` (gates
  `Sanctum.ProviderCredentials`) appear in the vocabulary but gate no MCP
  action annotation — they are checked on internal paths only.

  ## Usage

      iex> Sanctum.Atoms.safe_to_permission_atom("execute")
      :execute

      iex> Sanctum.Atoms.safe_to_permission_atom("unknown_permission")
      "unknown_permission"

  """

  # Known permission atoms — only scopes that are actually enforced via require_permission
  @known_permissions ~w(vault_read vault_write admin * execute storage_read storage_write execution_write component_read component_manage)

  @doc "The permission vocabulary — the one list every granted scope must appear in."
  @spec known_permissions() :: [String.t()]
  def known_permissions, do: @known_permissions

  # Known provider atoms
  @known_providers ~w(github google okta azure local oidc)

  # Known scope atoms
  @known_scopes ~w(org project platform)

  # Force every allowlisted atom to exist at compile time so the
  # membership-first converter below can use String.to_atom/1 without ever
  # creating an atom that wasn't declared here. Scopes and providers are
  # listed for the same guarantee even though only permissions convert —
  # their consumers pattern-match string values directly.
  @all_known_atoms Enum.map(
                     @known_permissions ++ @known_providers ++ @known_scopes,
                     &String.to_atom/1
                   )
  @doc false
  def __known_atoms__, do: @all_known_atoms

  @doc """
  Convert a string to a permission atom safely.

  Membership-first against the permission vocabulary — a retired or
  foreign name comes back as the string, which no permission check
  matches.
  """
  @spec safe_to_permission_atom(String.t() | atom()) :: atom() | String.t()
  def safe_to_permission_atom(str) when is_binary(str) do
    if str in @known_permissions, do: String.to_atom(str), else: str
  end

  def safe_to_permission_atom(atom) when is_atom(atom), do: atom
end
