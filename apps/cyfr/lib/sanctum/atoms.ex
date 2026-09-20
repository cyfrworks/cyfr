# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Atoms do
  @moduledoc """
  Safe string→atom conversion against an allowlist of known values.

  Checks membership before converting strings to atoms. All allowed atoms
  exist at compile time; conversion cannot create arbitrary atoms.

  Unknown strings remain strings and do not match permission checks.

  Every permission but `*` gates an action annotation or a
  `Sanctum.Context.require_permission/2` check.

  ## Usage

      iex> Sanctum.Atoms.safe_to_permission_atom("execute")
      :execute

      iex> Sanctum.Atoms.safe_to_permission_atom("unknown_permission")
      "unknown_permission"
  """

  # Known permission atoms — only scopes that are actually enforced via require_permission
  @known_permissions ~w(vault_read admin * execute storage_read storage_write component_read component_manage)

  @doc "The permission vocabulary — the one list every granted scope must appear in."
  @spec known_permissions() :: [String.t()]
  def known_permissions, do: @known_permissions

  # Every permission but the wildcard, which no sign-in path mints.
  @person_permissions Enum.map(@known_permissions -- ["*"], &String.to_atom/1)

  @doc """
  The permissions a signed-in person holds: every declared permission. A
  person is gated by membership, consent and policy, not by a permission
  subset; a narrower credential (an API key, a webhook, an internal
  context) states its own set.
  """
  @spec person_permissions() :: [atom()]
  def person_permissions, do: @person_permissions

  # Pre-create atoms for the supported sign-in providers.
  @known_providers ~w(github google oidcc)

  @doc "The sign-in provider vocabulary as strings."
  @spec providers() :: [String.t()]
  def providers, do: @known_providers

  # The tenancy scopes are `Cyfr.TenancyScope`'s: the stored membership row
  # is held to the same list, so the two sides read one declaration.
  @known_scopes Cyfr.TenancyScope.values()

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

  @doc "The tenancy scope vocabulary as strings: `[\"platform\", \"athanor\"]`."
  @spec scopes() :: [String.t()]
  defdelegate scopes(), to: Cyfr.TenancyScope, as: :values

  @doc "The tenancy scope vocabulary as atoms: `[:platform, :athanor]`."
  @spec scope_atoms() :: [atom()]
  defdelegate scope_atoms(), to: Cyfr.TenancyScope, as: :atoms

  @doc """
  Convert a string to a permission atom safely.

  Converts allowlisted permission names to atoms; leaves unknown names as strings.
  """
  @spec safe_to_permission_atom(String.t() | atom()) :: atom() | String.t()
  def safe_to_permission_atom(str) when is_binary(str) do
    if str in @known_permissions, do: String.to_atom(str), else: str
  end

  def safe_to_permission_atom(atom) when is_atom(atom), do: atom
end
