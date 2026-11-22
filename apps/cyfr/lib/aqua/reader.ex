# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Reader do
  @moduledoc """
  The one reader of a thread's rows for a model: what an API request, a
  program's post and context, and a turn's reread of a thread say of each.

  `read/2` words one row as the reading agent's own, as said to it, or as
  none, and loads nothing: an opening expands only the `refs` it is
  handed. So a caller joins before it reads (`join/4`): the rows and the
  posts their openings cite (`sources/2`) join the turn's read threads
  under its fence, and only those it may still read are handed over
  (`Aqua.Tape.join_sources/4`).

  A person's post of a turn that is over reads as not taken when no step
  carried it, or when the program it was handed to refused it
  (`Aqua.Tape.refused_posts/2`). A delivery that is uncertain is no
  refusal, since it may have been read.
  """

  alias Aqua.{Attachments, Tape}
  alias Sanctum.Context

  @typedoc """
  Who reads (`me`), the turns still open (`open`), the posts whose
  delivery was refused, whether a person's name goes before their text,
  the cited posts handed over, the files deleted by row id, and how a
  person is named.
  """
  @type reading :: %{
          me: String.t() | nil,
          open: [String.t()],
          refused: [String.t()],
          named?: boolean(),
          refs: %{String.t() => Tape.row()},
          removed: %{String.t() => [map()]},
          display: (String.t() -> String.t())
        }

  @doc """
  `rows` and the posts their openings cite, as those read now: a citation
  that is no post of the opening's daily thread, or one deleted since, is
  none.
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
          do: row

    Enum.uniq_by(rows ++ cited, & &1.id)
  end

  @doc """
  Join what `turn` is about to read of `rows` (`sources/2`), then answer
  the rows it may read and their reading as the turn's agent's, named.
  `read` names the threads the turn asked to read (`thread.events`).
  """
  @spec join(Context.t(), Tape.turn(), [Tape.row()], [String.t()]) ::
          {:ok, %{rows: [Tape.row()], reading: reading(), read_threads: [String.t()]}}
          | {:error, term()}
  def join(%Context{} = guest, turn, rows, read \\ []) when is_list(rows) do
    with {:ok, joined} <- Tape.join_sources(guest, turn, sources(guest, rows), read),
         {:ok, refused} <- Tape.refused_posts(guest, rows) do
      asked = MapSet.new(rows, & &1.id)
      {kept, cited} = Enum.split_with(joined.rows, &MapSet.member?(asked, &1.id))

      reading = %{
        me: turn.agent,
        open: [turn.id],
        refused: refused,
        named?: true,
        refs: Map.new(cited, &{&1.id, &1}),
        removed: %{},
        display: &Sanctum.Tenancy.Users.display_name/1
      }

      {:ok, %{rows: kept, reading: reading, read_threads: joined.read_threads}}
    end
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
  One row as `reading` reads it. The reader's own request and its own
  post are none, as their calls show them; so is every row that is no
  model's to read, and a call and its result, which are not words.
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
      agent?(row) -> {:said, "[#{row.sent_by}]\n#{row.content}"}
      untaken?(row, reading) -> {:said, untaken_text(row, reading)}
      true -> {:said, person_text(row, reading)}
    end
  end

  def read(%{}, _reading), do: :none

  # The reading agent's own speech: a row it sent. A row written before
  # rows named their sender is read by its author.
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
      for id <- List.wrap(payload["refs"]), %{} = cited <- [reading.refs[id]] do
        "\n\n[Post #{cited.id} of the daily thread, by #{sender(cited, reading)}]\n#{cited.content}"
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

  defp reply_text(row),
    do: "[#{row.sent_by} replied to request #{row.reply_to}: #{row.outcome}]\n#{row.content}"

  defp untaken_text(row, reading) do
    "[#{reading.display.(row.author)} posted this and it was not taken: its turn ended " <>
      "before any model read it. Act on it only if they ask again]\n#{row.content}"
  end

  defp person_text(row, %{named?: true} = reading),
    do: "#{reading.display.(row.author)}: #{row.content}"

  defp person_text(row, _reading), do: row.content || ""
end
