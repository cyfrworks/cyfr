# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Manifest.Tincture do
  @moduledoc """
  What a tincture declares about its frame, beside its entry and its
  `connect` origins: four blocks of the manifest's `tincture` object, and
  their digest.

    * `frame` — `capabilities` (names; which names exist, and what each
      opens, are `Compendium.Tincture.Rules`'), `placement` (a name, or
      absent for the shell's default) and `background` (a boolean,
      default false).
    * `cards` — each a `name`, a `title`, the projection fields its
      `number` and short `list` show, an `image` (a path inside the
      version), its `buttons` (a `label`, the system `action` it invokes
      and fixed `args`), the `stream` that refreshes it and its `source`:
      the invoke a refresh runs, a `component`, an `operation` and `args`
      fixed at publish (at most 4096 bytes of canonical JSON), or none for
      a static card.
    * `streams` — the streams the tincture may open, each a provider
      stream `name` and a `subject`: a literal, `"*"` for any subject the
      provider's grammar admits (`Prima.Provider.Stream`), or absent for a
      stream that takes none or binds its subject to its holder.
    * `actions` — the system actions the tincture may invoke, by operation
      name (`tool.action`).

  `from_manifest/1` reads the blocks' shapes, the part every manifest
  write holds them to (`Prima.Manifest.validate/2`). The rules over them —
  which capability and placement names exist, that a card's button names a
  declared action, its stream a declared stream and its source a component
  the tincture may invoke — are the component
  domain's (`Compendium.Tincture.Rules.validate_declaration/1`), which
  answers this struct.

  `digest/1` is taken over the canonical JSON of the four blocks
  (`Prima.JCS`): sets sorted and deduplicated, absent fields omitted,
  cards in their declared order, each with its source. The consent shape
  carries it as `tincture_digest` (`Sanctum.Consent.ShapeDerivation`), and
  a stream grant binds to it, so a version that declares more, or a card
  that runs something else, asks again.
  """

  defmodule Frame do
    @moduledoc "The frame block: its capabilities, placement and whether it runs in the background."
    @type t :: %__MODULE__{
            capabilities: [String.t()],
            placement: String.t() | nil,
            background: boolean()
          }
    defstruct capabilities: [], placement: nil, background: false
  end

  defmodule Button do
    @moduledoc "A card's button: its label, the declared system action it invokes and that action's fixed arguments."
    @type t :: %__MODULE__{label: String.t(), action: String.t(), args: map()}
    @enforce_keys [:label, :action]
    defstruct [:label, :action, args: %{}]
  end

  defmodule Source do
    @moduledoc """
    What a card's refresh runs: an invoke of a component the tincture
    declares, the shape `cyfr.invoke(ref, operation, args)` sends
    (`Prima.TinctureWire`), with its arguments fixed at publish.
    """
    @type t :: %__MODULE__{component: String.t(), operation: String.t(), args: map()}
    @enforce_keys [:component, :operation]
    defstruct [:component, :operation, args: %{}]
  end

  defmodule Card do
    @moduledoc """
    One card: its name and title, the projection fields its number and
    short list show, its image, its buttons, the stream that refreshes it
    and the source a refresh runs (none for a static card).
    """
    @type t :: %__MODULE__{
            name: String.t(),
            title: String.t(),
            number: String.t() | nil,
            list: String.t() | nil,
            image: String.t() | nil,
            buttons: [Prima.Manifest.Tincture.Button.t()],
            stream: String.t() | nil,
            source: Prima.Manifest.Tincture.Source.t() | nil
          }
    @enforce_keys [:name, :title]
    defstruct [
      :name,
      :title,
      number: nil,
      list: nil,
      image: nil,
      buttons: [],
      stream: nil,
      source: nil
    ]
  end

  defmodule Stream do
    @moduledoc "A stream the tincture may open: the provider stream's name and the subject it names."
    @type t :: %__MODULE__{name: String.t(), subject: String.t() | nil}
    @enforce_keys [:name]
    defstruct [:name, subject: nil]
  end

  @type t :: %__MODULE__{
          frame: Frame.t(),
          cards: [Card.t()],
          streams: [Stream.t()],
          actions: [String.t()]
        }

  # `struct/1` rather than `%Frame{}`: the nested module is defined as this
  # body runs, after the struct literal would have been expanded.
  defstruct frame: struct(Frame), cards: [], streams: [], actions: []

  @typedoc "A refusal in `Prima.Manifest`'s block vocabulary: the tag and a sentence."
  @type error :: {:invalid_tincture, String.t()}

  @blocks ~w(frame cards streams actions)
  @frame_keys ~w(capabilities placement background)
  @card_keys ~w(name title number list image buttons stream source)
  @source_keys ~w(component operation args)
  @button_keys ~w(label action args)
  @stream_keys ~w(name subject)

  # Bounds on what one manifest may declare, so a declaration a digest,
  # a consent sheet and a shell render is bounded before any rule reads it.
  @max_cards 16
  @max_buttons 4
  @max_streams 32
  @max_actions 64
  @max_capabilities 16
  @max_title 80
  @max_label 40
  @max_source_args 4096

  @identifier ~r/\A[a-z][a-z0-9_]{0,62}\z/
  @operation ~r/\A[a-z][a-z0-9_-]{0,62}\.[a-z][a-z0-9_-]{0,62}\z/
  @stream_name ~r/\A[a-z][a-z0-9_]{0,62}(\.[a-z][a-z0-9_]{0,62})+\z/
  @subject ~r/\A[A-Za-z0-9][A-Za-z0-9_.:@-]{0,127}\z/

  @doc "The four `tincture` keys this module reads."
  @spec blocks() :: [String.t()]
  def blocks, do: @blocks

  @doc "The subject a declared stream names for any subject its provider's grammar admits."
  @spec any_subject() :: String.t()
  def any_subject, do: "*"

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
  Whether the manifest's `tincture` object declares any of the four
  blocks. A tincture that declares none has no digest in its consent shape.
  """
  @spec declared?(term()) :: boolean()
  def declared?(%{"tincture" => %{} = tincture}),
    do: Enum.any?(@blocks, &Map.has_key?(tincture, &1))

  def declared?(_manifest), do: false

  @doc """
  The four blocks of a decoded manifest, held to their shapes. A manifest
  with no `tincture` object, or one declaring none of them, answers the
  empty declaration. The first shape that is wrong is the refusal.
  """
  @spec from_manifest(term()) :: {:ok, t()} | {:error, error()}
  def from_manifest(%{"tincture" => %{} = tincture}) do
    with {:ok, frame} <- frame(Map.get(tincture, "frame")),
         {:ok, actions} <- actions(Map.get(tincture, "actions")),
         {:ok, streams} <- streams(Map.get(tincture, "streams")),
         {:ok, cards} <- cards(Map.get(tincture, "cards")) do
      {:ok, %__MODULE__{frame: frame, cards: cards, streams: streams, actions: actions}}
    end
  end

  def from_manifest(_manifest), do: {:ok, %__MODULE__{}}

  @doc """
  The canonical JSON-shaped map `digest/1` hashes: string keys, sets
  sorted and deduplicated, absent optional fields omitted.
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
      "cards" => Enum.map(declaration.cards, &canonical_card/1),
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

  defp canonical_card(%Card{} = card) do
    %{
      "name" => card.name,
      "title" => card.title,
      "buttons" =>
        Enum.map(card.buttons, &%{"label" => &1.label, "action" => &1.action, "args" => &1.args})
    }
    |> put_present("number", card.number)
    |> put_present("list", card.list)
    |> put_present("image", card.image)
    |> put_present("stream", card.stream)
    |> put_present("source", canonical_source(card.source))
  end

  defp canonical_source(nil), do: nil

  defp canonical_source(%Source{} = source),
    do: %{"component" => source.component, "operation" => source.operation, "args" => source.args}

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
        {:ok, %Frame{capabilities: capabilities, placement: placement, background: background}}
    end
  end

  defp frame(_other), do: refuse("tincture.frame must be an object")

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

  # ---- cards -----------------------------------------------------------------

  defp cards(nil), do: {:ok, []}

  defp cards(list) when is_list(list) do
    if length(list) > @max_cards,
      do: refuse("tincture.cards declares at most #{@max_cards} cards"),
      else: collect(list, &card/1)
  end

  defp cards(_other), do: refuse("tincture.cards must be a list of objects")

  defp card(%{} = card) do
    name = Map.get(card, "name")

    with :ok <- card_keys(card),
         :ok <- card_name(name),
         :ok <- card_title(name, Map.get(card, "title")),
         :ok <- optional_field(name, "number", Map.get(card, "number")),
         :ok <- optional_field(name, "list", Map.get(card, "list")),
         :ok <- card_image(name, Map.get(card, "image")),
         :ok <- card_stream(name, Map.get(card, "stream")),
         {:ok, buttons} <- buttons(name, Map.get(card, "buttons")),
         {:ok, source} <- source(name, Map.get(card, "source")) do
      {:ok,
       %Card{
         name: name,
         title: Map.get(card, "title"),
         number: Map.get(card, "number"),
         list: Map.get(card, "list"),
         image: Map.get(card, "image"),
         buttons: buttons,
         stream: Map.get(card, "stream"),
         source: source
       }}
    end
  end

  defp card(_other), do: refuse("a tincture.cards entry must be an object")

  defp card_keys(card) do
    case extra_keys(card, @card_keys) do
      [] -> :ok
      extra -> refuse("a tincture.cards entry declares unknown key(s): #{Enum.join(extra, ", ")}")
    end
  end

  defp card_name(name) do
    if identifier?(name),
      do: :ok,
      else: refuse("a tincture.cards entry's name must be an identifier, got #{show(name)}")
  end

  defp card_title(name, title) do
    if is_binary(title) and title != "" and String.length(title) <= @max_title,
      do: :ok,
      else:
        refuse(
          "tincture.cards #{name}: the title must be text of at most #{@max_title} characters"
        )
  end

  defp optional_field(_name, _key, nil), do: :ok

  defp optional_field(name, key, value) do
    if identifier?(value),
      do: :ok,
      else:
        refuse("tincture.cards #{name}: #{key} must name a projection field, got #{show(value)}")
  end

  defp card_image(_name, nil), do: :ok

  defp card_image(name, image) when is_binary(image) and image != "" do
    case Prima.PathSafety.validate_relative_path(image) do
      :ok -> :ok
      {:error, _} -> refuse("tincture.cards #{name}: the image must be a path inside the version")
    end
  end

  defp card_image(name, _image),
    do: refuse("tincture.cards #{name}: the image must be a path inside the version")

  defp card_stream(_name, nil), do: :ok

  defp card_stream(name, stream) do
    if stream_name?(stream),
      do: :ok,
      else:
        refuse("tincture.cards #{name}: the stream must be a stream name, got #{show(stream)}")
  end

  # A source is an invoke as the wire reads one (`Prima.TinctureWire`), so
  # a card runs nothing a frame's invoke could not ask for; its arguments
  # are bounded by their canonical JSON.
  defp source(_name, nil), do: {:ok, nil}

  defp source(name, %{} = source) do
    args = Map.get(source, "args", %{})

    invoke =
      Prima.TinctureWire.request(:invoke, %{
        ref: Map.get(source, "component"),
        operation: Map.get(source, "operation"),
        args: args
      })

    with :ok <- source_keys(name, source),
         {:ok, %{ref: component, operation: operation, args: args}} <- source_invoke(name, invoke),
         :ok <- source_args(name, args) do
      {:ok, %Source{component: component, operation: operation, args: args}}
    end
  end

  defp source(name, _other),
    do:
      refuse(
        "tincture.cards #{name}: the source must be an object of component, operation and args"
      )

  defp source_keys(name, source) do
    case extra_keys(source, @source_keys) do
      [] ->
        :ok

      extra ->
        refuse(
          "tincture.cards #{name}: the source declares unknown key(s): #{Enum.join(extra, ", ")}"
        )
    end
  end

  defp source_invoke(name, invoke) do
    case Prima.TinctureWire.decode_request(:invoke, invoke) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, sentence} ->
        refuse(
          "tincture.cards #{name}: the source's #{String.replace_prefix(sentence, "ref ", "component ")}"
        )
    end
  end

  defp source_args(name, args) do
    case Prima.JCS.encode(args) do
      {:ok, bytes} when byte_size(bytes) <= @max_source_args ->
        :ok

      {:ok, _bytes} ->
        refuse(
          "tincture.cards #{name}: the source's args are at most #{@max_source_args} bytes of canonical JSON"
        )

      {:error, _} ->
        refuse("tincture.cards #{name}: the source's args must be JSON")
    end
  end

  defp buttons(_name, nil), do: {:ok, []}

  defp buttons(name, list) when is_list(list) do
    if length(list) > @max_buttons,
      do: refuse("tincture.cards #{name}: at most #{@max_buttons} buttons"),
      else: collect(list, &button(name, &1))
  end

  defp buttons(name, _other),
    do: refuse("tincture.cards #{name}: buttons must be a list of objects")

  defp button(name, %{} = button) do
    label = Map.get(button, "label")
    action = Map.get(button, "action")
    args = Map.get(button, "args", %{})

    cond do
      (extra = extra_keys(button, @button_keys)) != [] ->
        refuse(
          "tincture.cards #{name}: a button declares unknown key(s): #{Enum.join(extra, ", ")}"
        )

      not (is_binary(label) and label != "" and String.length(label) <= @max_label) ->
        refuse(
          "tincture.cards #{name}: a button's label must be text of at most #{@max_label} characters"
        )

      not operation_name?(action) ->
        refuse(
          "tincture.cards #{name}: a button's action must be an operation name, got #{show(action)}"
        )

      not is_map(args) ->
        refuse("tincture.cards #{name}: a button's args must be an object")

      true ->
        {:ok, %Button{label: label, action: action, args: args}}
    end
  end

  defp button(name, _other), do: refuse("tincture.cards #{name}: a button must be an object")

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
