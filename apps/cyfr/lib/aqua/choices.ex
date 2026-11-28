# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Choices do
  @moduledoc """
  Aqua's question with its choices as buttons: the one grammar of a
  choices block, the one row of a turn that gives buttons, and a press.

  ## The block

  Aqua's reply, trimmed as admission trims a line, may end with

      ```choices <turn id>
      Which database should the export target?
      - PostgreSQL
      - SQLite
      file: data/aqua/plans/<turn id>-1-export.md
      ```

  The tag is the id of the turn that asks, which its facts name. Then the
  question, 1 to 200 characters; 1 to 8 choices, each `- <label>` with a
  label of 1 to 100 characters, all different; at most one
  `file: <path>` line, a Files path of at most 512 bytes; and the closing
  fence. Neither the question nor a label holds « or », the marks Aqua
  reads a press's words between (`Aqua.Reader`). The whole block is at
  most 4096 bytes of UTF-8 and holds no control or format character but
  its line feeds. Anything else is text, shown as it is.

  ## Which row gives buttons

  Only Aqua's: the last row its brain wrote in the completed soul turn
  the tag names, in the room that turn ran in (`Arca.TurnStorage`'s
  `said!`, whose payload names the model step or the native message,
  never `thread.post`'s `post`). Never an intermediate message, a post a
  tool wrote, a failed reply, a person's or a member's message, a tool or
  page result, or a block carrying another turn's tag. A tag shows which
  row a block belongs to, not who first wrote its bytes: Aqua ending its
  own final reply with a sample block carrying its own turn's id offers
  those choices as its own.

  A card has no open or closed state: a press is the person's next
  message, and whether it still fits is Aqua's to judge.

  ## A press

  `press/2` reads again the row a press names, by the rules above, under
  the presser's own context, and answers what the press row carries: the
  row, the index, and the question and the label as the row reads now;
  `room/2` answers the room its card is in, where the press lands. Nothing
  but the row and the index comes from the presser.
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
  @marks ["«", "»"]

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
  question, its choices, and its `file:` line as Files holds it when read
  (nil without one).
  """
  @type card :: %{
          row: String.t(),
          prose: String.t(),
          question: String.t(),
          choices: [String.t(), ...],
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

    if words?(question, @question_max) and not String.starts_with?(question, ["- ", "file:"]),
      do: {:ok, question},
      else: :none
  end

  defp lines(["- " <> label | rest], choices) do
    label = String.trim(label)

    if words?(label, @label_max) and label not in choices,
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

  defp words?(text, most),
    do: text != "" and String.length(text) <= most and not String.contains?(text, @marks)

  @doc """
  The card `row` shows under `ctx`, the person's own context: `{:ok,
  card}` for Aqua's final reply row of the turn its block names;
  `:pending` for a row of Aqua's turn that is still open, which may yet
  be its final reply; `:none` for any other row, which shows as the text
  it is. A row that cannot be read now is `:none`.
  """
  @spec read(Context.t(), map()) :: {:ok, card()} | :pending | :none
  def read(%Context{} = ctx, row) do
    case source(ctx, row) do
      {:ok, block} -> {:ok, Map.put(card(row, block), :file_state, file_state(ctx, block.file))}
      :pending -> :pending
      _ -> :none
    end
  end

  @doc """
  A press of choice `index` on the card of row `row_id` by the person of
  `ctx`: what the press row carries, read again on the server. The row
  must be a card's, in a room of the person's own, and the index one of
  its choices; otherwise `{:error, :no_choice}`. A row that cannot be
  read now is `{:error, :unavailable}`.
  """
  @spec press(Context.t(), map()) :: {:ok, pressed()} | {:error, :no_choice | :unavailable}
  def press(%Context{} = ctx, %{"row" => row_id, "index" => index})
      when is_binary(row_id) and is_integer(index) and index >= 0 do
    with {:ok, row} <- message(ctx, row_id),
         {:ok, block} <- source(ctx, row),
         label when is_binary(label) <- Enum.at(block.choices, index) do
      {:ok, %{"row" => row.id, "index" => index, "question" => block.question, "label" => label}}
    else
      {:error, :unavailable} = unavailable -> unavailable
      _ -> {:error, :no_choice}
    end
  end

  def press(_ctx, _choice), do: {:error, :no_choice}

  @doc """
  The room the card a press names is in, read as `press/2` reads the
  press: where the press lands is the card's alone (`thread.send`).
  """
  @spec room(Context.t(), map()) :: {:ok, map()} | {:error, :no_choice | :unavailable}
  def room(%Context{} = ctx, choice) do
    with {:ok, %{"row" => row_id}} <- press(ctx, choice),
         {:ok, row} <- message(ctx, row_id),
         {:ok, room} <- thread(ctx, row.thread_id) do
      {:ok, room}
    else
      {:error, _} = refused -> refused
      _ -> {:error, :no_choice}
    end
  end

  @doc "The press a person's row carries, or nil (`press/2`)."
  @spec pressed(map()) :: pressed() | nil
  def pressed(%{kind: "text", sent_by: "person"} = row) do
    case Tape.payload(row)["choice"] do
      %{"row" => r, "index" => i, "question" => q, "label" => l} = choice
      when is_binary(r) and is_integer(i) and is_binary(q) and is_binary(l) ->
        choice

      _ ->
        nil
    end
  end

  def pressed(_row), do: nil

  defp card(row, block),
    do: %{
      row: row.id,
      prose: block.prose,
      question: block.question,
      choices: block.choices,
      file: block.file
    }

  # ---------------------------------------------------------------------------
  # The source row
  # ---------------------------------------------------------------------------

  # Aqua's own: a row its brain wrote, whose block's tag is the row's own
  # turn, a soul turn of a room of the person's; once that turn has
  # completed, the row is a card only when no later row of its brain's
  # in that turn follows it.
  defp source(ctx, row) do
    with true <- brain_written?(row) and Prima.AgentRef.soul?(row.sent_by),
         {:ok, %{tag: tag} = block} <- parse(row.content),
         true <- row.turn_id == tag,
         {:ok, %{kind: kind}} when kind in ["daily", "workspace"] <- thread(ctx, row.thread_id),
         {:ok, %{agent: agent, thread_id: thread_id} = turn} <- turn(ctx, tag),
         true <- agent == row.sent_by and thread_id == row.thread_id do
      cond do
        turn.status in Prima.TurnState.open_statuses() -> :pending
        turn.status == "completed" -> final(ctx, row, block)
        true -> :none
      end
    else
      {:error, :unavailable} = unavailable -> unavailable
      _ -> :none
    end
  end

  # What a brain wrote as its turn's speech (`Arca.TurnStorage`'s
  # `said!`): a text row of its agent naming the model step or the native
  # message it is, never a post a tool wrote or a request `crew.ask` wrote.
  defp brain_written?(%{kind: "text", sent_by: agent, author: author} = row)
       when is_binary(agent) do
    payload = Tape.payload(row)

    author == Prima.Author.agent() and payload["post"] != true and
      (is_binary(payload["step_id"]) or Map.has_key?(payload, "brain_message"))
  end

  defp brain_written?(_row), do: false

  # Whether a later row of the turn's brain follows `row` in it. Whatever
  # else lies between, a request, a tool's rows, a person's line, decides
  # nothing; a later turn's own speech begins only after this turn ended,
  # so the read stops at the first of it.
  defp final(ctx, row, block) do
    case fold(ctx, row.thread_id, row.seq, :final, fn later, :final ->
           cond do
             not brain_written?(later) -> {:cont, :final}
             later.turn_id == row.turn_id -> {:halt, :not_final}
             true -> {:halt, :final}
           end
         end) do
      {:ok, :final} -> {:ok, block}
      {:ok, :not_final} -> :none
      error -> error
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

  defp thread(ctx, id), do: found(Tape.thread(ctx, id))
  defp turn(ctx, id), do: found(Tape.turn(ctx, id))
  defp message(ctx, id), do: found(Tape.message(ctx, id))

  defp found({:ok, value}), do: {:ok, value}
  defp found({:error, :not_found}), do: :none
  defp found({:error, _}), do: {:error, :unavailable}

  # The `file:` line as Files holds it: whether the file's folder lists
  # it (`Arca.Files.list/2`), which reads no file's bytes. A path no shown
  # folder holds is not in Files.
  defp file_state(_ctx, nil), do: nil

  defp file_state(ctx, path) do
    {segments, [name]} = path |> String.trim("/") |> String.split("/") |> Enum.split(-1)

    case Arca.Files.list(Sanctum.Context.actor(ctx), Enum.join(segments, "/")) do
      {:ok, %{entries: entries}} ->
        if Enum.any?(entries, &(&1.kind == :file and &1.name == name)),
          do: :present,
          else: :missing

      {:error, {:invalid_argument, _}} ->
        :missing

      {:error, {:not_found, _, _}} ->
        :missing

      {:error, _} ->
        :unavailable
    end
  end
end
