# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Choices do
  @moduledoc """
  A question's choices as buttons: the one grammar of a choices block,
  which rows give buttons, whether a card is still open, and a press.

  ## The block

  A reply's own text, trimmed as admission trims a line, may end with

      ```choices <turn id>
      Which database should the export target?
      - PostgreSQL
      - SQLite
      file: data/aqua/plans/<turn id>-1-export.md
      ```

  The tag is the id of the turn that asks, which its facts name. Then the
  question, 1 to 200 characters; 1 to 8 choices, each `- <label>`
  with a label of 1 to 100 characters, all different; at most one
  `file: <path>` line, a Files path of at most 512 bytes; and the
  closing fence. The whole block is at most 4096 bytes of UTF-8 and holds
  no control or format character but its line feeds. Anything else is
  text, shown as it is.

  ## Which rows give buttons

  Only the final reply row of the turn the tag names, written by that
  turn's own brain (`Arca.TurnStorage`'s `said!`, whose payload names
  the model step or the native message, never `thread.post`'s `post`):

  - **Aqua's own:** the last text row its agent wrote in the completed
    soul turn the tag names, in the thread that turn ran in.
  - **A member's:** the room's reply row whose `from_turn` is the tag's
    turn, delivered with outcome `done` and not cut (`truncated`), whose
    text is that completed turn's last own text row as its brain wrote it.

  Never an intermediate message, a post a tool wrote, a failed reply, a
  person's message, a tool or page result, a file, an earlier turn's
  block, or a copy in another turn's reply. A tag shows which row a block
  belongs to, not who first wrote its bytes: a brain that ends its own
  final reply with a sample block carrying its own turn's id offers those
  choices as its own.

  ## Open and closed

  A card is open until a press names it, or until the brain that asked
  has moved on: a later turn in its thread for Aqua's, a later request to
  that member in its room for a member's. A card in a past day's daily
  thread is closed. Each card closes by its own asker alone.

  ## A press

  `press/3` re-reads the row a press names, by the rules above, under the
  presser's own context, and answers what the press row carries: the row,
  the index, and the question, the label and the asker as the row reads
  now. Nothing but the row and the index comes from the presser.
  """

  alias Aqua.Tape
  alias Sanctum.Context

  @question_max 200
  @choices_max 8
  @label_max 100
  @path_max 512
  @block_max 4096
  @page 500

  @fence "```"
  @opener "```choices "

  @typedoc "A choices block as the grammar reads it, with the text before it."
  @type block :: %{
          tag: String.t(),
          question: String.t(),
          choices: [String.t(), ...],
          file: String.t() | nil,
          prose: String.t()
        }

  @typedoc """
  A card as the pane draws it: the reply's text before the block, the
  question, its choices, who asked, whether it may still be pressed, and
  its `file:` line as Files holds it now (nil without one).
  """
  @type card :: %{
          row: String.t(),
          prose: String.t(),
          question: String.t(),
          choices: [String.t(), ...],
          asker: String.t(),
          open?: boolean(),
          file: String.t() | nil,
          file_state: :present | :missing | :unavailable | nil
        }

  @typedoc "What a press row carries in its payload's `choice`."
  @type pressed :: %{String.t() => String.t() | non_neg_integer()}

  @doc """
  The choices block `content` ends with, as the grammar reads it after
  the trim admission applies, or `:none`.
  """
  @spec parse(String.t() | nil) :: {:ok, block()} | :none
  def parse(content) when is_binary(content) do
    text = String.trim(content)

    with {:ok, at} <- last_opener(text),
         block = binary_part(text, at, byte_size(text) - at),
         true <- byte_size(block) <= @block_max and String.valid?(block),
         false <- String.replace(block, "\n", "") =~ ~r/[\p{Cc}\p{Cf}]/u,
         [@opener <> tag | body] <- String.split(block, "\n"),
         true <- tag =~ ~r/\A[A-Za-z0-9_-]+\z/,
         {[question | lines], [@fence]} <- Enum.split(body, -1),
         {:ok, question} <- question(question),
         {:ok, choices, file} <- lines(lines, []) do
      prose = text |> binary_part(0, at) |> String.trim()
      {:ok, %{tag: tag, question: question, choices: choices, file: file, prose: prose}}
    else
      _ -> :none
    end
  end

  def parse(_content), do: :none

  # The last line that opens a block: at the text's start or after a
  # line feed.
  defp last_opener(text) do
    text
    |> :binary.matches(@opener)
    |> Enum.filter(fn {at, _} -> at == 0 or :binary.at(text, at - 1) == ?\n end)
    |> List.last()
    |> case do
      {at, _} -> {:ok, at}
      nil -> :none
    end
  end

  defp question(line) do
    question = String.trim(line)

    if bounded?(question, @question_max) and not String.starts_with?(question, ["- ", "file:"]),
      do: {:ok, question},
      else: :none
  end

  defp lines(["- " <> label | rest], choices) do
    label = String.trim(label)

    if bounded?(label, @label_max) and label not in choices,
      do: lines(rest, choices ++ [label]),
      else: :none
  end

  defp lines(["file:" <> path], choices) do
    path = String.trim(path)
    if path != "" and byte_size(path) <= @path_max, do: done(choices, path), else: :none
  end

  defp lines([], choices), do: done(choices, nil)
  defp lines(_other, _choices), do: :none

  defp done(choices, file) when choices != [] and length(choices) <= @choices_max,
    do: {:ok, choices, file}

  defp done(_choices, _file), do: :none

  defp bounded?(text, most), do: text != "" and String.length(text) <= most

  @doc """
  The card `row` shows under `ctx`, the person's own context: `{:ok,
  card}` for the final reply row of the turn its block names, written by
  that turn's own brain; `:pending` for a row of Aqua's turn that is still
  open, which may yet be its final reply; `:none` for any other row,
  which shows as the text it is. A row that cannot be read now is
  `:none`.
  """
  @spec read(Context.t(), map()) :: {:ok, card()} | :pending | :none
  def read(%Context{} = ctx, row) do
    with {:ok, block} <- block_of(row),
         {:ok, asked} <- source(ctx, row, block.tag) do
      {:ok, Map.put(card(row, block, asked), :file_state, file_state(ctx, block.file))}
    else
      :pending -> :pending
      _ -> :none
    end
  end

  @doc """
  A press of choice `index` on the card of row `row_id`, by the person
  of `ctx`, landing in `thread_id`: what the press row carries, read
  again on the server. The row must be a card's, in that same thread, and
  still open, and the index one of its choices; otherwise
  `{:error, :choice_closed}`. A row that cannot be read now is
  `{:error, :unavailable}`.
  """
  @spec press(Context.t(), String.t(), map()) ::
          {:ok, pressed()} | {:error, :choice_closed | :unavailable}
  def press(%Context{} = ctx, thread_id, %{"row" => row_id, "index" => index})
      when is_binary(row_id) and is_integer(index) and index >= 0 do
    with {:ok, row} <- message(ctx, row_id),
         true <- row.thread_id == thread_id,
         {:ok, block} <- block_of(row),
         {:ok, %{open?: true} = asked} <- source(ctx, row, block.tag),
         label when is_binary(label) <- Enum.at(block.choices, index) do
      {:ok,
       %{
         "row" => row.id,
         "index" => index,
         "question" => block.question,
         "label" => label,
         "asker" => asked.asker
       }}
    else
      {:error, :unavailable} = unavailable -> unavailable
      _ -> {:error, :choice_closed}
    end
  end

  def press(_ctx, _thread_id, _choice), do: {:error, :choice_closed}

  @doc "The press a person's row carries, or nil (`press/3`)."
  @spec pressed(map()) :: pressed() | nil
  def pressed(%{kind: "text", sent_by: "person"} = row) do
    case Tape.payload(row)["choice"] do
      %{"row" => _, "question" => q, "label" => l, "asker" => a} = choice
      when is_binary(q) and is_binary(l) and is_binary(a) ->
        choice

      _ ->
        nil
    end
  end

  def pressed(_row), do: nil

  defp block_of(%{kind: "text", author: author, content: content}) when is_binary(content) do
    if author == Prima.Author.agent(), do: parse(content), else: :none
  end

  defp block_of(_row), do: :none

  defp card(row, block, asked) do
    %{
      row: row.id,
      prose: block.prose,
      question: block.question,
      choices: block.choices,
      asker: asked.asker,
      open?: asked.open?,
      file: block.file
    }
  end

  # ---------------------------------------------------------------------------
  # The source row
  # ---------------------------------------------------------------------------

  # A member's reply in its room: its `from_turn` is the tag's completed
  # turn of that member, which answered this room, and its text is that
  # turn's last own text row as its brain wrote it, uncut.
  defp source(ctx, %{reply_to: request} = row, tag) when is_binary(request) do
    payload = Tape.payload(row)

    with true <- row.outcome == "done" and payload["truncated"] != true,
         true <- payload["from_turn"] == tag,
         {:ok, %{status: "completed", agent: member} = turn} <- turn(ctx, tag),
         true <- member == row.sent_by and turn.asking_thread_id == row.thread_id,
         {:ok, final} <- final_row(ctx, turn),
         true <- brain_written?(final, member),
         true <- String.trim(final.content || "") == String.trim(row.content),
         {:ok, open?} <- open?(ctx, row, &member_moved_on?(&1, row, member)) do
      {:ok, %{asker: member, open?: open?}}
    else
      {:error, :unavailable} = unavailable -> unavailable
      _ -> :none
    end
  end

  # Aqua's own: the tag is the row's own turn, a turn of the soul in the
  # row's thread, and the row is its brain's. A completed turn's row is a
  # card only when no later text of that turn's agent is in it.
  defp source(ctx, row, tag) do
    with true <- row.turn_id == tag and brain_written?(row, row.sent_by),
         true <- Prima.AgentRef.soul?(row.sent_by),
         {:ok, %{agent: agent, thread_id: thread_id} = turn} <- turn(ctx, tag),
         true <- agent == row.sent_by and thread_id == row.thread_id do
      cond do
        turn.status in Prima.TurnState.open_statuses() -> :pending
        turn.status == "completed" -> own(ctx, row, tag)
        true -> :none
      end
    else
      {:error, :unavailable} = unavailable -> unavailable
      _ -> :none
    end
  end

  defp own(ctx, row, tag) do
    case open?(ctx, row, &own_moved_on?(&1, row, tag)) do
      {:ok, :not_final} -> :none
      {:ok, open?} -> {:ok, %{asker: row.sent_by, open?: open?}}
      error -> error
    end
  end

  # What a brain wrote as its turn's speech (`Arca.TurnStorage`'s
  # `said!`): a text row of its agent naming the model step or the native
  # message it is, never a post a tool wrote.
  defp brain_written?(%{kind: "text", sent_by: agent} = row, agent) when is_binary(agent) do
    payload = Tape.payload(row)

    row.author == Prima.Author.agent() and payload["post"] != true and
      (is_binary(payload["step_id"]) or Map.has_key?(payload, "brain_message"))
  end

  defp brain_written?(_row, _agent), do: false

  # The last text row a completed turn's agent wrote in its own thread,
  # read from its opening on. A later turn's speech there begins after
  # this turn ended, so the read stops at the first of it.
  defp final_row(ctx, turn) do
    %{id: id, agent: agent} = turn

    with {:ok, opening} <- message(ctx, turn.message_id) do
      fold(ctx, turn.thread_id, opening.seq - 1, nil, fn
        %{turn_id: ^id} = later, last ->
          {:cont, if(spoken?(later, agent), do: later, else: last)}

        later, last ->
          if spoken?(later, agent), do: {:halt, last}, else: {:cont, last}
      end)
      |> case do
        {:ok, %{} = final} -> {:ok, final}
        {:ok, nil} -> :none
        error -> error
      end
    end
  end

  defp spoken?(%{kind: "text", sent_by: agent, author: author}, agent),
    do: author == Prima.Author.agent()

  defp spoken?(_row, _agent), do: false

  # ---------------------------------------------------------------------------
  # Open and closed
  # ---------------------------------------------------------------------------

  # Whether the card of `row` is still open: not in a past day's daily
  # thread, and nothing after it closes it, by `moved_on`, which answers
  # `:closed`, `:not_final` (Aqua's row was not its turn's last) or
  # `:open` for each later row. A press naming the card closes it.
  defp open?(ctx, row, moved_on) do
    with {:ok, current?} <- current?(ctx, row.thread_id),
         {:ok, seen} <-
           fold(ctx, row.thread_id, row.seq, :open, fn later, seen ->
             case if(named?(later, row), do: :closed, else: moved_on.(later)) do
               :not_final -> {:halt, :not_final}
               :final_closed -> {:halt, :closed}
               :closed -> {:cont, :closed}
               :open -> {:cont, seen}
             end
           end) do
      case seen do
        :not_final -> {:ok, :not_final}
        seen -> {:ok, current? and seen == :open}
      end
    end
  end

  defp named?(later, row) do
    case pressed(later) do
      %{"row" => id} -> id == row.id
      nil -> false
    end
  end

  # Aqua's card: more of its own turn's text after it makes it no final
  # row; a later turn's speech ends the read, and any row of a later turn
  # closes it, a press's among them.
  defp own_moved_on?(%{turn_id: tag} = later, row, tag),
    do: if(spoken?(later, row.sent_by), do: :not_final, else: :open)

  defp own_moved_on?(later, row, _tag) do
    cond do
      spoken?(later, row.sent_by) -> :final_closed
      is_binary(later.turn_id) -> :closed
      true -> :open
    end
  end

  # A member's card: a later request to that member in the room closes it.
  defp member_moved_on?(later, _row, member) do
    if later.kind == "text" and later.addressee == member and
         later.status in ["pending", "answered"],
       do: :final_closed,
       else: :open
  end

  # A past day's daily thread holds no open card.
  defp current?(ctx, thread_id) do
    case Tape.thread(ctx, thread_id) do
      {:ok, %{kind: "daily", day: day}} -> {:ok, day == Aqua.Day.today(ctx)}
      {:ok, _thread} -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
      {:error, _} -> {:error, :unavailable}
    end
  end

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  # The rows of `thread_id` after `seq`, oldest first, page by page, until
  # `fun` halts or the rows end.
  defp fold(ctx, thread_id, seq, acc, fun) do
    case Arca.ThreadStorage.messages(Sanctum.Context.actor(ctx), thread_id,
           after_seq: seq,
           limit: @page
         ) do
      rows when is_list(rows) ->
        case Enum.reduce_while(rows, {:cont, acc}, fn row, {:cont, acc} ->
               case fun.(row, acc) do
                 {:cont, acc} -> {:cont, {:cont, acc}}
                 {:halt, acc} -> {:halt, {:halt, acc}}
               end
             end) do
          {:halt, acc} -> {:ok, acc}
          {:cont, acc} when length(rows) < @page -> {:ok, acc}
          {:cont, acc} -> fold(ctx, thread_id, List.last(rows).seq, acc, fun)
        end

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  defp turn(ctx, id) do
    case Tape.turn(ctx, id) do
      {:ok, turn} -> {:ok, turn}
      {:error, :not_found} -> :none
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp message(ctx, id) do
    case Tape.message(ctx, id) do
      {:ok, row} -> {:ok, row}
      {:error, :not_found} -> :none
      {:error, _} -> {:error, :unavailable}
    end
  end

  # The `file:` line as Files holds it now: a path no shown folder holds
  # is not in Files (`Arca.Files.locate/2`), and of one that is, the read
  # says whether the file is there (`Arca.Files.read/2`); one past what a
  # read answers inline is.
  defp file_state(_ctx, nil), do: nil

  defp file_state(ctx, path) do
    actor = Sanctum.Context.actor(ctx)

    with {:ok, _stored, _tier} <- Arca.Files.locate(actor, path),
         {:ok, _file} <- Arca.Files.read(actor, path) do
      :present
    else
      {:error, {:not_found, _what, _path}} -> :missing
      {:error, {:invalid_argument, _}} -> located(actor, path)
      {:error, _} -> :unavailable
    end
  end

  defp located(actor, path) do
    case Arca.Files.locate(actor, path) do
      {:ok, _stored, _tier} -> :present
      _ -> :missing
    end
  end
end
