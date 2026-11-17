# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Model do
  @moduledoc """
  `model/chat@1`, the contract a model catalyst declares in its manifest
  (`"contracts": ["model/chat@1"]`) and answers on its one `run` export as
  three operations of the catalyst envelope (`{"operation", "params"}` in,
  `{"status", "data" | "error"}` out):

    * `chat` — a contract request in, a contract response out. Request:
      `model`, `system?`, `messages` (`user`/`assistant`/`tool` roles;
      content a string or typed blocks: `text`, `image`, `document`,
      `tool_call {id, name, arguments, provider_data?}`, `tool_result
      {tool_call_id, name, content, is_error?}`), `tools?` (`name`,
      `description`, `parameters`), `provider_tools?` (names the catalyst
      offers, e.g. `web_search`), `max_tokens?`, `temperature?`,
      `session?` (a non-empty opaque string a response answered, continuing
      that session on the brain), `options?` (an object of the options
      `describe` declares, by name, each value of its option's kind).
      Response: `model`, `content` (`text` and `tool_call` blocks),
      `stop_reason` (`end_turn | tool_call | max_tokens | content_filter |
      other`), `usage` (`input_tokens`, `output_tokens`,
      `cache_read_tokens`, `cache_write_tokens`), `session?` (a non-empty
      opaque string naming the brain's session). A `tool_call`'s
      `provider_data` carries what the catalyst needs to continue from it.
    * `describe` — what the catalyst can do, answered without a key:
      `contracts`, `provider`, `tools`, `provider_tools`, `media_types`,
      `streaming`, `defaults`, `options?` (what a caller may set per
      request, `t:option/0`; absent is none). With `{"model": id}` it
      adds that model's `context_window` and `max_output_tokens` (from the
      provider's models API where it reports them, which may take the key), and
      `max_input_tokens` where the provider bounds the input on its own,
      or refuses a model the catalyst does not know as `unknown_model`.
    * `models` — what the bound key can reach: `models` as `{id, name,
      context_window?, max_output_tokens?}`.

  While `chat` runs, the catalyst streams the answer on its execution's
  event stream (`cyfr:emit/events`): `text.delta {text}`,
  `tool_call.start {index, id, name}`, `tool_call.delta {index,
  arguments}`, `tool_call.end {index}`, `usage {usage}`, `stop
  {stop_reason}`, `error {error}` — and still answers the whole response.

  While `chat` runs, the catalyst may ask for the call's further messages
  (`cyfr:model/inputs`, `c:Prima.HostAPI.input_next/1`): each an input
  (`t:input/0`), a message that arrived after the call began, which the
  catalyst writes into its harness's running session and reports sent
  once the harness accepted it (`c:Prima.HostAPI.input_sent/2`). When the
  harness's model reads it is the harness's business: a report promises
  neither an answer nor that a tool under way stops. An input is held to
  `check_input/1` before the catalyst is handed it, and the catalyst
  writes only the block kinds its harness takes.

  A refusal is `{"status": N, "error": {"type", "message", "provider"?,
  "session"?}}` with `type` one of `invalid_request`, `secret_denied`,
  `authentication`, `rate_limited`, `overloaded`, `provider_error`,
  `incomplete_stream` (the provider's stream ended before its closing
  signal), `unknown_model`, `unknown_operation`, `unknown_session` (the
  brain reports that the session the request named no longer exists, and
  refused before it took anything of the request). A refusal's `session`
  is a response's: the brain's session once it exists, such as a chat
  interrupted after it opened one, which the host keeps as it keeps a
  response's, so the next request continues it. An `unknown_session`
  refusal carries none, since the session is gone: the host forgets the
  one it kept, and the same request without `session` opens a new one.

  The provider's HTTP call and the key stay in the catalyst. This module
  names the contract, says whether a manifest declares it, reads the
  envelope, and checks the members a caller sets per brain (`options/1`,
  `check_chat_request/2`, `response_session/1`); running a catalyst is
  the assistant's (`Aqua.Models`). The shared vectors are
  `tests/fixtures/model_chat.json`. A catalyst that declares no options
  ignores a request's `session` and `options`, and the host sends none it
  did not declare (`Aqua.Loop.Request.build/1` refuses an option it does
  not know); the vectors' Rust consumers are the catalyst versions that
  implement options.
  """

  @chat "model/chat@1"
  @option_kinds ~w(enum string integer boolean)
  @option_members ~w(name kind values default)

  @input_id ~r/\A[A-Za-z0-9_.:-]{1,128}\z/
  # The most blocks one input carries: a bound of the input's own meaning
  # (ARCHITECTURE.md §5.8), beside the line bound its bytes are held to.
  @max_input_blocks 32
  @media_types %{
    "image" => ~w(image/jpeg image/png image/gif image/webp),
    "document" => ~w(application/pdf)
  }

  @typedoc """
  A further message of a running `chat` (`c:Prima.HostAPI.input_next/1`):
  its `id`, which its supplier knows it by (`valid_input_id?/1`), and its
  `content`, a user message's content: a non-empty string, or 1 to
  `max_input_blocks/0` blocks, each `{"type": "text", "text"}` or an
  attachment `{"type": "image" | "document", "media_type", "data"}` whose
  data is base64 of a media type `input_media_types/0` names. A block
  carries no other member, so nothing in it is a path or an address to
  fetch, and the input's JSON is at most `max_input_bytes/0`.
  """
  @type input :: %{String.t() => String.t() | [map()]}

  @typedoc """
  One option `describe` declares, as the wire carries it: `"name"` (a
  non-empty string, unique in the list), `"kind"` (one of
  `option_kinds/0`), `"values"` (an enum's non-empty list of distinct
  non-empty strings, and only an enum's) and `"default"` (optional, a
  value of the kind: one of an enum's values, a string, an integer or a
  boolean). No other member.
  """
  @type option :: %{String.t() => String.t() | [String.t()] | integer() | boolean()}

  @typedoc "A refusal naming the member it is about, e.g. `options[1].default`."
  @type invalid :: {:invalid, String.t()}

  @typedoc """
  What a planner needs to size a request: the model's context window,
  its output ceiling and its input ceiling where the provider bounds the
  input on its own, the provider tools and media types the catalyst
  offers, whether it streams, and its default `max_tokens`.

  Every limit is a positive integer or `nil`; a limit `describe` leaves
  out or answers as zero, negative or not an integer reads as `nil`,
  never as zero, so a malformed ceiling loosens nothing and tightens
  nothing. Only `context_window` is required: an input ceiling never
  stands in for the window. `options` are the options `describe`
  declares (`options/1`).
  """
  @type capabilities :: %{
          context_window: pos_integer(),
          max_output_tokens: pos_integer() | nil,
          max_input_tokens: pos_integer() | nil,
          provider_tools: [String.t()],
          media_types: [String.t()],
          streaming: boolean(),
          default_max_tokens: pos_integer() | nil,
          options: [option()]
        }

  @doc "The chat contract's name, as a manifest declares it."
  @spec chat_contract() :: String.t()
  def chat_contract, do: @chat

  @doc """
  Whether a manifest declares the chat contract. A manifest that does not
  decode declares nothing.
  """
  @spec speaks_chat?(map() | nil | binary()) :: boolean()
  def speaks_chat?(manifest) do
    case Prima.Manifest.decode_strict(manifest) do
      {:ok, decoded} -> @chat in Prima.Manifest.contracts(decoded)
      {:error, :malformed_manifest} -> false
    end
  end

  @doc "The kinds an option may be, as the wire spells them."
  @spec option_kinds() :: [String.t()]
  def option_kinds, do: @option_kinds

  @doc """
  The options a `describe` answer declares, as they are, or the member
  that breaks `t:option/0`. An answer with no `options` declares none.
  """
  @spec options(map()) :: {:ok, [option()]} | {:error, invalid()}
  def options(described) when is_map(described) do
    case Map.fetch(described, "options") do
      :error -> {:ok, []}
      {:ok, options} when is_list(options) -> declared(options)
      {:ok, _other} -> invalid("options")
    end
  end

  defp declared(options) do
    options
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {option, index}, {:ok, names} ->
      at = "options[#{index}]"

      with :ok <- option(option, at) do
        if MapSet.member?(names, option["name"]),
          do: {:halt, invalid(at <> ".name")},
          else: {:cont, {:ok, MapSet.put(names, option["name"])}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _names} -> {:ok, options}
      error -> error
    end
  end

  defp option(%{} = option, at) do
    cond do
      (unknown = Map.keys(option) -- @option_members) != [] ->
        invalid("#{at}.#{hd(Enum.sort(unknown))}")

      not (is_binary(option["name"]) and option["name"] != "") ->
        invalid(at <> ".name")

      option["kind"] not in @option_kinds ->
        invalid(at <> ".kind")

      not values?(option) ->
        invalid(at <> ".values")

      Map.has_key?(option, "default") and not of_kind?(option, option["default"]) ->
        invalid(at <> ".default")

      true ->
        :ok
    end
  end

  defp option(_other, at), do: invalid(at)

  defp values?(%{"kind" => "enum", "values" => [_ | _] = values}),
    do: Enum.all?(values, &(is_binary(&1) and &1 != "")) and Enum.uniq(values) == values

  defp values?(%{"kind" => "enum"}), do: false
  defp values?(option), do: not Map.has_key?(option, "values")

  defp of_kind?(%{"kind" => "enum", "values" => values}, value), do: value in values
  defp of_kind?(%{"kind" => "string"}, value), do: is_binary(value)
  defp of_kind?(%{"kind" => "integer"}, value), do: is_integer(value)
  defp of_kind?(%{"kind" => "boolean"}, value), do: is_boolean(value)

  @doc """
  Whether a `chat` request's `session` and `options` hold to the
  contract under `declared` (`options/1`): a session is a non-empty
  string, and every option the request sets is one `declared` names,
  with a value of its kind. The other members are the catalyst's to read.
  """
  @spec check_chat_request(map(), [option()]) :: :ok | {:error, invalid()}
  def check_chat_request(request, declared) when is_map(request) and is_list(declared) do
    with :ok <- session(request) do
      set_options(request, Map.new(declared, &{&1["name"], &1}))
    end
  end

  defp session(%{"session" => session}) when is_binary(session) and session != "", do: :ok
  defp session(%{"session" => _other}), do: invalid("session")
  defp session(%{}), do: :ok

  defp set_options(%{"options" => set}, declared) when is_map(set) do
    set
    |> Enum.sort()
    |> Enum.find_value(:ok, fn {name, value} ->
      case declared do
        %{^name => option} ->
          if of_kind?(option, value), do: nil, else: invalid("options.#{name}")

        _undeclared ->
          invalid("options.#{name}")
      end
    end)
  end

  defp set_options(%{"options" => _other}, _declared), do: invalid("options")
  defp set_options(%{}, _declared), do: :ok

  @doc """
  The session a `chat` answer names, a response's data or a refusal's
  `error`: `{:ok, nil}` when it names none, refused when its `session` is
  not a non-empty string, or when an `unknown_session` refusal names one.
  """
  @spec response_session(map()) :: {:ok, String.t() | nil} | {:error, invalid()}
  def response_session(%{"type" => "unknown_session", "session" => _any}), do: invalid("session")

  def response_session(%{"session" => session}) when is_binary(session) and session != "",
    do: {:ok, session}

  def response_session(%{"session" => _other}), do: invalid("session")
  def response_session(%{}), do: {:ok, nil}

  @doc "Whether `id` is an input's id: 1 to 128 characters of `[A-Za-z0-9_.:-]`."
  @spec valid_input_id?(term()) :: boolean()
  def valid_input_id?(id) when is_binary(id), do: Regex.match?(@input_id, id)
  def valid_input_id?(_id), do: false

  @doc """
  The most bytes an input's JSON may be: one line to a program's session
  (`Prima.LocusBackends.max_line_bytes/0`), which the catalyst writes it
  into; the catalyst holds the line it writes to the same bound.
  """
  @spec max_input_bytes() :: pos_integer()
  def max_input_bytes, do: Prima.LocusBackends.max_line_bytes()

  @doc "The most blocks an input's content carries."
  @spec max_input_blocks() :: pos_integer()
  def max_input_blocks, do: @max_input_blocks

  @doc "The media types an input's attachment may be, by block kind."
  @spec input_media_types() :: %{String.t() => [String.t()]}
  def input_media_types, do: @media_types

  @doc """
  Whether `input` holds to `t:input/0`, or the member that breaks it:
  `id`, `content`, `content[i]` for a block, `content[i].<member>` for one
  of its members (an unknown one by its own name), an unknown member of
  the input by its name, and `content` for an input whose JSON, or whose
  attachments' decoded bytes, are past `max_input_bytes/0`. What a member
  holds is never named.
  """
  @spec check_input(term()) :: :ok | {:error, invalid()}
  def check_input(%{} = input) when not is_struct(input) do
    cond do
      (unknown = Map.keys(input) -- ["id", "content"]) != [] ->
        invalid(unknown |> Enum.map(&to_string/1) |> Enum.sort() |> hd())

      not valid_input_id?(input["id"]) ->
        invalid("id")

      true ->
        with :ok <- content(input["content"]), do: sized(input)
    end
  end

  def check_input(_input), do: invalid("input")

  defp content(text) when is_binary(text) and text != "", do: :ok

  defp content([_ | _] = blocks) when length(blocks) <= @max_input_blocks do
    blocks
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {block, index} ->
      case block(block, "content[#{index}]") do
        :ok -> nil
        refused -> refused
      end
    end)
  end

  defp content(_other), do: invalid("content")

  defp block(%{"type" => "text"} = block, at), do: members(block, at, %{"text" => &text?/1})

  defp block(%{"type" => kind} = block, at) when is_map_key(@media_types, kind) do
    members(block, at, %{
      "media_type" => &(&1 in Map.fetch!(@media_types, kind)),
      "data" => &base64?/1
    })
  end

  defp block(%{"type" => _other}, at), do: invalid(at <> ".type")
  defp block(_other, at), do: invalid(at)

  # A block's members are exactly `type` and its kind's, each held to its
  # check, in the order of their names.
  defp members(block, at, checks) do
    case Enum.sort(Map.keys(block) -- ["type" | Map.keys(checks)]) do
      [unknown | _] ->
        invalid("#{at}.#{unknown}")

      [] ->
        checks
        |> Enum.sort()
        |> Enum.find_value(:ok, fn {name, check?} ->
          if Map.has_key?(block, name) and check?.(block[name]),
            do: nil,
            else: invalid("#{at}.#{name}")
        end)
    end
  end

  defp text?(text), do: is_binary(text) and text != ""

  defp base64?(data) when is_binary(data) and data != "",
    do: match?({:ok, _bytes}, Base.decode64(data))

  defp base64?(_data), do: false

  defp sized(%{"content" => content} = input) do
    decoded =
      if is_list(content),
        do: Enum.reduce(content, 0, &(&2 + decoded_bytes(&1))),
        else: 0

    if byte_size(Jason.encode!(input)) <= max_input_bytes() and decoded <= max_input_bytes(),
      do: :ok,
      else: invalid("content")
  end

  defp decoded_bytes(%{"data" => data}), do: data |> Base.decode64!() |> byte_size()
  defp decoded_bytes(_text), do: 0

  defp invalid(member), do: {:error, {:invalid, member}}

  @doc """
  The catalyst envelope an `execution.run` answered, read: `{:ok, data}`
  for a 2xx `data`, `{:error, %{"type" => _, "message" => _}}` for a
  refusal, and `{:error, %{"type" => "malformed"}}` for anything that is
  not the envelope. Accepts the run result (`%{result: envelope}`) or the
  envelope itself, as a map or JSON.
  """
  @spec decode_envelope(term()) :: {:ok, map()} | {:error, map()}
  def decode_envelope(%{result: envelope}), do: decode_envelope(envelope)
  def decode_envelope(%{"result" => envelope}), do: decode_envelope(envelope)

  def decode_envelope(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> decode_envelope(decoded)
      _ -> {:error, %{"type" => "malformed", "message" => "the catalyst answered no envelope"}}
    end
  end

  def decode_envelope(%{"status" => status, "data" => data} = envelope)
      when is_integer(status) and status >= 200 and status < 300 do
    case envelope do
      %{"error" => _} -> {:error, malformed(envelope)}
      _ when is_map(data) -> {:ok, data}
      _ -> {:error, malformed(envelope)}
    end
  end

  def decode_envelope(%{"error" => %{"type" => type, "message" => message} = error})
      when is_binary(type) and is_binary(message),
      do: {:error, error}

  def decode_envelope(%{"error" => other}) do
    message =
      if is_binary(other), do: other, else: "the catalyst answered an error with no message"

    {:error, %{"type" => "provider_error", "message" => message}}
  end

  def decode_envelope(other), do: {:error, malformed(other)}

  defp malformed(envelope) do
    %{
      "type" => "malformed",
      "message" =>
        "the catalyst answered something that is not the envelope: " <>
          String.slice(inspect(envelope), 0, 200)
    }
  end
end
