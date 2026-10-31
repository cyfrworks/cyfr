# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.CredentialKinds do
  @moduledoc """
  The credential kinds, in one place.

  A manifest need of one of these kinds names a credential an entry meets;
  every other need kind names a component. A person's vault entry holds any
  of them. A share offers a key or a bundle of fields only: an OAuth
  account's dispense refreshes its token under its own athanor, so an
  OAuth account is used by its own athanor alone.

  The manifest grammar, the vault, shares, consent and every surface read
  the lists here, and `mix ops.gen.cli` renders them for the CLI. Spelling
  a list again anywhere else is drift.
  """

  @all ~w(api_key oauth bundle)
  @shareable ~w(api_key bundle)

  @doc ~s|Every credential kind: `["api_key", "oauth", "bundle"]`.|
  @spec all() :: [String.t()]
  def all, do: @all

  @doc ~s|The kinds a share offers: `["api_key", "bundle"]`.|
  @spec shareable() :: [String.t()]
  def shareable, do: @shareable
end
