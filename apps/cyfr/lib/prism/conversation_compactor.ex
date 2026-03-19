defmodule Prism.ConversationCompactor do
  @moduledoc """
  Compacts conversation history to fit within provider context windows.

  Strategy: sliding window with tool result truncation.
  1. Estimate token count (chars / 4)
  2. If under threshold, pass through unchanged
  3. If over: truncate tool results in older messages, then drop oldest
     messages until under budget — always preserving the last 6 messages
  """

  # ~80k tokens worth of characters (80_000 * 4)
  @token_budget_chars 320_000

  # Truncate tool results in older messages to this many chars
  @truncated_result_chars 500

  # Always preserve at least this many recent messages
  @preserve_recent 6

  @doc """
  Compact a conversation history list to fit within the token budget.

  Handles all three provider message formats:
  - Claude: `%{"role" => "user", "content" => [%{"type" => "tool_result", ...}]}`
  - OpenAI: `%{"role" => "tool", "content" => "..."}`
  - Gemini: `%{"role" => "user", "parts" => [%{"functionResponse" => ...}]}`
  """
  def compact(messages) when is_list(messages) do
    total_chars = estimate_chars(messages)

    if total_chars <= @token_budget_chars do
      messages
    else
      do_compact(messages)
    end
  end

  def compact(other), do: other

  defp do_compact(messages) do
    count = length(messages)
    split_at = max(count - @preserve_recent, 0)
    {older, recent} = Enum.split(messages, split_at)

    # Phase 1: Truncate tool results in older messages
    truncated_older = Enum.map(older, &truncate_tool_results/1)

    # Check if truncation alone brought us under budget
    candidate = truncated_older ++ recent
    total_chars = estimate_chars(candidate)

    if total_chars <= @token_budget_chars do
      candidate
    else
      # Phase 2: Drop oldest messages from the truncated older set
      drop_until_fits(truncated_older, recent)
    end
  end

  defp drop_until_fits([], recent), do: recent

  defp drop_until_fits(older, recent) do
    candidate = older ++ recent
    total_chars = estimate_chars(candidate)

    if total_chars <= @token_budget_chars do
      candidate
    else
      # Drop the oldest message
      drop_until_fits(tl(older), recent)
    end
  end

  # ---------------------------------------------------------------------------
  # Tool result truncation — handles all provider formats
  # ---------------------------------------------------------------------------

  defp truncate_tool_results(%{"role" => "tool", "content" => content} = msg)
       when is_binary(content) and byte_size(content) > @truncated_result_chars do
    %{msg | "content" => String.slice(content, 0, @truncated_result_chars) <> "... [truncated]"}
  end

  defp truncate_tool_results(%{"role" => "user", "content" => content} = msg)
       when is_list(content) do
    updated =
      Enum.map(content, fn
        %{"type" => "tool_result", "content" => text} = part when is_binary(text) ->
          if byte_size(text) > @truncated_result_chars do
            %{part | "content" => String.slice(text, 0, @truncated_result_chars) <> "... [truncated]"}
          else
            part
          end

        %{"type" => "tool_result", "content" => nested} = part when is_list(nested) ->
          truncated_nested =
            Enum.map(nested, fn
              %{"type" => "text", "text" => text} = inner when is_binary(text) ->
                if byte_size(text) > @truncated_result_chars do
                  %{inner | "text" => String.slice(text, 0, @truncated_result_chars) <> "... [truncated]"}
                else
                  inner
                end

              other ->
                other
            end)

          %{part | "content" => truncated_nested}

        other ->
          other
      end)

    %{msg | "content" => updated}
  end

  defp truncate_tool_results(%{"role" => "user", "parts" => parts} = msg)
       when is_list(parts) do
    updated =
      Enum.map(parts, fn
        %{"functionResponse" => %{"response" => resp} = fr} = part when is_map(resp) ->
          json = Jason.encode!(resp)

          if byte_size(json) > @truncated_result_chars do
            truncated = String.slice(json, 0, @truncated_result_chars) <> "... [truncated]"

            case Jason.decode(truncated) do
              {:ok, decoded} ->
                %{part | "functionResponse" => %{fr | "response" => decoded}}

              _ ->
                %{part | "functionResponse" => %{fr | "response" => %{"truncated" => truncated}}}
            end
          else
            part
          end

        other ->
          other
      end)

    %{msg | "parts" => updated}
  end

  defp truncate_tool_results(msg), do: msg

  # ---------------------------------------------------------------------------
  # Size estimation
  # ---------------------------------------------------------------------------

  defp estimate_chars(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      acc + message_chars(msg)
    end)
  end

  defp message_chars(msg) when is_map(msg) do
    # Estimate from the content/parts fields
    content = msg["content"] || msg[:content]
    parts = msg["parts"]

    cond do
      is_binary(content) -> byte_size(content)
      is_list(content) -> Enum.reduce(content, 0, &(block_chars(&1) + &2))
      is_list(parts) -> Enum.reduce(parts, 0, &(block_chars(&1) + &2))
      true -> 0
    end
  end

  defp message_chars(_), do: 0

  defp block_chars(%{"text" => text}) when is_binary(text), do: byte_size(text)
  defp block_chars(%{"content" => text}) when is_binary(text), do: byte_size(text)

  defp block_chars(%{"content" => nested}) when is_list(nested),
    do: Enum.reduce(nested, 0, &(block_chars(&1) + &2))

  defp block_chars(%{"functionResponse" => %{"response" => resp}}) when is_map(resp),
    do: byte_size(Jason.encode!(resp))

  defp block_chars(_), do: 50
end
