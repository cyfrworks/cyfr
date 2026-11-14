# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.RoomExcerpt do
  @moduledoc """
  What a shared thread says, read for the person's own AQUA.

  The person has a shared thread open beside their own thread and asks
  their own assistant about it. That assistant is not in the shared
  thread — nothing runs there — so the excerpt is read here, under the
  person's own seat in it (`Sanctum.SharedThreads.tail/3`, which answers a
  thread they do not sit in as a missing one), and handed to the turn as
  context (`Aqua.Runner.send_message/4`'s `:room`): it rides the prompt
  of that one turn and is never a row of the private thread, never its
  history, never a note. Shared to private is the only direction;
  nothing here writes.

  Bounded: the newest lines that fit `max_bytes/0`, oldest first, headed
  by one line naming the thread, so the excerpt and the person's own
  message together stay inside the runner's message cap.

  The same text answers `threads.read` (`Aqua.Providers.Thread`), the
  person's AQUA reading a thread they sit in when a question needs it:
  there the lines the person has not seen are marked. What someone else
  wrote past the person's read mark is unread to them, and their own
  messages never are (`Sanctum.SharedThreads`), so the unread lines are
  exactly the newest `unread` lines someone else wrote. Reading moves no
  read mark.
  """

  alias Sanctum.Context
  alias Sanctum.SharedThreads

  @max_bytes 16 * 1024
  @rows 40

  @typedoc "Which shared thread, and how the person sees it named."
  @type room :: %{
          required(:shared_thread_id) => String.t(),
          optional(:title) => String.t() | nil
        }

  @doc """
  The thread's newest lines as one bounded text. `{:error, reason}` when the
  person holds no seat in the thread, or nobody has said anything there yet.
  `unread:` (default 0) is how many of the thread's messages are unread to
  the person; each of those lines is marked `(unread)`.
  """
  @spec read(Context.t(), room(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def read(ctx, room, opts \\ [])

  def read(%Context{user_id: user_id}, %{shared_thread_id: thread_id} = room, opts)
      when is_binary(user_id) and is_binary(thread_id) do
    unread = Keyword.get(opts, :unread, 0)

    with {:ok, thread} <- SharedThreads.get(user_id, thread_id),
         {:ok, messages} <- SharedThreads.tail(user_id, thread_id, @rows) do
      case lines(messages, unread_ids(messages, user_id, unread)) do
        [] -> {:error, :nothing_said}
        lines -> {:ok, header(room, thread, unread) <> "\n" <> fit(lines)}
      end
    end
  end

  def read(%Context{}, _room, _opts), do: {:error, :no_seat}

  defp header(room, thread, unread) do
    title = present(room[:title]) || present(thread.title) || pair_name(thread) || "a thread"

    said =
      ~s(Read from the shared thread "#{title}" — for context only; nobody in this thread said it)

    if unread > 0,
      do: said <> "; the lines marked (unread) the person has not seen yet:",
      else: said <> ":"
  end

  defp present(text) when is_binary(text) and text != "", do: text
  defp present(_text), do: nil

  defp pair_name(%{with: %{name: name}}), do: present(name)
  defp pair_name(_thread), do: nil

  # The ids of the messages here that are unread to the person: the newest
  # `unread` someone else wrote, all of them when the unread run back past
  # what was read.
  defp unread_ids(_messages, _user_id, unread) when unread <= 0, do: MapSet.new()

  defp unread_ids(messages, user_id, unread) do
    messages
    |> Enum.reject(&(&1.author == user_id))
    |> Enum.take(-unread)
    |> MapSet.new(& &1.id)
  end

  # What people said, each named once per author; a message with no words
  # (files alone) says nothing to read. A line the person has not seen is
  # marked unread.
  defp lines(messages, unread) do
    {lines, _names} =
      Enum.flat_map_reduce(messages, %{}, fn
        %{content: content}, names when content in [nil, ""] ->
          {[], names}

        %{author: author, content: content} = message, names when is_binary(author) ->
          {name, names} = name_of(names, author)
          {[mark(message, unread) <> name <> ": " <> String.trim(content)], names}

        _message, names ->
          {[], names}
      end)

    lines
  end

  defp mark(%{id: id}, unread), do: if(MapSet.member?(unread, id), do: "(unread) ", else: "")

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
        acc == [] -> {:halt, {[Aqua.Text.cut(line, @max_bytes - 3)], @max_bytes}}
        true -> {:halt, {acc, bytes}}
      end
    end)
    |> elem(0)
    |> Enum.join("\n")
  end
end
