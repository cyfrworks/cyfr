# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Manifest.Tincture do
  @moduledoc """
  What a tincture declares about its frame, beside its entry: three blocks
  of the manifest's `tincture` object and their digest, and the `connect`
  origins its frame may reach (`connect/1`).

    * `frame` — `capabilities` (names; which names exist, and what each
      opens, are `Compendium.Tincture.Rules`'), `placement` (a name, or
      absent for the shell's default), `background` (a boolean, default
      false) and `size`, the size hint the shell opens a window at
      (`Size`), every part of it optional.
    * `streams` — the streams the tincture may open, each a provider
      stream `name` and a `subject`: a literal, `"*"` for any subject the
      provider's grammar admits (`Prima.Provider.Stream`), or absent for a
      stream that takes none or binds its subject to its holder.
    * `actions` — the system actions the tincture may invoke, by operation
      name (`tool.action`).

  `from_manifest/1` reads the blocks' shapes, the part every manifest
  write holds them to (`Prima.Manifest.validate/2`). The rules over them —
  which capability and placement names exist, and what a canvas may
  declare — are the component domain's
  (`Compendium.Tincture.Rules.validate_declaration/1`), which answers this
  struct.

  `digest/1` is taken over the canonical JSON of the blocks
  (`Prima.JCS`): sets sorted and deduplicated, absent fields omitted. The
  consent shape carries it as `tincture_digest`
  (`Sanctum.Consent.ShapeDerivation`), and a stream grant binds to it, so
  a version that declares more asks again.

  A frame block declares something only when it names reach: a
  capability, a placement, or `background` true. A block that names none,
  empty or holding only its `size` hint, declares nothing (`declared?/1`),
  and the digest leaves `size` out, so a version that only adds or changes
  a hint asks nothing again, whatever its frame block held before.
  """

  defmodule Size do
    @moduledoc """
    The frame's size hint, each part optional: `min` and `preferred`, a
    width `w` and a height `h` in CSS pixels; `aspect`, the width-to-height
    ratio as two whole numbers; and `tile`, `left` or `right`, for a
    tincture that would rather open tiled at that edge than as a window.
    The shell reads it as a hint and fits it to the screen.
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
    The frame block: its capabilities, placement, whether it runs in the
    background and its size hint.
    """
    @type t :: %__MODULE__{
            capabilities: [String.t()],
            placement: String.t() | nil,
            background: boolean(),
            size: Prima.Manifest.Tincture.Size.t() | nil
          }
    defstruct capabilities: [], placement: nil, background: false, size: nil
  end

  defmodule Stream do
    @moduledoc "A stream the tincture may open: the provider stream's name and the subject it names."
    @type t :: %__MODULE__{name: String.t(), subject: String.t() | nil}
    @enforce_keys [:name]
    defstruct [:name, subject: nil]
  end

  @type t :: %__MODULE__{
          frame: Frame.t(),
          streams: [Stream.t()],
          actions: [String.t()]
        }

  # `struct/1` rather than `%Frame{}`: the nested module is defined as this
  # body runs, after the struct literal would have been expanded.
  defstruct frame: struct(Frame), streams: [], actions: []

  @typedoc "A refusal in `Prima.Manifest`'s block vocabulary: the tag and a sentence."
  @type error :: {:invalid_tincture, String.t()}

  @blocks ~w(frame streams actions)
  @frame_keys ~w(capabilities placement background size)
  @size_keys ~w(min preferred aspect tile)
  @extent_keys ~w(w h)
  @size_pixels 100..4000
  @aspect_parts 1..100
  @tiles ~w(left right)
  @stream_keys ~w(name subject)

  # Bounds on what one manifest may declare, so a declaration a digest,
  # a consent sheet and a shell render is bounded before any rule reads it.
  @max_streams 32
  @max_actions 64
  @max_capabilities 16

  @identifier ~r/\A[a-z][a-z0-9_]{0,62}\z/
  @operation ~r/\A[a-z][a-z0-9_-]{0,62}\.[a-z][a-z0-9_-]{0,62}\z/
  @stream_name ~r/\A[a-z][a-z0-9_]{0,62}(\.[a-z][a-z0-9_]{0,62})+\z/
  @subject ~r/\A[A-Za-z0-9][A-Za-z0-9_.:@-]{0,127}\z/

  @doc "The `tincture` keys this module reads."
  @spec blocks() :: [String.t()]
  def blocks, do: @blocks

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
  `streams` or `actions` block present, or a frame block that names reach
  (see the module's documentation). A tincture that declares none has no
  digest in its consent shape.
  """
  @spec declared?(term()) :: boolean()
  def declared?(%{"tincture" => %{} = tincture}),
    do: Enum.any?(@blocks, &declares?(tincture, &1))

  def declared?(_manifest), do: false

  defp declares?(%{"frame" => %{} = frame}, "frame"), do: reaches?(frame)
  defp declares?(tincture, block), do: Map.has_key?(tincture, block)

  defp reaches?(frame) do
    Map.get(frame, "capabilities", []) not in [[], nil] or
      not is_nil(Map.get(frame, "placement")) or
      Map.get(frame, "background") == true
  end

  @doc """
  The blocks of a decoded manifest, held to their shapes. A manifest with
  no `tincture` object, or one declaring none of them, answers the empty
  declaration. The first shape that is wrong is the refusal.
  """
  @spec from_manifest(term()) :: {:ok, t()} | {:error, error()}
  def from_manifest(%{"tincture" => %{} = tincture}) do
    with {:ok, frame} <- frame(Map.get(tincture, "frame")),
         {:ok, actions} <- actions(Map.get(tincture, "actions")),
         {:ok, streams} <- streams(Map.get(tincture, "streams")) do
      {:ok,
       %__MODULE__{
         frame: frame,
         streams: streams,
         actions: actions
       }}
    end
  end

  def from_manifest(_manifest), do: {:ok, %__MODULE__{}}

  @doc """
  The canonical JSON-shaped map `digest/1` hashes: string keys, sets
  sorted and deduplicated, absent optional fields omitted, and the frame's
  size hint left out.
  """
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = declaration) do
    %{
      "frame" =>
        %{
          "capabilities" => declaration.frame.capabilities |> Enum.uniq() |> Enum.sort(),
          "background" => declaration.frame.background
        }
        |> put_present("placement", declaration.frame.placement),
      "streams" =>
        declaration.streams
        |> Enum.map(&(%{"name" => &1.name} |> put_present("subject", &1.subject)))
        |> Enum.uniq()
        |> Enum.sort_by(&{&1["name"], &1["subject"] || ""}),
      "actions" => declaration.actions |> Enum.uniq() |> Enum.sort()
    }
  end

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
    placement = Map.get(frame, "placement")
    background = Map.get(frame, "background", false)

    cond do
      (extra = extra_keys(frame, @frame_keys)) != [] ->
        refuse("tincture.frame declares unknown key(s): #{Enum.join(extra, ", ")}")

      not names?(capabilities) ->
        refuse("tincture.frame.capabilities must be a list of names")

      length(capabilities) > @max_capabilities ->
        refuse("tincture.frame.capabilities names at most #{@max_capabilities}")

      not (is_nil(placement) or name?(placement)) ->
        refuse("tincture.frame.placement must be a name")

      not is_boolean(background) ->
        refuse("tincture.frame.background must be true or false")

      true ->
        with {:ok, size} <- size(Map.get(frame, "size")) do
          {:ok,
           %Frame{
             capabilities: capabilities,
             placement: placement,
             background: background,
             size: size
           }}
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
    cond do
      length(list) > @max_actions ->
        refuse("tincture.actions names at most #{@max_actions} operations")

      bad = Enum.find(list, &(not operation_name?(&1))) ->
        refuse("tincture.actions entries must be operation names (tool.action), got #{show(bad)}")

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

  # ---- helpers ---------------------------------------------------------------

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
