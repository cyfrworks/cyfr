# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Semver do
  @moduledoc """
  The component domain's spelling of the one version ordering.

  The comparator itself is `Cyfr.Semver`, where the identity domain reads
  it too (`Cyfr.ComponentRow.latest_of/1` orders rows with it): registered
  versions are validated semver, so unparsable input reaches ordering only
  from remote tag lists and seed directory names, and the order is total
  anyway. Never raises. Supersession (`strictly_newer?/2`) is deliberately
  more conservative: true only when BOTH sides parse.
  """

  @type comparison :: Cyfr.Semver.comparison()

  @doc """
  Parse a version string — a thin `Version.parse/1`.

  ## Examples

      iex> Compendium.Semver.parse("1.2.3")
      {:ok, %Version{major: 1, minor: 2, patch: 3}}

      iex> Compendium.Semver.parse("not-semver")
      :error

  """
  @spec parse(String.t()) :: {:ok, Version.t()} | :error
  defdelegate parse(version), to: Cyfr.Semver

  @doc """
  Whether the string is valid semver.

  ## Examples

      iex> Compendium.Semver.semver?("1.0.0-rc1")
      true

      iex> Compendium.Semver.semver?("1.2.3.4")
      false

  """
  @spec semver?(term()) :: boolean()
  defdelegate semver?(version), to: Cyfr.Semver

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
  defdelegate compare(a, b), to: Cyfr.Semver

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
  defdelegate gt?(a, b), to: Cyfr.Semver

  @doc """
  Sort version strings newest-first under the total order — parsable
  versions semver-descending, unparsable ones last, by string.
  """
  @spec sort_desc([String.t()]) :: [String.t()]
  defdelegate sort_desc(versions), to: Cyfr.Semver

  @doc """
  Sort elements by a version projected from each, newest first — the one
  spelling of "semver-descending by key" (`sort_desc/1` is the
  bare-strings form), so no view re-derives the comparator inline.
  """
  @spec sort_desc_by([elem], (elem -> String.t())) :: [elem] when elem: term()
  defdelegate sort_desc_by(items, key_fun), to: Cyfr.Semver

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
  defdelegate strictly_newer?(newer, version), to: Cyfr.Semver
end
