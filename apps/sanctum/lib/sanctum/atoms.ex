defmodule Sanctum.Atoms do
  @moduledoc """
  Safe atom conversion utilities to prevent atom table exhaustion.

  Provides a centralized approach to converting strings to atoms with
  an allowlist of known values. Unknown strings are returned as-is
  (since they won't match permission checks anyway).

  ## Usage

      iex> Sanctum.Atoms.safe_to_atom("execute")
      :execute

      iex> Sanctum.Atoms.safe_to_atom("unknown_permission")
      "unknown_permission"

  """

  # Known permission atoms - extend this list as needed
  @known_permissions ~w(
    execute read write admin publish build search audit secret_access
    create update delete list view manage configure deploy
    secrets_read secrets_write policy_read policy_write audit_read users_manage
  )

  # Known provider atoms
  @known_providers ~w(github google okta azure local oidc)

  # Known scope atoms
  @known_scopes ~w(personal org)

  @all_known_strings @known_permissions ++ @known_providers ++ @known_scopes

  @doc """
  Convert a string to an atom safely.

  First attempts to find an existing atom. If not found, checks against
  the allowlist of known strings. Unknown strings are returned as-is.

  ## Examples

      iex> Sanctum.Atoms.safe_to_atom("execute")
      :execute

      iex> Sanctum.Atoms.safe_to_atom(:execute)
      :execute

      iex> Sanctum.Atoms.safe_to_atom("malicious_atom_bomb_attempt")
      "malicious_atom_bomb_attempt"

  """
  @spec safe_to_atom(String.t() | atom() | any()) :: atom() | any()
  def safe_to_atom(str) when is_binary(str) do
    try do
      String.to_existing_atom(str)
    rescue
      ArgumentError ->
        if str in @all_known_strings do
          String.to_atom(str)
        else
          # Return as-is for unknown values (they won't match permission checks)
          str
        end
    end
  end

  def safe_to_atom(atom) when is_atom(atom), do: atom
  def safe_to_atom(other), do: other

  @doc """
  Convert a string to a permission atom safely.

  Similar to `safe_to_atom/1` but only allows known permission atoms.
  """
  @spec safe_to_permission_atom(String.t() | atom()) :: atom() | String.t()
  def safe_to_permission_atom(str) when is_binary(str) do
    try do
      String.to_existing_atom(str)
    rescue
      ArgumentError ->
        if str in @known_permissions do
          String.to_atom(str)
        else
          str
        end
    end
  end

  def safe_to_permission_atom(atom) when is_atom(atom), do: atom

  @doc """
  Convert a string to a provider atom safely.
  """
  @spec safe_to_provider_atom(String.t() | atom()) :: atom() | String.t()
  def safe_to_provider_atom(str) when is_binary(str) do
    try do
      String.to_existing_atom(str)
    rescue
      ArgumentError ->
        if str in @known_providers do
          String.to_atom(str)
        else
          str
        end
    end
  end

  def safe_to_provider_atom(atom) when is_atom(atom), do: atom
end
