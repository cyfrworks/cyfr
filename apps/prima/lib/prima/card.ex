# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Card do
  @moduledoc """
  A card as the desktop draws it: data, never a frame.

  What a card may show is declared once, in its tincture's manifest, by
  the grammar `Prima.Manifest.Tincture` reads (`Prima.Manifest.Tincture.Card`):
  its name, its title, the projection fields its `number` and short `list`
  show, its `image` (a path inside the version), its buttons (each bound
  to a declared system action with fixed arguments) and the `stream` that
  refreshes it. `declaration()` is that struct, referenced here and never
  restated.

  An instance is what one refresh answers, projected through the
  declaration (`project/3`): the declared title, the value of the
  declared `number` field, the entries of the declared `list` field, the
  declared image, the declared buttons and stream, and when it was
  refreshed. A card discloses only what its tincture declared: a
  projection field the declaration does not name is dropped, and a
  declared field the projection does not carry is absent.
  """

  alias Prima.Manifest.Tincture

  @typedoc "What a tincture declares for one card (`Prima.Manifest.Tincture.Card`)."
  @type declaration :: Tincture.Card.t()

  @typedoc "A card's number: an integer, or short text (a formatted amount, say)."
  @type number_value :: integer() | String.t()

  @typedoc "One card, as a refresh answered it."
  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t(),
          number: number_value() | nil,
          list: [String.t()],
          image: String.t() | nil,
          buttons: [Tincture.Button.t()],
          stream: String.t() | nil,
          refreshed_at: DateTime.t()
        }

  @enforce_keys [:name, :title, :refreshed_at]
  defstruct [
    :name,
    :title,
    :refreshed_at,
    number: nil,
    list: [],
    image: nil,
    buttons: [],
    stream: nil
  ]

  @typedoc "A refusal: the tag and a sentence."
  @type error :: {:invalid_card, String.t()}

  # Bounds on what one refresh may put on a card, so a card is drawable
  # before anything reads it.
  @max_number 32
  @max_list 8
  @max_entry 80

  @doc "The declared card `name` of a tincture's declaration, or `:error`."
  @spec declared(Tincture.t(), String.t()) :: {:ok, declaration()} | :error
  def declared(%Tincture{cards: cards}, name) when is_binary(name) do
    case Enum.find(cards, &(&1.name == name)) do
      nil -> :error
      card -> {:ok, card}
    end
  end

  @doc """
  The card `declaration` shows for `projection`, a refresh's answer (a
  string-keyed map), refreshed at `refreshed_at`. The declared `number`
  field must hold an integer or text of at most #{@max_number} characters,
  and the declared `list` field a list of at most #{@max_list} texts of at
  most #{@max_entry} characters each; any other field of the projection
  is dropped. The first shape that is wrong is the refusal.
  """
  @spec project(declaration(), map(), DateTime.t()) :: {:ok, t()} | {:error, error()}
  def project(%Tincture.Card{} = declaration, projection, %DateTime{} = refreshed_at)
      when is_map(projection) do
    with {:ok, number} <- number(declaration, projection),
         {:ok, list} <- list(declaration, projection) do
      {:ok,
       %__MODULE__{
         name: declaration.name,
         title: declaration.title,
         number: number,
         list: list,
         image: declaration.image,
         buttons: declaration.buttons,
         stream: declaration.stream,
         refreshed_at: refreshed_at
       }}
    end
  end

  def project(%Tincture.Card{name: name}, _projection, %DateTime{}),
    do: refuse("card #{name}: a refresh answers an object")

  @doc """
  The card as the desktop receives it: a string-keyed map, absent fields
  omitted, `refreshed_at` in ISO 8601.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = card) do
    %{
      "name" => card.name,
      "title" => card.title,
      "list" => card.list,
      "buttons" =>
        Enum.map(card.buttons, &%{"label" => &1.label, "action" => &1.action, "args" => &1.args}),
      "refreshed_at" => DateTime.to_iso8601(card.refreshed_at)
    }
    |> put_present("number", card.number)
    |> put_present("image", card.image)
    |> put_present("stream", card.stream)
  end

  defp number(%Tincture.Card{number: nil}, _projection), do: {:ok, nil}

  defp number(%Tincture.Card{name: name, number: field}, projection) do
    case Map.get(projection, field) do
      nil ->
        {:ok, nil}

      value when is_integer(value) ->
        {:ok, value}

      value when is_binary(value) ->
        if String.length(value) <= @max_number,
          do: {:ok, value},
          else: refuse("card #{name}: #{field} is text of at most #{@max_number} characters")

      _other ->
        refuse("card #{name}: #{field} must be an integer or short text")
    end
  end

  defp list(%Tincture.Card{list: nil}, _projection), do: {:ok, []}

  defp list(%Tincture.Card{name: name, list: field}, projection) do
    case Map.get(projection, field) do
      nil ->
        {:ok, []}

      entries when is_list(entries) and length(entries) <= @max_list ->
        if Enum.all?(entries, &(is_binary(&1) and String.length(&1) <= @max_entry)),
          do: {:ok, entries},
          else: refuse("card #{name}: #{field} holds texts of at most #{@max_entry} characters")

      entries when is_list(entries) ->
        refuse("card #{name}: #{field} holds at most #{@max_list} entries")

      _other ->
        refuse("card #{name}: #{field} must be a list of texts")
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp refuse(sentence), do: {:error, {:invalid_card, sentence}}
end
