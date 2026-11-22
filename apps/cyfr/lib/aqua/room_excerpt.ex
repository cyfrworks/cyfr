# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.RoomExcerpt do
  @moduledoc """
  What a shared thread says, read for the person's own Aqua.

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
  person's Aqua reading a thread they sit in when a question needs it
  (`read_marked/2`): there each message the person has not seen is marked,
  a message of files alone is named as one, and the answer counts them.
  The mark, the count and the lines come from one read
  (`Sanctum.SharedThreads.tail/3`): what someone else wrote past the
  person's read mark is unread, and their own messages never are.
  Reading moves no read mark. Unlike the excerpt, that answer is the
  call's result, kept as a row of the person's own thread as every
  call's result is (`Arca.TurnStorage.close_step/4`).
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
  """
  @spec read(Context.t(), room()) :: {:ok, String.t()} | {:error, term()}
  def read(%Context{user_id: user_id}, %{shared_thread_id: thread_id} = room)
      when is_binary(user_id) and is_binary(thread_id) do
    with {:ok, thread} <- SharedThreads.get(user_id, thread_id),
         {:ok, %{messages: messages}} <- SharedThreads.tail(user_id, thread_id, @rows) do
      case lines(messages, user_id, nil) do
        [] -> {:error, :nothing_said}
        lines -> {:ok, header(room, thread, 0) <> "\n" <> fit(lines)}
      end
    end
  end

  def read(%Context{}, _room), do: {:error, :no_seat}

  @doc """
  The thread's newest lines with those the person has not seen marked
  `(unread)`, and how many of the thread's messages are unread to them,
  those older than the lines included: `%{text, unread}`, the text empty
  when nobody has said anything there. `{:error, reason}` when the person
  holds no seat in the thread.
  """
  @spec read_marked(Context.t(), room()) ::
          {:ok, %{text: String.t(), unread: non_neg_integer()}} | {:error, term()}
  def read_marked(%Context{user_id: user_id}, %{shared_thread_id: thread_id} = room)
      when is_binary(user_id) and is_binary(thread_id) do
    with {:ok, thread} <- SharedThreads.get(user_id, thread_id),
         {:ok, %{read_seq: mark, unread: unread, messages: messages}} <-
           SharedThreads.tail(user_id, thread_id, @rows) do
      case lines(messages, user_id, mark) do
        [] ->
          {:ok, %{text: "", unread: unread}}

        lines ->
          {:ok, %{text: header(room, thread, unread) <> "\n" <> fit(lines), unread: unread}}
      end
    end
  end

  def read_marked(%Context{}, _room), do: {:error, :no_seat}

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

  defp unread?(%{author: author, seq: seq}, user_id, mark),
    do: is_integer(mark) and seq > mark and author != user_id

  # What people said, each named once per author. With a read mark (`mark`
  # an integer) each message past it that someone else wrote is marked
  # unread, and a message of files alone is named as one; without, a
  # message with no words says nothing to read.
  defp lines(messages, user_id, mark) do
    {lines, _names} =
      Enum.flat_map_reduce(messages, %{}, fn
        %{author: author} = message, names when is_binary(author) ->
          case said(message, mark) do
            nil ->
              {[], names}

            said ->
              {name, names} = name_of(names, author)
              {[mark(message, user_id, mark) <> name <> ": " <> said], names}
          end

        _message, names ->
          {[], names}
      end)

    lines
  end

  defp said(%{content: content}, mark) when content in [nil, ""],
    do: if(is_integer(mark), do: "(sent files, with no words)")

  defp said(%{content: content}, _mark), do: String.trim(content)

  defp mark(message, user_id, mark),
    do: if(unread?(message, user_id, mark), do: "(unread) ", else: "")

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
