# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ConversationCompactor do
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

  Handles the canonical shape the providers write back and the three
  native ones a history may still carry:
  - Canonical: `%{"role" => "tool_results", "results" => [%{"content" => ...}]}`
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
      compacted = drop_groups_until_fits(groups, recent)

      # Phase 3: the preserved window can hold the budget many times over
      # by itself — twenty messages each carrying a multi-hundred-KB tool
      # result passed phases 1 and 2 untouched, and the row never shrank.
      # Recent prose is always kept; oversized recent tool results are not.
      if estimate_chars(compacted) <= @token_budget_chars do
        compacted
      else
        Enum.map(compacted, &truncate_tool_results/1)
      end
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
       when is_binary(content),
       do: %{msg | "content" => cut(content)}

  # The canonical shape every provider writes back into the history: one
  # message carrying every result of the assistant turn before it. Without
  # this arm the compactor could only drop such a message whole.
  defp truncate_tool_results(%{"role" => "tool_results", "results" => results} = msg)
       when is_list(results),
       do: %{msg | "results" => Enum.map(results, &truncate_result/1)}

  defp truncate_tool_results(%{"role" => "user", "content" => content} = msg)
       when is_list(content),
       do: %{msg | "content" => Enum.map(content, &truncate_block/1)}

  # Gemini's native spelling, should a history still carry one.
  defp truncate_tool_results(%{"role" => "user", "parts" => parts} = msg)
       when is_list(parts) do
    %{
      msg
      | "parts" =>
          Enum.map(parts, fn
            %{"functionResponse" => %{"response" => response} = call} = part ->
              %{part | "functionResponse" => %{call | "response" => cut_value(response)}}

            other ->
              other
          end)
    }
  end

  defp truncate_tool_results(msg), do: msg

  # A `tool_result` content block; every other block in a user message is
  # the person's own and stays whole.
  defp truncate_block(%{"type" => "tool_result", "content" => content} = part)
       when is_binary(content) or is_list(content),
       do: %{part | "content" => cut_value(content)}

  defp truncate_block(other), do: other

  # One entry of a canonical `results` list.
  defp truncate_result(%{"content" => content} = result),
    do: %{result | "content" => cut_value(content)}

  defp truncate_result(other), do: other

  # Text is cut; a list of blocks has its text blocks cut one by one; a
  # structured value is cut as its JSON when that is what is large.
  defp cut_value(text) when is_binary(text), do: cut(text)

  defp cut_value(blocks) when is_list(blocks) do
    Enum.map(blocks, fn
      %{"type" => "text", "text" => text} = inner when is_binary(text) ->
        %{inner | "text" => cut(text)}

      other ->
        other
    end)
  end

  defp cut_value(%{} = value) do
    case Jason.encode(value) do
      {:ok, json} when byte_size(json) > @truncated_result_chars -> %{"content" => cut(json)}
      _ -> value
    end
  end

  defp cut_value(other), do: other

  defp cut(text), do: Cyfr.Text.cut(text, @truncated_result_chars, "... [truncated]")

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
