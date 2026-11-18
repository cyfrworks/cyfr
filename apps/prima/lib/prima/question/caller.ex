# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Question.Caller do
  @moduledoc """
  Who started a run's root, as a component's question names it: `:person`,
  `{:device, id}`, `{:tincture, reference}`, `{:agent, name}`,
  `{:schedule, id}`, `{:webhook, id}`, `{:key, id}`, or `:unknown`. A child
  has its root's caller. The caller names the starter for a card and for a
  standing answer's match; it admits nothing.

  Its text is the one spelling every store and wire uses: `person`,
  `unknown`, or the kind and its id joined by a colon (`device:<id>`), read
  back by splitting at the first colon, so an id may itself hold colons.
  `any` is reserved for a standing answer that covers every caller
  (`any/0`) and is never a run's caller.

  Where two starters apply, the nearest is the caller, in the order
  `nearest/1` reads: tincture, agent, schedule, webhook, key, device,
  person.
  """

  @kinds [:tincture, :agent, :schedule, :webhook, :key, :device]
  @by_spelling Map.new(@kinds, &{Atom.to_string(&1), &1})
  @any "any"

  @type t ::
          :person
          | :unknown
          | {:device, String.t()}
          | {:tincture, String.t()}
          | {:agent, String.t()}
          | {:schedule, String.t()}
          | {:webhook, String.t()}
          | {:key, String.t()}

  @doc "The stored value of a standing answer that covers every caller."
  @spec any() :: String.t()
  def any, do: @any

  @doc "Whether `value` is a caller."
  @spec caller?(term()) :: boolean()
  def caller?(:person), do: true
  def caller?(:unknown), do: true
  def caller?({kind, id}) when kind in @kinds, do: id?(id)
  def caller?(_other), do: false

  @doc "A caller's text."
  @spec encode(t()) :: String.t()
  def encode(:person), do: "person"
  def encode(:unknown), do: "unknown"

  def encode({kind, id}) when kind in @kinds do
    if id?(id),
      do: Atom.to_string(kind) <> ":" <> id,
      else: raise(ArgumentError, "a caller's id is a non-empty string")
  end

  @doc """
  The caller a text names. A stored null is a root that recorded none and
  reads as `:unknown`; `any`, an unknown kind or an empty id is refused.
  """
  @spec decode(String.t() | nil) :: {:ok, t()} | {:error, {:unknown_caller, term()}}
  def decode(nil), do: {:ok, :unknown}
  def decode("person"), do: {:ok, :person}
  def decode("unknown"), do: {:ok, :unknown}

  def decode(text) when is_binary(text) do
    with [spelling, id] <- String.split(text, ":", parts: 2),
         {:ok, kind} <- Map.fetch(@by_spelling, spelling),
         true <- id?(id) do
      {:ok, {kind, id}}
    else
      _ -> {:error, {:unknown_caller, text}}
    end
  end

  def decode(other), do: {:error, {:unknown_caller, other}}

  @doc """
  The nearest of the starters that apply: the first in the order tincture,
  agent, schedule, webhook, key, device, person; `:unknown` when none
  does. `:unknown` among them is passed over.
  """
  @spec nearest([t()]) :: t()
  def nearest(callers) when is_list(callers) do
    Enum.find(@kinds, :none, fn kind -> Enum.any?(callers, &match?({^kind, _}, &1)) end)
    |> case do
      :none -> if :person in callers, do: :person, else: :unknown
      kind -> Enum.find(callers, &match?({^kind, _}, &1))
    end
  end

  defp id?(id), do: is_binary(id) and id != ""
end
