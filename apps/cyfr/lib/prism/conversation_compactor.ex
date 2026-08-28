# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.ConversationCompactor do
  @moduledoc """
  Compacts conversation history to fit within provider context windows.

  Strategy: sliding window with tool result truncation.
  1. Estimate token count (chars / 4)
  2. If under threshold, pass through unchanged
  3. If over: truncate tool results in older messages, then drop oldest
     message groups until under budget — always preserving recent messages.

  Message groups are dropped as semantic units to avoid orphaning
  tool_results from their assistant messages:
  - assistant (with tool_use) + following tool_results = one group
  - standalone user or assistant messages = one group each
  """

  # ~80k tokens worth of characters (80_000 * 4)
  @token_budget_chars 320_000

  # Truncate tool results in older messages to this many chars
  @truncated_result_chars 500

  # Always preserve at least this many recent messages
  @preserve_recent 20

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
      # Phase 2: Drop oldest message groups until under budget
      groups = group_messages(truncated_older)
      drop_groups_until_fits(groups, recent)
    end
  end

  # ---------------------------------------------------------------------------
  # Message group dropping — respects assistant↔tool_results pairs
  # ---------------------------------------------------------------------------

  @doc false
  def group_messages(messages) do
    do_group(messages, [])
  end

  defp do_group([], acc), do: Enum.reverse(acc)

  defp do_group([msg | rest], acc) do
    if has_tool_calls?(msg) do
      # Assistant with tool_use — consume following tool_results as a group
      {tool_results, remaining} = take_tool_results(rest)
      group = [msg | tool_results]
      do_group(remaining, [group | acc])
    else
      do_group(rest, [[msg] | acc])
    end
  end

  defp has_tool_calls?(%{"role" => "assistant", "content" => content}) when is_list(content) do
    Enum.any?(content, fn
      %{"type" => "tool_use"} -> true
      _ -> false
    end)
  end

  defp has_tool_calls?(%{"role" => "assistant", "tool_calls" => tc})
       when is_list(tc) and tc != [],
       do: true

  defp has_tool_calls?(_), do: false

  defp take_tool_results(messages) do
    # Take consecutive tool_results / tool / user-with-tool_result messages
    Enum.split_while(messages, &tool_result_message?/1)
  end

  defp tool_result_message?(%{"role" => "tool"}), do: true
  defp tool_result_message?(%{"role" => "tool_results"}), do: true

  defp tool_result_message?(%{"role" => "user", "content" => content}) when is_list(content) do
    Enum.any?(content, fn
      %{"type" => "tool_result"} -> true
      _ -> false
    end)
  end

  defp tool_result_message?(_), do: false

  defp drop_groups_until_fits([], recent), do: recent

  defp drop_groups_until_fits(groups, recent) do
    # Each group is measured once and its size subtracted as it drops —
    # re-measuring the whole remainder on every drop made this quadratic
    # in message count.
    sized = Enum.map(groups, fn group -> {group, estimate_chars(group)} end)
    total = estimate_chars(recent) + Enum.sum(Enum.map(sized, &elem(&1, 1)))

    kept = drop_sized(sized, total)
    Enum.flat_map(kept, &elem(&1, 0)) ++ recent
  end

  defp drop_sized([], _total), do: []

  defp drop_sized([{_group, size} | rest] = sized, total) do
    if total <= @token_budget_chars, do: sized, else: drop_sized(rest, total - size)
  end

  # ---------------------------------------------------------------------------
  # Tool result truncation — handles all provider formats
  # ---------------------------------------------------------------------------

  defp truncate_tool_results(%{"role" => "tool", "content" => content} = msg)
       when is_binary(content) and byte_size(content) > @truncated_result_chars do
    %{
      msg
      | "content" => String.byte_slice(content, 0, @truncated_result_chars) <> "... [truncated]"
    }
  end

  defp truncate_tool_results(%{"role" => "user", "content" => content} = msg)
       when is_list(content) do
    updated =
      Enum.map(content, fn
        %{"type" => "tool_result", "content" => text} = part when is_binary(text) ->
          if byte_size(text) > @truncated_result_chars do
            %{
              part
              | "content" =>
                  String.byte_slice(text, 0, @truncated_result_chars) <> "... [truncated]"
            }
          else
            part
          end

        %{"type" => "tool_result", "content" => nested} = part when is_list(nested) ->
          truncated_nested =
            Enum.map(nested, fn
              %{"type" => "text", "text" => text} = inner when is_binary(text) ->
                if byte_size(text) > @truncated_result_chars do
                  %{
                    inner
                    | "text" =>
                        String.byte_slice(text, 0, @truncated_result_chars) <> "... [truncated]"
                  }
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
      # A shape this function does not recognise still goes to the provider,
      # so it is measured rather than assumed weightless.
      true -> encoded_size(msg)
    end
  end

  defp message_chars(msg), do: encoded_size(msg)

  defp block_chars(%{"text" => text}) when is_binary(text), do: byte_size(text)
  defp block_chars(%{"content" => text}) when is_binary(text), do: byte_size(text)

  defp block_chars(%{"content" => nested}) when is_list(nested),
    do: Enum.reduce(nested, 0, &(block_chars(&1) + &2))

  defp block_chars(%{"functionResponse" => %{"response" => resp}}) when is_map(resp),
    do: encoded_size(resp)

  # Every other block — a `tool_use` carrying its arguments, a `tool_calls`
  # entry, an image part — was charged a flat 50 characters. A tool-heavy
  # history is mostly those, so a megabyte of arguments estimated as a few
  # hundred bytes, compaction concluded it was well under budget, and the
  # provider rejected the request nobody had trimmed.
  defp block_chars(block), do: encoded_size(block)

  # The size the thing will actually be on the wire. `Jason.encode/1` rather
  # than `encode!/1`: this is an estimate on the way to a decision, and a
  # term it cannot encode must not take the turn down.
  defp encoded_size(term) do
    case Jason.encode(term) do
      {:ok, json} -> byte_size(json)
      {:error, _} -> term |> inspect(limit: 200, printable_limit: 4096) |> byte_size()
    end
  end
end
