# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.TinctureWire do
  @moduledoc """
  The wire between a tincture's frame and the server, and between the
  frame and the shell that holds it.

  ## Frame to endpoint

  Three requests, each an HTTP `POST` of a JSON body to its route
  (`route/1`) carrying the frame credential as a bearer
  (`authorization: Bearer <credential>`, `bearer_header/0`), never in the
  URL or the body:

    * `invoke` — run a component the tincture declares: `ref` (a
      component reference), `operation` (a name) and `args` (an object).
      The component runs with the input
      `{"operation": <operation>, "params": <args>}`;
    * `action` — run a system action the tincture declares: `operation`
      (`tool.action`) and `args`;
    * `stream_open` — open a stream the tincture declares: `stream` (the
      provider stream's name) and `subject` (a literal, or null for a
      stream that takes none).

  A public tincture's page opened at its address has no frame credential:
  its requests carry no bearer and name the tincture instead, as
  `public: {"athanor", "publisher", "name"}` (the athanor's URL segment,
  the publisher and the name, `public_identity?/1`). The endpoint admits
  such a request only for a tincture that is public, under its public
  profile.

  A body carries `v`, the wire version; one at no version or another is
  refused before anything else is read. An answer to `invoke` and
  `action` is `{"v", "ok": true, "result"}`, and for a refusal
  `{"v", "ok": false, "error": {"class", "message", "stage"}}`: the
  projection of a `Prima.Refusal` a frame may read, never its reason
  term. A refused `stream_open` is answered the same way. Each refusal
  is answered at the HTTP status its class answers with; a server error
  (5xx), like no answer at all, is no answer on a `stream_open`, which the
  SDK rejects as `unavailable` so the page may open it again later.

  An admitted `stream_open` is answered as `text/event-stream`
  (`stream_content_type/0`), one event per delivery under the grant
  (`stream_event/3`): `id` the payload's sequence number where the topic
  carries one, `event` the stream's name and `data` the payload projected
  to the grant's fields, as JSON. The stream ends at the grant's deadline
  or when the endpoint closes it; one it closes for a reason the frame
  should know ends with a `refusal` event (`stream_refusal/1`) whose data
  is the refusal's projection. The grant's bus topic never leaves the
  server, and a reconnect is a new open. `stream/2` is the grant as a
  frame may read it, the JSON form the SDK's reader still decodes.

  The frame's document is sandboxed without `allow-same-origin`, so its
  origin is `null` and every request is cross-origin to the endpoint.

  ## Frame to shell

  Messages over the frame's `MessagePort`, each `{"v", "verb", "frame",
  "args"}`, `frame` the frame id the shell minted:

    * `open` — open a tincture: `args.ref`, a tincture reference, and
      optionally `args.subject`, exactly `kind` (one of
      `Prima.Manifest.Tincture.subject_kinds/0`) and `id` (`subject_id?/1`),
      what the app is opened on;
    * `title` — set the frame's title: `args.title`;
    * `credential` — ask the person for a secret through the shell's own
      prompt: `args.name`, the vault entry name to store it under, a
      non-empty string as the vault takes it. The value is typed into the
      shell and goes to the vault; the frame is told only that the prompt
      closed and whether an entry was saved;
    * `press` — press a feed's action: `args.binding`, a binding id
      (`Prima.Feed.binding_id?/1`), and `args.action`, the action's name
      (`Prima.Feed.name?/1`), exactly those two; or press a control the
      desktop declares: `args.control`, its id (`control?/1`), `args.call`,
      the number the frame gives this press (`call?/1`), which its answer
      carries back, and, for a control with a pick, `args.value`, the
      picked string (`press_value?/1`);
    * `prefs` — write the desktop's preferences: `args.document`, an
      object (what it may hold is `Prima.CanvasPrefs`'), and `args.call`,
      the number its answer carries back;
    * `ask` — ask AQUA about a widget: `args.widget`, a widget id
      (`widget?/1`). The sentence AQUA's panel opens with is Prism's;
    * `settings` — open one of Prism's pages: `args.page`, a page's key
      (`page?/1`); which pages exist is Prism's;
    * `grant` — ask for the person's grant to a component: `args.ref`, a
      component reference (`Prima.ComponentRef`) of a catalyst, reagent,
      formula or tincture, at a version or none, and nothing else. Which
      component it names, and whether the person is asked, are the
      shell's; the person confirms in CYFR's own prompt;
    * `failed` — the page failed: `args.stage`, `load` or `runtime`
      (`stages/0`);
    * `ready`, `close` — no arguments.

  No verb places, sizes or raises a frame: which frame is shown is the
  shell's and the person's. Which verbs the shell acts on is the shell's,
  by the frame's kind: `press`, `failed`, `grant`, `prefs`, `ask` and
  `settings` only from a canvas (`canvas_verbs/0`).

  An app opened with a subject is answered it at its handshake beside its
  credential, `frame_handshake/2`: exactly `credential` and `subject`.

  ## A canvas

  A canvas (a tincture that declares the `tincture.desktop` block) is opened at its page,
  `page_path/2` (`/_c/v1/<asset credential>/<frame id>`, under
  `page_prefix/0`), and reads its streams at its open's data path alone:
  `data_path/1` (`/_f/v1/o/<frame id>/`) and its one route under it,
  `stream_path/1`. The version's own files stay under
  `Prima.TinctureUrl`'s served prefix.

  The shell answers a canvas frame's handshake with
  `canvas_handshake/5`: exactly `credential`, the frame credential, and
  `canvas`, exactly `mode` (`live` or `validation`, `canvas_modes/0`),
  `data_path`, the frame's own, `streams`, the version's declared
  streams, at most `max_canvas_streams/0` distinct objects of exactly
  `name` (a stream name, as `stream_open` holds it) and `subject` (a
  string or null), `prefs`, exactly `document` (an object) and
  `revision` (a whole number from 0), `appearance`, exactly `mode`
  (`appearance_modes/0`), `accent` (`#rrggbb`), `locale` (`locale?/1`),
  `time_zone` (`time_zone?/1`) and `safe_areas` (exactly `top`, `right`,
  `bottom` and `left`, whole CSS pixels to `max_safe_area/0`), and
  `person`, exactly `name`, the person's display name of 1 to
  `max_person_name/0` code points or null, never an identifier. Prism
  builds `streams` from the stored declaration of the version it serves,
  never from anything a frame or a page sends. The
  shell's later messages to a canvas over its port (`canvas`, `posture`,
  `covered`, `installed`, `state`, `pressed` and `prefs`) are JavaScript
  on both ends; `pressed` answers a control's press, exactly `control`,
  the press's `call` and `outcome` (`press_outcomes/0`), with `reason`, a
  refusal's class (`Prima.Refusal.classes/0`), exactly when refused;
  `prefs` answers a `prefs` write, exactly its `call`, `outcome`
  (`prefs_outcomes/0`), `document` and `revision` (the stored document as
  the shell now holds it), with `reason` exactly when refused. A frame
  numbers its presses of a control and its writes upward, one count for
  both, and the shell's end of its port drops one numbered no higher than
  the last, unanswered; the frame matches each answer to the call it is
  still waiting on by `call` and the answer's verb, never by order, and an
  answer to no such call moves nothing;
  `installed` names at most `max_installed/0` tinctures, each exactly the
  keys `installed_keys/0`: its `ref`, a tincture reference; its `name`, 1
  to `max_installed_name/0` code points; its `icon`, an emoji of 1 to
  `max_installed_icon/0` code points or null; and `open`, whether the
  tincture is open over the canvas.

  `tests/fixtures/tincture_wire.json` holds one example of each request,
  one public request, one refusal, one event stream, how the SDK rejects
  a `stream_open` for each answer that opens no stream, every shell verb's
  message and the messages refused, and a canvas's handshake replies, the
  shell's messages to a canvas and its paths; this module's test and the
  SDK's and the bridge's JavaScript tests read it.
  """

  @version 1
  @bearer_header "authorization"

  @routes %{
    invoke: "/_f/v1/invoke",
    action: "/_f/v1/action",
    stream_open: "/_f/v1/stream"
  }

  @verbs ~w(open close title ready credential press failed grant prefs ask settings)a
  @canvas_verbs ~w(press failed grant prefs ask settings)a
  @stages ~w(load runtime)

  @stream_content_type "text/event-stream"
  @refusal_event "refusal"

  @page_prefix "/_c/v1/"
  @data_prefix "/_f/v1/o/"
  @stream_route "stream"

  @canvas_modes ~w(live validation)
  @max_canvas_streams 64
  @max_installed 512
  @max_installed_name 128
  @max_installed_icon 16
  @installed_keys ~w(icon name open ref)

  @appearance_modes ~w(light dark)
  @max_safe_area 512
  @max_person_name 128
  @max_press_value 256
  @max_call 2_147_483_647
  @press_outcomes ~w(accepted refused cancelled)
  @prefs_outcomes ~w(saved stale refused cancelled)

  @frame_id ~r/\A[A-Za-z0-9_-]{8,64}\z/
  @athanor_segment ~r/\A@[a-z0-9]+(-[a-z0-9]+)*\z/
  @component_operation ~r/\A[a-z][a-z0-9_-]{0,62}\z/
  # A control's or a widget's id, as the desktop block spells them.
  @desktop_id ~r/\A[a-z][a-z0-9_-]{0,62}\z/
  @page ~r/\A[a-z][a-z0-9_]{0,31}\z/
  @subject_id ~r/\A[A-Za-z0-9][A-Za-z0-9_.:@\/-]{0,255}\z/
  @accent ~r/\A#[0-9a-f]{6}\z/
  @locale ~r/\A[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8}){0,7}\z/
  @time_zone ~r/\A[A-Za-z][A-Za-z0-9_+-]{0,31}(\/[A-Za-z0-9][A-Za-z0-9_+-]{0,31}){0,2}\z/
  @control_characters ~r/[\x{0}-\x{1F}\x{7F}-\x{9F}]/u
  @max_title 120

  @typedoc "A request the frame makes of the endpoint."
  @type kind :: :invoke | :action | :stream_open

  @typedoc "A message the frame sends the shell."
  @type verb ::
          :open
          | :close
          | :title
          | :ready
          | :credential
          | :press
          | :failed
          | :grant
          | :prefs
          | :ask
          | :settings

  @typedoc "The public tincture a request names in place of a bearer."
  @type public_identity :: %{athanor: String.t(), publisher: String.t(), name: String.t()}

  @typedoc """
  A decoded request: the kind's fields, atom-keyed, with `public` only
  when the body names a public tincture.
  """
  @type request :: %{
          optional(:ref) => String.t(),
          optional(:operation) => String.t(),
          optional(:args) => map(),
          optional(:stream) => String.t(),
          optional(:subject) => String.t() | nil,
          optional(:public) => public_identity()
        }

  @typedoc "What a frame may read of a refusal."
  @type refusal_projection :: %{class: String.t(), message: String.t(), stage: String.t()}

  @typedoc "A decoded shell message."
  @type shell_message :: %{verb: verb(), frame: String.t(), args: map()}

  @doc "The wire version every body, answer and message carries as `v`."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The request header the frame credential travels in, lowercase."
  @spec bearer_header() :: String.t()
  def bearer_header, do: @bearer_header

  @doc "The route of each request kind."
  @spec routes() :: %{kind() => String.t()}
  def routes, do: @routes

  @doc "The route `kind` is posted to."
  @spec route(kind()) :: String.t()
  def route(kind) when is_map_key(@routes, kind), do: Map.fetch!(@routes, kind)

  @doc "The request kinds."
  @spec kinds() :: [kind()]
  def kinds, do: Map.keys(@routes) |> Enum.sort()

  @doc "The shell verbs."
  @spec verbs() :: [verb()]
  def verbs, do: @verbs

  @doc """
  The shell verbs the shell takes from a canvas alone, `press`, `failed`,
  `grant`, `prefs`, `ask` and `settings`: from any other frame it drops
  them.
  """
  @spec canvas_verbs() :: [verb()]
  def canvas_verbs, do: @canvas_verbs

  @doc "The stages a `failed` message names: the page's load, or its run after it."
  @spec stages() :: [String.t()]
  def stages, do: @stages

  @doc "Whether `id` is a desktop control's id, as the desktop block spells one."
  @spec control?(term()) :: boolean()
  def control?(id), do: is_binary(id) and Regex.match?(@desktop_id, id)

  @doc "Whether `id` is a widget's id, as the desktop block's `prefs` spells one."
  @spec widget?(term()) :: boolean()
  def widget?(id), do: control?(id)

  @doc "Whether `page` is a page's key as Prism names its pages: a lowercase name."
  @spec page?(term()) :: boolean()
  def page?(page), do: is_binary(page) and Regex.match?(@page, page)

  @doc """
  Whether `value` is a value a press picks: text of 1 to
  #{@max_press_value} code points with no control character.
  """
  @spec press_value?(term()) :: boolean()
  def press_value?(value), do: bounded_text?(value, @max_press_value)

  @doc """
  Whether `call` numbers a frame's press or write: a whole number from 1
  to #{@max_call}, which the answer to it carries back.
  """
  @spec call?(term()) :: boolean()
  def call?(call), do: is_integer(call) and call >= 1 and call <= @max_call

  @doc """
  Whether `id` names what an app is opened on: 1 to 256 characters of
  letters, digits and `_ . : @ / -`, the first a letter or a digit.
  """
  @spec subject_id?(term()) :: boolean()
  def subject_id?(id), do: is_binary(id) and Regex.match?(@subject_id, id)

  @doc """
  Whether `subject` is what an app is opened on: exactly `kind`, one of
  `Prima.Manifest.Tincture.subject_kinds/0`, and `id` (`subject_id?/1`).
  """
  @spec subject?(term()) :: boolean()
  def subject?(%{"kind" => kind, "id" => id} = subject) when map_size(subject) == 2,
    do: kind in Prima.Manifest.Tincture.subject_kinds() and subject_id?(id)

  def subject?(_subject), do: false

  @doc "Whether `locale` is a language tag: a BCP 47 shape of at most 8 subtags."
  @spec locale?(term()) :: boolean()
  def locale?(locale),
    do: is_binary(locale) and byte_size(locale) <= 64 and Regex.match?(@locale, locale)

  @doc "Whether `zone` is an IANA time zone's name, such as `Europe/Lisbon` or `UTC`."
  @spec time_zone?(term()) :: boolean()
  def time_zone?(zone), do: is_binary(zone) and Regex.match?(@time_zone, zone)

  @doc "The modes a desktop's appearance names."
  @spec appearance_modes() :: [String.t()]
  def appearance_modes, do: @appearance_modes

  @doc "The most CSS pixels a safe-area inset of the appearance names."
  @spec max_safe_area() :: pos_integer()
  def max_safe_area, do: @max_safe_area

  @doc "The most code points the person's name in a canvas's handshake takes."
  @spec max_person_name() :: pos_integer()
  def max_person_name, do: @max_person_name

  @doc "The most code points a pressed value takes."
  @spec max_press_value() :: pos_integer()
  def max_press_value, do: @max_press_value

  @doc """
  What a control's press comes to, as `pressed` tells the canvas: the gate
  ran it (`accepted`), it was refused (`refused`, with the refusal's
  class), or it did not run because no input of the person's carried it
  or the desktop was not shown live (`cancelled`).
  """
  @spec press_outcomes() :: [String.t()]
  def press_outcomes, do: @press_outcomes

  @doc """
  What a `prefs` write comes to, as `prefs` tells the canvas: written
  (`saved`), not written because another write came first (`stale`, with
  the stored document), refused (`refused`, with the refusal's class), or
  not written for want of the person's input (`cancelled`).
  """
  @spec prefs_outcomes() :: [String.t()]
  def prefs_outcomes, do: @prefs_outcomes

  @doc "Whether `id` is a frame id: 8 to 64 URL-safe characters."
  @spec frame_id?(term()) :: boolean()
  def frame_id?(id), do: is_binary(id) and Regex.match?(@frame_id, id)

  @doc """
  Whether `identity` names a public tincture: an athanor URL segment
  (`@<namespace>`), a publisher and a name, and nothing else.
  """
  @spec public_identity?(term()) :: boolean()
  def public_identity?(%{athanor: athanor, publisher: publisher, name: name} = identity)
      when map_size(identity) == 3 and is_binary(athanor) do
    Regex.match?(@athanor_segment, athanor) and
      Prima.ComponentRef.validate_ref_parts(publisher, name) == :ok
  end

  def public_identity?(_identity), do: false

  @doc "The content type of an admitted `stream_open`'s answer."
  @spec stream_content_type() :: String.t()
  def stream_content_type, do: @stream_content_type

  @doc "The name of the event a stream the endpoint closes with a refusal ends with."
  @spec refusal_event() :: String.t()
  def refusal_event, do: @refusal_event

  # ---- the bearer ------------------------------------------------------------

  @doc "The header value that carries `credential`."
  @spec bearer(String.t()) :: String.t()
  def bearer(credential) when is_binary(credential) and credential != "",
    do: "Bearer " <> credential

  @doc """
  The credential a header value carries, or `:error` for a value that is
  not `Bearer <credential>` with a credential free of whitespace.
  """
  @spec read_bearer(term()) :: {:ok, String.t()} | :error
  def read_bearer("Bearer " <> credential) do
    if credential != "" and not String.match?(credential, ~r/\s/),
      do: {:ok, credential},
      else: :error
  end

  def read_bearer(_value), do: :error

  # ---- requests --------------------------------------------------------------

  @doc """
  The JSON body of a `kind` request with `fields` (atom-keyed, as
  `decode_request/2` answers), naming the public tincture when `fields`
  carry `public`.
  """
  @spec request(kind(), map()) :: map()
  def request(kind, %{public: %{athanor: athanor, publisher: publisher, name: name}} = fields) do
    kind
    |> request(Map.delete(fields, :public))
    |> Map.put("public", %{"athanor" => athanor, "publisher" => publisher, "name" => name})
  end

  def request(:invoke, %{ref: ref, operation: operation, args: args}),
    do: %{"v" => @version, "ref" => ref, "operation" => operation, "args" => args}

  def request(:action, %{operation: operation, args: args}),
    do: %{"v" => @version, "operation" => operation, "args" => args}

  def request(:stream_open, %{stream: stream, subject: subject}),
    do: %{"v" => @version, "stream" => stream, "subject" => subject}

  @doc """
  A decoded `kind` request body, or `{:error, sentence}`: a body at no
  version or another, a missing or malformed field, a field the kind
  does not carry, or a `public` that names no public tincture.
  """
  @spec decode_request(kind(), term()) :: {:ok, request()} | {:error, String.t()}
  def decode_request(kind, %{"v" => @version} = body) when is_map_key(@routes, kind) do
    with :ok <- only(body, ["public" | fields(kind)]),
         {:ok, fields} <- fields(kind, body) do
      public(fields, body)
    end
  end

  def decode_request(kind, %{}) when is_map_key(@routes, kind),
    do: {:error, "the body carries no wire version #{@version}"}

  def decode_request(kind, _body) when is_map_key(@routes, kind),
    do: {:error, "the body must be an object"}

  defp fields(:invoke), do: ~w(v ref operation args)
  defp fields(:action), do: ~w(v operation args)
  defp fields(:stream_open), do: ~w(v stream subject)

  defp fields(:invoke, body) do
    with {:ok, ref} <- component_ref(body["ref"]),
         {:ok, operation} <- component_operation(body["operation"]),
         {:ok, args} <- args(body) do
      {:ok, %{ref: ref, operation: operation, args: args}}
    end
  end

  defp fields(:action, body) do
    with {:ok, operation} <- system_operation(body["operation"]),
         {:ok, args} <- args(body) do
      {:ok, %{operation: operation, args: args}}
    end
  end

  defp fields(:stream_open, body) do
    stream = body["stream"]
    subject = body["subject"]

    cond do
      not Prima.Manifest.Tincture.stream_name?(stream) ->
        {:error, "stream must be a stream name"}

      not (is_nil(subject) or Prima.Manifest.Tincture.literal_subject?(subject)) ->
        {:error, "subject must be a literal subject or null"}

      true ->
        {:ok, %{stream: stream, subject: subject}}
    end
  end

  @public_refusal "public must name a public tincture: athanor, publisher and name"

  defp public(fields, %{"public" => %{} = public}) when map_size(public) == 3 do
    identity = %{
      athanor: public["athanor"],
      publisher: public["publisher"],
      name: public["name"]
    }

    if public_identity?(identity),
      do: {:ok, Map.put(fields, :public, identity)},
      else: {:error, @public_refusal}
  end

  defp public(_fields, %{"public" => _other}), do: {:error, @public_refusal}
  defp public(fields, _body), do: {:ok, fields}

  defp component_ref(ref) when is_binary(ref) do
    case Prima.ComponentRef.parse(ref) do
      {:ok, _parsed} -> {:ok, ref}
      {:error, _} -> {:error, "ref must be a component reference"}
    end
  end

  defp component_ref(_ref), do: {:error, "ref must be a component reference"}

  defp component_operation(operation) do
    if is_binary(operation) and Regex.match?(@component_operation, operation),
      do: {:ok, operation},
      else: {:error, "operation must be a name"}
  end

  defp system_operation(operation) do
    if Prima.Manifest.Tincture.operation_name?(operation),
      do: {:ok, operation},
      else: {:error, "operation must be an operation name (tool.action)"}
  end

  defp args(body) do
    case Map.get(body, "args", %{}) do
      %{} = args -> {:ok, args}
      _other -> {:error, "args must be an object"}
    end
  end

  # ---- answers ---------------------------------------------------------------

  @doc "The answer to an `invoke` or `action` request that succeeded."
  @spec result(term()) :: map()
  def result(value), do: %{"v" => @version, "ok" => true, "result" => value}

  @doc """
  A stream grant as a frame may read it, under the stream name it was
  opened by: the JSON form the SDK's reader decodes for `stream_open`.
  The bus topic stays on the server.
  """
  @spec stream(Prima.StreamGrant.t(), String.t()) :: map()
  def stream(%Prima.StreamGrant{} = grant, name) when is_binary(name) do
    %{
      "v" => @version,
      "ok" => true,
      "stream" => %{
        "grant_id" => grant.grant_id,
        "stream" => name,
        "subject" => grant.subject,
        "projection" => grant.projection,
        "deadline" => grant.deadline |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }
    }
  end

  @doc "The answer to a request that was refused: the refusal's class, message and stage."
  @spec refusal(Prima.Refusal.t()) :: map()
  def refusal(%Prima.Refusal{} = refusal),
    do: %{"v" => @version, "ok" => false, "error" => projection(refusal)}

  defp projection(%Prima.Refusal{} = refusal) do
    %{
      "class" => Atom.to_string(refusal.class),
      "message" => refusal.message,
      "stage" => Atom.to_string(refusal.stage)
    }
  end

  # ---- the event stream ------------------------------------------------------

  @doc """
  One event of an admitted stream: `id` the payload's sequence number
  (nil for a topic that carries none), `event` the stream's name and
  `data` the projected payload, encoded as JSON on one line.
  """
  @spec stream_event(non_neg_integer() | nil, String.t(), term()) :: String.t()
  def stream_event(id, name, data)
      when (is_nil(id) or (is_integer(id) and id >= 0)) and is_binary(name) do
    id_line = if is_nil(id), do: "", else: "id: #{id}\n"
    id_line <> "event: " <> name <> "\ndata: " <> Jason.encode!(data) <> "\n\n"
  end

  @doc """
  The last event of a stream the endpoint closed for a reason the frame
  should know: `event: refusal`, its data the refusal's class, message
  and stage.
  """
  @spec stream_refusal(Prima.Refusal.t()) :: String.t()
  def stream_refusal(%Prima.Refusal{} = refusal),
    do: stream_event(nil, @refusal_event, projection(refusal))

  @doc """
  An answer read back: `{:ok, result}` for `invoke` and `action`,
  `{:ok, stream}` (string-keyed, the deadline a `DateTime`) for
  `stream_open`, `{:refused, projection}` for a refusal whose class is one
  of `Prima.Refusal`'s, and `{:error, :invalid_answer}` for anything else.
  """
  @spec decode_answer(kind(), term()) ::
          {:ok, term()} | {:refused, refusal_projection()} | {:error, :invalid_answer}
  def decode_answer(kind, %{"v" => @version, "ok" => true, "result" => value} = answer)
      when kind in [:invoke, :action] and map_size(answer) == 3,
      do: {:ok, value}

  def decode_answer(:stream_open, %{"v" => @version, "ok" => true, "stream" => stream} = answer)
      when map_size(answer) == 3 do
    with %{
           "grant_id" => grant_id,
           "stream" => name,
           "subject" => subject,
           "projection" => projection,
           "deadline" => deadline
         } <- stream,
         true <- map_size(stream) == 5 and is_binary(grant_id) and is_binary(name),
         true <- is_nil(subject) or is_binary(subject),
         true <- is_list(projection) and Enum.all?(projection, &is_binary/1),
         {:ok, at, 0} <- DateTime.from_iso8601(deadline || "") do
      {:ok, %{stream | "deadline" => at}}
    else
      _ -> {:error, :invalid_answer}
    end
  end

  def decode_answer(kind, %{"v" => @version, "ok" => false, "error" => error} = answer)
      when is_map_key(@routes, kind) and map_size(answer) == 3 do
    classes = Enum.map(Prima.Refusal.classes(), &Atom.to_string/1)

    case error do
      %{"class" => class, "message" => message, "stage" => stage}
      when map_size(error) == 3 and is_binary(message) and stage in ["admission", "execution"] ->
        if class in classes,
          do: {:refused, %{class: class, message: message, stage: stage}},
          else: {:error, :invalid_answer}

      _ ->
        {:error, :invalid_answer}
    end
  end

  def decode_answer(kind, _answer) when is_map_key(@routes, kind), do: {:error, :invalid_answer}

  # ---- a canvas --------------------------------------------------------------

  @doc "The modes a canvas frame is opened in: shown live, or trialled in validation."
  @spec canvas_modes() :: [String.t()]
  def canvas_modes, do: @canvas_modes

  @doc "The most streams a canvas's handshake names."
  @spec max_canvas_streams() :: pos_integer()
  def max_canvas_streams, do: @max_canvas_streams

  @doc "The most tinctures the shell's `installed` message to a canvas names."
  @spec max_installed() :: pos_integer()
  def max_installed, do: @max_installed

  @doc "The most code points a tincture's name in `installed` takes."
  @spec max_installed_name() :: pos_integer()
  def max_installed_name, do: @max_installed_name

  @doc "The most code points a tincture's icon in `installed` takes."
  @spec max_installed_icon() :: pos_integer()
  def max_installed_icon, do: @max_installed_icon

  @doc "The keys of one tincture in `installed`, each present, sorted."
  @spec installed_keys() :: [String.t()]
  def installed_keys, do: @installed_keys

  @doc """
  The prefix every canvas page's path begins with, `/_c/v1/`: the segment
  after it is the asset credential, which a log or a telemetry span must
  never carry (`CyfrWeb.Plugs.ScrubTinctureCredentials`).
  """
  @spec page_prefix() :: String.t()
  def page_prefix, do: @page_prefix

  @doc """
  The page of a canvas open: `/_c/v1/<credential>/<frame id>`. A
  credential outside `Prima.TinctureUrl.credential?/1` or a frame id
  outside `frame_id?/1` raises.
  """
  @spec page_path(String.t(), String.t()) :: String.t()
  def page_path(credential, frame_id) do
    unless Prima.TinctureUrl.credential?(credential),
      do: raise(ArgumentError, "an asset credential is opaque, URL-safe and bounded")

    @page_prefix <> credential <> "/" <> frame!(frame_id)
  end

  @doc "The data prefix of a canvas open: `/_f/v1/o/<frame id>/`. A frame id outside its grammar raises."
  @spec data_path(String.t()) :: String.t()
  def data_path(frame_id), do: @data_prefix <> frame!(frame_id) <> "/"

  @doc "The stream route of a canvas open: `data_path/1` and `stream`."
  @spec stream_path(String.t()) :: String.t()
  def stream_path(frame_id), do: data_path(frame_id) <> @stream_route

  @doc """
  The shell's answer to canvas frame `frame_id`'s handshake: exactly
  `credential` and `canvas`, which holds exactly `mode`, the frame's own
  `data_path`, `streams`, each stream exactly `name` and `subject`, and
  the desktop's `prefs`, `appearance` and `person` from `desktop`
  (string-keyed, as the module doc spells them).

  Every argument is CYFR's own, so one outside the wire raises an
  `ArgumentError` whose sentence names no value, since the credential is
  one: a credential that is not a non-empty string, a mode that is not
  one of `canvas_modes/0`, a frame id outside `frame_id?/1`, streams
  that are not a list of at most `max_canvas_streams/0` distinct
  `%{"name", "subject"}` objects, each a stream name and a string or nil,
  or a `desktop` whose `prefs`, `appearance` or `person` is not the
  wire's.
  """
  @spec canvas_handshake(String.t(), String.t(), String.t(), [map()], map()) :: map()
  def canvas_handshake(frame_id, credential, mode, streams, desktop) do
    unless is_binary(credential) and credential != "",
      do: raise(ArgumentError, "a canvas's handshake carries the frame credential")

    unless mode in @canvas_modes,
      do: raise(ArgumentError, "a canvas's mode is #{Enum.join(@canvas_modes, " or ")}")

    unless canvas_streams?(streams),
      do:
        raise(
          ArgumentError,
          "a canvas's handshake names at most #{@max_canvas_streams} distinct streams, " <>
            "each exactly a stream name and a subject"
        )

    case desktop do
      %{"prefs" => prefs, "appearance" => appearance, "person" => person}
      when map_size(desktop) == 3 ->
        unless prefs?(prefs),
          do: raise(ArgumentError, "a canvas's prefs are exactly a document and its revision")

        unless appearance?(appearance),
          do:
            raise(
              ArgumentError,
              "a canvas's appearance is exactly mode, accent, locale, time_zone and safe_areas"
            )

        unless person?(person),
          do: raise(ArgumentError, "a canvas's person is exactly a name, or none")

        %{
          "credential" => credential,
          "canvas" => %{
            "mode" => mode,
            "data_path" => data_path(frame_id),
            "streams" => streams,
            "prefs" => prefs,
            "appearance" => appearance,
            "person" => person
          }
        }

      _other ->
        raise ArgumentError, "a canvas's handshake carries exactly prefs, appearance and person"
    end
  end

  @doc """
  The shell's answer to an app frame's handshake: its credential, and the
  subject it was opened on when it was opened on one. A credential that
  is not a non-empty string, or a subject outside `subject?/1`, raises.
  """
  @spec frame_handshake(String.t(), map() | nil) :: map()
  def frame_handshake(credential, subject) do
    unless is_binary(credential) and credential != "",
      do: raise(ArgumentError, "a frame's handshake carries the frame credential")

    cond do
      is_nil(subject) -> %{"credential" => credential}
      subject?(subject) -> %{"credential" => credential, "subject" => subject}
      true -> raise ArgumentError, "a frame's subject is exactly a kind and an id"
    end
  end

  @doc """
  The `pressed` message's arguments: press `call` of control `control`
  came to `outcome`, with the refusal's class `reason` exactly when
  refused. A value outside the wire raises.
  """
  @spec pressed(String.t(), pos_integer(), String.t(), String.t() | nil) :: map()
  def pressed(control, call, outcome, reason \\ nil) do
    unless control?(control), do: raise(ArgumentError, "pressed names a control id")
    unless call?(call), do: raise(ArgumentError, "pressed names the press's call")

    %{"control" => control, "call" => call, "outcome" => outcome}
    |> answered(outcome, reason, @press_outcomes)
  end

  @doc """
  The `prefs` message's arguments: write `call` came to `outcome`, and
  the shell now holds `document` at `revision`, with the refusal's class
  `reason` exactly when refused. A value outside the wire raises.
  """
  @spec prefs_answer(pos_integer(), String.t(), map(), non_neg_integer(), String.t() | nil) ::
          map()
  def prefs_answer(call, outcome, document, revision, reason \\ nil) do
    unless call?(call), do: raise(ArgumentError, "a prefs answer names the write's call")

    unless prefs?(%{"document" => document, "revision" => revision}),
      do: raise(ArgumentError, "a prefs answer carries a document and its revision")

    %{"call" => call, "outcome" => outcome, "document" => document, "revision" => revision}
    |> answered(outcome, reason, @prefs_outcomes)
  end

  defp answered(args, outcome, reason, outcomes) do
    classes = Enum.map(Prima.Refusal.classes(), &Atom.to_string/1)

    cond do
      outcome not in outcomes ->
        raise ArgumentError, "an outcome is one of #{Enum.join(outcomes, ", ")}"

      outcome == "refused" and reason in classes ->
        Map.put(args, "reason", reason)

      outcome == "refused" ->
        raise ArgumentError, "a refused outcome names its refusal's class"

      is_nil(reason) ->
        args

      true ->
        raise ArgumentError, "only a refused outcome names a reason"
    end
  end

  defp prefs?(%{"document" => document, "revision" => revision} = prefs)
       when map_size(prefs) == 2,
       do: is_map(document) and not is_struct(document) and is_integer(revision) and revision >= 0

  defp prefs?(_prefs), do: false

  defp appearance?(
         %{
           "mode" => mode,
           "accent" => accent,
           "locale" => locale,
           "time_zone" => zone,
           "safe_areas" => areas
         } = appearance
       )
       when map_size(appearance) == 5 do
    mode in @appearance_modes and is_binary(accent) and Regex.match?(@accent, accent) and
      locale?(locale) and time_zone?(zone) and safe_areas?(areas)
  end

  defp appearance?(_appearance), do: false

  defp safe_areas?(%{"top" => _, "right" => _, "bottom" => _, "left" => _} = areas)
       when map_size(areas) == 4,
       do: Enum.all?(Map.values(areas), &(is_integer(&1) and &1 in 0..@max_safe_area))

  defp safe_areas?(_areas), do: false

  defp person?(%{"name" => nil} = person) when map_size(person) == 1, do: true

  defp person?(%{"name" => name} = person) when map_size(person) == 1,
    do: bounded_text?(name, @max_person_name)

  defp person?(_person), do: false

  # Text of 1 to `max` code points with no control character.
  defp bounded_text?(text, max) do
    is_binary(text) and String.valid?(text) and String.length(text) > 0 and
      length(String.codepoints(text)) <= max and not Regex.match?(@control_characters, text)
  end

  defp frame!(frame_id) do
    if frame_id?(frame_id),
      do: frame_id,
      else: raise(ArgumentError, "a frame id is 8 to 64 URL-safe characters")
  end

  # A list's length is counted only once it is known to be proper:
  # `length/1` raises on an improper list, and its report prints the list.
  defp canvas_streams?(streams) do
    case proper_length(streams, 0) do
      count when is_integer(count) and count <= @max_canvas_streams ->
        Enum.all?(streams, &canvas_stream?/1) and Enum.uniq(streams) == streams

      _improper_or_long ->
        false
    end
  end

  defp proper_length([], count), do: count
  defp proper_length([_head | tail], count), do: proper_length(tail, count + 1)
  defp proper_length(_improper_tail, _count), do: nil

  # A stream `stream_open` could name: the stream-name grammar and a
  # subject that is a string or null.
  defp canvas_stream?(%{"name" => name, "subject" => subject} = stream)
       when map_size(stream) == 2 do
    Prima.Manifest.Tincture.stream_name?(name) and
      (is_nil(subject) or (is_binary(subject) and String.valid?(subject)))
  end

  defp canvas_stream?(_stream), do: false

  # ---- shell messages --------------------------------------------------------

  @doc "The message the frame `frame_id` posts for `verb`."
  @spec shell_message(verb(), String.t(), map()) :: map()
  def shell_message(verb, frame_id, args \\ %{}) when verb in @verbs and is_map(args),
    do: %{"v" => @version, "verb" => Atom.to_string(verb), "frame" => frame_id, "args" => args}

  @doc """
  A shell message read back, or `{:error, sentence}`: another version, a
  verb that is none of `verbs/0`, a frame id that is not one, or arguments
  the verb does not take.
  """
  @spec decode_shell_message(term()) :: {:ok, shell_message()} | {:error, String.t()}
  def decode_shell_message(%{"v" => @version} = message) do
    with :ok <- only(message, ~w(v verb frame args)),
         {:ok, verb} <- verb(message["verb"]),
         :ok <- frame(message["frame"]),
         {:ok, args} <- shell_args(verb, Map.get(message, "args", %{})) do
      {:ok, %{verb: verb, frame: message["frame"], args: args}}
    end
  end

  def decode_shell_message(%{}), do: {:error, "the message carries no wire version #{@version}"}
  def decode_shell_message(_message), do: {:error, "the message must be an object"}

  defp verb(name) do
    case Enum.find(@verbs, &(Atom.to_string(&1) == name)) do
      nil -> {:error, "verb must be one of #{Enum.join(@verbs, ", ")}"}
      verb -> {:ok, verb}
    end
  end

  defp frame(id), do: if(frame_id?(id), do: :ok, else: {:error, "frame must be a frame id"})

  defp shell_args(:open, %{"ref" => ref} = args) when map_size(args) in [1, 2] do
    cond do
      not match?({:ok, %{type: "tincture"}}, Prima.ComponentRef.parse(ref)) ->
        {:error, "open names a tincture reference"}

      map_size(args) == 1 ->
        {:ok, args}

      subject?(Map.get(args, "subject")) ->
        {:ok, args}

      true ->
        {:error, "open's subject is exactly a kind the apps accept and an id"}
    end
  end

  defp shell_args(:open, _args), do: {:error, "open names a tincture reference"}

  defp shell_args(:title, %{"title" => title} = args)
       when map_size(args) == 1 and is_binary(title) and title != "" do
    if String.length(title) <= @max_title,
      do: {:ok, args},
      else: {:error, "a title is at most #{@max_title} characters"}
  end

  defp shell_args(:title, _args), do: {:error, "title names a title"}

  defp shell_args(:credential, %{"name" => name} = args)
       when map_size(args) == 1 and is_binary(name) and name != "",
       do: {:ok, args}

  defp shell_args(:credential, _args), do: {:error, "credential names a vault entry"}

  defp shell_args(:press, %{"binding" => binding, "action" => action} = args)
       when map_size(args) == 2 do
    cond do
      not Prima.Feed.binding_id?(binding) -> {:error, "press names a binding id"}
      not Prima.Feed.name?(action) -> {:error, "press names an action by its name"}
      true -> {:ok, args}
    end
  end

  defp shell_args(:press, %{"control" => control, "call" => call} = args)
       when map_size(args) in [2, 3] do
    cond do
      not control?(control) -> {:error, "press names a control by its id"}
      not call?(call) -> {:error, "a press's call is a whole number from 1 to #{@max_call}"}
      map_size(args) == 2 -> {:ok, args}
      press_value?(Map.get(args, "value")) -> {:ok, args}
      true -> {:error, "a press's value is text of 1 to #{@max_press_value} code points"}
    end
  end

  defp shell_args(:press, _args),
    do: {:error, "press names a binding id and an action, or a control and its call"}

  defp shell_args(:prefs, %{"document" => document, "call" => call} = args)
       when map_size(args) == 2 and is_map(document) do
    if call?(call),
      do: {:ok, args},
      else: {:error, "a prefs write's call is a whole number from 1 to #{@max_call}"}
  end

  defp shell_args(:prefs, _args),
    do: {:error, "prefs carries exactly a document, an object, and its call"}

  defp shell_args(:ask, %{"widget" => widget} = args) when map_size(args) == 1 do
    if widget?(widget), do: {:ok, args}, else: {:error, "ask names a widget by its id"}
  end

  defp shell_args(:ask, _args), do: {:error, "ask names a widget by its id"}

  defp shell_args(:settings, %{"page" => page} = args) when map_size(args) == 1 do
    if page?(page), do: {:ok, args}, else: {:error, "settings names a page by its key"}
  end

  defp shell_args(:settings, _args), do: {:error, "settings names a page by its key"}

  defp shell_args(:grant, %{"ref" => ref} = args) when map_size(args) == 1 do
    case Prima.ComponentRef.parse(ref) do
      {:ok, %{type: type}} ->
        if type in Prima.ComponentRef.valid_types(),
          do: {:ok, args},
          else: {:error, "grant names a component reference"}

      _ ->
        {:error, "grant names a component reference"}
    end
  end

  defp shell_args(:grant, _args), do: {:error, "grant names a component reference"}

  defp shell_args(:failed, %{"stage" => stage} = args)
       when map_size(args) == 1 and stage in @stages,
       do: {:ok, args}

  defp shell_args(:failed, _args),
    do: {:error, "failed names a stage: #{Enum.join(@stages, " or ")}"}

  defp shell_args(_verb, args) when args == %{}, do: {:ok, args}
  defp shell_args(verb, _args), do: {:error, "#{verb} takes no arguments"}

  defp only(map, keys) do
    case map |> Map.keys() |> Enum.reject(&(&1 in keys)) do
      [] ->
        :ok

      extra ->
        {:error,
         "unknown field(s): #{extra |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(", ")}"}
    end
  end
end
