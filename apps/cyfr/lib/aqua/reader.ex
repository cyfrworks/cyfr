# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Reader do
  @moduledoc """
  The one reader of a thread's rows for a model: what an API request, a
  program's post and context, and a turn's reread of a thread say of each.

  `read/2` words one row and loads nothing: an opening expands only the
  `refs` it is handed. So a caller joins before it reads (`join/4`): the
  rows and the posts their openings cite (`sources/2`) go through the one
  rule of what is handed over and what joins (`Aqua.Tape.join_read/4`).

  Only an API request has roles and calls to show what is the reading
  agent's own (`me`), so only there is a row its own or none. A program's
  context, a reread and a citation have neither (`me: :nobody`): each row
  there is said by who said it.

  A person's post of a turn that is over reads as not taken when no step
  carried it, or when the program it was handed to refused it
  (`Aqua.Tape.refused_posts/2`). A delivery that is uncertain is no
  refusal, since it may have been read.
  """

  alias Aqua.{Attachments, Tape}
  alias Sanctum.Context

  @typedoc """
  Who reads (`me`: an agent by name, `:nobody` where nothing shows a
  reader's own, nil for a summary, to which every agent's words are the
  assistant's), the turns still open (`open`), the posts whose
  delivery was refused, whether a person's name goes before their text,
  the cited posts handed over, the files deleted by row id, and how a
  person is named.
  """
  @type reading :: %{
          me: String.t() | :nobody | nil,
          open: [String.t()],
          refused: [String.t()],
          named?: boolean(),
          refs: %{String.t() => Tape.row()},
          removed: %{String.t() => [map()]},
          display: (String.t() -> String.t())
        }

  @doc """
  `rows` and the posts their openings cite: a citation is a post a model
  reads (no call, result or note) of the opening's daily thread, and one
  deleted since is none.
  """
  @spec sources(Context.t(), [Tape.row()]) :: [Tape.row()]
  def sources(%Context{} = guest, rows) when is_list(rows) do
    cited =
      for %{kind: "opening"} = opening <- rows,
          %{"from" => %{"thread" => daily}, "refs" => ids} when is_list(ids) <-
            [Tape.payload(opening)],
          id <- ids,
          is_binary(id),
          {:ok, %{thread_id: ^daily} = row} <- [Tape.message(guest, id)],
          citable?(row),
          do: row

    Enum.uniq_by(rows ++ cited, & &1.id)
  end

  defp citable?(row),
    do: Arca.ThreadStorage.post?(row) and row.kind not in ~w(error system)

  @doc """
  Join what `turn` is about to read of `rows` (`sources/2`), then answer
  the rows it may read, as they now read, and their reading: the turn's
  agent's for `:history`, its own thread's, and `:nobody`'s for a reread
  of the threads `read` names, both named.
  """
  @spec join(Context.t(), Tape.turn(), [Tape.row()], :history | [String.t()]) ::
          {:ok, %{rows: [Tape.row()], reading: reading(), read_threads: [String.t()]}}
          | {:error, term()}
  def join(%Context{} = guest, turn, rows, read \\ :history) when is_list(rows) do
    sources = sources(guest, rows)
    asked = MapSet.new(rows, & &1.id)
    {me, threads} = if read == :history, do: {turn.agent, []}, else: {:nobody, read}
    cited_in = for row <- sources, row.id not in asked, do: row.thread_id

    # The open turns are read before the rows are read again: a post's
    # carry is then never older than the turn's end it is judged by.
    with {:ok, open} <- open(guest, turn, Enum.uniq(threads ++ cited_in)),
         {:ok, joined} <- Tape.join_read(guest, turn, read, sources),
         {:ok, refused} <- Tape.refused_posts(guest, joined.rows) do
      {handed, cited} = Enum.split_with(joined.rows, &(&1.id in asked))

      reading = %{
        me: me,
        open: open,
        refused: refused,
        named?: true,
        refs: Map.new(cited, &{&1.id, &1}),
        removed: %{},
        display: &Sanctum.Tenancy.Users.display_name/1
      }

      {:ok, %{rows: handed, reading: reading, read_threads: joined.read_threads}}
    end
  end

  # The reading turn, and the open turns of the threads it reads besides
  # its own history: whose posts may still be taken.
  defp open(guest, turn, threads) do
    Enum.reduce_while(threads, {:ok, [turn.id]}, fn thread, {:ok, open} ->
      case Tape.open_turns(guest, thread) do
        {:ok, turns} -> {:cont, {:ok, open ++ Enum.map(turns, & &1.id)}}
        {:error, _unread} = unread -> {:halt, unread}
      end
    end)
  end

  @doc """
  By row id, the refs of each row's files the person deleted from Files
  (`Aqua.Attachments.as_kept/2`): one listing per row that holds files.
  """
  @spec removed(Context.t(), [Tape.row()]) :: %{String.t() => [map()]}
  def removed(%Context{} = ctx, rows) when is_list(rows) do
    for row <- rows,
        Attachments.refs_of(row) != [],
        removed = Enum.filter(Attachments.as_kept(ctx, row), &(&1["removed"] == true)),
        removed != [],
        into: %{},
        do: {row.id, removed}
  end

  @doc "The line that names deleted files, by their refs."
  @spec removed_note([map()]) :: String.t()
  def removed_note(refs) when is_list(refs) do
    "[The person deleted these files of posts in this thread; they can no longer " <>
      "be read: #{Enum.map_join(refs, ", ", & &1["filename"])}]"
  end

  @doc "A request still waiting on its reply, once a compaction summarized its call away."
  @spec waiting(Tape.row()) :: String.t()
  def waiting(row),
    do: "[Request #{row.id} to #{row.addressee}, still waiting on its reply]\n#{row.content}"

  @doc """
  A compaction's summary, standing in for the rows before its boundary:
  in a request, and before the rows the next summary folds.
  """
  @spec summary(String.t() | nil) :: String.t()
  def summary(text), do: "[Summary of the thread so far]\n" <> (text || "")

  @doc "A workspace thread's first ask, as the prompt quotes it."
  @spec asked(String.t()) :: String.t()
  def asked(ask) do
    quoted = ask |> String.trim() |> String.split("\n") |> Enum.map_join("\n", &("> " <> &1))
    "They asked:\n\n" <> quoted
  end

  @doc "A request still waiting on its reply, as the prompt lists it at `now`."
  @spec open_request(Tape.row(), DateTime.t()) :: String.t()
  def open_request(row, now) do
    asker = if row.sent_by == "person", do: "the person", else: row.sent_by

    "#{row.id} to #{row.addressee}, asked by #{asker} #{age(row.inserted_at, now)} ago: " <>
      first_line(row.content)
  end

  @doc "A call's result whose answer comes too late to be one, as a message of its own."
  @spec late_answer(Tape.row()) :: String.t()
  def late_answer(row) do
    payload = Tape.payload(row)

    "Your work was interrupted before your call #{payload["name"]} " <>
      "(#{payload["tool_call_id"]}) was answered, so its answer comes as this message " <>
      "instead. It answered" <>
      if(payload["is_error"], do: " with an error: ", else: ": ") <>
      (row.content || "")
  end

  @doc """
  One row as `reading` reads it. Where the caller has roles and calls to
  show them, the reader's speech is its own, and its request and its post
  are none, as their calls show them, as is every row that is no model's
  to read. Read as `:nobody`, none of these is its own: each post is said
  by who said it, the server's notes among them, and a call's result as
  its answer.
  """
  @spec read(Tape.row(), reading()) :: {:own, String.t()} | {:said, String.t()} | :none
  def read(%{kind: "opening"} = row, reading), do: {:said, opening_text(row, reading)}
  def read(%{kind: "pointer"} = row, _reading), do: {:said, pointer_text(row)}
  def read(%{kind: "report"} = row, _reading), do: {:said, report_text(row)}
  def read(%{kind: "nudge"} = row, _reading), do: {:said, server_text(row)}

  def read(%{kind: "turn_aborted"} = row, _reading) do
    {:said,
     "[The server restarted while the assistant was working; tools may have partially executed. " <>
       (row.content || "") <> "]"}
  end

  def read(%{kind: "text"} = row, %{me: me} = reading) do
    cond do
      # The reader's own post is its call's to show (`thread.post`).
      posted?(row) and own?(row, me) -> :none
      is_binary(Map.get(row, :reply_to)) -> {:said, reply_text(row)}
      request?(row) and own?(row, me) -> :none
      request?(row) -> {:said, request_text(row, reading)}
      # Before the reader's own speech: a line in the server's voice, a
      # schedule's or the server's own post, which a reading that names no
      # reader reads as its own.
      server?(row) -> {:said, server_text(row)}
      own?(row, me) -> {:own, row.content || ""}
      agent?(row) -> {:said, agent_text(row)}
      untaken?(row, reading) -> {:said, untaken_text(row, reading)}
      true -> {:said, person_text(row, reading)}
    end
  end

  def read(%{kind: kind} = row, %{me: :nobody}) when kind in ~w(error system),
    do: {:said, server_text(row)}

  def read(%{kind: "tool_result"} = row, %{me: :nobody}),
    do: {:said, "Your call #{Tape.payload(row)["name"]} answered: #{row.content}"}

  def read(%{}, _reading), do: :none

  # The reading agent's own speech: a row it sent. A row written before
  # rows named their sender is read by its author.
  defp own?(_row, :nobody), do: false
  defp own?(%{sent_by: sent_by}, me) when is_binary(sent_by) and is_binary(me), do: sent_by == me
  defp own?(row, _me), do: row.author in Prima.Author.reserved()

  defp agent?(%{sent_by: sent_by}), do: is_binary(sent_by) and sent_by != "person"
  defp agent?(_row), do: false

  # A line in the server's voice: written by the server, never by the
  # person or an agent.
  defp server?(%{author: author}), do: author == Prima.Author.system()
  defp server?(_row), do: false

  defp request?(row),
    do: is_binary(Map.get(row, :addressee)) and Map.get(row, :status) in ["pending", "answered"]

  defp posted?(row), do: Tape.payload(row)["post"] == true

  defp untaken?(%{turn_id: turn_id} = row, reading) when is_binary(turn_id) do
    turn_id not in reading.open and
      (is_nil(Map.get(row, :carried_by)) or row.id in reading.refused)
  end

  defp untaken?(_row, _reading), do: false

  # A schedule's line, which its fire wrote for the person, names the
  # schedule (`Aqua.ScheduleTurns`); any other line of the server's is its
  # own (`Aqua.Nudge`).
  defp server_text(row) do
    case Tape.payload(row)["schedule"] do
      %{"id" => id, "name" => name} when is_binary(id) and is_binary(name) ->
        "[The schedule \"#{name}\" (#{id}) fired with its line]\n#{row.content}"

      _own ->
        "[A line from the server, not the person]\n" <> (row.content || "")
    end
  end

  # A workspace thread's opening: the ask, attributed to the person who
  # asked, then each daily-thread post it refers to as that post reads
  # now, then the files it carries, which ride as blocks on the turn it
  # opened.
  defp opening_text(row, reading) do
    payload = Tape.payload(row)
    title = payload["title"] || ""
    asker = reading.display.(payload["asked_by"] || row.author)

    refs =
      for id <- List.wrap(payload["refs"]),
          %{} = cited <- [reading.refs[id]],
          {:said, text} <- [quoted(cited, reading)] do
        "\n\n[Post #{cited.id} of the daily thread, by #{sender(cited, reading)}]\n#{text}"
      end

    gone = for ref <- Map.get(reading.removed, row.id, []), do: ref["stored_name"]

    files =
      case Enum.reject(Attachments.refs_of(row), &(&1["stored_name"] in gone)) do
        [] -> ""
        refs -> "\n\n[Files carried in: #{Enum.map_join(refs, ", ", & &1["filename"])}]"
      end

    "[#{asker} asked, in this workspace thread \"#{title}\" (#{row.thread_id})]\n" <>
      (row.content || "") <> Enum.join(refs) <> files
  end

  # A cited post in the words it reads in by itself, which keep a warning
  # it has. The line above it names who sent it, so an agent's words do
  # not name them again.
  defp quoted(cited, reading) do
    named_by_agent = agent_text(cited)

    case read(cited, %{reading | me: :nobody, named?: false, refs: %{}}) do
      {:said, ^named_by_agent} -> {:said, cited.content}
      said_or_none -> said_or_none
    end
  end

  # A pointer: one line naming the workspace thread and its title.
  defp pointer_text(row) do
    payload = Tape.payload(row)

    "[The workspace thread \"#{payload["title"] || ""}\" (#{row.workspace_id}) was opened or asked again from here]"
  end

  # A report: one block naming the workspace thread, its outcome and
  # its summary.
  defp report_text(row) do
    payload = Tape.payload(row)

    "[Report from the workspace thread \"#{payload["title"] || ""}\" (#{row.workspace_id}): " <>
      "#{reported(payload)}]\n" <> (row.content || "")
  end

  # The outcome as the reading model is told it: Aqua's `done` or
  # `needs_you`, or the server's `error`.
  defp reported(%{"outcome" => "needs_you"}), do: "needs the person"
  defp reported(%{"outcome" => "error"}), do: "error, Aqua could not run it"
  defp reported(_payload), do: "done"

  defp sender(%{sent_by: "person"} = row, reading), do: reading.display.(row.author)
  defp sender(%{sent_by: sent_by}, _reading) when is_binary(sent_by), do: sent_by
  defp sender(row, reading), do: reading.display.(row.author)

  defp request_text(row, reading) do
    asker = if row.sent_by == "person", do: reading.display.(row.author), else: row.sent_by

    "[#{asker} asked #{row.addressee} (request #{row.id}, #{row.status})]\n#{row.content}"
  end

  defp agent_text(row), do: "[#{row.sent_by}]\n#{row.content}"

  defp reply_text(row),
    do: "[#{row.sent_by} replied to request #{row.reply_to}: #{row.outcome}]\n#{row.content}"

  defp untaken_text(row, reading) do
    "[#{reading.display.(row.author)} posted this and it was not taken: its turn ended " <>
      "before any model read it. Act on it only if they ask again]\n#{row.content}"
  end

  defp person_text(row, %{named?: true} = reading),
    do: "#{reading.display.(row.author)}: #{row.content}"

  defp person_text(row, _reading), do: row.content || ""

  defp age(%DateTime{} = at, now) do
    seconds = max(DateTime.diff(now, at, :second), 0)

    cond do
      seconds < 120 -> "#{seconds}s"
      seconds < 7_200 -> "#{div(seconds, 60)}m"
      seconds < 172_800 -> "#{div(seconds, 3_600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  defp age(_at, _now), do: "a while"

  defp first_line(content) do
    line = (content || "") |> String.trim() |> String.split("\n", parts: 2) |> hd()
    if String.length(line) > 160, do: String.slice(line, 0, 160) <> "…", else: line
  end
end
