# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Layout do
  @moduledoc """
  The layout document: which tinctures sit where on a person's desktop,
  at what size, per posture. It is the person's, kept by Arca
  (`Arca.Layouts`) and published fenced; editing it is instant and can
  only arrange. Window geometry, which apps are open and what hardware is
  present stay with the device and are not in it.

      %Prima.Layout{
        version: 1,
        postures: %{
          "hand" | "desk" => %{
            desktop: ref,
            slots: [%{id, tincture: ref, size: :icon | :card | :full, order, card}],
            floating: [%{tincture: ref, position: %{x, y}}]
          }
        }
      }

    * A posture is `hand` or `desk`; a document names one or both, and a
      posture it does not name reads as the shipped default's
      (`posture/2`).
    * `desktop` is the one tincture the posture's desktop layer runs.
    * `slots` are the apps layer: each an `id` unique in its posture, the
      `tincture` it holds, its `size` and its `order`. `icon` and `card`
      are data the desktop draws; `full` is the tincture's own frame. A
      `card` slot may name which of its tincture's declared cards it
      shows (`card`, an identifier); without one the desktop shows the
      first declared card.
    * `floating` entries are placed over the desktop, with permission:
      the `tincture` and its `position`, `x` and `y` in hundredths of a
      percent of the viewport (0 to 10000), so a position means the same
      on every device.

  A tincture reference is a versionless tincture reference in its
  canonical spelling (`tincture:local.desktop`): a code change is a new
  version, and the layout follows it. A reference to a tincture nobody
  installed is valid and is kept; the desktop draws it as a placeholder.

  The document names tinctures, sizes and places and nothing else: an
  unknown key anywhere is refused, so a layout can never carry an
  operation, a stream or a grant.

  `validate/1` reads the JSON form (string keys) and answers the struct
  with its slots in `{order, id}` order; `to_json/1` writes it back.
  `encode/1` is the canonical JSON (`Prima.JCS`) Arca stores and
  `digest/1` its `sha256:` digest. `tests/fixtures/layout.json` holds a
  valid document, its canonical bytes and digest, and refused ones.
  """

  @postures ~w(desk hand)
  @sizes [:icon, :card, :full]
  @version 1

  @max_slots 64
  @max_floating 16
  @max_position 10_000

  @default_desktop "tincture:local.desktop"

  @document_keys ~w(version postures)
  @posture_keys ~w(desktop slots floating)
  @slot_keys ~w(id tincture size order card)
  @floating_keys ~w(tincture position)
  @position_keys ~w(x y)

  @slot_id ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/
  @card_name ~r/\A[a-z][a-z0-9_]{0,62}\z/

  @typedoc "A versionless tincture reference, canonically spelt."
  @type ref :: String.t()

  @typedoc "A posture's name."
  @type posture_name :: String.t()

  @typedoc "How a slot is drawn."
  @type size :: :icon | :card | :full

  @typedoc "One app slot."
  @type slot :: %{
          id: String.t(),
          tincture: ref(),
          size: size(),
          order: non_neg_integer(),
          card: String.t() | nil
        }

  @typedoc "One floating tincture and where it sits."
  @type floating :: %{
          tincture: ref(),
          position: %{x: non_neg_integer(), y: non_neg_integer()}
        }

  @typedoc "One posture's arrangement."
  @type posture :: %{desktop: ref(), slots: [slot()], floating: [floating()]}

  @typedoc "A layout document."
  @type t :: %__MODULE__{version: pos_integer(), postures: %{posture_name() => posture()}}

  @enforce_keys [:postures]
  defstruct version: @version, postures: %{}

  @typedoc "A refusal: the tag and a sentence."
  @type error :: {:invalid_layout, String.t()}

  @doc "The posture names a document may carry."
  @spec postures() :: [posture_name()]
  def postures, do: @postures

  @doc "The sizes a slot may take."
  @spec sizes() :: [size()]
  def sizes, do: @sizes

  @doc "The document version this module reads and writes."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  The shipped default: every posture runs the shipped desktop
  (`#{@default_desktop}`) with no slots and nothing floating.
  """
  @spec default() :: t()
  def default do
    empty = %{desktop: @default_desktop, slots: [], floating: []}
    %__MODULE__{postures: Map.new(@postures, &{&1, empty})}
  end

  @doc """
  The arrangement for posture `name`: the document's own, or the shipped
  default's when the document does not name it. `:error` for a name that
  is not a posture.
  """
  @spec posture(t(), term()) :: {:ok, posture()} | :error
  def posture(%__MODULE__{postures: postures}, name) when name in @postures do
    case Map.fetch(postures, name) do
      {:ok, posture} -> {:ok, posture}
      :error -> Map.fetch(default().postures, name)
    end
  end

  def posture(%__MODULE__{}, _name), do: :error

  @doc """
  A decoded JSON document held to the layout's shape, answered as the
  struct with each posture's slots in `{order, id}` order. The first shape
  that is wrong is the refusal.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, error()}
  def validate(%{} = document) do
    with :ok <- known_keys(document, @document_keys, "the layout"),
         :ok <- document_version(Map.get(document, "version")),
         {:ok, postures} <- postures(Map.get(document, "postures")) do
      {:ok, %__MODULE__{version: @version, postures: postures}}
    end
  end

  def validate(_other), do: refuse("the layout must be an object")

  @doc "The document's bytes decoded and validated (`validate/1`)."
  @spec decode(binary()) :: {:ok, t()} | {:error, error()}
  def decode(bytes) when is_binary(bytes) do
    case Prima.Json.decode(bytes) do
      {:ok, document} -> validate(document)
      {:error, :invalid_json} -> refuse("the layout is not JSON")
    end
  end

  @doc "The JSON form: string keys, absent optional fields omitted."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{version: version, postures: postures}) do
    %{
      "version" => version,
      "postures" => Map.new(postures, fn {name, posture} -> {name, posture_to_json(posture)} end)
    }
  end

  @doc "The canonical JSON bytes (`Prima.JCS`) of the document."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = layout) do
    {:ok, bytes} = Prima.JCS.encode(to_json(layout))
    bytes
  end

  @doc "The document's digest: `sha256:` over `encode/1`."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = layout), do: Prima.JCS.hash_binary(encode(layout))

  @doc "Every tincture the document names, each once, sorted."
  @spec tinctures(t()) :: [ref()]
  def tinctures(%__MODULE__{postures: postures}) do
    postures
    |> Map.values()
    |> Enum.flat_map(fn posture ->
      [posture.desktop | Enum.map(posture.slots, & &1.tincture)] ++
        Enum.map(posture.floating, & &1.tincture)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "One posture's arrangement in the JSON form `to_json/1` writes."
  @spec posture_to_json(posture()) :: map()
  def posture_to_json(posture) do
    %{
      "desktop" => posture.desktop,
      "slots" => Enum.map(posture.slots, &slot_json/1),
      "floating" =>
        Enum.map(posture.floating, fn entry ->
          %{
            "tincture" => entry.tincture,
            "position" => %{"x" => entry.position.x, "y" => entry.position.y}
          }
        end)
    }
  end

  # ---- JSON ------------------------------------------------------------------

  defp slot_json(slot) do
    json = %{
      "id" => slot.id,
      "tincture" => slot.tincture,
      "size" => Atom.to_string(slot.size),
      "order" => slot.order
    }

    if slot.card, do: Map.put(json, "card", slot.card), else: json
  end

  # ---- the shape -------------------------------------------------------------

  defp document_version(@version), do: :ok
  defp document_version(_other), do: refuse("the layout's version must be #{@version}")

  defp postures(%{} = postures) when map_size(postures) > 0 do
    case Enum.reject(Map.keys(postures), &(&1 in @postures)) do
      [] ->
        postures
        |> Enum.sort()
        |> collect(fn {name, posture} ->
          with {:ok, posture} <- arrangement(name, posture), do: {:ok, {name, posture}}
        end)
        |> case do
          {:ok, pairs} -> {:ok, Map.new(pairs)}
          refusal -> refusal
        end

      unknown ->
        refuse(
          "the layout names unknown posture(s): #{unknown |> Enum.map(&show/1) |> Enum.join(", ")}"
        )
    end
  end

  defp postures(_other),
    do: refuse("the layout's postures must be an object naming hand, desk or both")

  defp arrangement(name, %{} = posture) do
    with :ok <- known_keys(posture, @posture_keys, "posture #{name}"),
         {:ok, desktop} <- tincture(Map.get(posture, "desktop"), "posture #{name}: the desktop"),
         {:ok, slots} <- slots(name, Map.get(posture, "slots", [])),
         {:ok, floating} <- floating(name, Map.get(posture, "floating", [])) do
      {:ok, %{desktop: desktop, slots: slots, floating: floating}}
    end
  end

  defp arrangement(name, _other), do: refuse("posture #{name} must be an object")

  defp slots(name, slots) when is_list(slots) and length(slots) <= @max_slots do
    with {:ok, slots} <- collect(slots, &slot(name, &1)) do
      case slots |> Enum.frequencies_by(& &1.id) |> Enum.find(fn {_id, n} -> n > 1 end) do
        nil -> {:ok, Enum.sort_by(slots, &{&1.order, &1.id})}
        {id, _n} -> refuse("posture #{name}: the slot id #{show(id)} is used twice")
      end
    end
  end

  defp slots(name, slots) when is_list(slots),
    do: refuse("posture #{name} holds at most #{@max_slots} slots")

  defp slots(name, _other), do: refuse("posture #{name}: slots must be a list")

  defp slot(name, %{} = slot) do
    id = Map.get(slot, "id")
    where = "posture #{name}: slot #{show(id)}"

    with :ok <- known_keys(slot, @slot_keys, "posture #{name}: a slot"),
         :ok <- slot_id(name, id),
         {:ok, tincture} <- tincture(Map.get(slot, "tincture"), "#{where}: the tincture"),
         {:ok, size} <- size(where, Map.get(slot, "size")),
         {:ok, order} <- order(where, Map.get(slot, "order")),
         {:ok, card} <- card(where, size, Map.get(slot, "card")) do
      {:ok, %{id: id, tincture: tincture, size: size, order: order, card: card}}
    end
  end

  defp slot(name, _other), do: refuse("posture #{name}: a slot must be an object")

  defp slot_id(name, id) do
    if is_binary(id) and Regex.match?(@slot_id, id),
      do: :ok,
      else: refuse("posture #{name}: a slot's id must be a short lowercase name, got #{show(id)}")
  end

  defp size(_where, "icon"), do: {:ok, :icon}
  defp size(_where, "card"), do: {:ok, :card}
  defp size(_where, "full"), do: {:ok, :full}

  defp size(where, size),
    do: refuse("#{where}: the size must be icon, card or full, got #{show(size)}")

  defp order(_where, order) when is_integer(order) and order >= 0 and order <= 1_000_000,
    do: {:ok, order}

  defp order(where, _order), do: refuse("#{where}: the order must be a whole number from 0")

  defp card(_where, _size, nil), do: {:ok, nil}

  defp card(where, :card, card) do
    if is_binary(card) and Regex.match?(@card_name, card),
      do: {:ok, card},
      else: refuse("#{where}: the card must name a declared card, got #{show(card)}")
  end

  defp card(where, _size, _card), do: refuse("#{where}: only a card slot names a card")

  defp floating(name, entries) when is_list(entries) and length(entries) <= @max_floating,
    do: collect(entries, &floating_entry(name, &1))

  defp floating(name, entries) when is_list(entries),
    do: refuse("posture #{name} floats at most #{@max_floating} tinctures")

  defp floating(name, _other), do: refuse("posture #{name}: floating must be a list")

  defp floating_entry(name, %{} = entry) do
    where = "posture #{name}: a floating tincture"

    with :ok <- known_keys(entry, @floating_keys, where),
         {:ok, tincture} <- tincture(Map.get(entry, "tincture"), where),
         {:ok, position} <- position(where, Map.get(entry, "position")) do
      {:ok, %{tincture: tincture, position: position}}
    end
  end

  defp floating_entry(name, _other),
    do: refuse("posture #{name}: a floating entry must be an object")

  defp position(where, %{} = position) do
    x = Map.get(position, "x")
    y = Map.get(position, "y")

    with :ok <- known_keys(position, @position_keys, "#{where}: the position") do
      if coordinate?(x) and coordinate?(y),
        do: {:ok, %{x: x, y: y}},
        else: refuse("#{where}: x and y must be whole numbers from 0 to #{@max_position}")
    end
  end

  defp position(where, _other), do: refuse("#{where}: the position must be an object of x and y")

  defp coordinate?(value), do: is_integer(value) and value >= 0 and value <= @max_position

  # A versionless tincture reference, spelt as `Prima.ComponentRef` spells
  # it, so one tincture has one spelling in every document.
  defp tincture(ref, where) when is_binary(ref) do
    case Prima.ComponentRef.parse(ref) do
      {:ok, %Prima.ComponentRef{type: "tincture", version: nil} = parsed} ->
        if Prima.ComponentRef.to_string(parsed) == ref,
          do: {:ok, ref},
          else: refuse("#{where} must be spelt #{Prima.ComponentRef.to_string(parsed)}")

      {:ok, %Prima.ComponentRef{type: "tincture"}} ->
        refuse("#{where} names a tincture, never one of its versions, got #{show(ref)}")

      _ ->
        refuse(
          "#{where} must be a tincture reference (tincture:namespace.name), got #{show(ref)}"
        )
    end
  end

  defp tincture(ref, where),
    do:
      refuse("#{where} must be a tincture reference (tincture:namespace.name), got #{show(ref)}")

  # ---- helpers ---------------------------------------------------------------

  defp known_keys(map, known, where) do
    case map |> Map.keys() |> Enum.reject(&(&1 in known)) do
      [] ->
        :ok

      extra ->
        refuse(
          "#{where} declares unknown key(s): #{extra |> Enum.map(&show/1) |> Enum.sort() |> Enum.join(", ")}"
        )
    end
  end

  defp collect(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = refusal -> {:halt, refusal}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      refusal -> refusal
    end
  end

  # A refusal names what it was handed by its shape, never by an arbitrary
  # term's inspection, so a sentence stays a sentence.
  defp show(value) when is_binary(value) and byte_size(value) <= 64, do: ~s("#{value}")
  defp show(value) when is_binary(value), do: "a string of #{String.length(value)} characters"
  defp show(nil), do: "nothing"
  defp show(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp show(value) when is_list(value), do: "a list"
  defp show(value) when is_map(value), do: "an object"
  defp show(_value), do: "a value of another kind"

  defp refuse(sentence), do: {:error, {:invalid_layout, sentence}}
end
