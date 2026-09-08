# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ApprovalScope do
  @moduledoc """
  How far an approval reaches, spelled once.

  A person answers a card `:once`, `:conversation` ("always for this
  chat"), `:always` (the agent, everywhere in this estate) or `:never`.
  The wire, the card, the pane and the runner all carry the answer as a
  string somewhere, and each used to decode it on its own — one of them
  without `never`, which turned a "never" into a "once". This is the one
  codec, and the one place the standing annotation's two spellings
  (`:conversation` | `"conversation"` | `false` | `nil`) meet.
  """

  @type t :: :once | :conversation | :always | :never
  @scopes [:once, :conversation, :always, :never]

  @doc "Every scope, in the order a card offers them."
  @spec all() :: [t()]
  def all, do: @scopes

  @doc """
  The scope a string or atom names; anything else is `:once` — the answer
  that reaches no further than the click.
  """
  @spec parse(term()) :: t()
  def parse(scope) when scope in @scopes, do: scope
  def parse("conversation"), do: :conversation
  def parse("always"), do: :always
  def parse("never"), do: :never
  def parse(_), do: :once

  @doc "The wire spelling of a scope."
  @spec to_string(t()) :: String.t()
  def to_string(scope) when scope in @scopes, do: Atom.to_string(scope)

  @doc "Whether a scope is a STANDING answer — one that answers for calls nobody has seen yet."
  @spec standing?(t()) :: boolean()
  def standing?(scope), do: scope in [:conversation, :always]

  @doc """
  An action's `standing:` declaration as it arrives from any surface —
  the annotation's atom, the row's JSON string, or nothing — as one of
  `:conversation` (a standing allow for one conversation only), `false`
  (none at all) or `nil` (either scope).
  """
  @spec standing(term()) :: :conversation | false | nil
  def standing(:conversation), do: :conversation
  def standing("conversation"), do: :conversation
  def standing(false), do: false
  def standing(_), do: nil
end
