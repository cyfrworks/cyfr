# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Reader do
  @moduledoc """
  The one reader of a thread's rows for a model: what an API request, a
  program's post and context, and a turn's reread of a thread say of each.

  `read/2` words one row and loads nothing: an opening expands only the
  `refs` it is handed. So a caller joins before it reads (`join/5`): the
  one rule (`Aqua.Tape.join_read/5`) says which rows are handed over and
  which posts those cite, as both now read, and records what they depend
  on.

  Only an API request has roles and calls to show what is the reading
  agent's own (`me`), so only there is a row its own or none. A program's
  context, a reread and a citation have neither (`me: :nobody`): each row
  there is said by who said it.

  A person's post of a turn that is over reads as not taken when no step
  carried it, or when the program it was handed to refused it
  (`Aqua.Tape.refused_posts/2`). A delivery that is uncertain is no
  refusal, since it may have been read.

  ## Frames

  What the athanor hands a model as its procedure, a scroll, and what an
  outside source returned each read inside a frame of the engine's: an
  opening line, `⟦<mark> scroll "<name>"⟧` (`scroll/2`) or `⟦<mark>
  outside <name>⟧` (`outside/3`), the text, then `⟦<mark> end⟧`. The mark
  is the thread's own (`mark/1`), derived from the server's secret, so it
  needs no stored state. Until a model is handed them, the frames and the
  rule that names them (`Aqua.Prompt`) are written with a stand-in no
  stored or outside text holds (`token/0`), and `deliver/2`, where what a
  model reads is assembled, is the one removal: every text in it is read
  without the thread's mark, then the stand-in becomes the mark. So only a
  frame or the rule the engine wrote holds the mark, whatever any input
  says. A reading that hands nothing to a model (`frames` nil, a reread
  that a tool's answer or a page holds) draws no frame at all. A changed
  server secret changes every mark.

  A job's scrolls are kept as they were read in the row that hands it, a
  request's or an opening's `scrolls`, and read after the job's words,
  each in its frame. A call's result row keeps its answer as it came and,
  for a scroll or an outside answer, the frame it reads in
  (`payload["frame"]`, `result/2`), so a shortened result keeps both of
  its frame's lines.
  """

  alias Aqua.{Attachments, Tape}
  alias Sanctum.Context

  @typedoc """
  Who reads (`me`: an agent by name, `:nobody` where nothing shows a
  reader's own, nil for a summary, to which every agent's words are the
  assistant's), the stand-in its frames are written with (`frames`:
  `token/0` where a model is handed what it reads, nil where nothing is),
  the turns still open (`open`), the posts whose delivery was refused, whether a person's
  name goes before their text, the cited posts handed over, the files
  deleted by row id, and how a person is named.
  """
  @type reading :: %{
          me: String.t() | :nobody | nil,
          frames: String.t() | nil,
          open: [String.t()],
          refused: [String.t()],
          named?: boolean(),
          refs: %{String.t() => Tape.row()},
          removed: %{String.t() => [map()]},
          display: (String.t() -> String.t())
        }

  @doc """
  Join what `turn` is about to read of `rows`, then answer the rows it
  may read, as they now read, and their reading, which holds the posts
  they cite: the turn's agent's for `:history`, its own thread's, and
  `:nobody`'s for a reread of the threads `read` names, both named.
  `most` bounds the rows answered.
  """
  @spec join(Context.t(), Tape.turn(), [Tape.row()], :history | [String.t()], pos_integer() | nil) ::
          {:ok, %{rows: [Tape.row()], reading: reading(), read_threads: [String.t()]}}
          | {:error, term()}
  def join(%Context{} = guest, turn, rows, read \\ :history, most \\ nil) when is_list(rows) do
    with {:ok, joined} <- Tape.join_read(guest, turn, read, rows, most),
         {:ok, refused} <- Tape.refused_posts(guest, joined.rows ++ joined.cited) do
      reading = %{
        me: if(read == :history, do: turn.agent, else: :nobody),
        frames: if(read == :history, do: token()),
        open: [turn.id | joined.open],
        refused: refused,
        named?: true,
        refs: Map.new(joined.cited, &{&1.id, &1}),
        removed: %{},
        display: &Sanctum.Tenancy.Users.display_name/1
      }

      {:ok, %{rows: joined.rows, reading: reading, read_threads: joined.read_threads}}
    end
  end

  @mark_key "cyfr-thread-mark|"
  @token_key "cyfr-frame-token|"

  @doc """
  The thread's mark, `cyfr-` and 16 base32 characters: HMAC-SHA256 of the
  thread's id under a key derived from the server's secret under a label
  of its own, as the at-rest keyring is
  (`Cyfr.Application.derive_keyring!/1`). The same thread has the same
  mark for as long as the secret stands, with nothing stored.
  """
  @spec mark(String.t()) :: String.t()
  def mark(thread_id) when is_binary(thread_id) do
    key = :crypto.hash(:sha256, @mark_key <> key_base())
    tag = :crypto.mac(:hmac, :sha256, key, thread_id) |> binary_part(0, 10)
    "cyfr-" <> Base.encode32(tag, padding: false)
  end

  @doc """
  The stand-in the engine writes its frames and the rule with until
  `deliver/2` makes each the mark: derived from the server's secret and
  this node's own start, so it differs at every boot and no stored or
  outside text can hold it. Nothing that holds it is stored or handed on
  but through `deliver/2`.
  """
  @spec token() :: String.t()
  def token do
    case :persistent_term.get({__MODULE__, :token}, nil) do
      nil ->
        boot = "#{node()}|#{System.pid()}|#{:erlang.system_info(:start_time)}"
        key = :crypto.hash(:sha256, @token_key <> key_base())
        tag = :crypto.mac(:hmac, :sha256, key, boot) |> binary_part(0, 15)
        token = "cyfr-frame-" <> Base.encode32(tag, padding: false)
        :persistent_term.put({__MODULE__, :token}, token)
        token

      token ->
        token
    end
  end

  defp key_base, do: Application.fetch_env!(:sanctum, :secret_key_base)

  @doc """
  What a model is handed of `term`, the thread's mark being `mark`: every
  text in it, a map's keys among them, read without the mark, removed
  until none is left, then the stand-in the engine's frames and rule are
  written with (`token/0`) made the mark. The one removal: where the
  engine assembles what a model reads, a request or a program's line, it
  hands `deliver/2`'s answer and writes nothing after it.
  """
  @spec deliver(term(), String.t()) :: term()
  def deliver(term, mark) when is_binary(mark) and mark != "",
    do: delivered(term, mark, token())

  defp delivered(text, mark, token) when is_binary(text),
    do: text |> unmarked(mark) |> String.replace(token, mark)

  defp delivered(values, mark, token) when is_list(values),
    do: Enum.map(values, &delivered(&1, mark, token))

  defp delivered(%{} = values, mark, token) when not is_struct(values),
    do:
      Map.new(values, fn {key, value} ->
        {delivered(key, mark, token), delivered(value, mark, token)}
      end)

  defp delivered(value, _mark, _token), do: value

  @doc """
  `text` without `mark`, removed until none is left, so no removal joins
  the text around it into the mark again.
  """
  @spec unmarked(String.t() | nil, String.t()) :: String.t()
  def unmarked(nil, _mark), do: ""

  def unmarked(text, mark) when is_binary(text) and is_binary(mark) and mark != "" do
    if String.contains?(text, mark),
      do: unmarked(String.replace(text, mark, ""), mark),
      else: text
  end

  @doc """
  A scroll as `frames` reads it: in its frame, written with the stand-in
  (`token/0`), its body as written and then its other files' names; or,
  where nothing is handed to a model (nil), the same words under a plain
  heading and no frame. A scroll a job carries and a scroll a turn reads
  (`aqua.skill_get`) read alike.
  """
  @spec scroll(String.t() | nil, %{name: String.t(), body: String.t(), files: [String.t()]}) ::
          String.t()
  def scroll(frames, %{name: name, body: body, files: files}) do
    files =
      case files do
        [] -> ""
        names -> "\n\n[The scroll's files: " <> Enum.join(names, ", ") <> "]"
      end

    case frames do
      nil -> "[The scroll \"#{name}\"]\n" <> body <> files
      token -> "⟦#{token} scroll \"#{name}\"⟧\n" <> body <> files <> "\n⟦#{token} end⟧"
    end
  end

  @doc """
  What an outside source returned to the call named `name`, as `frames`
  reads it: in its frame, or, where nothing is handed to a model (nil),
  as it came.
  """
  @spec outside(String.t() | nil, String.t(), String.t()) :: String.t()
  def outside(nil, _name, text), do: text
  def outside(token, name, text), do: "⟦#{token} outside #{name}⟧\n" <> text <> "\n⟦#{token} end⟧"

  @doc """
  A call's result row as `frames` reads it: its answer as it came, in the
  frame its row keeps for a scroll or an outside answer
  (`payload["frame"]`), else as it is.
  """
  @spec result(Tape.row(), String.t() | nil) :: String.t()
  def result(row, frames) do
    text = row.content || ""

    case Tape.payload(row)["frame"] do
      %{"kind" => "scroll", "name" => name} = frame ->
        scroll(frames, %{name: name, body: text, files: List.wrap(frame["files"])})

      %{"kind" => "outside", "name" => name} ->
        outside(frames, name, text)

      _unframed ->
        text
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

  @doc """
  A call's result whose answer comes too late to be one, as a message of
  its own, its answer as `frames` reads it (`result/2`).
  """
  @spec late_answer(Tape.row(), String.t() | nil) :: String.t()
  def late_answer(row, frames) do
    payload = Tape.payload(row)

    "Your work was interrupted before your call #{payload["name"]} " <>
      "(#{payload["tool_call_id"]}) was answered, so its answer comes as this message " <>
      "instead. It answered" <>
      if(payload["is_error"], do: " with an error: ", else: ": ") <> result(row, frames)
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
  # A call's result, in the frame its row keeps.
  def read(%{kind: "tool_result"} = row, %{me: :nobody} = reading),
    do:
      {:said, "Your call #{Tape.payload(row)["name"]} answered: " <> result(row, frames(reading))}

  # Any other row's words, then the scrolls the job it hands carries, each
  # in its frame.
  def read(row, reading) do
    case words(row, reading) do
      {:said, text} -> {:said, text <> attached(row, frames(reading))}
      own_or_none -> own_or_none
    end
  end

  defp frames(reading), do: Map.get(reading, :frames)

  defp words(%{kind: "opening"} = row, reading), do: {:said, opening_text(row, reading)}
  defp words(%{kind: "pointer"} = row, _reading), do: {:said, pointer_text(row)}
  defp words(%{kind: "report"} = row, _reading), do: {:said, report_text(row)}
  defp words(%{kind: "nudge"} = row, _reading), do: {:said, server_text(row)}

  # A stop, a take-over, a restart and an unknown outcome each leave one;
  # what is true of them all is said, then the row's own words of its cause.
  defp words(%{kind: "turn_aborted"} = row, _reading) do
    {:said,
     "[The assistant's work here was interrupted before it finished; tools may have partially " <>
       "executed. " <> (row.content || "") <> "]"}
  end

  defp words(%{kind: "text"} = row, %{me: me} = reading) do
    cond do
      # The reader's own post is its call's to show (`thread.post`).
      posted?(row) and own?(row, me) -> :none
      is_binary(Map.get(row, :reply_to)) -> {:said, reply_text(row)}
      Arca.ThreadStorage.request?(row) and own?(row, me) -> :none
      Arca.ThreadStorage.request?(row) -> {:said, request_text(row, reading)}
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

  defp words(%{kind: kind} = row, %{me: :nobody}) when kind in ~w(error system),
    do: {:said, server_text(row)}

  defp words(%{}, _reading), do: :none

  # The scrolls a job carries, kept in the row that hands it: an opening,
  # a request, and the request's copy delivered into its member's thread.
  # Its asker never reads its own request (`words/2` answers none).
  defp attached(row, frames), do: scrolls(List.wrap(Tape.payload(row)["scrolls"]), frames)

  @doc """
  A job's scrolls, each `%{"name", "body", "files"}` as the row that hands
  it keeps them, as `frames` reads them after the job's words: each after
  a blank line, in its frame (`scroll/2`). What a job's bound is measured
  on (`Aqua.Crew.scrolls/3`).
  """
  @spec scrolls([map()], String.t() | nil) :: String.t()
  def scrolls(scrolls, frames) when is_list(scrolls) do
    for %{"name" => name, "body" => body} = scroll <- scrolls, into: "" do
      "\n\n" <> scroll(frames, %{name: name, body: body, files: List.wrap(scroll["files"])})
    end
  end

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

    case words(cited, %{reading | me: :nobody, named?: false, refs: %{}}) do
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

  defp sender(row, reading) do
    cond do
      # A line in the server's voice, whoever's turn wrote it.
      server?(row) -> "the server"
      agent?(row) -> row.sent_by
      true -> reading.display.(row.author)
    end
  end

  defp request_text(row, reading) do
    asker = if row.sent_by == "person", do: reading.display.(row.author), else: row.sent_by

    "[#{asker} asked #{row.addressee} (request #{row.id}, #{row.status})]\n#{row.content}"
  end

  defp agent_text(row), do: "[#{row.sent_by}]\n#{row.content}"

  defp reply_text(row),
    do: "[#{row.sent_by} replied to request #{row.reply_to}: #{row.outcome}]\n#{row.content}"

  defp untaken_text(row, reading) do
    "[#{reading.display.(row.author)} posted this and it was not taken: its turn ended " <>
      "before any model read it. Act on it only if they ask again]\n" <> spoken(row, reading)
  end

  defp person_text(row, reading) do
    case Aqua.Choices.pressed(row) do
      %{} = pressed -> pressed_text(pressed, row, reading)
      nil when reading.named? == true -> "#{reading.display.(row.author)}: #{row.content}"
      nil -> row.content || ""
    end
  end

  defp spoken(row, reading) do
    case Aqua.Choices.pressed(row) do
      %{} = pressed -> pressed_text(pressed, row, reading)
      nil -> row.content || ""
    end
  end

  # A press of a choice on Aqua's own question (`Aqua.Choices.press/2`),
  # in the words its row carried when it was pressed, set between « and »,
  # which neither holds (`Aqua.Choices.parse/1`).
  defp pressed_text(%{"question" => question, "label" => label}, row, reading) do
    who = if reading.named? == true, do: reading.display.(row.author), else: "The person"
    whose = if Prima.AgentRef.soul?(reading.me), do: "your", else: "Aqua's"

    "[#{who} pressed a choice on #{whose} question. The question: «#{question}». The " <>
      "choice: «#{label}». A press selects that option and asks nothing beyond it.]"
  end

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
