# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Manifest.Tincture do
  @moduledoc """
  What a tincture declares about its frame, beside its entry: three blocks
  of the manifest's `tincture` object and their digest, and the `connect`
  origins its frame may reach (`connect/1`).

    * `frame` — `capabilities` (names; which names exist, and what each
      opens, are `Compendium.Tincture.Rules`'), `placement` (a name, or
      absent for the shell's default) and `background` (a boolean,
      default false).
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
  @frame_keys ~w(capabilities placement background)
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
  Whether the manifest's `tincture` object declares any of the blocks. A
  tincture that declares none has no digest in its consent shape.
  """
  @spec declared?(term()) :: boolean()
  def declared?(%{"tincture" => %{} = tincture}),
    do: Enum.any?(@blocks, &Map.has_key?(tincture, &1))

  def declared?(_manifest), do: false

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
