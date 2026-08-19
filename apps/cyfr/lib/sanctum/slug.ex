# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Slug do
  @moduledoc """
  Slugs from names, in the grammar personal namespaces use
  (`Sanctum.ComponentRef.personal_slug_regex/0`): lowercase alphanumerics
  and single hyphens, 1–39 bytes. A group's slug is derived from its name
  once, at creation; a person's slug is their namespace and never derived.
  """

  @max_length 39

  @doc """
  Derive a slug from a display name; `nil` when nothing usable remains.

      iex> Sanctum.Slug.from_name("Home & Family!")
      "home-family"
  """
  @spec from_name(String.t() | nil) :: String.t() | nil
  def from_name(name) when is_binary(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, @max_length)
      |> String.trim("-")

    if valid?(slug), do: slug
  end

  def from_name(_), do: nil

  @doc """
  Derive a slug from an email address: the local part, in the same grammar.
  A string with no `@` is taken whole, so a bare handle works too.

      iex> Sanctum.Slug.from_email("alice.smith+tag@example.com")
      "alice-smith-tag"
  """
  @spec from_email(String.t() | nil) :: String.t() | nil
  def from_email(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [local, _domain] -> from_name(local)
      [local] -> from_name(local)
    end
  end

  def from_email(_), do: nil

  @doc "Whether the string is a well-formed slug."
  @spec valid?(String.t() | nil) :: boolean()
  def valid?(slug), do: Sanctum.ComponentRef.valid_personal_slug?(slug)
end
