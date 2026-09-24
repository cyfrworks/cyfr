# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Model do
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
      offers, e.g. `web_search`), `max_tokens?`, `temperature?`. Response:
      `model`, `content` (`text` and `tool_call` blocks), `stop_reason`
      (`end_turn | tool_call | max_tokens | content_filter | other`),
      `usage` (`input_tokens`, `output_tokens`, `cache_read_tokens`,
      `cache_write_tokens`).
    * `describe` — what the catalyst can do, answered without a key:
      `contracts`, `provider`, `tools`, `provider_tools`, `media_types`,
      `streaming`, `defaults`. With `{"model": id}` it adds that model's
      `context_window` and `max_output_tokens` (from the provider's models
      API where it reports them, which may take the key), and
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
  names the contract, says whether a manifest declares it, and reads the
  envelope; running a catalyst is the assistant's (`Aqua.Models`).
  """

  @chat "model/chat@1"

  @typedoc """
  What a planner needs to size a request: the model's context window,
  its output ceiling and its input ceiling where the provider bounds the
  input on its own, the provider tools and media types the catalyst
  offers, whether it streams, and its default `max_tokens`.

  Every limit is a positive integer or `nil`; a limit `describe` leaves
  out or answers as zero, negative or not an integer reads as `nil`,
  never as zero, so a malformed ceiling loosens nothing and tightens
  nothing. Only `context_window` is required: an input ceiling never
  stands in for the window.
  """
  @type capabilities :: %{
          context_window: pos_integer(),
          max_output_tokens: pos_integer() | nil,
          max_input_tokens: pos_integer() | nil,
          provider_tools: [String.t()],
          media_types: [String.t()],
          streaming: boolean(),
          default_max_tokens: pos_integer() | nil
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
    @chat in Cyfr.Manifest.contracts(Cyfr.Manifest.decode(manifest))
  end

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
    message = if is_binary(other), do: other, else: inspect(other)
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
