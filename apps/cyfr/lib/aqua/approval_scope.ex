# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ApprovalScope do
  @moduledoc """
  How far an approval reaches, spelled once.

  Encodes and decodes `:once`, `:thread`, `:always` and `:never` for
  the wire, cards, panes and runner. Action standing declarations use
  `Grimoire.Annotations.standing/1`.
  """

  @type t :: :once | :thread | :always | :never
  @scopes [:once, :thread, :always, :never]

  @doc "Every scope, in the order a card offers them."
  @spec all() :: [t()]
  def all, do: @scopes

  @doc """
  The scope a string or atom names; anything else is `:once` — the answer
  that reaches no further than the click.
  """
  @spec parse(term()) :: t()
  def parse(scope) when scope in @scopes, do: scope
  def parse("thread"), do: :thread
  def parse("always"), do: :always
  def parse("never"), do: :never
  def parse(_), do: :once

  @doc "The wire spelling of a scope."
  @spec to_string(t()) :: String.t()
  def to_string(scope) when scope in @scopes, do: Atom.to_string(scope)

  @doc "Whether a scope is a STANDING answer — one that answers for calls nobody has seen yet."
  @spec standing?(t()) :: boolean()
  def standing?(scope), do: scope in [:thread, :always]
end
