# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.CanvasPrefs do
  @moduledoc """
  The preferences document of a desktop: what one person keeps for one
  canvas, held to the schema its active version declares
  (`Prima.Manifest.Tincture.Desktop`'s `prefs`). Arca keeps it
  (`Arca.CanvasPrefs`).

      %{
        "widgets" => %{
          widget_id => %{"on" => boolean, "rect" => %{"x", "y", "w", "h"}, field => value}
        },
        "desktop" => %{field => value}
      }

    * Both keys are present in a document, either possibly empty
      (`empty/0`).
    * A widget's entry may name `on` (true or false), `rect` (a window's
      geometry, `Prima.Layout.geometry?/1`) and the fields its schema
      declares, each optional; `desktop` names the desktop's declared
      fields, each optional.
    * A field's value is of its declared type: `boolean` true or false;
      `integer` and `number` a JSON integer of magnitude at most
      `Prima.JCS.max_safe_integer/0`; `string` UTF-8 text of at most its
      `max` code points with no control character; `enum` one of its
      `values`. Canonical JSON (`Prima.JCS`) carries no fraction, so a
      `number` holds whole values alone.

  `validate/2` holds what a desktop sends, `widgets`, `desktop` or both,
  to the schema. `merge/2` lays it over the stored document: each widget
  entry it names replaces the stored entry whole, widgets it does not
  name are kept, and a `desktop` it names replaces the stored one whole.
  `project/2` reduces a document to what a schema admits now, for a
  version whose schema differs from the one the document was written
  under.

  `encode/1` is the document's canonical JSON, `decode/1` reads only
  bytes exactly as `encode/1` writes them, `digest/1` is the `sha256:`
  digest of those bytes, and `max_bytes/0` caps them.
  """

  alias Prima.Manifest.Tincture

  @top_keys ~w(widgets desktop)
  @max_bytes 16_384

  # The types of the fields every widget carries, by the names
  # `Prima.Manifest.Tincture.widget_fixed_fields/0` gives them: a name it
  # adds fails the build here until its type is written.
  @fixed Map.new(Tincture.widget_fixed_fields(), fn
           "on" -> {"on", %{"type" => "boolean"}}
           "rect" -> {"rect", %{"type" => "rect"}}
         end)

  @control ~r/[\x{0}-\x{1F}\x{7F}-\x{9F}]/u

  @typedoc "A field's value."
  @type value :: boolean() | integer() | String.t() | %{String.t() => non_neg_integer()}

  @typedoc "A preferences document: `widgets` and `desktop`, both present."
  @type t :: %{
          required(String.t()) => %{String.t() => %{String.t() => value()} | value()}
        }

  @typedoc "What a desktop sends: `widgets`, `desktop` or both, validated by `validate/2`."
  @type incoming :: %{optional(String.t()) => %{String.t() => %{String.t() => value()} | value()}}

  @typedoc "The schema: `Prima.Manifest.Tincture.Desktop`'s `prefs`."
  @type schema :: Tincture.Desktop.prefs()

  @doc "The document of a person who kept nothing: no widget, no desktop field."
  @spec empty() :: t()
  def empty, do: %{"widgets" => %{}, "desktop" => %{}}

  @doc "The cap on a document's encoded bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  What a desktop sends, held to `schema`: an object naming `widgets`,
  `desktop` or both and nothing else; each widget one the schema
  declares, each field one its widget or the desktop declares (`on` and
  `rect` on every widget), each value of its type (the module doc).
  Answers the incoming document as validated, with the keys it named, or
  `{:error, sentence}` naming the first path refused, in sorted order:
  the top keys, then each widget, then the desktop. A sentence shows a
  value only by its shape or as short text.
  """
  @spec validate(term(), schema()) :: {:ok, incoming()} | {:error, String.t()}
  def validate(%{} = incoming, %{widgets: widgets, desktop: desktop})
      when not is_struct(incoming) do
    with :ok <- top_keys(incoming),
         :ok <- validate_widgets(Map.get(incoming, "widgets", %{}), widgets),
         :ok <- validate_section(Map.get(incoming, "desktop", %{}), desktop, "desktop") do
      {:ok, incoming}
    end
  end

  def validate(_incoming, %{widgets: _, desktop: _}),
    do: {:error, "the preferences must be an object of widgets, desktop or both"}

  @doc """
  `document` reduced to what `schema` admits: widgets it does not
  declare, fields their widget or the desktop does not declare, and
  values their type no longer admits are dropped. A declared widget whose
  every field is dropped keeps an empty entry.
  """
  @spec project(t(), schema()) :: t()
  def project(%{"widgets" => widgets, "desktop" => desktop}, %{
        widgets: declared,
        desktop: fields
      }) do
    %{
      "widgets" =>
        for {id, entry} <- widgets, Map.has_key?(declared, id), into: %{} do
          {id, admitted(entry, widget_fields(declared, id))}
        end,
      "desktop" => admitted(desktop, fields)
    }
  end

  @doc """
  `incoming` (`validate/2`) laid over `stored`: each widget entry
  `incoming` names replaces `stored`'s entry for that id whole, the
  widgets it does not name are kept, and its `desktop`, when it names
  one, replaces `stored`'s whole.
  """
  @spec merge(t(), incoming()) :: t()
  def merge(%{"widgets" => widgets, "desktop" => desktop}, incoming) do
    %{
      "widgets" => Map.merge(widgets, Map.get(incoming, "widgets", %{})),
      "desktop" => Map.get(incoming, "desktop", desktop)
    }
  end

  @doc """
  The canonical JSON bytes (`Prima.JCS`) of `document`. Raises
  `ArgumentError` for a term that is not a document.
  """
  @spec encode(t()) :: binary()
  def encode(document) do
    if document?(document) do
      {:ok, bytes} = Prima.JCS.encode(document)
      bytes
    else
      raise ArgumentError, "encode/1 takes a preferences document"
    end
  end

  @doc """
  The document `bytes` hold, or `{:error, :invalid_document}` for bytes
  that are not exactly what `encode/1` writes for one.
  """
  @spec decode(term()) :: {:ok, t()} | {:error, :invalid_document}
  def decode(bytes) when is_binary(bytes) do
    with {:ok, document} <- Prima.Json.decode(bytes),
         true <- document?(document),
         ^bytes <- encode(document) do
      {:ok, document}
    else
      _ -> {:error, :invalid_document}
    end
  end

  def decode(_bytes), do: {:error, :invalid_document}

  @doc "The document's digest: `sha256:` over `encode/1`."
  @spec digest(t()) :: String.t()
  def digest(document), do: Prima.Digest.sha256(encode(document))

  # ---- validation ------------------------------------------------------------

  defp top_keys(incoming) do
    case incoming |> Map.keys() |> Enum.reject(&(&1 in @top_keys)) do
      [] when map_size(incoming) > 0 ->
        :ok

      [] ->
        {:error, "the preferences must name widgets, desktop or both"}

      extra ->
        {:error, "the preferences name unknown key(s): #{shown(extra)}"}
    end
  end

  defp validate_widgets(%{} = widgets, declared) when not is_struct(widgets) do
    widgets
    |> Enum.sort()
    |> first_refusal(fn {id, entry} ->
      if is_binary(id) and Map.has_key?(declared, id),
        do: validate_section(entry, widget_fields(declared, id), "widgets.#{id}"),
        else: {:error, "widgets: #{show(id)} is no widget this desktop declares"}
    end)
  end

  defp validate_widgets(_widgets, _declared), do: {:error, "widgets must be an object"}

  defp validate_section(%{} = section, fields, where) when not is_struct(section) do
    section
    |> Enum.sort()
    |> first_refusal(fn {name, value} ->
      case is_binary(name) and Map.fetch(fields, name) do
        {:ok, type} -> admit(type, value, "#{where}.#{name}")
        _undeclared -> {:error, "#{where}: #{show(name)} is no field it declares"}
      end
    end)
  end

  defp validate_section(_section, _fields, where), do: {:error, "#{where} must be an object"}

  defp admit(type, value, where) do
    if admits?(type, value),
      do: :ok,
      else: {:error, "#{where} must be #{expected(type)}, got #{show(value)}"}
  end

  defp expected(%{"type" => "boolean"}), do: "true or false"

  defp expected(%{"type" => "integer"}), do: whole_numbers()

  defp expected(%{"type" => "number"}),
    do: whole_numbers() <> " (the document keeps no fraction)"

  defp expected(%{"type" => "string", "max" => max}),
    do: "text of at most #{max} code points with no control character"

  defp expected(%{"type" => "enum"}), do: "one of its declared values"

  defp expected(%{"type" => "rect"}),
    do: "a window's geometry: exactly x, y, w and h, in whole hundredths of a percent"

  # ---- the types ---------------------------------------------------------------

  # One rule per type, read by `validate/2` and `project/2` alike.
  defp admits?(%{"type" => "boolean"}, value), do: is_boolean(value)
  defp admits?(%{"type" => type}, value) when type in ["integer", "number"], do: whole?(value)

  defp admits?(%{"type" => "string", "max" => max}, value) do
    is_binary(value) and String.valid?(value) and not Regex.match?(@control, value) and
      code_points(value) <= max
  end

  defp admits?(%{"type" => "enum", "values" => values}, value),
    do: is_binary(value) and value in values

  defp admits?(%{"type" => "rect"}, value), do: Prima.Layout.geometry?(value)

  defp whole?(value), do: is_integer(value) and abs(value) <= Prima.JCS.max_safe_integer()

  defp whole_numbers do
    max = Prima.JCS.max_safe_integer()
    "a whole number from -#{max} to #{max}"
  end

  defp widget_fields(declared, id), do: Map.merge(Map.fetch!(declared, id), @fixed)

  defp admitted(section, fields) do
    for {name, value} <- section,
        type = Map.get(fields, name),
        type != nil and admits?(type, value),
        into: %{},
        do: {name, value}
  end

  # ---- the document's shape ----------------------------------------------------

  # What a document holds whatever its schema: the two sections, a
  # widget's fixed fields of their types, and every other value one a
  # field type admits.
  defp document?(%{"widgets" => widgets, "desktop" => desktop} = document)
       when map_size(document) == 2,
       do: object?(widgets, fn {_id, entry} -> entry?(entry) end) and section?(desktop)

  defp document?(_term), do: false

  defp entry?(entry) do
    object?(entry, fn
      {name, value} when is_map_key(@fixed, name) -> admits?(Map.fetch!(@fixed, name), value)
      {_name, value} -> scalar?(value)
    end)
  end

  defp section?(section), do: object?(section, fn {_name, value} -> scalar?(value) end)

  defp object?(%{} = map, member?) when not is_struct(map) do
    Enum.all?(map, fn {key, _value} = pair -> text?(key) and member?.(pair) end)
  end

  defp object?(_term, _member?), do: false

  defp scalar?(value),
    do: is_boolean(value) or whole?(value) or (is_binary(value) and String.valid?(value))

  defp text?(value), do: is_binary(value) and String.valid?(value)

  # ---- helpers ---------------------------------------------------------------

  defp first_refusal(list, fun) do
    Enum.reduce_while(list, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        refusal -> {:halt, refusal}
      end
    end)
  end

  # A bound on text counts Unicode code points, never graphemes.
  defp code_points(text), do: text |> String.codepoints() |> length()

  defp shown(values), do: values |> Enum.map(&show/1) |> Enum.sort() |> Enum.join(", ")

  # A refusal names what it was handed by its shape, never by an arbitrary
  # term's inspection, and quotes only short printable text, so a sentence
  # stays a sentence.
  defp show(value) when is_binary(value) do
    cond do
      not String.valid?(value) -> "bytes that are not UTF-8 text"
      Regex.match?(@control, value) -> "text with a control character"
      byte_size(value) <= 64 -> ~s("#{value}")
      true -> "a string of #{String.length(value)} characters"
    end
  end

  defp show(nil), do: "nothing"
  defp show(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp show(value) when is_list(value), do: "a list"
  defp show(value) when is_map(value), do: "an object"
  defp show(_value), do: "a value of another kind"
end
