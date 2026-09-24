# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.TenancyScope do
  @moduledoc """
  The tenancy scope vocabulary, in one place.

  A scope answers which tenant a caller acts in: `athanor` names one
  athanor, `platform` names none and is the server's own operator scope,
  which reads across tenants. Two sides agree on the list — the identity
  domain converts and validates against it, the stored membership row is
  held to it — so it is declared here and read from here.

  One fact, one home: `t:t/0` is the scope an actor carries
  (`t:Prima.Actor.scope/0` is this type), `values/0` the strings a stored
  row is held to, `atoms/0` the same list converted. Spelling the two
  atoms again anywhere else is drift.

  Nothing about a scope is authority: holding the platform scope is what
  a system responsibility carries, and the decision to grant it is the
  identity domain's alone.
  """

  @scopes ~w(platform athanor)
  @atoms Enum.map(@scopes, &String.to_atom/1)

  @typedoc "The scope a context or an actor carries."
  @type t :: :platform | :athanor

  @doc ~s|The vocabulary as strings: `["platform", "athanor"]`.|
  @spec values() :: [String.t()]
  def values, do: @scopes

  @doc "The vocabulary as atoms: `[:platform, :athanor]`."
  @spec atoms() :: [atom()]
  def atoms, do: @atoms
end
