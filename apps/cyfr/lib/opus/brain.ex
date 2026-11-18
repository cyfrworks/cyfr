# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Brain do
  @moduledoc """
  The holder of a program used as a brain: one session of a brain's
  driver (`apps/locus/keeper/cmd/cyfr-claude-code`, `cmd/cyfr-codex`) for
  one thread, kept open for as long as the work needs it, as
  `Opus.Browser` keeps the person's browser. A thread keeps one native
  session (`brain_session`) whichever agent its turns address, so one
  holder runs per thread. The driver runs beside the harness in its
  program row's box and speaks the harness's own protocol to it; this
  process speaks the brain wire (`Opus.Brain.Wire`) to the driver over a
  `run` session (`Opus.Programs.Session`), and holds nothing else of the
  harness's.

  ## One attendant

  The process that opens the session (`open/1`) is its one attached
  process, the attendant: it alone writes (`write/4`), it is handed what
  the driver says, and its exit ends the session. A later `open/1` for
  the same thread, another agent's work among them, for work that proves
  itself, ends this one first (`:replaced`), so a take-over never shares
  a session with the work it took over and no two driver processes run
  one native session: its next start resumes the native session in a new
  process.

  A take-over is decided by the holder it would end: that holder reads
  the opener's binding as it handles the request and ends only when the
  binding proves, so a stale open never ends its successor. The new holder
  reads the binding again before it opens the driver's session and after,
  so a binding that went stale while the opener waited opens nothing.

  ## Reading

  The driver's lines are read in order, each read past the last line the
  attendant said it took. Each batch is decoded whole and handed to the
  attendant as `{Opus.Brain, ref, {:lines, boot, lines}}`, `boot` the
  driver process's (its `hello`'s) and each line `{seq, event}`, its
  number in the session and the event it reads as; the next is read only
  once the attendant has said, by `read_on/3`, the last line whose effects
  it committed. A line at or before that one is never handed again, and
  the first line of a session is its driver's `hello`. Every line is the
  program's word: the harness runs under the driver's uid and can write as
  it does, so a line that does not read, one past a bound, a `hello` of
  another version, or a line lost unread ends the session.

  ## Writing

  One command is written at a time, after the driver's `hello`: the next
  only once the driver has answered the last (`started` or `gone`,
  `accepted` or `refused`). Whether a command reaches the driver is decided
  once, as it is about to be written, by the binding it is written under
  (below). A write the service did not answer may have reached the driver,
  and is never written again: the session ends `:interrupted`, and the
  next start resumes the native session, whose transcript says what it
  holds (`started.held`).

  A `work` names the configuration its turn runs with. One that differs
  from the configuration the running harness was started with writes
  nothing: the driver's process is closed and a new one opened in the same
  holder, `{:ok, :restarted}`, and the attendant starts it again, resuming.

  The configuration's `read_only` is the holder's to set, never the
  caller's: in every `start` and every `work` it is the mode the turn's
  row stored when it started (`turns.agent_mode`), read with the binding, and a
  read-only one also drops the harness's own `permission_mode` and
  `harness_tools`. A mode switched between turns therefore makes the next
  `work`'s configuration differ, and the program is started again in the
  mode of the turn it now works for.

  ## The binding to admitted work

  Each write names the work it is written for (`t:binding/0`): the turn,
  its person, its origin, its fence, the step that admitted the program's
  start, the program row and its epoch and the thread's session generation.
  As the command is about to be written, once the attendant's own veto
  (`admits?`) has said nothing against it, it is read again from the
  store:

    * the person stands, and is the turn's;
    * the turn is the thread's and agent's, of that origin, at that fence,
      and running; a paused turn may be written only a `post` or an
      `answer` (the narrow proof below);
    * the step is that turn's `program.start`, dispatched or closed as it
      ran, with no refusal and no Stop, and the call it was recorded for
      (its `tool_call` row) starts this row at this epoch: the loop
      dispatches a step only after deciding it, so the dispatched step is
      the proof;
    * the row is the holder's, a driven program with a kept folder,
      enabled and at that epoch;
    * the thread is at that session generation.

  The veto is the attendant's and only ever withdraws: the stored step is
  the proof.

  A `start` names the binding's generation; a `work` and a `post` name the
  binding's turn as their work; an `answer` answers an ask the driver
  showed for the binding's turn and that has not been answered.

  A paused turn's proof is narrow: it delivers a `post` or an `answer` of
  its own work and nothing else, so a paused turn never starts the harness
  or sets its tools. A turn the store reads as anything but running or
  paused writes nothing.

  ## Two paths no turn admits

  A `models` or a `forget` is never a delivery: `write/4` refuses both
  with nothing written, so no turn and no binding reaches either. Each
  runs in a process of its own under the holders' supervisor, which holds
  the row's owner, opens a new process of the driver, writes the one
  command after its `hello`, reads the one answer and ends; it starts no
  harness session and writes nothing else.

    * **Cleanup** (`forget/1`) runs for the `brain_cleanup` consumer
      (`Opus.Brain.Cleanup`), for the session one `brain_forget` record
      names (`Prima.OutboxRecord.brain_forget/1`). The record is read
      again from the store, still owed to that consumer, and only what the
      stored record names is acted on, so a caller can hasten an owed
      removal and ask for no other. It runs under the record's thread,
      the key a holder of that session runs under: a holder there on the
      record's row whose session generation is the record's or older is
      ended first (`:forgotten`), so the box closes the driver's process
      that ran the session before the one that forgets it opens; one of a
      later generation is a successor, one on another row holds nothing
      of that row's folder, and the removal waits for either, staying
      owed until that holder ends. A thread that holds the record's
      session again, under a later generation, is a successor too, and
      its session is never removed. The cleanup's own holder decides it,
      reading the record and the thread again once it owns the key and
      before anything opens, and a successor's open under the key waits
      for that holder to end. The answer is `forgot` for that record's id
      and session, or not a removal.
    * **Discovery** (`models/2`) runs only for a person at a screen, an
      interactive caller of the row's athanor (`Opus.Programs.caller/1`),
      for a brain's row of that athanor: the models and efforts the
      harness itself lists. A turn's caller is a stranger to it.

  A forgetting transaction answers the sessions it owed
  (`t:Arca.ThreadStorage.forgotten/0`), and its caller closes their holders
  at once (`forgotten/2`), which also wakes the consumer.

  ## Its end

  It ends, telling the attendant `{Opus.Brain, ref, {:ended, reason}}`
  once, when it is told (`close/1`, `:closed`), when a later open replaces
  it (`:replaced`), when its session is forgotten (`forgotten/2` or a
  cleanup of its thread, `:forgotten`), on a line lost unread
  (`:dropped`), on a line that does
  not read or past a bound (`:unreadable`, `:too_large`), on its row's
  change (`:row_changed`, `Opus.Programs.end_mounts/2` or the box telling
  it to stand down), when the driver's process ends (`:exited`), when the
  service could not be read for a minute (`:unavailable`), and after a
  write whose answer did not come (`:interrupted`). Its attendant's exit
  ends it too. However it ends, killed included, the box closes its
  session (`Opus.Programs.box_open/4`), and on its way out it asks so
  itself.
  """

  use GenServer, restart: :temporary

  alias Opus.Brain.Wire
  alias Opus.Programs
  alias Opus.Programs.Session

  @registry Opus.Brain.Registry
  @holders Opus.Brain.Holders
  @open_ms 60_000
  @answer_margin_ms 5_000
  @write_ms 30_000
  @recv_wait_ms 20_000
  @read_retries 60
  @read_retry_ms 1_000
  # How long a cleanup or a discovery waits for its driver's answer, from
  # the open of its session; past it the answer is lost.
  @once_ms 60_000
  # The refusals of a session route that say the session is not on the
  # service any more.
  @gone [:unknown_session, :stale_boot, :epoch_ahead, :unknown_owner, :lapsed]
  # What a send's failure says of its line: these may follow its writing.
  @uncertain [:backends_unavailable]

  @typedoc """
  The work a write is made for, as the attendant holds it: the turn's
  context (its athanor and person), the thread the session is kept for,
  the agent whose work it is, the turn, its origin as the row stores it
  and the fence its runner holds, the step that admitted the program's
  start, the program row and the epoch the start showed, the thread's
  session generation, and `admits?`, the attendant's own veto, which can
  only withdraw what the stored decision allows.
  """
  @type binding :: %{
          required(:ctx) => Sanctum.Context.t(),
          required(:thread_id) => String.t(),
          required(:agent) => String.t(),
          required(:turn_id) => String.t(),
          required(:origin) => String.t(),
          required(:fence) => non_neg_integer(),
          required(:step) => String.t(),
          required(:row_id) => String.t(),
          required(:epoch) => pos_integer(),
          required(:generation) => non_neg_integer(),
          required(:admits?) => (-> boolean())
        }

  @typedoc "A held session: its holder and the reference its messages carry."
  @type brain :: {pid(), reference()}

  @doc """
  The most milliseconds of a program's own silence a job runs before it
  ends (the `program_silence_ms` platform setting).
  """
  @spec silence_ms() :: pos_integer()
  def silence_ms do
    case Arca.PlatformSettings.effective("program_silence_ms") do
      {:ok, value} when is_integer(value) and value > 0 -> value
    end
  end

  @doc """
  Open the session of `binding`'s thread on its program row, for the
  calling process, which becomes its attendant: a new process of the
  row's driver, once `binding` is read again and proves a running turn
  (moduledoc). A holder of the same thread, whichever agent's work it
  carried, is ended first (`:replaced`), by that holder, once it has read
  `binding` and found it proves; the new holder reads it again before it
  opens the driver's session and after. Answers the held session, whose
  first line is the driver's `hello`; `{:error, {:not_admitted, reason}}`
  for a binding that does not prove, or the refusal of the owner's hold or
  the session's open.
  """
  @spec open(binding()) :: {:ok, brain()} | {:error, term()}
  def open(%{ctx: %Sanctum.Context{athanor_id: athanor_id}} = binding)
      when is_binary(athanor_id) do
    key = {athanor_id, binding.thread_id}

    with :ok <- replace(key, binding) do
      case DynamicSupervisor.start_child(@holders, {__MODULE__, key}) do
        {:ok, pid} -> call(pid, {:open, self(), binding}, @open_ms + @answer_margin_ms)
        {:error, {:already_started, _pid}} -> {:error, :busy}
        {:error, _reason} -> {:error, :unavailable}
      end
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Write `command` (a brain wire command: `start`, `work`, `post` or
  `answer`) under `binding`, read again from the store just before it is
  written (moduledoc). `opts`: `config`, the configuration a `work`'s turn
  runs with. Answers `:ok` once the service took it, `{:ok, :restarted}`
  for a `work` whose configuration differs from the running harness's
  (nothing written; a new process runs), or `{:error, reason}` with
  nothing written: `:not_a_delivery` (a `models` or a `forget`, which no
  binding writes), `:busy` (before the `hello`, or while the last
  command's answer is outstanding), `:not_attached`, `:unreadable`,
  `:running` (a `start` while a harness runs), `:not_started`,
  `:not_this_work`, `:not_this_generation` (a `start` naming another
  generation than the binding's), `{:not_admitted, reason}`; or
  `{:error, :uncertain}`, a write that may have reached the driver, after
  which the session ends.
  """
  @spec write(brain(), binding(), Wire.message(), keyword()) ::
          :ok | {:ok, :restarted} | {:error, term()}
  def write({pid, ref}, binding, %{} = command, opts \\ []) when is_reference(ref) do
    call(pid, {:write, ref, binding, command, opts}, @write_ms + @open_ms + @answer_margin_ms)
  end

  @doc """
  The attendant committed the effects of the session's lines through
  `seq` of the driver process `boot`: the next lines are read past it. A
  `boot` that is not the running driver's says nothing.
  """
  @spec read_on(brain(), String.t(), non_neg_integer()) :: :ok
  def read_on({pid, ref}, boot, seq) when is_binary(boot) and is_integer(seq) and seq >= 0,
    do: GenServer.cast(pid, {:read_on, ref, self(), boot, seq})

  @doc "End the session: its driver's process is closed, the attendant told `:closed`."
  @spec close(brain()) :: :ok
  def close({pid, ref}) when is_reference(ref) do
    _ = call(pid, {:close, ref}, Programs.Box.close_timeout_ms() + @answer_margin_ms)
    :ok
  end

  @doc "The held session of a thread, if one runs."
  @spec whereis(String.t(), String.t()) :: pid() | nil
  def whereis(athanor_id, thread_id) do
    if Process.whereis(@registry) do
      case Registry.lookup(@registry, {athanor_id, thread_id}) do
        [{pid, _}] -> pid
        [] -> nil
      end
    end
  end

  @doc """
  Close at once the holders of sessions a forgetting transaction owed
  their removal (`t:Arca.ThreadStorage.forgotten/0`): each holder of the
  thread whose session generation is that one or older ends,
  its attendant told `:forgotten`, and one of a later generation runs on.
  Then the consumer is told the athanor owes removals
  (`Opus.Brain.Cleanup.wake/1`). Called after the transaction commits.
  """
  @spec forgotten(String.t(), [Arca.ThreadStorage.forgotten()]) :: :ok
  def forgotten(athanor_id, forgotten) when is_binary(athanor_id) and is_list(forgotten) do
    Enum.each(forgotten, fn %{thread_id: thread_id, generation: generation} ->
      case whereis(athanor_id, thread_id) do
        nil ->
          :ok

        pid ->
          call(
            pid,
            {:forgotten, generation, nil},
            Programs.Box.close_timeout_ms() + @answer_margin_ms
          )
      end
    end)

    if forgotten != [], do: Opus.Brain.Cleanup.wake(athanor_id)
    :ok
  end

  @doc """
  Remove from its row's folder the native session one `brain_forget`
  record names, for the `brain_cleanup` consumer (moduledoc, "Two paths
  no turn admits"). Answers `:forgot` once the driver answered `forgot`
  for the record's id and session, and otherwise what stands in the way:
  `{:error, :not_owed}` (no such record is owed to the consumer),
  `{:error, :successor}` (the thread holds that session again),
  `{:error, :row_gone}`, `{:error, :not_a_brain_row}`,
  `{:error, :no_driver}` (the row's command names no driver),
  `{:error, :disabled}`, `{:error, :busy}` (a successor's holder, or
  another cleanup, runs under the key), `{:error, {:refused, reason}}`
  (the driver refused it), or the refusal of the owner's hold, the
  session's open or the line's write, and `{:error, :lost}` for an answer
  that did not come.
  """
  @spec forget(Prima.OutboxRecord.t()) :: :forgot | {:error, term()}
  def forget(%Prima.OutboxRecord{kind: "brain_forget", athanor_id: athanor_id} = record)
      when is_binary(athanor_id) and athanor_id != "" do
    actor = Prima.Actor.in_athanor(athanor_id)

    with {:ok, owed} <- owed(actor, record),
         {:ok, row} <- forget_row(actor, owed["row_id"]),
         key = {athanor_id, owed["thread_id"]},
         :ok <- retire(key, owed["generation"], owed["row_id"]),
         {:ok, pid} <- holder(key) do
      id = forget_id(record)
      session = owed["session"]

      case call(pid, {:forget, owner(athanor_id, row), record}, @once_ms + @answer_margin_ms) do
        {:ok, %{"t" => "forgot", "id" => ^id, "session" => ^session}} ->
          :forgot

        {:ok, %{"t" => "refused", "reason" => reason}} ->
          {:error, {:refused, reason}}

        {:ok, _another_answer} ->
          {:error, :unreadable}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  The models and efforts the harness of the brain's row `row_id` lists,
  for a person at a screen (moduledoc, "Two paths no turn admits"):
  `{:ok, %{models: [%{id, name}], efforts: [effort]}}`; `{:error,
  :not_interactive}` for any other caller, a turn's among them;
  `:not_standing` or `:unavailable` as `Opus.Programs.caller/1` answers;
  `{:error, :row_not_found}`, `:not_a_brain_row`, `:no_driver` or
  `:disabled` for the row; `{:error, {:refused, reason}}` when the driver
  did not list them; or the refusal of the owner's hold, the session's
  open or the line's write, and `{:error, :lost}` for an answer that did
  not come.
  """
  @spec models(Sanctum.Context.t(), String.t()) ::
          {:ok, %{models: [%{id: String.t(), name: String.t()}], efforts: [String.t()]}}
          | {:error, term()}
  def models(%Sanctum.Context{athanor_id: athanor_id} = ctx, row_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(row_id) do
    id = "mdl_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    with :ok <- interactive(ctx),
         {:ok, row} <-
           read(
             Arca.McpServerStorage.get_by_id(Sanctum.Context.actor(ctx), row_id),
             :row_not_found
           ),
         :ok <- brain_row(row),
         {:ok, pid} <- holder({athanor_id, id}) do
      case call(
             pid,
             {:once, owner(athanor_id, row), %{"t" => "models", "id" => id}},
             @once_ms + @answer_margin_ms
           ) do
        {:ok, %{"t" => "models", "id" => ^id, "models" => models, "efforts" => efforts}} ->
          {:ok,
           %{
             models: Enum.map(models, &%{id: &1["id"], name: &1["name"]}),
             efforts: efforts
           }}

        {:ok, %{"t" => "refused", "reason" => reason}} ->
          {:error, {:refused, reason}}

        {:ok, _another_answer} ->
          {:error, :unreadable}

        {:error, reason} ->
          {:error, reason}
      end
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  # A holder of the key is ended, and gone, before a new one starts. It
  # ends only once it has read `binding` itself and found it proves, so
  # the check and the ending are one step of that holder's: a request it
  # refuses leaves it running. A holder that ended while asked is gone
  # all the same.
  defp replace({athanor_id, thread_id}, binding) do
    case whereis(athanor_id, thread_id) do
      nil ->
        :ok

      pid ->
        monitor = Process.monitor(pid)
        wait = Programs.Box.close_timeout_ms() + @answer_margin_ms

        case call(pid, {:replace, binding}, wait) do
          {:error, {:not_admitted, _reason}} = refused ->
            Process.demonitor(monitor, [:flush])
            refused

          _ended_or_gone ->
            receive do
              {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
            after
              wait -> {:error, :busy}
            end
        end
    end
  end

  defp call(pid, message, timeout) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :unavailable}
    :exit, _ -> {:error, :unavailable}
  end

  # ===========================================================================
  # Cleanup and discovery
  # ===========================================================================

  # The record as the store holds it, still owed to the consumer: what it
  # names is read there, never from the caller's copy.
  defp owed(actor, record) do
    source = Prima.OutboxRecord.source(record)

    case Arca.Outbox.pending(actor, Opus.Brain.Cleanup.consumer(), "brain_forget") do
      {:ok, pending} ->
        case Enum.find(pending, &(Prima.OutboxRecord.source(&1) == source)) do
          %Prima.OutboxRecord{snapshot: %{} = owed} -> snapshot(owed)
          nil -> {:error, :not_owed}
        end

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp snapshot(
         %{
           "thread_id" => thread_id,
           "row_id" => row_id,
           "session" => session,
           "generation" => generation
         } = owed
       )
       when is_binary(thread_id) and is_binary(row_id) and is_binary(session) and
              is_integer(generation),
       do: {:ok, owed}

  defp snapshot(_unreadable), do: {:error, :not_owed}

  # A thread that holds the record's session again holds a successor's:
  # it is never removed.
  defp no_successor(actor, %{"thread_id" => thread_id, "session" => session}) do
    case Arca.ThreadStorage.get(actor, thread_id) do
      {:ok, %{brain_session: ^session}} -> {:error, :successor}
      {:ok, _another_or_none} -> :ok
      {:error, :not_found} -> :ok
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp forget_row(actor, row_id) do
    case Arca.McpServerStorage.get_by_id(actor, row_id) do
      {:ok, row} -> with :ok <- brain_row(row), do: {:ok, row}
      {:error, :not_found} -> {:error, :row_gone}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # A brain's row: a driven program with a kept folder, not the browser,
  # whose command starts with a driver, enabled. A row whose command is
  # the bare harness runs no driver, so nothing would answer the wire.
  defp brain_row(row) do
    cond do
      row.transport != "program" or row.mark != "driven" or row.home != "kept" ->
        {:error, :not_a_brain_row}

      Programs.Definition.browser?(row) ->
        {:error, :not_a_brain_row}

      Arca.McpServerStorage.driver(row) == nil ->
        {:error, :no_driver}

      row.enabled != true ->
        {:error, :disabled}

      true ->
        :ok
    end
  end

  # A person at a screen of the context's athanor; anything else, a
  # turn's call among them, is no caller here.
  defp interactive(ctx) do
    case Programs.caller(ctx) do
      {:ok, {athanor_id, _user_id}} when athanor_id == ctx.athanor_id -> :ok
      {:ok, _stranger_or_another} -> {:error, :not_interactive}
      {:error, reason} -> {:error, reason}
    end
  end

  defp owner(athanor_id, row), do: %{athanor_id: athanor_id, server_id: row.id, epoch: row.epoch}

  # The id the record's `forget` names: derived from the record's source,
  # so every try of one record names the same.
  defp forget_id(record) do
    %{source_id: source_id, source_revision: revision} = Prima.OutboxRecord.source(record)

    digest =
      Prima.Digest.sha256_hex(IO.iodata_to_binary([record.athanor_id, 0, source_id, 0, revision]))

    "obx_" <> binary_part(digest, 0, 40)
  end

  # A holder of the record's thread on the record's row whose
  # session is the record's generation or older is ended, and gone, before
  # the cleanup's own process starts there; one of a later generation is a
  # successor's, and one on another row holds no session of that row's
  # folder (an attendant starting over there after its brain found the
  # session gone), and the cleanup waits for either.
  defp retire({athanor_id, thread_id}, generation, row_id) do
    case whereis(athanor_id, thread_id) do
      nil ->
        :ok

      pid ->
        monitor = Process.monitor(pid)
        wait = Programs.Box.close_timeout_ms() + @answer_margin_ms

        case call(pid, {:forgotten, generation, row_id}, wait) do
          {:error, :successor} ->
            Process.demonitor(monitor, [:flush])
            {:error, :busy}

          _ended_or_gone ->
            receive do
              {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
            after
              wait -> {:error, :busy}
            end
        end
    end
  end

  defp holder(key) do
    case DynamicSupervisor.start_child(@holders, {__MODULE__, key}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, _pid}} -> {:error, :busy}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  # One command and its one answer on a new process of the driver: the
  # owner held, the session opened, the driver's `hello` read, the line
  # written, and the first event after it read as the answer. Anything
  # else of the driver's ends it unanswered.
  defp once(state, command, deadline) do
    with {:ok, line} <- encode(command),
         {:ok, seq} <- hello(state, deadline),
         :ok <- send_once(state, line),
         {:ok, _seq, event} <- next(state, seq, deadline) do
      answer(event, command)
    end
  end

  defp hello(state, deadline) do
    case next(state, 0, deadline) do
      {:ok, seq, %{"t" => "hello", "v" => v}} ->
        if v == Wire.version(), do: {:ok, seq}, else: {:error, :unreadable}

      {:ok, _seq, _not_hello} ->
        {:error, :unreadable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp answer(%{"t" => t, "id" => id} = event, %{"id" => id})
       when t in ["forgot", "models", "refused"],
       do: {:ok, event}

  defp answer(_event, _command), do: {:error, :unreadable}

  defp send_once(state, line) do
    case Session.send(state.grant, state.session, [line], @write_ms) do
      {:ok, :running} -> :ok
      {:ok, :ended} -> {:error, :lost}
      {:error, {:refused, code, _boot}} when code in @gone -> {:error, :lost}
      {:error, reason} -> if uncertain?(reason), do: {:error, :lost}, else: {:error, :not_written}
    end
  end

  # The next line of the session past `after_seq`, decoded, by `deadline`.
  defp next(state, after_seq, deadline) do
    wait = min(@recv_wait_ms, deadline - System.monotonic_time(:millisecond))

    if wait <= 0 do
      {:error, :lost}
    else
      case Session.recv(state.grant, state.session, after_seq, wait) do
        {:ok, %{dropped: dropped}} when dropped > 0 ->
          {:error, :lost}

        {:ok, %{lines: [%{seq: seq, text: text} | _rest]}} ->
          case Wire.decode(text) do
            {:ok, event} -> {:ok, seq, event}
            {:error, _unreadable} -> {:error, :unreadable}
          end

        {:ok, %{lines: [], running: false}} ->
          {:error, :lost}

        {:ok, %{lines: []}} ->
          next(state, after_seq, deadline)

        {:error, {:refused, code, _boot}} when code in @gone ->
          {:error, :lost}

        {:error, _unanswered} ->
          Process.sleep(@read_retry_ms)
          next(state, after_seq, deadline)
      end
    end
  end

  # ===========================================================================
  # The binding
  # ===========================================================================

  # Whether `binding` proves work a command of type `t` may be written
  # for, read from the store now (moduledoc), with the turn as read. The attendant's veto is
  # asked first, so every read of the store follows whatever it waited
  # on. Every read is scoped to the binding's athanor, so a turn, step,
  # call, thread or row of another athanor is not found.
  defp admitted(binding, t, opts \\ []) do
    actor = Sanctum.Context.actor(binding.ctx)
    user_id = binding.ctx.user_id

    with :ok <- veto(binding.admits?),
         :ok <- person(binding.ctx.athanor_id, user_id),
         {:ok, turn} <- read(Arca.TurnStorage.get(actor, binding.turn_id), :turn_not_found),
         :ok <- turn(turn, binding, user_id),
         :ok <- proof(turn.status, t, Keyword.get(opts, :running_only, false)),
         {:ok, step} <- read(Arca.TurnStorage.step(actor, binding.step), :step_not_found),
         :ok <- start_step(step, turn),
         :ok <- start_call(actor, step, turn, binding),
         {:ok, row} <-
           read(Arca.McpServerStorage.get_by_id(actor, binding.row_id), :row_not_found),
         :ok <- row(row, binding),
         {:ok, thread} <-
           read(Arca.ThreadStorage.get(actor, binding.thread_id), :thread_not_found),
         :ok <- generation(thread, binding) do
      {:ok, turn}
    else
      {:error, reason} -> {:error, {:not_admitted, reason}}
    end
  end

  defp person(athanor_id, user_id) when is_binary(athanor_id) and is_binary(user_id) do
    case Programs.stands(athanor_id, user_id) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :not_standing}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  defp person(_athanor_id, _user_id), do: {:error, :not_standing}

  defp read({:ok, found}, _not_found), do: {:ok, found}
  defp read({:error, :not_found}, not_found), do: {:error, not_found}
  defp read({:error, _unanswered}, _not_found), do: {:error, :unavailable}

  defp turn(turn, binding, user_id) do
    cond do
      turn.thread_id != binding.thread_id or turn.agent != binding.agent -> {:error, :wrong_turn}
      turn.requested_by != user_id -> {:error, :wrong_person}
      turn.origin != binding.origin -> {:error, :wrong_origin}
      turn.fence != binding.fence -> {:error, :superseded}
      true -> :ok
    end
  end

  # A running turn proves any delivery; a paused one only a post or an
  # answer of its own work, and none when the caller asks for a running
  # turn's proof alone.
  defp proof("running", _t, _running_only), do: :ok
  defp proof("paused", t, false) when t in ["post", "answer"], do: :ok
  defp proof("paused", _t, _running_only), do: {:error, :paused}
  defp proof(_over_or_accepted, _t, _running_only), do: {:error, :not_running}

  # The step that admitted the start: the turn's own `program.start`,
  # dispatched or closed as it ran, not denied, skipped or cancelled, and
  # not asked to stop (a Stop or a supersede marks it so).
  defp start_step(step, turn) do
    cond do
      step.turn_id != turn.id -> {:error, :wrong_step}
      step.tool != "program" or step.action != "start" -> {:error, :wrong_step}
      step.dispatch_state not in ["dispatched", "closed"] -> {:error, :not_decided}
      step.outcome not in [nil, "ok"] -> {:error, :not_allowed}
      step.cancel_requested_at != nil -> {:error, :stopped}
      true -> :ok
    end
  end

  defp row(row, binding) do
    cond do
      row.transport != "program" or row.mark != "driven" or row.home != "kept" ->
        {:error, :not_a_brain_row}

      Programs.Definition.browser?(row) ->
        {:error, :not_a_brain_row}

      row.enabled != true ->
        {:error, :disabled}

      row.epoch != binding.epoch ->
        {:error, :row_changed}

      true ->
        :ok
    end
  end

  # The call the step was recorded for, from its `tool_call` row: the
  # turn's own `program.start` of this row at this epoch.
  defp start_call(_actor, %{message_id: nil}, _turn, _binding), do: {:error, :wrong_step}

  defp start_call(actor, step, turn, binding) do
    with {:ok, message} <-
           read(Arca.ThreadStorage.get_message(actor, step.message_id), :wrong_step) do
      payload = Arca.ThreadStorage.payload(message)
      args = payload["arguments"]

      cond do
        message.kind != "tool_call" or message.turn_id != turn.id ->
          {:error, :wrong_step}

        payload["tool"] != "program" or payload["action"] != "start" or not is_map(args) ->
          {:error, :wrong_step}

        args["program"] != binding.row_id or args["epoch"] != binding.epoch ->
          {:error, :not_this_program}

        true ->
          :ok
      end
    end
  end

  defp generation(%{brain_generation: generation}, %{generation: generation}), do: :ok
  defp generation(_thread, _binding), do: {:error, :generation_moved}

  # The attendant's veto: it may withdraw, never prove.
  defp veto(admits?) when is_function(admits?, 0) do
    if admits?.() == true, do: :ok, else: {:error, :vetoed}
  end

  # ===========================================================================
  # The holder
  # ===========================================================================

  @doc false
  def start_link({_athanor_id, _thread_id} = key),
    do: GenServer.start_link(__MODULE__, key, name: {:via, Registry, {@registry, key}})

  @impl true
  def init({athanor_id, thread_id}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       athanor_id: athanor_id,
       thread_id: thread_id,
       agent: nil,
       ref: make_ref(),
       attendant: nil,
       owner: nil,
       grant: nil,
       session: nil,
       reader: nil,
       boot: nil,
       after: 0,
       applied: 0,
       handed: nil,
       outstanding: nil,
       harness: :none,
       starting: nil,
       config: nil,
       asks: %{},
       generation: nil
     }}
  end

  @impl true
  # The binding is read before the driver's session opens and again after
  # it, so one that went stale while the opener or the open waited opens
  # nothing. A take-over asked meanwhile waits in this holder's mailbox.
  def handle_call({:open, attendant, binding}, _from, %{attendant: nil} = state) do
    owner = %{athanor_id: state.athanor_id, server_id: binding.row_id, epoch: binding.epoch}

    state = %{state | owner: owner, generation: binding.generation, agent: binding.agent}

    with {:ok, _turn} <- admitted(binding, "start", running_only: true),
         {:ok, connected} <- connect(state) do
      case admitted(binding, "start", running_only: true) do
        {:ok, _turn} ->
          Process.monitor(attendant)
          {:reply, {:ok, {self(), connected.ref}}, %{connected | attendant: attendant}}

        {:error, reason} ->
          {:stop, :normal, {:error, reason}, connected}
      end
    else
      {:error, reason} -> {:stop, :normal, {:error, reason}, state}
    end
  end

  def handle_call({:open, _attendant, _binding}, _from, state),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:write, ref, binding, command, opts}, {pid, _tag}, %{ref: ref} = state) do
    cond do
      pid != state.attendant -> {:reply, {:error, :not_attached}, state}
      state.boot == nil or state.outstanding != nil -> {:reply, {:error, :busy}, state}
      true -> deliver(state, binding, command, opts)
    end
  end

  def handle_call({:write, _ref, _binding, _command, _opts}, _from, state),
    do: {:reply, {:error, :not_attached}, state}

  def handle_call({:close, ref}, _from, %{ref: ref} = state),
    do: {:stop, :normal, :ok, ended(state, :closed)}

  def handle_call({:close, _ref}, _from, state), do: {:reply, :ok, state}

  # A take-over ends this holder only for a binding that proves now, read
  # here, so nothing proves between the check and the end.
  def handle_call({:replace, binding}, _from, state) do
    case admitted(binding, "start", running_only: true) do
      {:ok, _turn} -> {:stop, :normal, :ok, ended(state, :replaced)}
      {:error, _reason} = refused -> {:reply, refused, state}
    end
  end

  # A session forgotten at `generation`, in the folder of `row_id` (nil
  # for any): this holder ends if the session it holds is of that
  # generation or older (one not yet started is) and runs on that row (or
  # on none yet), and runs on otherwise.
  def handle_call({:forgotten, generation, row_id}, _from, state) do
    if (state.generation == nil or state.generation <= generation) and
         (row_id == nil or state.owner == nil or state.owner.server_id == row_id),
       do: {:stop, :normal, :ok, ended(state, :forgotten)},
       else: {:reply, {:error, :successor}, state}
  end

  # A cleanup's `forget`, decided by the holder that owns the record's
  # key, before anything opens: the record is read again from the store,
  # still owed, and the thread again for a successor that holds its
  # session. A successor's open under the key waits for this holder to end
  # (`replace/2`), so none opens between this decision and the write; one
  # that opened, kept the session and ended before the key was taken is in
  # the thread read here.
  def handle_call({:forget, owner, record}, from, %{attendant: nil, owner: nil} = state) do
    actor = Prima.Actor.in_athanor(state.athanor_id)

    with {:ok, owed} <- owed(actor, record),
         :ok <- no_successor(actor, owed) do
      command = %{"t" => "forget", "id" => forget_id(record), "session" => owed["session"]}
      handle_call({:once, owner, command}, from, state)
    else
      {:error, reason} -> {:stop, :normal, {:error, reason}, state}
    end
  end

  def handle_call({:forget, _owner, _record}, _from, state), do: {:reply, {:error, :busy}, state}

  # A cleanup's or a discovery's one command, in a holder no attendant
  # opened: the owner held, a new process of the driver opened, the
  # command written after its hello and its answer read, and the holder
  # ends, its session closed on the way out (`terminate/2`).
  def handle_call({:once, owner, command}, _from, %{attendant: nil, owner: nil} = state) do
    deadline = System.monotonic_time(:millisecond) + @once_ms
    state = %{state | owner: owner}

    # Each refusal stops with the state that holds what was taken, so the
    # way out (`terminate/2`) gives back the owner a failed open held.
    case hold(state) do
      {:ok, held} ->
        case fresh(held, 1) do
          {:ok, session} ->
            opened = %{held | session: session}
            {:stop, :normal, once(opened, command, deadline), opened}

          {:error, reason} ->
            {:stop, :normal, {:error, reason}, held}
        end

      {:error, reason} ->
        {:stop, :normal, {:error, reason}, state}
    end
  end

  def handle_call({:once, _owner, _command}, _from, state), do: {:reply, {:error, :busy}, state}

  @impl true
  def handle_cast(
        {:read_on, ref, pid, boot, seq},
        %{ref: ref, attendant: pid, boot: boot} = state
      )
      when is_integer(state.handed) do
    after_seq = min(max(seq, state.after), state.handed)
    send(state.reader, {:go, after_seq})
    {:noreply, %{state | after: after_seq, handed: nil}}
  end

  def handle_cast({:read_on, _ref, _pid, _boot, _seq}, state), do: {:noreply, state}

  def handle_cast({:row_ended, athanor_id, row_id}, %{owner: %{server_id: row_id}} = state)
      when athanor_id == state.athanor_id,
      do: {:stop, :normal, ended(state, :row_changed)}

  def handle_cast({:row_ended, _athanor_id, _row_id}, state), do: {:noreply, state}

  @impl true
  def handle_info({:read, reader, answer}, %{reader: reader} = state), do: lines(state, answer)
  def handle_info({:read, _stale_reader, _answer}, state), do: {:noreply, state}

  def handle_info({:read_failed, reader, reason}, %{reader: reader} = state) do
    reason =
      case reason do
        {:refused, code, _boot} when code in @gone -> :exited
        _unanswered -> :unavailable
      end

    {:stop, :normal, ended(state, reason)}
  end

  def handle_info({:read_failed, _stale_reader, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, _monitor, :process, pid, _reason}, %{attendant: pid} = state),
    do: {:stop, :normal, %{state | attendant: nil}}

  def handle_info({Opus.Programs, :stand_down, _key}, state),
    do: {:stop, :normal, ended(state, :row_changed)}

  # A new grant means the box synced the owner again: the service the
  # session ran on is not the one it runs on now.
  def handle_info({Opus.Programs, :owner, _grant}, state),
    do: {:stop, :normal, ended(state, :exited)}

  def handle_info({:EXIT, reader, _reason}, %{reader: reader} = state),
    do: {:stop, :normal, ended(state, :unavailable)}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Prima.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  # The fast path: the box closes what a holder leaves however it ends.
  @impl true
  def terminate(_reason, state) do
    disconnect(state)
    :ok
  end

  # What the person posts and what the program says pass through here, in
  # its state, its messages and its replies, beside the grant's key: no
  # status, debug log or crash report prints a byte of any, each binary
  # showing its size alone.
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {key, value} when key in [:state, :message, :reason, :log] -> {key, scrub(value)}
      other -> other
    end)
  end

  defp scrub(binary) when is_binary(binary), do: "#{byte_size(binary)} bytes"
  defp scrub(%module{} = struct), do: {module, struct |> Map.from_struct() |> scrub()}
  defp scrub(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, scrub(value)} end)
  defp scrub([head | tail]), do: [scrub(head) | scrub(tail)]

  defp scrub(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> scrub() |> List.to_tuple()

  defp scrub(other), do: other

  # ---------------------------------------------------------------------------
  # The session

  # The owner is held for this process and a new process of the driver is
  # opened under the thread's key. One that was still running
  # (a close the box still owes) is closed and opened again, so every
  # holder speaks to a driver that has heard nothing.
  defp connect(state) do
    with {:ok, state} <- hold(state),
         {:ok, session} <- fresh(state, 1) do
      {:ok, read_from(%{state | session: session}, 0)}
    end
  end

  defp hold(%{grant: nil} = state) do
    with {:ok, grant} <- Programs.hold(state.owner), do: {:ok, %{state | grant: grant}}
  end

  defp hold(state), do: {:ok, state}

  defp fresh(state, tries) do
    deadline = System.system_time(:millisecond) + @open_ms

    params = %{
      program: Programs.Definition.program_name(),
      home_id: state.owner.server_id,
      key: key(state),
      mode: :run,
      argv: Programs.Words.new([])
    }

    case Programs.box_open(state.owner, self(), params, deadline) do
      {:ok, %{session: session, resumed: false}} ->
        {:ok, session}

      {:ok, %{resumed: true}} when tries > 0 ->
        _ = Programs.box_close(state.owner, state.owner.server_id, key(state))
        fresh(state, tries - 1)

      {:ok, %{resumed: true}} ->
        {:error, :unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The service's key of the thread's session.
  defp key(state) do
    digest = Prima.Digest.sha256_hex(state.thread_id)
    "brain-" <> binary_part(digest, 0, 40)
  end

  defp disconnect(state) do
    if state.reader, do: Process.exit(state.reader, :kill)

    if state.grant do
      if state.session, do: Programs.box_close(state.owner, state.owner.server_id, key(state))
      Programs.release(state.owner)
    end

    :ok
  end

  # A new process of the driver in the same holder: the last is closed,
  # and what it held is forgotten.
  defp restart(state) do
    if state.reader, do: Process.exit(state.reader, :kill)
    _ = Programs.box_close(state.owner, state.owner.server_id, key(state))
    state = reset(%{state | session: nil, reader: nil})

    case fresh(state, 1) do
      {:ok, session} -> {:ok, read_from(%{state | session: session}, 0)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reset(state) do
    %{
      state
      | boot: nil,
        after: 0,
        applied: 0,
        handed: nil,
        outstanding: nil,
        harness: :none,
        starting: nil,
        config: nil,
        asks: %{}
    }
  end

  defp read_from(state, after_seq) do
    holder = self()
    grant = state.grant
    session = state.session
    reader = spawn_link(fn -> reader(holder, grant, session, after_seq, 0) end)
    %{state | reader: reader}
  end

  # The reader: one read at a time, each past the last line the attendant
  # took, so a lost answer is read again by the same `after`, and the next
  # only once the holder says. A service that does not answer is asked
  # again each second for a minute.
  defp reader(holder, grant, session, after_seq, failures) do
    case Session.recv(grant, session, after_seq, @recv_wait_ms) do
      {:ok, answer} ->
        send(holder, {:read, self(), answer})

        receive do
          {:go, after_seq} -> reader(holder, grant, session, after_seq, 0)
        end

      {:error, {:refused, _code, _boot} = refused} ->
        send(holder, {:read_failed, self(), refused})

      {:error, reason} when failures >= @read_retries ->
        send(holder, {:read_failed, self(), reason})

      {:error, _unanswered} ->
        Process.sleep(@read_retry_ms)
        reader(holder, grant, session, after_seq, failures + 1)
    end
  end

  # ---------------------------------------------------------------------------
  # Lines

  defp lines(state, %{dropped: dropped}) when dropped > 0,
    do: {:stop, :normal, ended(state, :dropped)}

  defp lines(state, %{lines: [], running: false}), do: {:stop, :normal, ended(state, :exited)}

  # Nothing came within the wait: read on from the same place.
  defp lines(state, %{lines: []}) do
    send(state.reader, {:go, state.after})
    {:noreply, state}
  end

  defp lines(state, %{lines: lines}) do
    case decode(lines, state, []) do
      {:ok, events, state} ->
        last = elem(List.last(events), 0)
        send(state.attendant, {__MODULE__, state.ref, {:lines, state.boot, events}})
        {:noreply, %{state | handed: last}}

      {:error, reason, state} ->
        {:stop, :normal, ended(state, reason)}
    end
  end

  defp decode([], state, events), do: {:ok, Enum.reverse(events), state}

  defp decode([%{seq: seq, text: text} | rest], state, events) do
    with {:ok, event} <- Wire.decode(text),
         {:ok, applied} <- apply_event(state, seq, event) do
      decode(rest, applied, [{seq, event} | events])
    else
      {:error, :too_large} -> {:error, :too_large, state}
      {:error, _unreadable_or_unknown} -> {:error, :unreadable, state}
    end
  end

  # What the holder keeps of an event, once: the driver's boot from its
  # hello, which is the session's first line and its only one; the
  # answer to the command it waits on; and the asks it may answer. A line
  # read again after the attendant asked for it again changes nothing.
  defp apply_event(state, seq, _event) when seq <= state.applied, do: {:ok, state}

  defp apply_event(%{boot: nil} = state, seq, %{"t" => "hello", "v" => v, "boot" => boot}) do
    if v == Wire.version(),
      do: {:ok, %{state | boot: boot, applied: seq}},
      else: {:error, :unreadable}
  end

  defp apply_event(%{boot: nil}, _seq, _not_hello), do: {:error, :unreadable}
  defp apply_event(_state, _seq, %{"t" => "hello"}), do: {:error, :unreadable}

  defp apply_event(state, seq, event), do: {:ok, %{answered(state, event) | applied: seq}}

  defp answered(%{outstanding: {"start", _}} = state, %{"t" => "started"}),
    do: %{state | outstanding: nil, harness: :started, config: state.starting, starting: nil}

  defp answered(%{outstanding: {"start", _}} = state, %{"t" => "gone"}),
    do: %{state | outstanding: nil, harness: :none, starting: nil}

  defp answered(%{outstanding: {_t, id}} = state, %{"t" => t, "id" => id})
       when t in ["accepted", "refused"],
       do: %{state | outstanding: nil}

  defp answered(state, %{"t" => "ask", "ask" => ask} = event),
    do: %{state | asks: Map.put(state.asks, ask, Map.get(event, "work"))}

  defp answered(state, _event), do: state

  # ---------------------------------------------------------------------------
  # Writing

  # Neither path no turn admits is a delivery: nothing a binding proves
  # writes either.
  defp deliver(state, _binding, %{"t" => t}, _opts) when t in ["models", "forget"],
    do: {:reply, {:error, :not_a_delivery}, state}

  defp deliver(state, binding, %{"t" => t} = command, opts) when is_binary(t) do
    with :ok <- this_place(state, binding),
         :ok <- in_turn(state, binding, command),
         {:ok, turn} <- admitted(binding, t),
         command = held(command, turn),
         {:ok, line} <- encode(command) do
      if t == "work" and Keyword.has_key?(opts, :config) and
           state.config != held_config(opts[:config], turn),
         do: restarted(state),
         else: send_line(state, command, line)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp deliver(state, _binding, _command, _opts), do: {:reply, {:error, :unreadable}, state}

  # A start's configuration as the holder sets it from the turn it is
  # admitted for (moduledoc, "Writing").
  defp held(%{"t" => "start"} = command, turn),
    do: Map.put(command, "config", held_config(command["config"], turn))

  defp held(command, _turn), do: command

  # The configuration's `read_only` is the turn's stored mode, whatever
  # the caller named; a read-only one carries none of the harness's own
  # permission mode or tools, which the driver refuses beside it.
  defp held_config(config, %{agent_mode: "read-only"}) do
    (config || %{})
    |> Map.drop(["permission_mode", "harness_tools"])
    |> Map.put("read_only", true)
  end

  defp held_config(config, _auto), do: Map.put(config || %{}, "read_only", false)

  # A binding is of this holder's athanor, thread and row, and of the
  # agent whose work opened it.
  defp this_place(state, binding) do
    if binding.ctx.athanor_id == state.athanor_id and binding.thread_id == state.thread_id and
         binding.agent == state.agent and binding.row_id == state.owner.server_id and
         binding.epoch == state.owner.epoch,
       do: :ok,
       else: {:error, {:not_admitted, :wrong_place}}
  end

  defp encode(command) do
    case Wire.encode(command) do
      {:ok, line} -> {:ok, line}
      {:error, _refusal} -> {:error, :unreadable}
    end
  end

  # A command fits what the session holds now: a start only while no
  # harness runs and of the binding's session generation, every delivery
  # once one does, a work and a post of the binding's turn, an answer to an
  # ask shown for it and not yet answered.
  defp in_turn(%{harness: harness}, _binding, %{"t" => "start"}) when harness != :none,
    do: {:error, :running}

  defp in_turn(_state, binding, %{"t" => "start", "gen" => gen}),
    do: if(gen == binding.generation, do: :ok, else: {:error, :not_this_generation})

  defp in_turn(%{harness: harness}, _binding, _delivery) when harness != :started,
    do: {:error, :not_started}

  defp in_turn(_state, binding, %{"t" => t, "work" => work}) when t in ["work", "post"],
    do: if(work == binding.turn_id, do: :ok, else: {:error, :not_this_work})

  defp in_turn(state, binding, %{"t" => "answer", "ask" => ask}) do
    case state.asks do
      %{^ask => work} when work == binding.turn_id -> :ok
      _not_shown_answered_or_another_work -> {:error, :not_this_work}
    end
  end

  defp in_turn(_state, _binding, _not_a_delivery), do: {:error, :unreadable}

  defp restarted(state) do
    case restart(state) do
      {:ok, state} -> {:reply, {:ok, :restarted}, state}
      {:error, reason} -> {:stop, :normal, {:error, reason}, ended(state, :unavailable)}
    end
  end

  defp send_line(state, command, line) do
    case Session.send(state.grant, state.session, [line], @write_ms) do
      {:ok, :running} ->
        {:reply, :ok, written(state, command)}

      {:ok, :ended} ->
        {:stop, :normal, {:error, :ended}, ended(state, :exited)}

      {:error, {:refused, code, _boot}} when code in @gone ->
        {:stop, :normal, {:error, :ended}, ended(state, :exited)}

      {:error, reason} ->
        if uncertain?(reason),
          do: {:stop, :normal, {:error, :uncertain}, ended(state, :interrupted)},
          else: {:stop, :normal, {:error, :not_written}, ended(state, :exited)}
    end
  end

  # A send whose answer did not arrive, did not read, or says the service
  # failed inside, may follow its writing.
  defp uncertain?(reason) when reason in @uncertain, do: true
  defp uncertain?({:unreadable, _error}), do: true
  defp uncertain?({:refused, :internal, _boot}), do: true
  defp uncertain?(_refused_before_writing), do: false

  defp written(state, %{"t" => "start"} = command),
    do: %{
      state
      | outstanding: {"start", nil},
        harness: :starting,
        starting: command["config"],
        generation: command["gen"]
    }

  defp written(state, %{"t" => "answer", "id" => id, "ask" => ask}),
    do: %{state | outstanding: {"answer", id}, asks: Map.delete(state.asks, ask)}

  defp written(state, %{"t" => t, "id" => id}), do: %{state | outstanding: {t, id}}

  # The attendant is told once how the session ended.
  defp ended(%{attendant: pid} = state, reason) when is_pid(pid) do
    send(pid, {__MODULE__, state.ref, {:ended, reason}})
    %{state | attendant: nil}
  end

  defp ended(state, _reason), do: state
end
