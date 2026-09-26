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

    * `invoke` — run a component: `ref` (a component reference),
      `operation` (a name) and `args` (an object);
    * `action` — run a system action the tincture declares: `operation`
      (`tool.action`) and `args`;
    * `stream_open` — open a stream the tincture declares: `stream` (the
      provider stream's name) and `subject` (a literal, or null for a
      stream that takes none).

  A body carries `v`, the wire version; one at no version or another is
  refused before anything else is read. An answer is `{"v", "ok": true,
  "result"}` for `invoke` and `action`, `{"v", "ok": true, "stream"}` for
  `stream_open` (the grant's id, stream, subject, projection and
  deadline, never its bus topic), and for a refusal `{"v", "ok": false,
  "error": {"class", "message", "stage"}}`: the projection of a
  `Prima.Refusal` a frame may read, never its reason term.

  The frame's document is sandboxed without `allow-same-origin`, so its
  origin is `null` and every request is cross-origin to the endpoint.

  ## Frame to shell

  Messages over the frame's `MessagePort`, each `{"v", "verb", "frame",
  "args"}`, `frame` the frame id the shell minted:

    * `open` — open a tincture: `args.ref`, a tincture reference;
    * `title` — set the frame's title: `args.title`;
    * `ready`, `focus`, `close` — no arguments.

  `tests/fixtures/tincture_wire.json` holds one example of each and one
  refusal; this module's test and the SDK's JavaScript test both read it.
  """

  @version 1
  @bearer_header "authorization"

  @routes %{
    invoke: "/_f/v1/invoke",
    action: "/_f/v1/action",
    stream_open: "/_f/v1/stream"
  }

  @verbs ~w(open close title ready focus)a

  @frame_id ~r/\A[A-Za-z0-9_-]{8,64}\z/
  @component_operation ~r/\A[a-z][a-z0-9_-]{0,62}\z/
  @max_title 120

  @typedoc "A request the frame makes of the endpoint."
  @type kind :: :invoke | :action | :stream_open

  @typedoc "A message the frame sends the shell."
  @type verb :: :open | :close | :title | :ready | :focus

  @typedoc "A decoded request: the kind's fields, atom-keyed."
  @type request ::
          %{ref: String.t(), operation: String.t(), args: map()}
          | %{operation: String.t(), args: map()}
          | %{stream: String.t(), subject: String.t() | nil}

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

  @doc "The JSON body of a `kind` request with `fields` (atom-keyed, as `decode_request/2` answers)."
  @spec request(kind(), map()) :: map()
  def request(:invoke, %{ref: ref, operation: operation, args: args}),
    do: %{"v" => @version, "ref" => ref, "operation" => operation, "args" => args}

  def request(:action, %{operation: operation, args: args}),
    do: %{"v" => @version, "operation" => operation, "args" => args}

  def request(:stream_open, %{stream: stream, subject: subject}),
    do: %{"v" => @version, "stream" => stream, "subject" => subject}

  @doc """
  A decoded `kind` request body, or `{:error, sentence}`: a body at no
  version or another, a missing or malformed field, or a field the kind
  does not carry.
  """
  @spec decode_request(kind(), term()) :: {:ok, request()} | {:error, String.t()}
  def decode_request(kind, %{"v" => @version} = body) when is_map_key(@routes, kind) do
    with :ok <- only(body, fields(kind)) do
      fields(kind, body)
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
  The answer to a `stream_open` request the gate admitted: the grant as a
  frame may read it, under the stream name it was opened by. The bus
  topic stays on the server.
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
  def refusal(%Prima.Refusal{} = refusal) do
    %{
      "v" => @version,
      "ok" => false,
      "error" => %{
        "class" => Atom.to_string(refusal.class),
        "message" => refusal.message,
        "stage" => Atom.to_string(refusal.stage)
      }
    }
  end

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
