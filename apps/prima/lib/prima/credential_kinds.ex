# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.CredentialKinds do
  @moduledoc """
  The credential kinds, in one place.

  A manifest need of one of these kinds names a credential an entry meets;
  every other need kind names a component. A person's vault entry holds any
  of them. An instance entry, which an operator supplies for every athanor,
  holds a key or a bundle of fields only: an OAuth account is an athanor's
  own entry.

  The manifest grammar, the vault, the instance entries, consent and every
  surface read the lists here, and `mix ops.gen.cli` renders them for the
  CLI. Spelling a list again anywhere else is drift.
  """

  @all ~w(api_key oauth bundle)
  @instance ~w(api_key bundle)

  @doc ~s|Every credential kind: `["api_key", "oauth", "bundle"]`.|
  @spec all() :: [String.t()]
  def all, do: @all

  @doc ~s|The kinds an instance entry holds: `["api_key", "bundle"]`.|
  @spec instance() :: [String.t()]
  def instance, do: @instance
end
