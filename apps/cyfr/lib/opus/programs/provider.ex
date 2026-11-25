# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs.Provider do
  @moduledoc """
  The `program` tool: Aqua's own runs of the athanor's programs, in a
  turn's chain and nowhere else (`planes: [:in_chain]`).

  `list` names the athanor's enabled program rows, each by its id, its
  name, its pinned command and its epoch, nothing of its environment,
  hosts or folder. `start` runs one, its pinned command followed by the words the
  turn gives, as a session the turn owns (`Opus.Programs.start/3`), and
  answers what it printed once it exited, paused or the call's own time
  passed; `send` types on it; `read` answers what it printed past an
  offset, and `wait` does once it printed more and paused, or its program
  ended, as long as that takes (`waits: true`, `Prima.Operation`), or
  within the `ms` it names; `stop` ends it.

  ## Who the caller is

  Every action is `consent: :interactive`, which in a chain the gate
  admits only for a person's own sign-in (an `:oidc` chain: a person's
  turn, its continuation, a schedule's turn of that person), never a
  key's. The handler hands the session owner the
  context with the lineage the gate stamped on the call
  (`Opus.Programs.turn/2`): the gate drops whatever a guest sends under
  `thread_id`, `root_execution_id` and `parent_execution_id` and writes
  its own, so no call names another turn. The owner proves from the
  store that the lineage is an open turn of that thread, in the caller's
  athanor, asked for by the caller's person, whose root made the call
  itself, so a component the turn started (a hand, an app it launched)
  reaches nothing. A turn reaches only the sessions it started.

  ## What a start runs

  The words after the command are the turn's own. They are bounded: at
  most 32 words of at most 256 characters each. The program gets them as
  its own arguments, never read by a shell. The terminal is 50 rows by
  200 columns. A start names the row's epoch as `list` answered it, so
  the row the turn read is the row that runs: one changed since is
  refused (`:row_changed`).

  ## What the turn reads

  What a session printed, kept as its last 256 KiB and counted from its
  first byte, is answered as text: the terminal's escape sequences and
  control characters other than newlines and tabs taken out, at most
  64 KiB a call, with the offset to read on from and how many bytes
  were no longer kept. It passed the backends service's masking of the
  row's credentials first.
  """

  @behaviour Prima.Provider

  alias Opus.Programs
  alias Sanctum.Context

  @rows 50
  @cols 200
  @max_words 32
  @max_word_chars 256
  # How long a start waits for what it prints, at most and by default.
  @start_max_ms 30_000
  @start_wait_ms 10_000

  @impl true
  def service, do: "opus"

  @impl true
  def tools, do: [definition()]

  @doc false
  def definition do
    alias Prima.{Arg, Operation}

    session =
      Arg.new("session", :string,
        required: true,
        description: "send, read, wait, stop: the session start answered"
      )

    after_arg =
      Arg.new("after", :integer,
        min: 0,
        description:
          "read, wait: the offset to read on from, the `next` an earlier answer gave (0 from the start)"
      )

    Operation.tool(
      [
        Operation.new("program", "list", "List programs", [],
          kind: :read,
          planes: [:in_chain],
          consent: :interactive,
          recovery: :replay_safe
        ),
        Operation.new(
          "program",
          "start",
          "Start a program",
          [
            Arg.new("program", :string,
              required: true,
              description: "start: the id of the program to run, as list answers it"
            ),
            Arg.new("epoch", :integer,
              required: true,
              min: 1,
              description:
                "start: the program's epoch, as list answers it; a program changed since is not started"
            ),
            Arg.new("terminal_args", {:array, Arg.new(nil, :string, max: @max_word_chars)},
              max: @max_words,
              description:
                "start: the words to follow the program's command, each one argument, at most #{@max_words} of at most #{@max_word_chars} characters"
            ),
            Arg.new("wait_ms", :integer,
              min: 0,
              max: @start_max_ms,
              description:
                "start: how long to wait for what it prints before answering (default #{@start_wait_ms})"
            )
          ],
          kind: :execute,
          resource: {"program", :program_row},
          planes: [:in_chain],
          consent: :interactive
        ),
        Operation.new(
          "program",
          "send",
          "Type on a program",
          [
            session,
            Arg.new("terminal_input", :string,
              required: true,
              description:
                "send: the text to type, as typed (at most #{div(Prima.LocusBackends.max_chunk_bytes(), 1024)} KiB)"
            ),
            Arg.new("enter", :boolean, description: "send: press Enter after the text")
          ],
          kind: :execute,
          planes: [:in_chain],
          consent: :interactive
        ),
        Operation.new("program", "read", "Read a program", [session, after_arg],
          kind: :read,
          planes: [:in_chain],
          consent: :interactive,
          recovery: :replay_safe
        ),
        Operation.new(
          "program",
          "wait",
          "Wait for a program",
          [
            session,
            after_arg,
            Arg.new("ms", :integer,
              min: 0,
              description:
                "wait: how long to wait at most, in milliseconds; leave it out to wait as long as it takes"
            )
          ],
          kind: :read,
          planes: [:in_chain],
          consent: :interactive,
          recovery: :replay_safe,
          waits: true
        ),
        Operation.new("program", "stop", "Stop a program", [session],
          kind: :write,
          planes: [:in_chain],
          consent: :interactive,
          reduces_authority: true
        )
      ],
      description:
        "Run one of this athanor's programs on a terminal of its own and read what it prints. list names them; start runs one with the words to follow its command; send types on it; read answers what it printed past an offset, and wait does once it prints more and pauses or ends, as long as that takes; stop ends it. A run ends with this turn.",
      title: "Programs"
    )
  end

  @impl true
  def handle("program", %Context{} = ctx, %{"action" => action} = args),
    do: dispatch(action, Programs.turn(ctx, args), args)

  # ---------------------------------------------------------------------------

  defp dispatch("list", caller, _args), do: Programs.rows(caller)

  defp dispatch("start", caller, %{"program" => row_id, "epoch" => epoch} = args)
       when is_binary(row_id) and is_integer(epoch) do
    words = Map.get(args, "terminal_args") || []

    opts = %{rows: @rows, cols: @cols, args: words, epoch: args["epoch"]}

    with {:ok, session} <- Programs.start(caller, row_id, opts) |> refused(),
         do: answer(caller, session, 0, Map.get(args, "wait_ms") || @start_wait_ms)
  end

  defp dispatch("send", caller, %{"session" => session, "terminal_input" => text} = args)
       when is_binary(session) and is_binary(text) do
    text = if args["enter"] == true, do: text <> "\r", else: text

    case Programs.input(caller, session, text) do
      :ok -> {:ok, %{session: session, sent: byte_size(text)}}
      {:error, reason} -> refused({:error, reason})
    end
  end

  defp dispatch("read", caller, %{"session" => session} = args) when is_binary(session),
    do: shown(session, Programs.read(caller, session, Map.get(args, "after") || 0))

  defp dispatch("wait", caller, %{"session" => session} = args) when is_binary(session),
    do: answer(caller, session, Map.get(args, "after") || 0, Map.get(args, "ms") || :infinity)

  defp dispatch("stop", caller, %{"session" => session}) when is_binary(session) do
    case Programs.close(caller, session) do
      {:ok, outcome} -> {:ok, %{session: session, stopped: outcome}}
      {:error, reason} -> refused({:error, reason})
    end
  end

  defp dispatch(action, _caller, _args),
    do: {:error, {:invalid_argument, "program.#{action}: the arguments are incomplete"}}

  defp answer(caller, session, offset, ms),
    do: shown(session, Programs.wait(caller, session, offset, ms))

  defp shown(session, {:ok, %{output: output} = transcript}) do
    {:ok,
     %{
       session: session,
       program: transcript.program,
       output: text(output.bytes),
       next: transcript.next,
       dropped: transcript.dropped,
       running: transcript.running,
       ended: transcript.ended && Atom.to_string(transcript.ended)
     }}
  end

  defp shown(_session, {:error, reason}), do: refused({:error, reason})

  @doc """
  The text a turn reads of what a terminal printed: escape sequences
  (CSI, OSC and the other `ESC` forms) and control characters other than
  newline and tab taken out, a carriage return before a newline dropped
  and any other read as a newline, and bytes that are not UTF-8 replaced.
  """
  @spec text(binary()) :: String.t()
  def text(bytes) when is_binary(bytes) do
    bytes
    |> String.replace(~r/\e\][^\a\e]*(?:\a|\e\\)?/, "")
    |> String.replace(~r/\e\[[0-?]*[ -\/]*[@-~]/, "")
    |> String.replace(~r/\e[P^_X][^\e]*(?:\e\\)?/, "")
    |> String.replace(~r/\e[ -\/]*[0-~]?/, "")
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F]/, "")
    |> valid()
  end

  defp valid(text) do
    if String.valid?(text),
      do: text,
      else:
        text |> String.chunk(:valid) |> Enum.map_join(&if(String.valid?(&1), do: &1, else: "�"))
  end

  # The owner's refusals, in words the turn reads.
  defp refused({:ok, _} = ok), do: ok
  defp refused({:error, :not_found}), do: {:error, {:not_found, "Program or session", "that"}}

  defp refused({:error, :too_many_sessions}),
    do:
      {:error,
       {:invalid_argument,
        "This turn already runs #{Programs.turn_sessions()} programs; stop one first"}}

  defp refused({:error, :row_changed}),
    do: {:error, {:invalid_argument, "The program changed since it was shown; ask again"}}

  defp refused({:error, :too_large}),
    do: {:error, {:invalid_argument, "Too much to type at once"}}

  defp refused({:error, :ended}),
    do: {:error, {:invalid_argument, "The program is no longer running"}}

  defp refused({:error, reason}) when reason in [:disabled, :not_a_program],
    do: {:error, {:invalid_argument, "That program cannot be started"}}

  defp refused({:error, reason}) when reason in [:invalid_args, :invalid_size],
    do: {:error, {:invalid_argument, "The words to follow the command are not valid"}}

  defp refused({:error, reason}), do: {:error, reason}
end
