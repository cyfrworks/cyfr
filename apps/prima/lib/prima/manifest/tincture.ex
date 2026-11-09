# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Manifest.Tincture do
  @moduledoc """
  What a tincture declares about its frame, beside its entry: the blocks
  of the manifest's `tincture` object and their digest, the subjects an
  app is opened with, and the `connect` origins its frame may reach
  (`connect/1`).

    * `frame` — `capabilities` (names; which names exist, and what each
      opens, are `Compendium.Tincture.Rules`'), `background` (a boolean,
      default false) and `size`, the size hint (`Size`), every part of it
      optional.
    * `streams` — the streams an app may open, each a provider stream
      `name` and a `subject`: a literal, `"*"` for any subject the
      provider's grammar admits (`Prima.Provider.Stream`), or absent for a
      stream that takes none or binds its subject to its holder.
    * `actions` — the system actions an app may invoke, by operation name
      (`tool.action`).
    * `desktop` — present, it makes the tincture a desktop, what the code
      calls a canvas (`canvas?/1`); every key of it is optional (`Desktop`).
      A desktop's `data` and `feeds` are its streams: the
      declaration's `streams` are derived from them, each `data` name with
      no subject and each feed as `feed_results/0` with the feed's name,
      and a desktop that also lists `streams` is refused.
    * `subjects` — the kinds of subject an app accepts when it is opened
      (`subject_kinds/0`), presentation that declares nothing.

  `from_manifest/1` reads the blocks' shapes, the part every manifest
  write holds them to (`Prima.Manifest.validate/2`). The rules over them —
  which capability names exist, which streams a desktop reads and which
  operations its controls run — are the component domain's
  (`Compendium.Tincture.Rules.validate_declaration/1`), which answers this
  struct.

  `digest/1` is taken over the canonical JSON of the blocks
  (`Prima.JCS`): sets sorted and deduplicated, absent fields omitted. The
  consent shape carries it as `tincture_digest`
  (`Sanctum.Consent.ShapeDerivation`), and a stream grant binds to it, so
  a version that declares more asks again. Of a desktop it covers `data`
  and `feeds`, through the streams derived from them, and `controls`;
  `prefs` and `chrome` carry no authority and stay out, as `frame.size`
  and `subjects` do.

  A frame block declares something only when it names reach: a
  capability or `background` true. A block that names none, empty or
  holding only its `size` hint, declares nothing (`declared?/1`), and the
  digest leaves `size` out, so a version that only adds or changes a hint
  asks nothing again, whatever its frame block held before.
  """

  defmodule Size do
    @moduledoc """
    The frame's size hint, each part optional: `min` and `preferred`, a
    width `w` and a height `h` in CSS pixels; `aspect`, the width-to-height
    ratio as two whole numbers; and `tile`, `left` or `right`, for a
    tincture that would rather open tiled at that edge than as a window.
    The shell reads only `tile`, when it first places the app; the rest
    is held to its bounds here and kept with the version.
    """
    @type extent :: %{w: pos_integer(), h: pos_integer()}
    @type t :: %__MODULE__{
            min: extent() | nil,
            preferred: extent() | nil,
            aspect: extent() | nil,
            tile: String.t() | nil
          }
    defstruct min: nil, preferred: nil, aspect: nil, tile: nil
  end

  defmodule Frame do
    @moduledoc """
    The frame block: its capabilities, whether it runs in the background
    and its size hint.
    """
    @type t :: %__MODULE__{
            capabilities: [String.t()],
            background: boolean(),
            size: Prima.Manifest.Tincture.Size.t() | nil
          }
    defstruct capabilities: [], background: false, size: nil
  end

  defmodule Stream do
    @moduledoc "A stream the tincture may open: the provider stream's name and the subject it names."
    @type t :: %__MODULE__{name: String.t(), subject: String.t() | nil}
    @enforce_keys [:name]
    defstruct [:name, subject: nil]
  end

  defmodule Pick do
    @moduledoc """
    A control's one enumerated argument: the stream it is picked from
    (`stream`, with the feed's name as `subject` for a feed's results),
    the RFC 6901 pointer `field` into that stream's shape where the
    choices are, and the operation's argument `arg` the choice fills.
    """
    @type t :: %__MODULE__{
            stream: String.t(),
            subject: String.t() | nil,
            field: String.t(),
            arg: String.t()
          }
    @enforce_keys [:stream, :field, :arg]
    defstruct [:stream, :field, :arg, subject: nil]
  end

  defmodule Control do
    @moduledoc """
    A control a desktop offers, which the shell runs on the person's tap:
    its `id`, the `label` it shows, the `operation` (`tool.action`) it
    runs, its fixed `args` and at most one `pick`.
    """
    @type t :: %__MODULE__{
            id: String.t(),
            label: String.t(),
            operation: String.t(),
            args: map(),
            pick: Prima.Manifest.Tincture.Pick.t() | nil
          }
    @enforce_keys [:id, :label, :operation]
    defstruct [:id, :label, :operation, args: %{}, pick: nil]
  end

  defmodule Desktop do
    @moduledoc """
    The desktop block, every key optional: the canvas-readable streams it
    reads (`data`), the feeds it reads by name (`feeds`), the controls it
    offers (`controls`), the schema of its preferences document (`prefs`:
    `widgets`, each widget id to its fields, and `desktop`, the desktop's
    own fields, each field name to its normalized type) and the path of its
    chrome declaration (`chrome`, read by `Prima.Manifest.Chrome`).
    """
    @type field :: %{required(String.t()) => term()}
    @type prefs :: %{
            widgets: %{String.t() => %{String.t() => field()}},
            desktop: %{String.t() => field()}
          }
    @type t :: %__MODULE__{
            data: [String.t()],
            feeds: [String.t()],
            controls: [Prima.Manifest.Tincture.Control.t()],
            prefs: prefs(),
            chrome: String.t() | nil
          }
    defstruct data: [], feeds: [], controls: [], prefs: %{widgets: %{}, desktop: %{}}, chrome: nil
  end

  @type t :: %__MODULE__{
          frame: Frame.t(),
          streams: [Stream.t()],
          actions: [String.t()],
          desktop: Desktop.t() | nil,
          subjects: [String.t()]
        }

  # `struct/1` rather than `%Frame{}`: the nested module is defined as this
  # body runs, after the struct literal would have been expanded.
  defstruct frame: struct(Frame), streams: [], actions: [], desktop: nil, subjects: []

  @typedoc "A refusal in `Prima.Manifest`'s block vocabulary: the tag and a sentence."
  @type error :: {:invalid_tincture, String.t()}

  @blocks ~w(frame streams actions desktop)
  @frame_keys ~w(capabilities background size)
  @size_keys ~w(min preferred aspect tile)
  @extent_keys ~w(w h)
  @size_pixels 100..4000
  @aspect_parts 1..100
  @tiles ~w(left right)
  @stream_keys ~w(name subject)
  @desktop_keys ~w(data feeds controls prefs chrome)
  @control_keys ~w(id label operation args pick)
  @pick_keys ~w(stream subject field arg)
  @prefs_keys ~w(widgets desktop)
  @widget_keys ~w(fields)
  @subject_kinds ~w(run thread schedule component file)

  # The fields every widget's preferences carry, which its schema does
  # not declare.
  @widget_fixed_fields ~w(on rect)
  @field_types ~w(boolean integer number string enum)
  @field_keys %{
    "boolean" => [],
    "integer" => [],
    "number" => [],
    "string" => ~w(max),
    "enum" => ~w(values)
  }
  @string_max 1..256
  @enum_values 1..64
  @enum_value_points 1..256

  # The stream a desktop reads a feed's results from, by the feed's name.
  @feed_results "feed.results"

  # Bounds on what one manifest may declare, so a declaration a digest,
  # a consent sheet and a shell render is bounded before any rule reads it.
  @max_streams 32
  @max_actions 64
  @max_capabilities 16
  @max_desktop_names 32
  @max_controls 32
  @max_label_points 32
  @max_widgets 32
  @max_fields 16

  @identifier ~r/\A[a-z][a-z0-9_]{0,62}\z/
  @control_id ~r/\A[a-z][a-z0-9_-]{0,62}\z/
  @operation ~r/\A[a-z][a-z0-9_-]{0,62}\.[a-z][a-z0-9_-]{0,62}\z/
  @stream_name ~r/\A[a-z][a-z0-9_]{0,62}(\.[a-z][a-z0-9_]{0,62})+\z/
  @subject ~r/\A[A-Za-z0-9][A-Za-z0-9_.:@-]{0,127}\z/
  @control_characters ~r/[\x{0}-\x{1F}\x{7F}-\x{9F}]/u
  # An RFC 6901 pointer that names a member: `/` then segments, each with
  # `~` only as `~0` or `~1`.
  @pointer ~r/\A(\/([^~\/]|~[01])*)+\z/u
  @chrome_extension ".css"

  @doc "The `tincture` keys this module reads as the declaration."
  @spec blocks() :: [String.t()]
  def blocks, do: @blocks

  @doc "The keys of `tincture.desktop`, each optional."
  @spec desktop_keys() :: [String.t()]
  def desktop_keys, do: @desktop_keys

  @doc "The stream a desktop reads a feed's results from: `#{@feed_results}`, by the feed's name."
  @spec feed_results() :: String.t()
  def feed_results, do: @feed_results

  @doc "The kinds of subject `tincture.subjects` names."
  @spec subject_kinds() :: [String.t()]
  def subject_kinds, do: @subject_kinds

  @doc "The types a preferences field takes."
  @spec field_types() :: [String.t()]
  def field_types, do: @field_types

  @doc "The fields every widget's preferences carry, which its schema does not declare."
  @spec widget_fixed_fields() :: [String.t()]
  def widget_fixed_fields, do: @widget_fixed_fields

  @doc """
  The bounds of the desktop block: names in `data` and in `feeds`,
  controls, a label's code points, widgets, fields per widget or section,
  a string field's `max`, and an enum field's values and their code points.
  """
  @spec desktop_bounds() :: %{atom() => pos_integer() | Range.t()}
  def desktop_bounds,
    do: %{
      names: @max_desktop_names,
      controls: @max_controls,
      label_points: @max_label_points,
      widgets: @max_widgets,
      fields: @max_fields,
      string_max: @string_max,
      enum_values: @enum_values,
      enum_value_points: @enum_value_points
    }

  @doc """
  Whether the declaration is a desktop, what the code calls a canvas: it
  carries the `desktop` block.
  """
  @spec canvas?(t()) :: boolean()
  def canvas?(%__MODULE__{desktop: %Desktop{}}), do: true
  def canvas?(%__MODULE__{}), do: false

  @doc """
  Whether `pointer` is an RFC 6901 pointer naming a member (never `""`,
  the whole value), and its unescaped segments.
  """
  @spec pointer_segments(term()) :: {:ok, [String.t()]} | :error
  def pointer_segments(pointer) when is_binary(pointer) do
    if Regex.match?(@pointer, pointer) do
      {:ok,
       pointer
       |> String.split("/")
       |> tl()
       |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))}
    else
      :error
    end
  end

  def pointer_segments(_pointer), do: :error

  @doc "The subject a declared stream names for any subject its provider's grammar admits."
  @spec any_subject() :: String.t()
  def any_subject, do: "*"

  @doc "The keys of `frame.size`."
  @spec size_keys() :: [String.t()]
  def size_keys, do: @size_keys

  @doc "The CSS pixels each side of `frame.size.min` and `frame.size.preferred` takes."
  @spec size_pixels() :: Range.t()
  def size_pixels, do: @size_pixels

  @doc "The whole numbers each part of `frame.size.aspect` takes."
  @spec aspect_parts() :: Range.t()
  def aspect_parts, do: @aspect_parts

  @doc "The edges `frame.size.tile` names."
  @spec tiles() :: [String.t()]
  def tiles, do: @tiles

  @doc "Whether `name` is a stream name: two or more dotted lowercase identifiers."
  @spec stream_name?(term()) :: boolean()
  def stream_name?(name), do: is_binary(name) and Regex.match?(@stream_name, name)

  @doc "Whether `name` is an operation name, `tool.action`."
  @spec operation_name?(term()) :: boolean()
  def operation_name?(name), do: is_binary(name) and Regex.match?(@operation, name)

  @doc "Whether `subject` is a literal stream subject (never `\"*\"`)."
  @spec literal_subject?(term()) :: boolean()
  def literal_subject?(subject), do: is_binary(subject) and Regex.match?(@subject, subject)

  @doc """
  The external origins the manifest's `tincture.connect` declares: the
  domains the served page's CSP `connect-src` admits over `https`, each a
  bare domain `Prima.Manifest.valid_connect_domain?/1` reads, sorted and
  without duplicates. They are exits of the tincture's frame
  (`Prima.Flow`): a flow names one as spelled here, and the consent shape
  carries them. An entry that does not read is no origin, as the CSP
  drops it; a manifest write refuses it first.
  """
  @spec connect(term()) :: [String.t()]
  def connect(%{"tincture" => %{"connect" => connect}}) when is_list(connect),
    do:
      connect
      |> Enum.filter(&Prima.Manifest.valid_connect_domain?/1)
      |> Enum.uniq()
      |> Enum.sort()

  def connect(_manifest), do: []

  @doc """
  Whether the manifest's `tincture` object declares any of the blocks: a
  `streams`, `actions` or `desktop` block present, or a frame block that
  names reach (see the module's documentation). A tincture that declares
  none has no digest in its consent shape.
  """
  @spec declared?(term()) :: boolean()
  def declared?(%{"tincture" => %{} = tincture}),
    do: Enum.any?(@blocks, &declares?(tincture, &1))

  def declared?(_manifest), do: false

  defp declares?(%{"frame" => %{} = frame}, "frame"), do: reaches?(frame)
  defp declares?(tincture, block), do: Map.has_key?(tincture, block)

  defp reaches?(frame) do
    Map.get(frame, "capabilities", []) not in [[], nil] or
      Map.get(frame, "background") == true
  end

  @doc """
  The blocks of a decoded manifest, held to their shapes. A manifest with
  no `tincture` object, or one declaring none of them, answers the empty
  declaration. The first shape that is wrong is the refusal. A desktop's
  streams are derived from its `data` and `feeds`, and one that also
  lists `streams` is refused.
  """
  @spec from_manifest(term()) :: {:ok, t()} | {:error, error()}
  def from_manifest(%{"tincture" => %{} = tincture}) do
    with {:ok, frame} <- frame(Map.get(tincture, "frame")),
         {:ok, actions} <- actions(Map.get(tincture, "actions")),
         {:ok, streams} <- streams(Map.get(tincture, "streams")),
         {:ok, desktop} <- desktop(Map.get(tincture, "desktop")),
         {:ok, subjects} <- subjects(Map.get(tincture, "subjects")),
         {:ok, streams} <- desktop_streams(desktop, streams, Map.has_key?(tincture, "streams")) do
      {:ok,
       %__MODULE__{
         frame: frame,
         streams: streams,
         actions: actions,
         desktop: desktop,
         subjects: subjects
       }}
    end
  end

  def from_manifest(_manifest), do: {:ok, %__MODULE__{}}

  @doc """
  The canonical JSON-shaped map `digest/1` hashes: string keys, sets
  sorted and deduplicated, absent optional fields omitted, and the frame's
  size hint and the subjects left out. A desktop's `data` and `feeds` are
  in it as the streams derived from them, and its `controls`, by id, under
  `desktop`; its `prefs` and `chrome` are not.
  """
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = declaration) do
    %{
      "frame" => %{
        "capabilities" => declaration.frame.capabilities |> Enum.uniq() |> Enum.sort(),
        "background" => declaration.frame.background
      },
      "streams" =>
        declaration.streams
        |> Enum.map(&(%{"name" => &1.name} |> put_present("subject", &1.subject)))
        |> Enum.uniq()
        |> Enum.sort_by(&{&1["name"], &1["subject"] || ""}),
      "actions" => declaration.actions |> Enum.uniq() |> Enum.sort()
    }
    |> put_present("desktop", canonical_desktop(declaration.desktop))
  end

  defp canonical_desktop(nil), do: nil

  defp canonical_desktop(%Desktop{controls: controls}),
    do: %{"controls" => controls |> Enum.map(&canonical_control/1) |> Enum.sort_by(& &1["id"])}

  defp canonical_control(%Control{} = control) do
    %{
      "id" => control.id,
      "label" => control.label,
      "operation" => control.operation,
      "args" => control.args
    }
    |> put_present("pick", canonical_pick(control.pick))
  end

  defp canonical_pick(nil), do: nil

  defp canonical_pick(%Pick{} = pick),
    do:
      %{"stream" => pick.stream, "field" => pick.field, "arg" => pick.arg}
      |> put_present("subject", pick.subject)

  @doc "The declaration's digest: `sha256:` over the JCS encoding of `canonical/1`."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = declaration) do
    {:ok, digest} = Prima.JCS.hash(canonical(declaration))
    digest
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # ---- frame -----------------------------------------------------------------

  defp frame(nil), do: {:ok, %Frame{}}

  defp frame(%{} = frame) do
    capabilities = Map.get(frame, "capabilities", [])
    background = Map.get(frame, "background", false)

    cond do
      (extra = extra_keys(frame, @frame_keys)) != [] ->
        refuse("tincture.frame declares unknown key(s): #{Enum.join(extra, ", ")}")

      not names?(capabilities) ->
        refuse("tincture.frame.capabilities must be a list of names")

      length(capabilities) > @max_capabilities ->
        refuse("tincture.frame.capabilities names at most #{@max_capabilities}")

      not is_boolean(background) ->
        refuse("tincture.frame.background must be true or false")

      true ->
        with {:ok, size} <- size(Map.get(frame, "size")) do
          {:ok, %Frame{capabilities: capabilities, background: background, size: size}}
        end
    end
  end

  defp frame(_other), do: refuse("tincture.frame must be an object")

  # ---- frame.size ------------------------------------------------------------

  defp size(nil), do: {:ok, nil}

  defp size(%{} = size) do
    first..last//_ = @size_pixels
    low..high//_ = @aspect_parts

    with :ok <- no_extra_keys(size, @size_keys, "tincture.frame.size"),
         {:ok, min} <- extent(size, "min", @size_pixels, "#{first} to #{last} CSS pixels"),
         {:ok, preferred} <-
           extent(size, "preferred", @size_pixels, "#{first} to #{last} CSS pixels"),
         {:ok, aspect} <- extent(size, "aspect", @aspect_parts, "whole numbers #{low} to #{high}"),
         {:ok, tile} <- tile(Map.get(size, "tile")),
         :ok <- at_least(preferred, min) do
      {:ok, %Size{min: min, preferred: preferred, aspect: aspect, tile: tile}}
    end
  end

  defp size(_other), do: refuse("tincture.frame.size must be an object")

  defp extent(size, key, range, sentence) do
    case Map.get(size, key) do
      nil ->
        {:ok, nil}

      %{"w" => w, "h" => h} = extent
      when map_size(extent) == 2 and is_integer(w) and is_integer(h) ->
        if w in range and h in range,
          do: {:ok, %{w: w, h: h}},
          else: refuse("tincture.frame.size.#{key}'s w and h are #{sentence}")

      _other ->
        refuse(
          "tincture.frame.size.#{key} is an object of exactly #{Enum.join(@extent_keys, " and ")}, " <>
            "each #{sentence}"
        )
    end
  end

  defp tile(nil), do: {:ok, nil}
  defp tile(tile) when tile in @tiles, do: {:ok, tile}
  defp tile(_tile), do: refuse("tincture.frame.size.tile is #{Enum.join(@tiles, " or ")}")

  defp at_least(%{w: w, h: h}, %{w: min_w, h: min_h}) when w < min_w or h < min_h,
    do: refuse("tincture.frame.size.preferred is at least its min on each side")

  defp at_least(_preferred, _min), do: :ok

  defp no_extra_keys(map, known, where) do
    case extra_keys(map, known) do
      [] -> :ok
      extra -> refuse("#{where} declares unknown key(s): #{Enum.join(extra, ", ")}")
    end
  end

  # ---- actions ---------------------------------------------------------------

  defp actions(nil), do: {:ok, []}

  defp actions(list) when is_list(list) do
    refused = first_refused(list, &operation_name?/1)

    cond do
      length(list) > @max_actions ->
        refuse("tincture.actions names at most #{@max_actions} operations")

      match?({:refused, _}, refused) ->
        refuse(
          "tincture.actions entries must be operation names (tool.action), " <>
            "got #{show(elem(refused, 1))}"
        )

      true ->
        {:ok, list}
    end
  end

  defp actions(_other), do: refuse("tincture.actions must be a list of operation names")

  # ---- streams ---------------------------------------------------------------

  defp streams(nil), do: {:ok, []}

  defp streams(list) when is_list(list) do
    if length(list) > @max_streams,
      do: refuse("tincture.streams declares at most #{@max_streams} streams"),
      else: collect(list, &stream/1)
  end

  defp streams(_other), do: refuse("tincture.streams must be a list of objects")

  defp stream(%{} = stream) do
    name = Map.get(stream, "name")
    subject = Map.get(stream, "subject")

    cond do
      (extra = extra_keys(stream, @stream_keys)) != [] ->
        refuse("a tincture.streams entry declares unknown key(s): #{Enum.join(extra, ", ")}")

      not stream_name?(name) ->
        refuse("a tincture.streams entry's name must be a dotted stream name, got #{show(name)}")

      not (is_nil(subject) or subject == any_subject() or literal_subject?(subject)) ->
        refuse(
          "tincture.streams #{name}: the subject must be a literal or \"*\", got #{show(subject)}"
        )

      true ->
        {:ok, %Stream{name: name, subject: subject}}
    end
  end

  defp stream(_other), do: refuse("a tincture.streams entry must be an object")

  # ---- subjects --------------------------------------------------------------

  defp subjects(nil), do: {:ok, []}

  defp subjects(list) when is_list(list) do
    refused = first_refused(list, &(&1 in @subject_kinds))

    cond do
      match?({:refused, _}, refused) ->
        refuse(
          "tincture.subjects names kinds of #{Enum.join(@subject_kinds, ", ")}, " <>
            "got #{show(elem(refused, 1))}"
        )

      Enum.uniq(list) != list ->
        refuse("tincture.subjects names each kind once")

      true ->
        {:ok, list}
    end
  end

  defp subjects(_other), do: refuse("tincture.subjects must be a list of kinds")

  # ---- desktop ---------------------------------------------------------------

  defp desktop(nil), do: {:ok, nil}

  defp desktop(%{} = desktop) do
    with :ok <- no_extra_keys(desktop, @desktop_keys, "tincture.desktop"),
         {:ok, data} <- desktop_names(Map.get(desktop, "data"), "data", &stream_name?/1),
         {:ok, feeds} <- desktop_names(Map.get(desktop, "feeds"), "feeds", &Prima.Feed.name?/1),
         {:ok, controls} <- controls(Map.get(desktop, "controls")),
         {:ok, prefs} <- prefs(Map.get(desktop, "prefs")),
         {:ok, chrome} <- chrome(Map.get(desktop, "chrome")) do
      {:ok, %Desktop{data: data, feeds: feeds, controls: controls, prefs: prefs, chrome: chrome}}
    end
  end

  defp desktop(_other), do: refuse("tincture.desktop must be an object")

  # A desktop's streams are its data and its feeds' results; it lists no
  # streams of its own.
  defp desktop_streams(nil, streams, _listed?), do: {:ok, streams}

  defp desktop_streams(%Desktop{}, _streams, true),
    do:
      refuse(
        "a tincture.desktop lists no tincture.streams: its data and feeds are the streams it reads"
      )

  defp desktop_streams(%Desktop{data: data, feeds: feeds}, [], false),
    do:
      {:ok,
       Enum.map(data, &%Stream{name: &1}) ++
         Enum.map(feeds, &%Stream{name: @feed_results, subject: &1})}

  defp desktop_names(nil, _key, _grammar), do: {:ok, []}

  defp desktop_names(list, key, grammar) when is_list(list) do
    noun = if key == "data", do: "a dotted stream name", else: "a feed's name"
    refused = first_refused(list, grammar)

    cond do
      length(list) > @max_desktop_names ->
        refuse("tincture.desktop.#{key} names at most #{@max_desktop_names}")

      match?({:refused, _}, refused) ->
        refuse("tincture.desktop.#{key} entries are each #{noun}, got #{show(elem(refused, 1))}")

      Enum.uniq(list) != list ->
        refuse("tincture.desktop.#{key} names each once")

      true ->
        {:ok, list}
    end
  end

  defp desktop_names(_other, key, _grammar),
    do: refuse("tincture.desktop.#{key} must be a list of names")

  # ---- desktop.controls ------------------------------------------------------

  defp controls(nil), do: {:ok, []}

  defp controls(list) when is_list(list) do
    if length(list) > @max_controls do
      refuse("tincture.desktop.controls declares at most #{@max_controls} controls")
    else
      with {:ok, controls} <- collect(list, &control/1) do
        ids = Enum.map(controls, & &1.id)

        if Enum.uniq(ids) == ids,
          do: {:ok, controls},
          else: refuse("tincture.desktop.controls declares each id once")
      end
    end
  end

  defp controls(_other), do: refuse("tincture.desktop.controls must be a list of objects")

  defp control(%{} = control) do
    id = Map.get(control, "id")
    label = Map.get(control, "label")
    operation = Map.get(control, "operation")
    args = Map.get(control, "args", %{})

    cond do
      not (is_binary(id) and Regex.match?(@control_id, id)) ->
        refuse(
          "a tincture.desktop.controls entry's id must be an identifier " <>
            "(lowercase letters, digits, _ and -), got #{show(id)}"
        )

      (extra = extra_keys(control, @control_keys)) != [] ->
        refuse(
          "tincture.desktop.controls #{id} declares unknown key(s): #{Enum.join(extra, ", ")}"
        )

      not label?(label) ->
        refuse(
          "tincture.desktop.controls #{id}: the label is text of 1 to #{@max_label_points} " <>
            "code points with no control character"
        )

      not operation_name?(operation) ->
        refuse(
          "tincture.desktop.controls #{id}: the operation must be an operation name " <>
            "(tool.action), got #{show(operation)}"
        )

      not (is_map(args) and not is_struct(args)) ->
        refuse("tincture.desktop.controls #{id}: args must be an object")

      true ->
        with {:ok, pick} <- pick(Map.get(control, "pick"), id) do
          {:ok, %Control{id: id, label: label, operation: operation, args: args, pick: pick}}
        end
    end
  end

  defp control(_other), do: refuse("a tincture.desktop.controls entry must be an object")

  defp label?(label) do
    is_binary(label) and String.valid?(label) and code_points(label) in 1..@max_label_points and
      not Regex.match?(@control_characters, label)
  end

  defp pick(nil, _id), do: {:ok, nil}

  defp pick(%{} = pick, id) do
    stream = Map.get(pick, "stream")
    subject = Map.get(pick, "subject")
    field = Map.get(pick, "field")
    arg = Map.get(pick, "arg")
    where = "tincture.desktop.controls #{id}: the pick"

    cond do
      (extra = extra_keys(pick, @pick_keys)) != [] ->
        refuse("#{where} declares unknown key(s): #{Enum.join(extra, ", ")}")

      not stream_name?(stream) ->
        refuse("#{where}'s stream must be a dotted stream name, got #{show(stream)}")

      not (is_nil(subject) or Prima.Feed.name?(subject)) ->
        refuse("#{where}'s subject must be a feed's name, got #{show(subject)}")

      pointer_segments(field) == :error ->
        refuse(
          "#{where}'s field must be an RFC 6901 pointer into the stream's shape " <>
            "(such as /result/servers), got #{show(field)}"
        )

      not name?(arg) ->
        refuse("#{where}'s arg must name an argument of the operation, got #{show(arg)}")

      true ->
        {:ok, %Pick{stream: stream, subject: subject, field: field, arg: arg}}
    end
  end

  defp pick(_other, id),
    do: refuse("tincture.desktop.controls #{id}: the pick must be an object")

  # ---- desktop.prefs ---------------------------------------------------------

  defp prefs(nil), do: {:ok, %{widgets: %{}, desktop: %{}}}

  defp prefs(%{} = prefs) do
    with :ok <- no_extra_keys(prefs, @prefs_keys, "tincture.desktop.prefs"),
         {:ok, widgets} <- widgets(Map.get(prefs, "widgets")),
         {:ok, desktop} <- section(Map.get(prefs, "desktop"), "tincture.desktop.prefs.desktop") do
      {:ok, %{widgets: widgets, desktop: desktop}}
    end
  end

  defp prefs(_other), do: refuse("tincture.desktop.prefs must be an object")

  defp widgets(nil), do: {:ok, %{}}

  defp widgets(%{} = widgets) when not is_struct(widgets) do
    cond do
      map_size(widgets) > @max_widgets ->
        refuse("tincture.desktop.prefs.widgets names at most #{@max_widgets} widgets")

      bad = widgets |> Map.keys() |> Enum.sort() |> Enum.find(&(not widget_id?(&1))) ->
        refuse(
          "tincture.desktop.prefs.widgets: a widget id is an identifier " <>
            "(lowercase letters, digits, _ and -), got #{show(bad)}"
        )

      true ->
        widgets
        |> Enum.sort()
        |> collect(fn {id, widget} -> widget(id, widget) end)
        |> case do
          {:ok, pairs} -> {:ok, Map.new(pairs)}
          refusal -> refusal
        end
    end
  end

  defp widgets(_other), do: refuse("tincture.desktop.prefs.widgets must be an object")

  defp widget(id, %{} = widget) when not is_struct(widget) do
    where = "tincture.desktop.prefs.widgets.#{id}"

    with :ok <- no_extra_keys(widget, @widget_keys, where),
         {:ok, fields} <- section(widget, where),
         :ok <- no_fixed_fields(fields, where) do
      {:ok, {id, fields}}
    end
  end

  defp widget(id, _other),
    do: refuse("tincture.desktop.prefs.widgets.#{id} must be an object")

  defp no_fixed_fields(fields, where) do
    case Enum.filter(@widget_fixed_fields, &Map.has_key?(fields, &1)) do
      [] ->
        :ok

      fixed ->
        refuse(
          "#{where}.fields names #{Enum.join(fixed, ", ")}, which every widget carries already"
        )
    end
  end

  # A section of the preferences schema: an object whose `fields` maps
  # each field name to its type.
  defp section(nil, _where), do: {:ok, %{}}

  defp section(%{} = section, where) when not is_struct(section) do
    with :ok <- no_extra_keys(section, @widget_keys, where) do
      case Map.get(section, "fields") do
        nil -> {:ok, %{}}
        %{} = fields when not is_struct(fields) -> fields(fields, "#{where}.fields")
        _other -> refuse("#{where}.fields must be an object")
      end
    end
  end

  defp section(_other, where), do: refuse("#{where} must be an object")

  defp fields(fields, where) do
    cond do
      map_size(fields) > @max_fields ->
        refuse("#{where} declares at most #{@max_fields} fields")

      bad = fields |> Map.keys() |> Enum.sort() |> Enum.find(&(not name?(&1))) ->
        refuse("#{where}: a field's name must be a name, got #{show(bad)}")

      true ->
        fields
        |> Enum.sort()
        |> collect(fn {name, type} ->
          with {:ok, type} <- field(type, "#{where}.#{name}"), do: {:ok, {name, type}}
        end)
        |> case do
          {:ok, pairs} -> {:ok, Map.new(pairs)}
          refusal -> refusal
        end
    end
  end

  defp field(%{"type" => type} = field, where) when type in @field_types do
    with :ok <- no_extra_keys(field, ["type" | Map.fetch!(@field_keys, type)], where) do
      field_bounds(type, field, where)
    end
  end

  defp field(_other, where),
    do: refuse("#{where} must be an object whose type is one of #{Enum.join(@field_types, ", ")}")

  defp field_bounds("string", field, where) do
    first..last//_ = @string_max

    case Map.get(field, "max", last) do
      max when is_integer(max) and max in @string_max ->
        {:ok, %{"type" => "string", "max" => max}}

      _other ->
        refuse("#{where}'s max is a whole number #{first} to #{last}")
    end
  end

  defp field_bounds("enum", field, where) do
    first..last//_ = @enum_values
    low..high//_ = @enum_value_points
    values = Map.get(field, "values")

    cond do
      not (is_list(values) and length(values) in @enum_values) ->
        refuse("#{where}'s values are a list of #{first} to #{last} strings")

      not Enum.all?(values, &enum_value?/1) ->
        refuse("#{where}'s values are each text of #{low} to #{high} code points")

      Enum.uniq(values) != values ->
        refuse("#{where}'s values are distinct")

      true ->
        {:ok, %{"type" => "enum", "values" => values}}
    end
  end

  defp field_bounds(type, _field, _where), do: {:ok, %{"type" => type}}

  defp enum_value?(value) do
    is_binary(value) and String.valid?(value) and code_points(value) in @enum_value_points and
      not Regex.match?(@control_characters, value)
  end

  defp widget_id?(value), do: is_binary(value) and Regex.match?(@control_id, value)

  # ---- desktop.chrome --------------------------------------------------------

  defp chrome(nil), do: {:ok, nil}

  defp chrome(path) when is_binary(path) do
    if Prima.PathSafety.validate_segments(String.split(path, "/")) == :ok and
         Path.extname(path) == @chrome_extension,
       do: {:ok, path},
       else:
         refuse(
           "tincture.desktop.chrome must be the relative path of a #{@chrome_extension} " <>
             "file in the version, got #{show(path)}"
         )
  end

  defp chrome(other),
    do: refuse("tincture.desktop.chrome must be a relative path, got #{show(other)}")

  # ---- helpers ---------------------------------------------------------------

  # The first entry `ok?` refuses, as `{:refused, entry}`, so a refused
  # `nil` or `false` is a refusal and never a falsy miss; `:none` when
  # every entry holds.
  defp first_refused(list, ok?) do
    case Enum.find_index(list, &(not ok?.(&1))) do
      nil -> :none
      index -> {:refused, Enum.at(list, index)}
    end
  end

  # A bound on text counts Unicode code points, never graphemes: a letter
  # and its combining mark are two.
  defp code_points(text), do: text |> String.codepoints() |> length()

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

  defp extra_keys(map, known),
    do: map |> Map.keys() |> Enum.reject(&(&1 in known)) |> Enum.map(&to_string/1) |> Enum.sort()

  defp identifier?(value), do: is_binary(value) and Regex.match?(@identifier, value)
  defp name?(value), do: identifier?(value)
  defp names?(list), do: is_list(list) and Enum.all?(list, &name?/1)

  # A refusal names what it was handed by its shape, never by an arbitrary
  # term's inspection, so a sentence stays a sentence.
  defp show(value) when is_binary(value) and byte_size(value) <= 64, do: ~s("#{value}")
  defp show(value) when is_binary(value), do: "a string of #{String.length(value)} characters"
  defp show(nil), do: "nothing"
  defp show(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp show(value) when is_list(value), do: "a list"
  defp show(value) when is_map(value), do: "an object"
  defp show(_value), do: "a value of another kind"

  defp refuse(sentence), do: {:error, {:invalid_tincture, sentence}}
end
