# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.RoomExcerpt do
  @moduledoc """
  What a room shows, read for the person's own AQUA.

  The person has a room open beside their own thread and asks their own
  assistant about it. That assistant is not in the room — a group's tape
  is the group's — so the excerpt is read here, under the person's own
  membership of the room (`Sanctum.Context.focus/2`), and handed to the
  turn as context (`Aqua.ConversationRunner.send_message/4`'s `:context`):
  it rides the prompt of that one turn and is never a row of the private
  thread, never its history, never a note. Shared to private is the only
  direction; nothing here writes.

  Bounded: the newest lines that fit `max_bytes/0`, oldest first, headed
  by one line naming the room, so the excerpt and the person's own
  message together stay inside the runner's message cap.
  """

  alias Arca.ConversationStorage, as: Conversations
  alias Sanctum.Context

  @max_bytes 16 * 1024
  @rows 40

  @typedoc "Which room, and how the person sees it named."
  @type room :: %{
          required(:athanor_id) => String.t(),
          required(:conversation_id) => String.t(),
          optional(:title) => String.t() | nil,
          optional(:estate) => String.t() | nil
        }

  @doc "The excerpt's byte bound — half the runner's message cap."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  The room's newest lines as one bounded text. `{:error, reason}` when the
  person holds no seat in the room, the thread is gone, or nobody has said
  anything there yet.
  """
  @spec read(Context.t(), room()) :: {:ok, String.t()} | {:error, term()}
  def read(%Context{} = ctx, %{athanor_id: athanor_id, conversation_id: conversation_id} = room) do
    with {:ok, room_ctx} <- Context.focus(ctx, athanor_id),
         {:ok, conv} <- Conversations.get(room_ctx, conversation_id),
         rows when is_list(rows) <-
           Conversations.latest_messages(room_ctx, conversation_id, @rows) do
      case lines(rows) do
        [] -> {:error, :nothing_said}
        lines -> {:ok, header(room, conv) <> "\n" <> fit(lines)}
      end
    end
  end

  defp header(room, conv) do
    where =
      [room[:estate], room[:title] || conv.title]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" · ")

    ~s(Read from the room "#{where}" — for context only; nobody in this thread said it:)
  end

  # People's lines and the room's own assistant's — cards, system lines and
  # errors are the room's machinery, not what it said. Names are resolved
  # once per author.
  defp lines(rows) do
    {lines, _names} =
      Enum.flat_map_reduce(rows, %{}, fn
        %{kind: "text", content: content}, names when content in [nil, ""] ->
          {[], names}

        %{kind: "text", author: "aqua", content: content}, names ->
          {["AQUA: " <> String.trim(content)], names}

        %{kind: "text", author: author, content: content}, names when is_binary(author) ->
          {name, names} = name_of(names, author)
          {[name <> ": " <> String.trim(content)], names}

        _row, names ->
          {[], names}
      end)

    lines
  end

  defp name_of(names, user_id) do
    case names do
      %{^user_id => name} ->
        {name, names}

      _ ->
        name = Sanctum.Tenancy.Users.display_name(user_id)
        {name, Map.put(names, user_id, name)}
    end
  end

  # The newest lines that fit, oldest first. A single line past the bound
  # is cut rather than dropped, so the newest thing said always arrives.
  defp fit(lines) do
    lines
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn line, {acc, bytes} ->
      size = byte_size(line) + 1

      cond do
        bytes + size <= @max_bytes -> {:cont, {[line | acc], bytes + size}}
        acc == [] -> {:halt, {[cut(line, @max_bytes - 2)], @max_bytes}}
        true -> {:halt, {acc, bytes}}
      end
    end)
    |> elem(0)
    |> Enum.join("\n")
  end

  defp cut(text, max) when byte_size(text) <= max, do: text
  defp cut(text, max), do: whole(binary_part(text, 0, max)) <> "…"

  defp whole(bin),
    do: if(String.valid?(bin), do: bin, else: whole(binary_part(bin, 0, byte_size(bin) - 1)))
end
