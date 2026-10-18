# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.CanvasWire do
  @moduledoc """
  The wire between a canvas's frame and the shell, and the paths a canvas
  is served and read at.

  ## Messages

  Each message is `{"v", "verb", "frame", "args"}`, exactly those keys,
  over the `MessagePort` Prism handed that frame: `v` the wire version,
  `frame` the frame id (`Prima.TinctureWire.frame_id?/1`) and `args` an
  object, required even when empty.

  The toolkit posts to Prism (`to_prism_verbs/0`):

    * `ready {}`;
    * `tree {}`, in validation mode only;
    * `open {ref}`, a tincture reference, as `Prima.TinctureWire`'s `open`;
    * `press {binding, action}`, a binding id (`Prima.Feed.binding_id?/1`)
      and an action name (`Prima.Feed.name?/1`);
    * `failed {stage}`, `load`, `tree` or `runtime`.

  Prism posts to the toolkit (`to_toolkit_verbs/0`):

    * `boot {mode, credential, data_path, module_url, toolkit, streams}`:
      `mode` `live` or `validation`; `credential` the frame credential, a
      non-empty string; `data_path` the message's own frame's data path
      (`data_path/1`); `module_url` a file under the version's served
      prefix (`Prima.TinctureUrl.asset_path/2`) ending `.js` or `.mjs`;
      `toolkit` a toolkit major, a positive integer, which the toolkit
      holds to the majors it supports; `streams` the version's declared
      streams, at most 64 distinct objects of exactly `name` (a stream
      name, as `Prima.TinctureWire`'s `stream_open` holds it) and
      `subject` (a string or null). The host script resolves both paths
      against its document's URL before the worker sees them, since a
      `blob:` worker cannot resolve a relative URL. Prism builds
      `streams` from the stored declaration of the version it serves,
      never from anything a module, a frame or the page sends; it is
      required, and `[]` declares no stream;
    * `posture {posture}`, `desk` or `hand`;
    * `covered {rects}`, at most 64 objects of exactly `x`, `y`, `width`
      and `height`, each a non-negative number;
    * `installed {tinctures}`, at most 512 objects of exactly `ref` (a
      tincture reference) and `name` (1 to 128 code points);
    * `state {state}`, `live` or `frozen`;
    * `credential {credential}`, the frame credential Prism renewed while
      the canvas is shown, a non-empty string: the toolkit hands it to
      its streams worker alone, which opens every later stream under it
      and moves every open one onto it.

  `decode/1` reads a message of either direction, and a receiver holds its
  verb to the set its direction names. An unknown verb, an extra or a
  missing key, or a wrong type is refused, and so is any term outside the
  grammar, an improper list or a struct among them. A refusal names no
  key or value the message carries.

  ## Paths

    * `page_path/2` — `/_c/v1/<asset credential>/<frame id>`, the host page,
      under `page_prefix/0`;
    * `data_path/1` — `/_f/v1/o/<frame id>/`, the prefix a canvas's policy
      names in `connect-src`;
    * `stream_path/1` — `data_path/1` and `stream`, a canvas's one data
      route.

  The version's own files stay under `Prima.TinctureUrl`'s served prefix.
  `tests/fixtures/canvas_wire.json` holds valid and refused messages of
  every verb and the paths; this module's test and the toolkit's
  JavaScript tests read it.
  """

  alias Prima.{Feed, TinctureUrl, TinctureWire}

  @version 1

  @to_prism ~w(ready tree open press failed)a
  @to_toolkit ~w(boot posture covered installed state credential)a

  @page_prefix "/_c/v1/"
  @data_prefix "/_f/v1/o/"
  @stream_route "stream"

  @modes ~w(live validation)
  @stages ~w(load tree runtime)
  @postures ~w(desk hand)
  @states ~w(live frozen)

  @max_rects 64
  @rect_keys ~w(height width x y)
  @max_tinctures 512
  @max_name 128
  @max_streams 64

  @typedoc "A verb of either direction."
  @type verb ::
          :ready
          | :tree
          | :open
          | :press
          | :failed
          | :boot
          | :posture
          | :covered
          | :installed
          | :state
          | :credential

  @typedoc "A message: its verb, its frame id and its string-keyed arguments."
  @type message :: %{verb: verb(), frame: String.t(), args: map()}

  @doc "The wire version every message carries as `v`."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The verbs the toolkit posts to Prism."
  @spec to_prism_verbs() :: [verb()]
  def to_prism_verbs, do: @to_prism

  @doc "The verbs Prism posts to the toolkit."
  @spec to_toolkit_verbs() :: [verb()]
  def to_toolkit_verbs, do: @to_toolkit

  @doc "Whether `id` is a frame id: `Prima.TinctureWire`'s grammar."
  @spec frame_id?(term()) :: boolean()
  def frame_id?(id), do: TinctureWire.frame_id?(id)

  # ---- paths -----------------------------------------------------------------

  @doc """
  The prefix every host page's path begins with, `/_c/v1/`: the segment
  after it is the asset credential, which a log or a telemetry span must
  never carry (`CyfrWeb.Plugs.ScrubTinctureCredentials`).
  """
  @spec page_prefix() :: String.t()
  def page_prefix, do: @page_prefix

  @doc """
  The host page of a canvas open: `/_c/v1/<credential>/<frame id>`. A
  credential outside `Prima.TinctureUrl.credential?/1` or a frame id
  outside `frame_id?/1` raises.
  """
  @spec page_path(String.t(), String.t()) :: String.t()
  def page_path(credential, frame_id) do
    unless TinctureUrl.credential?(credential),
      do: raise(ArgumentError, "an asset credential is opaque, URL-safe and bounded")

    @page_prefix <> credential <> "/" <> frame!(frame_id)
  end

  @doc "The data prefix of a canvas open: `/_f/v1/o/<frame id>/`. A frame id outside its grammar raises."
  @spec data_path(String.t()) :: String.t()
  def data_path(frame_id), do: @data_prefix <> frame!(frame_id) <> "/"

  @doc "The stream route of a canvas open: `data_path/1` and `stream`."
  @spec stream_path(String.t()) :: String.t()
  def stream_path(frame_id), do: data_path(frame_id) <> @stream_route

  defp frame!(frame_id) do
    if frame_id?(frame_id),
      do: frame_id,
      else: raise(ArgumentError, "a frame id is 8 to 64 URL-safe characters")
  end

  # ---- messages --------------------------------------------------------------

  @doc """
  The JSON form of `message`, a `%{verb, frame, args}` as `decode/1`
  answers it: `{"v", "verb", "frame", "args"}`. Any other term, the wire
  form itself among them, and any message `decode/1` would refuse raise an
  `ArgumentError` whose sentence names no key or value the message
  carries, since a `boot` carries the frame credential and every message
  is built by CYFR's own code.
  """
  @spec encode(message()) :: map()
  def encode(%{verb: verb, frame: frame, args: args} = message)
      when map_size(message) == 3 and is_atom(verb) do
    envelope = %{
      "v" => @version,
      "verb" => Atom.to_string(verb),
      "frame" => frame,
      "args" => args
    }

    case decode(envelope) do
      {:ok, _message} -> envelope
      {:error, sentence} -> raise ArgumentError, "not a canvas wire message: " <> sentence
    end
  end

  # Never a clause error: its report would print the message, credential
  # and all.
  def encode(_message),
    do: raise(ArgumentError, "not a canvas wire message: encode takes %{verb, frame, args}")

  @doc """
  A message read back, of either direction: `{:ok, %{verb, frame, args}}`,
  or `{:error, sentence}` for another version, an unknown verb, an extra
  or a missing key, a frame id that is not one, or arguments the verb does
  not take.
  """
  @spec decode(term()) :: {:ok, message()} | {:error, String.t()}
  def decode(%{} = message) when not is_struct(message) do
    with :ok <- exact(message, ~w(args frame v verb), "the message"),
         :ok <- version(message["v"]),
         {:ok, verb} <- verb(message["verb"]),
         :ok <- frame(message["frame"]),
         :ok <- args(verb, message["args"], message["frame"]) do
      {:ok, %{verb: verb, frame: message["frame"], args: message["args"]}}
    end
  end

  def decode(_message), do: {:error, "the message must be an object"}

  defp version(@version), do: :ok
  defp version(_v), do: {:error, "the message carries no wire version #{@version}"}

  defp verb(name) do
    case Enum.find(@to_prism ++ @to_toolkit, &(Atom.to_string(&1) == name)) do
      nil -> {:error, "verb must be one of #{Enum.join(@to_prism ++ @to_toolkit, ", ")}"}
      verb -> {:ok, verb}
    end
  end

  defp frame(id), do: if(frame_id?(id), do: :ok, else: {:error, "frame must be a frame id"})

  defp args(verb, %{} = args, frame) when not is_struct(args), do: verb_args(verb, args, frame)
  defp args(_verb, _args, _frame), do: {:error, "args must be an object"}

  defp verb_args(verb, args, _frame) when verb in [:ready, :tree],
    do: exact(args, [], "#{verb}")

  defp verb_args(:open, args, _frame) do
    with :ok <- exact(args, ~w(ref), "open"),
         do: check(tincture_ref?(args["ref"]), "open names a tincture reference")
  end

  defp verb_args(:press, args, _frame) do
    with :ok <- exact(args, ~w(action binding), "press"),
         :ok <- check(Feed.binding_id?(args["binding"]), "press names a binding id") do
      check(Feed.name?(args["action"]), "press names an action by its name")
    end
  end

  defp verb_args(:failed, args, _frame) do
    with :ok <- exact(args, ~w(stage), "failed"),
         do: check(args["stage"] in @stages, "failed names a stage: #{Enum.join(@stages, ", ")}")
  end

  defp verb_args(:boot, args, frame) do
    with :ok <- exact(args, ~w(credential data_path mode module_url streams toolkit), "boot"),
         :ok <- check(args["mode"] in @modes, "boot's mode is live or validation"),
         :ok <- check(credential?(args["credential"]), "boot carries the frame credential"),
         :ok <- check(args["data_path"] == data_path(frame), "boot's data path is its frame's"),
         :ok <- check(module_url?(args["module_url"]), "boot's module is a served .js or .mjs"),
         :ok <- check(major?(args["toolkit"]), "boot's toolkit is a major, a positive integer"),
         :ok <-
           check(
             bounded_list?(args["streams"], @max_streams, &stream?/1),
             "boot names at most #{@max_streams} streams, each exactly a stream name and a subject"
           ) do
      check(distinct?(args["streams"]), "boot names each stream and subject once")
    end
  end

  defp verb_args(:posture, args, _frame) do
    with :ok <- exact(args, ~w(posture), "posture"),
         do: check(args["posture"] in @postures, "posture is desk or hand")
  end

  defp verb_args(:covered, args, _frame) do
    with :ok <- exact(args, ~w(rects), "covered") do
      check(
        bounded_list?(args["rects"], @max_rects, &rect?/1),
        "covered names at most #{@max_rects} rects of x, y, width and height"
      )
    end
  end

  defp verb_args(:installed, args, _frame) do
    with :ok <- exact(args, ~w(tinctures), "installed") do
      check(
        bounded_list?(args["tinctures"], @max_tinctures, &installed?/1),
        "installed names at most #{@max_tinctures} tinctures of ref and name"
      )
    end
  end

  defp verb_args(:state, args, _frame) do
    with :ok <- exact(args, ~w(state), "state"),
         do: check(args["state"] in @states, "state is live or frozen")
  end

  defp verb_args(:credential, args, _frame) do
    with :ok <- exact(args, ~w(credential), "credential"),
         do: check(credential?(args["credential"]), "credential carries the frame credential")
  end

  defp tincture_ref?(ref) when is_binary(ref),
    do: match?({:ok, %Prima.ComponentRef{type: "tincture"}}, Prima.ComponentRef.parse(ref))

  defp tincture_ref?(_ref), do: false

  defp credential?(credential), do: is_binary(credential) and credential != ""

  # A path `Prima.TinctureUrl.asset_path/2` writes, spelt exactly as it
  # writes it, naming a `.js` or `.mjs` file.
  defp module_url?(url) when is_binary(url) do
    case TinctureUrl.parse_asset_path(url) do
      {:ok, %{credential: credential, path: segments}} ->
        TinctureUrl.asset_path(credential, segments) == url and
          String.ends_with?(List.last(segments), [".js", ".mjs"])

      :error ->
        false
    end
  end

  defp module_url?(_url), do: false

  defp major?(major), do: is_integer(major) and major > 0

  # A list's length is counted only once it is known to be proper: `length/1`
  # raises on an improper list, and its report prints the list.
  defp bounded_list?(list, max, fun) do
    case proper_length(list, 0) do
      count when is_integer(count) and count <= max -> Enum.all?(list, fun)
      _improper_or_long -> false
    end
  end

  defp proper_length([], count), do: count
  defp proper_length([_head | tail], count), do: proper_length(tail, count + 1)
  defp proper_length(_improper_tail, _count), do: nil

  # A stream `stream_open` could name: the stream-name grammar the tincture
  # wire holds, and a subject that is a string or null.
  defp stream?(%{"name" => name, "subject" => subject} = stream) when map_size(stream) == 2 do
    Prima.Manifest.Tincture.stream_name?(name) and
      (is_nil(subject) or (is_binary(subject) and String.valid?(subject)))
  end

  defp stream?(_stream), do: false

  defp distinct?(list), do: length(Enum.uniq(list)) == length(list)

  defp rect?(%{} = rect) when not is_struct(rect) do
    rect |> Map.keys() |> Enum.sort() == @rect_keys and
      Enum.all?(rect, fn {_key, n} -> is_number(n) and n >= 0 end)
  end

  defp rect?(_rect), do: false

  defp installed?(%{"ref" => ref, "name" => name} = tincture) when map_size(tincture) == 2 do
    tincture_ref?(ref) and is_binary(name) and String.valid?(name) and
      length(String.codepoints(name)) in 1..@max_name
  end

  defp installed?(_tincture), do: false

  defp check(true, _sentence), do: :ok
  defp check(false, sentence), do: {:error, sentence}

  defp exact(map, keys, where) do
    present = map |> Map.keys() |> Enum.sort()

    case {present -- keys, keys -- present} do
      {[], []} ->
        :ok

      {[], missing} ->
        {:error, "#{where} lacks #{Enum.join(missing, ", ")}"}

      # A refusal names no key it was handed, since a key is part of what
      # the message carries.
      {_extra, _missing} ->
        {:error, "#{where} carries a key it does not take"}
    end
  end
end
