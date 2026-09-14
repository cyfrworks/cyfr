# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.Annotations do
  @moduledoc """
  One reader for a tool's action-annotation map, wherever it appears.

  The same annotations travel under three spellings: a provider's
  `tools/0` map carries `annotations: %{actions: ...}` (atom keys), the
  registry cache carries that same atom shape inside its `meta`, and the
  wire tool definition wraps it as `"annotations" => %{actions: ...}` — a
  string outer key with the provider's atom-keyed map inside. Reading the
  wrong spelling does not crash, it returns nothing: one caller classified
  every internal tool's kind as nil that way, silently. Every reader goes
  through here so the spelling is decided once.

  Absence stays fail-closed at the call sites: `planes/2` answers `[]`,
  `auth/2` answers `:required`, the rest answer `nil`.
  """

  @type source :: map()

  @doc """
  The action map (string verb => annotation) from any accepted source
  shape; `%{}` when the source carries none.
  """
  @spec actions_of(source()) :: %{optional(String.t()) => map()}
  def actions_of(%{annotations: %{actions: actions}}) when is_map(actions), do: actions
  def actions_of(%{"annotations" => %{actions: actions}}) when is_map(actions), do: actions
  def actions_of(_), do: %{}

  @doc "One action's annotation, or nil — unknown action or no declaration."
  @spec annotation(source(), String.t() | nil) :: map() | nil
  def annotation(_source, nil), do: nil
  def annotation(source, action), do: Map.get(actions_of(source), action)

  @doc "The action's kind, when declared as an atom; nil otherwise."
  @spec kind(source(), String.t() | nil) :: atom() | nil
  def kind(source, action) do
    case annotation(source, action) do
      %{kind: kind} when is_atom(kind) -> kind
      _ -> nil
    end
  end

  @doc "The action's planes; `[]` when undeclared, so absence stays fail-closed."
  @spec planes(source(), String.t() | nil) :: [atom()]
  def planes(source, action) do
    case annotation(source, action) do
      %{planes: planes} when is_list(planes) -> planes
      _ -> []
    end
  end

  @doc """
  Whether a running chain reaches the action through the HOST rather than
  the catalog: the formula host intercepts the request and runs it under
  the chain's authority itself, so the catalog never dispatches it
  in-chain and yet a chain can run it.
  """
  @spec host_intercepted?(source(), String.t() | nil) :: boolean()
  def host_intercepted?(source, action), do: field(source, action, :host) == :intercepted

  @doc "The action's auth requirement; `:required` when undeclared."
  @spec auth(source(), String.t() | nil) :: atom()
  def auth(source, action) do
    case annotation(source, action) do
      %{} = annotation -> Map.get(annotation, :auth, :required)
      _ -> :required
    end
  end

  @spec permission(source(), String.t() | nil) :: atom() | nil
  def permission(source, action), do: field(source, action, :permission)

  @spec consent(source(), String.t() | nil) :: atom() | nil
  def consent(source, action), do: field(source, action, :consent)

  @spec scope(source(), String.t() | nil) :: atom() | nil
  def scope(source, action), do: field(source, action, :scope)

  @doc """
  The action's standing rule — `:thread`, `false`, or nil when the
  action declares none (any standing scope).
  """
  @spec standing(source(), String.t() | nil) :: :thread | false | nil
  def standing(source, action), do: field(source, action, :standing)

  @doc """
  The `recovery` annotation of an action: `:replay_safe` for a read
  reviewed as safe to re-dispatch after an uncertain recovery, nil for
  every other action.
  """
  @spec recovery(map(), String.t()) :: :replay_safe | nil
  def recovery(source, action) do
    case field(source, action, :recovery) do
      :replay_safe -> :replay_safe
      _ -> nil
    end
  end

  @doc """
  The one codec for a `standing` value as it travels: the annotation's
  atom, the wire's string, or nothing. `standing/1` decodes any spelling
  to `:thread` (a standing allow for one thread only),
  `false` (none at all) or `nil` (either scope); `standing_to_wire/1` is
  the string the intent carries.
  """
  @spec standing(term()) :: :thread | false | nil
  def standing(:thread), do: :thread
  def standing("thread"), do: :thread
  def standing(false), do: false
  def standing(_), do: nil

  @spec standing_to_wire(term()) :: String.t() | false | nil
  def standing_to_wire(value) do
    case standing(value) do
      :thread -> "thread"
      false -> false
      nil -> nil
    end
  end

  defp field(source, action, key) do
    case annotation(source, action) do
      %{} = annotation -> Map.get(annotation, key)
      _ -> nil
    end
  end

  @doc """
  The action map read strictly from a provider's atom-keyed `tools/0`
  shape — no other spelling accepted. The boot audit uses this arm: the
  registry caches `Map.get(tool, :annotations)`, so a provider that
  spelled the key any other way would register with no annotations and
  default-deny at dispatch. The audit must reject exactly what the load
  would break.
  """
  @spec declared_actions(map()) :: %{optional(String.t()) => map()}
  def declared_actions(%{annotations: %{actions: actions}}) when is_map(actions), do: actions
  def declared_actions(_), do: %{}
end
