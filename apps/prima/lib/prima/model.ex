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

  A refusal is `{"status": N, "error": {"type", "message", "provider"?}}`
  with `type` one of `invalid_request`, `secret_denied`, `authentication`,
  `rate_limited`, `overloaded`, `provider_error`, `incomplete_stream` (the
  provider's stream ended before its closing signal), `unknown_model`,
  `unknown_operation`.

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
  The session a `chat` response names: `{:ok, nil}` when it names none,
  refused when its `session` is not a non-empty string.
  """
  @spec response_session(map()) :: {:ok, String.t() | nil} | {:error, invalid()}
  def response_session(%{"session" => session}) when is_binary(session) and session != "",
    do: {:ok, session}

  def response_session(%{"session" => _other}), do: invalid("session")
  def response_session(%{}), do: {:ok, nil}

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
