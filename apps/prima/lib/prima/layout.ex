# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Layout do
  @moduledoc """
  The layout document: the person's canvases in order and, over each, per
  posture, the apps open over it and where each stands. It is the
  person's, kept by Arca (`Arca.Layouts`) and published fenced; editing it
  is instant and can only arrange. Which canvas a browser shows, which
  window has focus and what hardware is present stay with the device and
  are not in it.

      %Prima.Layout{
        version: 3,
        canvases: [
          %{
            id: "home",
            tincture: ref,
            postures: %{
              "desk" | "hand" => %{
                apps: [
                  %{
                    tincture: ref,
                    placement: :window | :tile | :full,
                    order: n,
                    geometry: %{x, y, w, h} | nil,
                    side: :left | :right | nil,
                    share: n | nil,
                    minimised: boolean
                  }
                ]
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
    * A posture is `hand` or `desk`. A posture has exactly `apps`,
      possibly empty, and a posture a canvas does not name reads as empty
      (`arrangement/2`).
    * `apps` are the tinctures open over the canvas, at most 32, a
      tincture at most once. Each has its `tincture`, its `placement`, its
      `order` (a whole number from 0 to 1,000,000: the stacking order of
      windows, the left-to-right order of tiles) and whether it is
      `minimised` (it keeps its placement), and exactly the keys its
      placement takes:
      * a `window` has its `geometry`: `x`, `y`, `w` and `h` in hundredths
        of a percent of the viewport, `x` and `y` from 0 and `w` and `h`
        from 1, each to 10000, so a window means the same on every device;
      * a `tile` has its `side`, `left` or `right`, and its `share` of the
        viewport's width in hundredths of a percent, from 1 to 10000;
      * a `full` app has nothing more: it takes the whole area while it
        is shown.
      In the struct an app carries all three of `geometry`, `side` and
      `share`, each `nil` where its placement takes none.

  A tincture reference is a versionless tincture reference in its
  canonical spelling (`tincture:local.canvas`): a code change is a new
  version, and the layout follows it. A reference to a tincture nobody
  installed is valid and is kept.

  The document names tinctures, placements and geometry and nothing else:
  an unknown key anywhere is refused, and so is a document of any other
  version, so a layout can never carry an operation, a stream or a grant.

  `validate/1` reads the JSON form (string keys) and answers the struct
  with each posture's apps in `{order, tincture}` order; `to_json/1`
  writes it back. `decode/1` reads stored bytes, and tells a document of
  another version (`:unsupported_version`) from one that does not read.
  `encode/1` is the canonical JSON (`Prima.JCS`) Arca stores and
  `digest/1` its `sha256:` digest. `tests/fixtures/layout.json` holds a
  valid document, its canonical bytes and digest, and refused ones.
  """

  @postures ~w(desk hand)
  @placements [:window, :tile, :full]
  @sides [:left, :right]
  @version 3

  @max_canvases 8
  @max_apps 32
  @max_order 1_000_000
  @max_fraction 10_000

  @default_canvas "tincture:local.canvas"
  @default_id "home"

  @document_keys ~w(canvases version)
  @canvas_keys ~w(id postures tincture)
  @posture_keys ~w(apps)
  @app_keys ~w(minimised order placement tincture)
  @placement_keys %{window: ~w(geometry), tile: ~w(share side), full: []}
  @geometry_keys ~w(h w x y)

  @canvas_id ~r/\A[a-z0-9][a-z0-9-]{0,31}\z/

  @typedoc "A versionless tincture reference, canonically spelt."
  @type ref :: String.t()

  @typedoc "A posture's name."
  @type posture_name :: String.t()

  @typedoc "How an app stands over its canvas."
  @type placement :: :window | :tile | :full

  @typedoc "The edge a tile is docked at."
  @type side :: :left | :right

  @typedoc "A window's place and size, each in hundredths of a percent of the viewport."
  @type geometry :: %{
          x: non_neg_integer(),
          y: non_neg_integer(),
          w: pos_integer(),
          h: pos_integer()
        }

  @typedoc "One app open over a canvas."
  @type app ::
          %{
            tincture: ref(),
            placement: :window,
            order: non_neg_integer(),
            geometry: geometry(),
            side: nil,
            share: nil,
            minimised: boolean()
          }
          | %{
              tincture: ref(),
              placement: :tile,
              order: non_neg_integer(),
              geometry: nil,
              side: side(),
              share: pos_integer(),
              minimised: boolean()
            }
          | %{
              tincture: ref(),
              placement: :full,
              order: non_neg_integer(),
              geometry: nil,
              side: nil,
              share: nil,
              minimised: boolean()
            }

  @typedoc "One posture's apps over a canvas."
  @type posture :: %{apps: [app()]}

  @typedoc "One canvas: its id, the tincture it runs and its postures."
  @type canvas :: %{id: String.t(), tincture: ref(), postures: %{posture_name() => posture()}}

  @typedoc "One canvas as a posture arranges it."
  @type arranged :: %{id: String.t(), tincture: ref(), apps: [app()]}

  @typedoc "A layout document."
  @type t :: %__MODULE__{version: pos_integer(), canvases: [canvas()]}

  @enforce_keys [:canvases]
  defstruct version: @version, canvases: []

  @typedoc "A refusal: the tag and a sentence."
  @type error :: {:invalid_layout, String.t()}

  @doc "The posture names a canvas may carry."
  @spec postures() :: [posture_name()]
  def postures, do: @postures

  @doc "The placements an app may take."
  @spec placements() :: [placement()]
  def placements, do: @placements

  @doc "The edges a tile may be docked at."
  @spec sides() :: [side()]
  def sides, do: @sides

  @doc "The document version this module reads and writes."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  The shipped default: one canvas, `#{@default_id}`, running the shipped
  canvas (`#{@default_canvas}`), with nothing open over it in any posture.
  """
  @spec default() :: t()
  def default do
    %__MODULE__{canvases: [%{id: @default_id, tincture: @default_canvas, postures: %{}}]}
  end

  @doc """
  The canvases as posture `name` arranges them, in the document's order:
  each canvas's `id` and `tincture`, and that posture's `apps` (in
  `{order, tincture}` order), empty for a posture the canvas does not
  name. `:error` for a name that is not a posture.
  """
  @spec arrangement(t(), term()) :: {:ok, [arranged()]} | :error
  def arrangement(%__MODULE__{canvases: canvases}, name) when name in @postures do
    {:ok,
     Enum.map(canvases, fn canvas ->
       posture = Map.get(canvas.postures, name, %{apps: []})
       %{id: canvas.id, tincture: canvas.tincture, apps: posture.apps}
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

  @doc """
  Stored bytes decoded and validated (`validate/1`). Bytes that decode as
  a JSON object naming another whole-number `version` are
  `:unsupported_version`: a document an earlier or a later CYFR wrote,
  which this one does not read. Anything else that does not validate is
  the refusal.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, :unsupported_version | error()}
  def decode(bytes) when is_binary(bytes) do
    case Prima.Json.decode(bytes) do
      {:ok, %{"version" => version}} when is_integer(version) and version != @version ->
        {:error, :unsupported_version}

      {:ok, document} ->
        validate(document)

      {:error, :invalid_json} ->
        refuse("the layout is not JSON")
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
                {name, %{"apps" => Enum.map(posture.apps, &app_json/1)}}
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
      placed = for {_name, posture} <- canvas.postures, app <- posture.apps, do: app.tincture
      [canvas.tincture | placed]
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "One canvas as `arrangement/2` answers it, in the JSON form `to_json/1` writes."
  @spec arranged_to_json(arranged()) :: map()
  def arranged_to_json(%{id: id, tincture: tincture, apps: apps}) do
    %{"id" => id, "tincture" => tincture, "apps" => Enum.map(apps, &app_json/1)}
  end

  # ---- JSON ------------------------------------------------------------------

  defp app_json(app) do
    %{
      "tincture" => app.tincture,
      "placement" => Atom.to_string(app.placement),
      "order" => app.order,
      "minimised" => app.minimised
    }
    |> Map.merge(placed_json(app))
  end

  defp placed_json(%{placement: :window, geometry: geometry}),
    do: %{"geometry" => Map.new(geometry, fn {key, value} -> {Atom.to_string(key), value} end)}

  defp placed_json(%{placement: :tile, side: side, share: share}),
    do: %{"side" => Atom.to_string(side), "share" => share}

  defp placed_json(%{placement: :full}), do: %{}

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
         :ok <- distinct(apps, & &1.tincture, "#{where}: the tincture") do
      {:ok, %{apps: Enum.sort_by(apps, &{&1.order, &1.tincture})}}
    end
  end

  defp posture(where, _other), do: refuse("#{where} must be an object of apps")

  defp apps(where, apps) when is_list(apps) and length(apps) <= @max_apps,
    do: collect(apps, &app(where, &1))

  defp apps(where, apps) when is_list(apps),
    do: refuse("#{where} places at most #{@max_apps} apps")

  defp apps(where, _other), do: refuse("#{where}: apps must be a list")

  defp app(where, %{} = app) do
    where = "#{where}: an app"

    with {:ok, placement} <- placement(where, Map.get(app, "placement")),
         keys = @app_keys ++ Map.fetch!(@placement_keys, placement),
         where = "#{where} placed as a #{placement}",
         :ok <- known_keys(app, keys, where),
         :ok <- required(app, keys, where),
         {:ok, tincture} <- tincture(Map.get(app, "tincture"), "#{where}: its tincture"),
         {:ok, order} <- order(where, Map.get(app, "order")),
         {:ok, minimised} <- minimised(where, Map.get(app, "minimised")),
         {:ok, placed} <- placed(where, placement, app) do
      {:ok,
       Map.merge(
         %{
           tincture: tincture,
           placement: placement,
           order: order,
           geometry: nil,
           side: nil,
           share: nil,
           minimised: minimised
         },
         placed
       )}
    end
  end

  defp app(where, _other), do: refuse("#{where}: an app must be an object")

  defp placement(where, placement) do
    case Enum.find(@placements, &(Atom.to_string(&1) == placement)) do
      nil ->
        refuse(
          "#{where}: the placement must be #{Enum.join(@placements, ", ")}, got #{show(placement)}"
        )

      placement ->
        {:ok, placement}
    end
  end

  defp order(_where, order) when is_integer(order) and order >= 0 and order <= @max_order,
    do: {:ok, order}

  defp order(where, _order),
    do: refuse("#{where}: the order must be a whole number from 0 to #{@max_order}")

  defp minimised(_where, minimised) when is_boolean(minimised), do: {:ok, minimised}
  defp minimised(where, _other), do: refuse("#{where}: minimised must be true or false")

  defp placed(where, :window, %{"geometry" => %{} = geometry}) do
    with :ok <- known_keys(geometry, @geometry_keys, "#{where}: the geometry"),
         :ok <- required(geometry, @geometry_keys, "#{where}: the geometry") do
      %{"x" => x, "y" => y, "w" => w, "h" => h} = geometry

      if fraction?(x, 0) and fraction?(y, 0) and fraction?(w, 1) and fraction?(h, 1),
        do: {:ok, %{geometry: %{x: x, y: y, w: w, h: h}}},
        else:
          refuse(
            "#{where}: x and y must be whole numbers from 0, and w and h from 1, to #{@max_fraction}"
          )
    end
  end

  defp placed(where, :window, _app),
    do: refuse("#{where}: the geometry must be an object of x, y, w and h")

  defp placed(where, :tile, app) do
    side = Enum.find(@sides, &(Atom.to_string(&1) == app["side"]))
    share = app["share"]

    cond do
      is_nil(side) ->
        refuse("#{where}: the side must be left or right, got #{show(app["side"])}")

      not fraction?(share, 1) ->
        refuse("#{where}: the share must be a whole number from 1 to #{@max_fraction}")

      true ->
        {:ok, %{side: side, share: share}}
    end
  end

  defp placed(_where, :full, _app), do: {:ok, %{}}

  defp fraction?(value, least),
    do: is_integer(value) and value >= least and value <= @max_fraction

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
