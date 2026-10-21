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

  # The permissions, each one a `Sanctum.Context.require_permission/2`
  # check or an action annotation enforces. Declared as atoms, so the
  # converter below maps a name to an atom that already exists and never
  # makes one.
  @permissions [
    :vault_read,
    :admin,
    :*,
    :execute,
    :storage_read,
    :storage_write,
    :component_read,
    :component_manage
  ]
  @by_name Map.new(@permissions, &{Atom.to_string(&1), &1})
  @known_permissions Enum.map(@permissions, &Atom.to_string/1)

  @doc "The permission vocabulary — the one list every granted scope must appear in."
  @spec known_permissions() :: [String.t()]
  def known_permissions, do: @known_permissions

  # Every permission but the wildcard, which no sign-in path mints.
  @person_permissions List.delete(@permissions, :*)

  @doc """
  The permissions a signed-in person holds: every declared permission. A
  person is gated by membership, consent and policy, not by a permission
  subset; a narrower credential (an API key, a webhook, an internal
  context) states its own set.
  """
  @spec person_permissions() :: [atom()]
  def person_permissions, do: @person_permissions

  @doc """
  The permission atom a stored permission name names; a name outside the
  vocabulary stays a string, which no permission check matches.
  """
  @spec safe_to_permission_atom(String.t()) :: atom() | String.t()
  def safe_to_permission_atom(name) when is_binary(name), do: Map.get(@by_name, name, name)
end
