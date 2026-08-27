# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Semver do
  @moduledoc """
  The one version ordering. Registered versions are validated semver
  (`Sanctum.ComponentRef.validate_version/1` at every ingress), so
  unparsable input reaches ordering only from remote tag lists and seed
  directory names — and the order is total anyway: both parse →
  `Version.compare/2` (prereleases order correctly, `1.0.0-rc1 < 1.0.0`);
  exactly one parses → the parsable side is greater; neither → binary
  comparison. Never raises.

  Supersession (`strictly_newer?/2`) is deliberately more conservative:
  true only when BOTH sides parse — an unparsable seed directory name
  never supersedes anything.
  """

  @type comparison :: :lt | :eq | :gt

  @doc """
  Parse a version string — a thin `Version.parse/1`.

  ## Examples

      iex> Compendium.Semver.parse("1.2.3")
      {:ok, %Version{major: 1, minor: 2, patch: 3}}

      iex> Compendium.Semver.parse("not-semver")
      :error

  """
  @spec parse(String.t()) :: {:ok, Version.t()} | :error
  def parse(version) when is_binary(version), do: Version.parse(version)

  @doc """
  Whether the string is valid semver.

  ## Examples

      iex> Compendium.Semver.semver?("1.0.0-rc1")
      true

      iex> Compendium.Semver.semver?("1.2.3.4")
      false

  """
  @spec semver?(term()) :: boolean()
  def semver?(version), do: is_binary(version) and match?({:ok, _}, Version.parse(version))

  @doc """
  The total order.

  ## Examples

      iex> Compendium.Semver.compare("1.10.0", "1.2.0")
      :gt

      iex> Compendium.Semver.compare("1.0.0-rc1", "1.0.0")
      :lt

      iex> Compendium.Semver.compare("1.0.0", "not-semver")
      :gt

      iex> Compendium.Semver.compare("abc", "abd")
      :lt

  """
  @spec compare(String.t(), String.t()) :: comparison()
  def compare(a, b) when is_binary(a) and is_binary(b) do
    case {Version.parse(a), Version.parse(b)} do
      {{:ok, va}, {:ok, vb}} -> Version.compare(va, vb)
      {{:ok, _}, :error} -> :gt
      {:error, {:ok, _}} -> :lt
      {:error, :error} -> binary_compare(a, b)
    end
  end

  @doc """
  Nil-aware strict greater-than: `nil` never beats anything, anything
  beats `nil`.

  ## Examples

      iex> Compendium.Semver.gt?("2.0.0", nil)
      true

      iex> Compendium.Semver.gt?(nil, "0.0.1")
      false

  """
  @spec gt?(String.t() | nil, String.t() | nil) :: boolean()
  def gt?(nil, _b), do: false
  def gt?(_a, nil), do: true
  def gt?(a, b), do: compare(a, b) == :gt

  @doc """
  Sort version strings newest-first under the total order — parsable
  versions semver-descending, unparsable ones last, by string.
  """
  @spec sort_desc([String.t()]) :: [String.t()]
  def sort_desc(versions), do: Enum.sort(versions, &(compare(&1, &2) != :lt))

  @doc """
  The supersession predicate: `newer` strictly supersedes `version` only
  when BOTH parse and `newer` is greater — an unparsable name never
  supersedes anything.

  ## Examples

      iex> Compendium.Semver.strictly_newer?("1.1.0", "1.0.0")
      true

      iex> Compendium.Semver.strictly_newer?("weird-tag", "1.0.0")
      false

  """
  @spec strictly_newer?(String.t(), String.t()) :: boolean()
  def strictly_newer?(newer, version) when is_binary(newer) and is_binary(version) do
    case {Version.parse(newer), Version.parse(version)} do
      {{:ok, n}, {:ok, v}} -> Version.compare(n, v) == :gt
      _either_unparsable -> false
    end
  end

  defp binary_compare(a, b) do
    cond do
      a == b -> :eq
      a > b -> :gt
      true -> :lt
    end
  end
end
