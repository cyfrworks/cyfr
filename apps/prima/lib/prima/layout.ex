# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Layout do
  @moduledoc """
  The layout document: the person's canvases in order and, over each, per
  posture, the tinctures placed and where. It is the person's, kept by
  Arca (`Arca.Layouts`) and published fenced; editing it is instant and
  can only arrange. Which canvas a glass shows, window geometry, which
  apps are open and what hardware is present stay with the device and are
  not in it.

      %Prima.Layout{
        version: 2,
        canvases: [
          %{
            id: "home",
            tincture: ref,
            postures: %{
              "desk" | "hand" => %{
                apps: [%{tincture: ref, mode: :full | :column, order: n}],
                floating: [%{tincture: ref, position: %{x, y}}]
              }
            }
          }
        ]
      }

    * `canvases` are the person's canvases in order, at most 8; an empty
      list is valid, and the shell then draws its picker.
      Each canvas has exactly an `id` (a short lowercase name, unique in
      the document), the `tincture` it runs (each canvas names a tincture
      of its own) and its `postures`, which may be empty.
    * A posture is `hand` or `desk`. A posture has exactly `apps` and
      `floating`, either possibly empty, and a posture a canvas does not
      name reads as empty (`arrangement/2`).
    * `apps` are the tinctures placed over the canvas, at most 32: each
      exactly its `tincture`, its `mode` (`full`, the whole screen while it
      is shown; `column`, a column beside the canvas) and its `order`, a
      whole number from 0 to 1,000,000.
    * `floating` entries are placed over the canvas, with permission, at
      most 16: exactly the `tincture` and its `position`, `x` and `y`
      in hundredths of a percent of the viewport (0 to 10000), so a
      position means the same on every device.
    * A tincture appears at most once per canvas and posture, across its
      apps and its floating entries.

  A tincture reference is a versionless tincture reference in its
  canonical spelling (`tincture:local.canvas`): a code change is a new
  version, and the layout follows it. A reference to a tincture nobody
  installed is valid and is kept.

  The document names tinctures, modes and places and nothing else: an
  unknown key anywhere is refused, and so is a document of any other
  version, so a layout can never carry an operation, a stream or a grant.

  `validate/1` reads the JSON form (string keys) and answers the struct
  with each posture's apps in `{order, tincture}` order; `to_json/1`
  writes it back. `encode/1` is the canonical JSON (`Prima.JCS`) Arca
  stores and `digest/1` its `sha256:` digest. `tests/fixtures/layout.json`
  holds a valid document, its canonical bytes and digest, and refused
  ones.
  """

  @postures ~w(desk hand)
  @modes [:full, :column]
  @version 2

  @max_canvases 8
  @max_apps 32
  @max_floating 16
  @max_order 1_000_000
  @max_position 10_000

  @default_canvas "tincture:local.canvas"
  @default_id "home"

  @document_keys ~w(canvases version)
  @canvas_keys ~w(id postures tincture)
  @posture_keys ~w(apps floating)
  @app_keys ~w(mode order tincture)
  @floating_keys ~w(position tincture)
  @position_keys ~w(x y)

  @canvas_id ~r/\A[a-z0-9][a-z0-9-]{0,31}\z/

  @typedoc "A versionless tincture reference, canonically spelt."
  @type ref :: String.t()

  @typedoc "A posture's name."
  @type posture_name :: String.t()

  @typedoc "How an app is shown over its canvas."
  @type mode :: :full | :column

  @typedoc "One app placed over a canvas."
  @type app :: %{tincture: ref(), mode: mode(), order: non_neg_integer()}

  @typedoc "One floating tincture and where it sits."
  @type floating :: %{
          tincture: ref(),
          position: %{x: non_neg_integer(), y: non_neg_integer()}
        }

  @typedoc "One posture's placements over a canvas."
  @type posture :: %{apps: [app()], floating: [floating()]}

  @typedoc "One canvas: its id, the tincture it runs and its postures."
  @type canvas :: %{id: String.t(), tincture: ref(), postures: %{posture_name() => posture()}}

  @typedoc "One canvas as a posture arranges it."
  @type arranged :: %{
          id: String.t(),
          tincture: ref(),
          apps: [app()],
          floating: [floating()]
        }

  @typedoc "A layout document."
  @type t :: %__MODULE__{version: pos_integer(), canvases: [canvas()]}

  @enforce_keys [:canvases]
  defstruct version: @version, canvases: []

  @typedoc "A refusal: the tag and a sentence."
  @type error :: {:invalid_layout, String.t()}

  @doc "The posture names a canvas may carry."
  @spec postures() :: [posture_name()]
  def postures, do: @postures

  @doc "The modes an app may take."
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc "The document version this module reads and writes."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  The shipped default: one canvas, `#{@default_id}`, running the shipped
  canvas (`#{@default_canvas}`), with nothing placed over it in any
  posture.
  """
  @spec default() :: t()
  def default do
    %__MODULE__{canvases: [%{id: @default_id, tincture: @default_canvas, postures: %{}}]}
  end

  @doc """
  The canvases as posture `name` arranges them, in the document's order:
  each canvas's `id` and `tincture`, and that posture's `apps` (in
  `{order, tincture}` order) and `floating` entries, empty for a posture
  the canvas does not name. `:error` for a name that is not a posture.
  """
  @spec arrangement(t(), term()) :: {:ok, [arranged()]} | :error
  def arrangement(%__MODULE__{canvases: canvases}, name) when name in @postures do
    {:ok,
     Enum.map(canvases, fn canvas ->
       posture = Map.get(canvas.postures, name, %{apps: [], floating: []})
       %{id: canvas.id, tincture: canvas.tincture, apps: posture.apps, floating: posture.floating}
     end)}
  end

  def arrangement(%__MODULE__{}, _name), do: :error

  @doc """
  A decoded JSON document held to the layout's shape, answered as the
  struct with each posture's apps in `{order, tincture}` order. The first
  shape that is wrong is the refusal.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, error()}
  def validate(%{} = document) do
    with :ok <- document_version(Map.get(document, "version")),
         :ok <- known_keys(document, @document_keys, "the layout"),
         {:ok, canvases} <- canvases(Map.get(document, "canvases")) do
      {:ok, %__MODULE__{version: @version, canvases: canvases}}
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

  @doc "The JSON form: string keys, every posture the document names."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{version: version, canvases: canvases}) do
    %{
      "version" => version,
      "canvases" =>
        Enum.map(canvases, fn canvas ->
          %{
            "id" => canvas.id,
            "tincture" => canvas.tincture,
            "postures" =>
              Map.new(canvas.postures, fn {name, posture} ->
                {name,
                 %{
                   "apps" => Enum.map(posture.apps, &app_json/1),
                   "floating" => Enum.map(posture.floating, &floating_json/1)
                 }}
              end)
          }
        end)
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
  def digest(%__MODULE__{} = layout), do: Prima.Digest.sha256(encode(layout))

  @doc "Every tincture the document names, each once, sorted."
  @spec tinctures(t()) :: [ref()]
  def tinctures(%__MODULE__{canvases: canvases}) do
    canvases
    |> Enum.flat_map(fn canvas ->
      placed =
        for {_name, posture} <- canvas.postures,
            entry <- posture.apps ++ posture.floating,
            do: entry.tincture

      [canvas.tincture | placed]
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "One canvas as `arrangement/2` answers it, in the JSON form `to_json/1` writes."
  @spec arranged_to_json(arranged()) :: map()
  def arranged_to_json(%{id: id, tincture: tincture, apps: apps, floating: floating}) do
    %{
      "id" => id,
      "tincture" => tincture,
      "apps" => Enum.map(apps, &app_json/1),
      "floating" => Enum.map(floating, &floating_json/1)
    }
  end

  # ---- JSON ------------------------------------------------------------------

  defp app_json(app),
    do: %{"tincture" => app.tincture, "mode" => Atom.to_string(app.mode), "order" => app.order}

  defp floating_json(entry) do
    %{
      "tincture" => entry.tincture,
      "position" => %{"x" => entry.position.x, "y" => entry.position.y}
    }
  end

  # ---- the shape -------------------------------------------------------------

  defp document_version(@version), do: :ok

  defp document_version(_other),
    do: refuse("the layout's version must be #{@version}; no other version is read")

  defp canvases(canvases) when is_list(canvases) and length(canvases) <= @max_canvases do
    with {:ok, canvases} <- collect(canvases, &canvas/1),
         :ok <- distinct(canvases, & &1.id, "the canvas id"),
         :ok <- distinct(canvases, & &1.tincture, "the canvas tincture") do
      {:ok, canvases}
    end
  end

  defp canvases(canvases) when is_list(canvases),
    do: refuse("the layout holds at most #{@max_canvases} canvases")

  defp canvases(_other), do: refuse("the layout's canvases must be a list")

  defp canvas(%{} = canvas) do
    id = Map.get(canvas, "id")

    with :ok <- known_keys(canvas, @canvas_keys, "a canvas"),
         :ok <- required(canvas, @canvas_keys, "a canvas"),
         :ok <- canvas_id(id),
         where = "canvas #{show(id)}",
         {:ok, tincture} <- tincture(Map.get(canvas, "tincture"), "#{where}: the tincture"),
         {:ok, postures} <- postures(where, Map.get(canvas, "postures")) do
      {:ok, %{id: id, tincture: tincture, postures: postures}}
    end
  end

  defp canvas(_other), do: refuse("a canvas must be an object")

  defp canvas_id(id) do
    if is_binary(id) and Regex.match?(@canvas_id, id),
      do: :ok,
      else: refuse("a canvas's id must be a short lowercase name, got #{show(id)}")
  end

  defp postures(where, %{} = postures) do
    case Enum.reject(Map.keys(postures), &(&1 in @postures)) do
      [] ->
        postures
        |> Enum.sort()
        |> collect(fn {name, posture} ->
          with {:ok, posture} <- posture("#{where}, posture #{name}", posture),
               do: {:ok, {name, posture}}
        end)
        |> case do
          {:ok, pairs} -> {:ok, Map.new(pairs)}
          refusal -> refusal
        end

      unknown ->
        refuse(
          "#{where} names unknown posture(s): #{unknown |> Enum.map(&show/1) |> Enum.sort() |> Enum.join(", ")}"
        )
    end
  end

  defp postures(where, _other),
    do: refuse("#{where}: postures must be an object naming hand, desk, both or neither")

  defp posture(where, %{} = posture) do
    with :ok <- known_keys(posture, @posture_keys, where),
         :ok <- required(posture, @posture_keys, where),
         {:ok, apps} <- apps(where, Map.get(posture, "apps")),
         {:ok, floating} <- floating(where, Map.get(posture, "floating")),
         :ok <-
           distinct(
             Enum.map(apps, & &1.tincture) ++ Enum.map(floating, & &1.tincture),
             & &1,
             "#{where}: the tincture"
           ) do
      {:ok, %{apps: Enum.sort_by(apps, &{&1.order, &1.tincture}), floating: floating}}
    end
  end

  defp posture(where, _other), do: refuse("#{where} must be an object of apps and floating")

  defp apps(where, apps) when is_list(apps) and length(apps) <= @max_apps,
    do: collect(apps, &app(where, &1))

  defp apps(where, apps) when is_list(apps),
    do: refuse("#{where} places at most #{@max_apps} apps")

  defp apps(where, _other), do: refuse("#{where}: apps must be a list")

  defp app(where, %{} = app) do
    where = "#{where}: an app"

    with :ok <- known_keys(app, @app_keys, where),
         :ok <- required(app, @app_keys, where),
         {:ok, tincture} <- tincture(Map.get(app, "tincture"), "#{where}'s tincture"),
         {:ok, mode} <- mode(where, Map.get(app, "mode")),
         {:ok, order} <- order(where, Map.get(app, "order")) do
      {:ok, %{tincture: tincture, mode: mode, order: order}}
    end
  end

  defp app(where, _other), do: refuse("#{where}: an app must be an object")

  defp mode(_where, "full"), do: {:ok, :full}
  defp mode(_where, "column"), do: {:ok, :column}

  defp mode(where, mode),
    do: refuse("#{where}: the mode must be full or column, got #{show(mode)}")

  defp order(_where, order) when is_integer(order) and order >= 0 and order <= @max_order,
    do: {:ok, order}

  defp order(where, _order),
    do: refuse("#{where}: the order must be a whole number from 0 to #{@max_order}")

  defp floating(where, entries) when is_list(entries) and length(entries) <= @max_floating,
    do: collect(entries, &floating_entry(where, &1))

  defp floating(where, entries) when is_list(entries),
    do: refuse("#{where} floats at most #{@max_floating} tinctures")

  defp floating(where, _other), do: refuse("#{where}: floating must be a list")

  defp floating_entry(where, %{} = entry) do
    where = "#{where}: a floating tincture"

    with :ok <- known_keys(entry, @floating_keys, where),
         :ok <- required(entry, @floating_keys, where),
         {:ok, tincture} <- tincture(Map.get(entry, "tincture"), where),
         {:ok, position} <- position(where, Map.get(entry, "position")) do
      {:ok, %{tincture: tincture, position: position}}
    end
  end

  defp floating_entry(where, _other), do: refuse("#{where}: a floating entry must be an object")

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

  defp required(map, keys, where) do
    case Enum.reject(keys, &Map.has_key?(map, &1)) do
      [] -> :ok
      missing -> refuse("#{where} lacks #{Enum.join(missing, ", ")}")
    end
  end

  defp distinct(items, by, what) do
    case items |> Enum.frequencies_by(by) |> Enum.find(fn {_value, n} -> n > 1 end) do
      nil -> :ok
      {value, _n} -> refuse("#{what} #{show(value)} is named twice")
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
