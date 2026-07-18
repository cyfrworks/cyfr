# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaLive.View do
  @moduledoc """
  Pure presentation / formatting helpers for `PrismWeb.AquaLive`.

  Everything here returns plain data or strings (never `~H` markup) and never
  touches `socket` or assigns. Covers tool-activity formatting, formula-input
  shaping, model-list normalization, and conversation (de)serialization /
  index upserts. Behaviour matches the in-line versions exactly.
  """

  @doc """
  Mark the most recent running tool-activity entry for `tool` as done,
  attaching `preview`. Appends a synthetic done entry if none was running.
  """
  def mark_tool_done(activity, tool, preview) do
    target =
      activity
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find(fn {e, _i} -> e.tool == tool and e.status == :running end)

    case target do
      {_entry, idx} ->
        List.update_at(activity, idx, fn e -> %{e | status: :done, preview: preview} end)

      nil ->
        activity ++ [%{tool: tool, status: :done, preview: preview}]
    end
  end

  # ---------------------------------------------------------------------------
  # Formula-input shaping
  # ---------------------------------------------------------------------------

  def maybe_put_active_context(input, nil), do: input
  def maybe_put_active_context(input, ctx), do: Map.put(input, "active_context", ctx)

  def maybe_put_attachments(input, []), do: input
  def maybe_put_attachments(input, attachments), do: Map.put(input, "attachments", attachments)

  def maybe_put_messages(input, []), do: input

  def maybe_put_messages(input, history) when is_list(history) do
    cleaned = Enum.map(history, &strip_actions_in_message/1)
    Map.put(input, "messages", Prism.ConversationCompactor.compact(cleaned))
  end

  def maybe_put_messages(input, _), do: input

  # Strip aqua-actions blocks from any assistant text blocks before
  # forwarding history back to the formula. Otherwise the model re-encounters
  # its own block on the next turn and may copy-paste the literal JSON
  # instead of treating it as already-executed.
  defp strip_actions_in_message(%{"role" => "assistant", "content" => content} = msg)
       when is_binary(content) do
    %{msg | "content" => Prism.AquaActions.strip_blocks(content)}
  end

  defp strip_actions_in_message(%{"role" => "assistant", "content" => parts} = msg)
       when is_list(parts) do
    %{msg | "content" => Enum.map(parts, &strip_actions_in_part/1)}
  end

  defp strip_actions_in_message(msg), do: msg

  defp strip_actions_in_part(%{"type" => "text", "text" => text} = part) when is_binary(text) do
    %{part | "text" => Prism.AquaActions.strip_blocks(text)}
  end

  defp strip_actions_in_part(part), do: part

  # ---------------------------------------------------------------------------
  # Model-list normalization
  # ---------------------------------------------------------------------------

  # Catalysts return their list-models response verbatim — typically a list
  # of `%{"id" => ...}` objects, sometimes wrapped in a `{"data": [...]}`
  # envelope (Anthropic/OpenAI shape). Reduce to a plain list of model ids
  # so the templates can iterate without sniffing shape.
  def normalize_provider_models(value) do
    cond do
      is_list(value) -> Enum.map(value, &model_id/1) |> Enum.reject(&is_nil/1)
      is_map(value) and is_list(value["data"]) -> normalize_provider_models(value["data"])
      true -> []
    end
  end

  defp model_id(m) when is_binary(m), do: m
  defp model_id(%{"id" => id}) when is_binary(id), do: id
  defp model_id(%{id: id}) when is_binary(id), do: id
  defp model_id(_), do: nil

  # ---------------------------------------------------------------------------
  # Conversation (de)serialization + index upserts
  # ---------------------------------------------------------------------------

  def first_user_title(messages) do
    Enum.find_value(messages, "New conversation", fn
      %{role: "user", content: c} when is_binary(c) -> String.slice(c, 0..80)
      _ -> nil
    end)
  end

  # Approval cards aren't re-renderable interactively in a loaded conversation
  # (the decision already happened, and `pending_approvals` is reset on load),
  # so persist them as a plain text note. The model's own context lives in
  # `conversation_history` (the `[System: user approved …]` turns), separate
  # from this UI thread.
  def serialize_message(%{role: "approval"} = msg) do
    role = if Map.get(msg, :status) == :error, do: "error", else: "system"

    %{
      "role" => role,
      "content" => approval_note(msg),
      "timestamp" => DateTime.to_iso8601(Map.get(msg, :timestamp) || DateTime.utc_now())
    }
  end

  def serialize_message(%{} = msg) do
    %{
      "role" => Map.get(msg, :role, "assistant"),
      "content" => Map.get(msg, :content) || "",
      "timestamp" => DateTime.to_iso8601(Map.get(msg, :timestamp) || DateTime.utc_now())
    }
  end

  defp approval_note(msg) do
    title = get_in(msg, [:payload, :title]) || get_in(msg, [:payload, "title"]) || "action"

    extra =
      if msg[:result_summary] && msg[:result_summary] != "",
        do: " — #{msg[:result_summary]}",
        else: ""

    reason = if msg[:reason] && msg[:reason] != "", do: " — #{msg[:reason]}", else: ""

    case Map.get(msg, :status) do
      :approved -> "✓ Approved: #{title}#{extra}"
      :declined -> "✕ Declined: #{title}#{reason}"
      :error -> "! Failed: #{title}#{extra}"
      _ -> "⏳ Pending approval: #{title}"
    end
  end

  def deserialize_message(%{"role" => role, "content" => content} = m) do
    %{
      role: role,
      content: content,
      timestamp: parse_ts(m["timestamp"])
    }
  end

  def deserialize_message(_), do: %{role: "assistant", content: "", timestamp: DateTime.utc_now()}

  def parse_ts(nil), do: DateTime.utc_now()

  def parse_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  def parse_ts(_), do: DateTime.utc_now()

  def upsert_entry(entries, %{"id" => id} = new_entry) do
    if Enum.any?(entries, fn e -> e["id"] == id end) do
      Enum.map(entries, fn e -> if e["id"] == id, do: new_entry, else: e end)
    else
      [new_entry | entries]
    end
  end

  def upsert_in_memory(%{id: id} = new_entry, conversations) do
    if Enum.any?(conversations, fn c -> c.id == id end) do
      Enum.map(conversations, fn c -> if c.id == id, do: new_entry, else: c end)
    else
      [new_entry | conversations]
    end
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
  end
end
