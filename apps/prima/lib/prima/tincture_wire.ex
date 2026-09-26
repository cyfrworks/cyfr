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
  term. A refused `stream_open` is answered the same way.

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

    * `open` — open a tincture: `args.ref`, a tincture reference;
    * `title` — set the frame's title: `args.title`;
    * `ready`, `focus`, `close` — no arguments.

  `tests/fixtures/tincture_wire.json` holds one example of each, one
  public request, one refusal and one event stream; this module's test
  and the SDK's JavaScript test both read it.
  """

  @version 1
  @bearer_header "authorization"

  @routes %{
    invoke: "/_f/v1/invoke",
    action: "/_f/v1/action",
    stream_open: "/_f/v1/stream"
  }

  @verbs ~w(open close title ready focus)a

  @stream_content_type "text/event-stream"
  @refusal_event "refusal"

  @frame_id ~r/\A[A-Za-z0-9_-]{8,64}\z/
  @athanor_segment ~r/\A@?[a-z0-9]+(-[a-z0-9]+)*\z/
  @component_operation ~r/\A[a-z][a-z0-9_-]{0,62}\z/
  @max_title 120

  @typedoc "A request the frame makes of the endpoint."
  @type kind :: :invoke | :action | :stream_open

  @typedoc "A message the frame sends the shell."
  @type verb :: :open | :close | :title | :ready | :focus

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

  @typedoc "One event of a stream, read back: its id, its name and its data."
  @type stream_event :: %{id: non_neg_integer() | nil, event: String.t(), data: term()}

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

  @doc "Whether `id` is a frame id: 8 to 64 URL-safe characters."
  @spec frame_id?(term()) :: boolean()
  def frame_id?(id), do: is_binary(id) and Regex.match?(@frame_id, id)

  @doc """
  Whether `identity` names a public tincture: an athanor URL segment
  (`@<namespace>` or a group's slug), a publisher and a name, and nothing
  else.
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
  The events of a `text/event-stream` body read back, in order: each
  group of lines ended by a blank line, `id` a number or nil, `event`
  its name (`"message"` when it names none) and `data` its JSON (data
  lines joined with a newline). A comment line (`:`) and any other field
  are skipped, an event not ended by its blank line is incomplete, and an
  event with no data or data that is not JSON is dropped, as the SDK's
  reader drops it.
  """
  @spec decode_stream(String.t()) :: [stream_event()]
  def decode_stream(body) when is_binary(body) do
    body
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.chunk_while(
      [],
      fn
        "", acc -> {:cont, Enum.reverse(acc), []}
        line, acc -> {:cont, [line | acc]}
      end,
      fn _incomplete -> {:cont, []} end
    )
    |> Enum.flat_map(&stream_group/1)
  end

  defp stream_group(lines) do
    event =
      Enum.reduce(lines, %{id: nil, event: "message", data: []}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          ["", _comment] -> acc
          [field, value] -> stream_field(acc, field, String.replace_prefix(value, " ", ""))
          [field] -> stream_field(acc, field, "")
        end
      end)

    with [_ | _] = data <- event.data,
         {:ok, decoded} <- Jason.decode(data |> Enum.reverse() |> Enum.join("\n")) do
      [%{id: event.id, event: event.event, data: decoded}]
    else
      _ -> []
    end
  end

  defp stream_field(acc, "data", value), do: %{acc | data: [value | acc.data]}
  defp stream_field(acc, "event", value), do: %{acc | event: value}

  defp stream_field(acc, "id", value) do
    case Integer.parse(value) do
      {id, ""} when id >= 0 -> %{acc | id: id}
      _ -> %{acc | id: nil}
    end
  end

  defp stream_field(acc, _field, _value), do: acc

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

  defp shell_args(:open, %{"ref" => ref} = args) when map_size(args) == 1 do
    case Prima.ComponentRef.parse(ref) do
      {:ok, %{type: "tincture"}} -> {:ok, args}
      _ -> {:error, "open names a tincture reference"}
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
