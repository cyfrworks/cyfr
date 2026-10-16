# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Source do
  @moduledoc """
  Where material a turn read came from. The classes are closed:

    * `pinned` — the athanor's pinned page, read into every prompt;
    * `filed` — a filed note, read or shown in the notes index;
    * `files_by_grant` — a file read through the turn's storage grant;
    * `vault_disclosed` — a value a vault entry disclosed to the turn;
    * `outside` — anything from outside the athanor: an external tool, a
      host the HTTP hand read, a component whose grant reaches the
      network, a webhook payload or a feed. Its `name` says which tool,
      host or feed; the other classes carry none.

  The canonical JSON of a source is `{"class", "name"}`, `name` null but
  for an outside source, and a set is a sorted, duplicate-free list of
  them. A source whose class is unknown or absent reads as `outside`,
  keeping whatever name it carried, and a set that does not decode reads
  as one unnamed outside source: provenance that cannot be read is never
  read as the athanor's own. Model outputs carry no source: what a model
  wrote is derived from what its turn read.

  `unsettled` is not a class. It is a refusal for bytes of a write that
  never settled, which no source can name.
  """

  @classes ~w(pinned filed files_by_grant vault_disclosed outside)a
  @by_spelling Map.new(@classes, &{Atom.to_string(&1), &1})
  @order @classes |> Enum.with_index() |> Map.new()

  @type class :: :pinned | :filed | :files_by_grant | :vault_disclosed | :outside

  @type t :: %__MODULE__{class: class(), name: String.t() | nil}

  @enforce_keys [:class]
  defstruct [:class, :name]

  @doc "The classes, in their fixed order."
  @spec classes() :: [class()]
  def classes, do: @classes

  @doc """
  A source of `class`. An outside source names its origin; a source of
  any other class names none, and a name given to one is dropped.
  """
  @spec new(class(), String.t() | nil) :: t()
  def new(class, name \\ nil)

  def new(:outside, name), do: %__MODULE__{class: :outside, name: name(name)}
  def new(class, _name) when class in @classes, do: %__MODULE__{class: class}

  @doc "An outside source named by `name`: the tool, host or feed it came from."
  @spec outside(String.t() | nil) :: t()
  def outside(name), do: new(:outside, name)

  @doc "Whether `source` is an outside source."
  @spec outside?(t()) :: boolean()
  def outside?(%__MODULE__{class: :outside}), do: true
  def outside?(%__MODULE__{}), do: false

  @doc "The canonical JSON object of one source."
  @spec to_json(t()) :: %{String.t() => String.t() | nil}
  def to_json(%__MODULE__{class: class, name: name}),
    do: %{"class" => Atom.to_string(class), "name" => name}

  @doc """
  One source from its JSON object (string or atom keys). An unknown or
  absent class reads as an outside source under the name it carried.
  """
  @spec from_json(term()) :: t()
  def from_json(%{} = json) do
    name = Map.get(json, "name", Map.get(json, :name))

    case Map.fetch(@by_spelling, to_spelling(Map.get(json, "class", Map.get(json, :class)))) do
      {:ok, class} -> new(class, name)
      :error -> outside(name)
    end
  end

  def from_json(_json), do: outside(nil)

  @doc "A set as its canonical JSON text: sorted, without duplicates."
  @spec encode([t()]) :: String.t()
  def encode(sources) when is_list(sources),
    do: sources |> set() |> Enum.map(&to_json/1) |> Jason.encode!()

  @doc """
  A set from its JSON text. `nil` and the empty list are no sources; text
  that is not a JSON list of objects reads as one unnamed outside source,
  and each object as `from_json/1` reads it.
  """
  @spec decode(String.t() | nil) :: [t()]
  def decode(nil), do: []

  def decode(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, list} when is_list(list) -> list |> Enum.map(&from_json/1) |> set()
      _unreadable -> [outside(nil)]
    end
  end

  def decode(_text), do: [outside(nil)]

  @doc "A set as a list of canonical JSON objects."
  @spec to_json_list([t()]) :: [%{String.t() => String.t() | nil}]
  def to_json_list(sources) when is_list(sources), do: sources |> set() |> Enum.map(&to_json/1)

  @doc "A list of sources as a set: sorted by class order, then name, without duplicates."
  @spec set([t()]) :: [t()]
  def set(sources) when is_list(sources) do
    sources
    |> Enum.uniq_by(&{&1.class, &1.name})
    |> Enum.sort_by(&{Map.fetch!(@order, &1.class), &1.name || ""})
  end

  @doc "The union of two sets."
  @spec union([t()], [t()]) :: [t()]
  def union(left, right) when is_list(left) and is_list(right), do: set(left ++ right)

  @doc "The classes a set holds, in their fixed order."
  @spec classes_of([t()]) :: [class()]
  def classes_of(sources) when is_list(sources),
    do: sources |> Enum.map(& &1.class) |> Enum.uniq() |> Enum.sort_by(&Map.fetch!(@order, &1))

  @doc """
  The outside sources of `sources` that `covered` does not name. An
  outside source with no name is never covered: nothing can name it.
  """
  @spec uncovered([t()], [t()]) :: [t()]
  def uncovered(sources, covered) when is_list(sources) and is_list(covered) do
    named = for %__MODULE__{class: :outside, name: name} when is_binary(name) <- covered, do: name

    sources
    |> Enum.filter(&outside?/1)
    |> Enum.reject(&(is_binary(&1.name) and &1.name in named))
    |> set()
  end

  defp to_spelling(class) when is_atom(class) and not is_nil(class), do: Atom.to_string(class)
  defp to_spelling(class), do: class

  defp name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp name(_name), do: nil
end
