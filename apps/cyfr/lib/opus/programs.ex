# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs do
  @moduledoc """
  The programs controller: what the backends service runs, its sessions and
  its kept homes. Programs are the `mcp_servers` rows whose transport is
  `program`, marked `mcp` (Emissary speaks MCP to them) or `driven` (a
  person or a brain drives them).

  It is shaped per box: one `Opus.Programs.Box` per backends service, each
  with its own owner table and lease loop, found by name in this
  supervisor's registry. The local box, named by `.env`
  (`CYFR_LOCUS_BACKENDS_URL` and `CYFR_LOCUS_BACKENDS_KEY`, which the
  composition root reads and passes down), is the only one, and every row
  runs on it. With no URL or key, or while `CYFR_CLUSTER` is on, there is no
  box: `running?/0` is false and every call is refused
  `:backends_not_configured`.

  ## Owners and holders

  `hold/1` asks the box to run a row's owner for the calling process, its
  holder, and answers the grant the holder speaks over the session routes
  with (`Opus.Programs.Session`). An owner lives while one of its holders
  does; `release/1`, or the holder's exit, lets it go. A holder hears
  `{Opus.Programs, :owner, grant}` when the box synced the owner again
  (the service restarted, or this member's generation moved), and
  `{Opus.Programs, :stand_down, {athanor_id, server_id}}` when the owner is
  not its to use any more (the claim moved to a peer, the row changed, the
  service forgot it): it stops using the grant and stops itself.

  ## Kept homes

  A program row with a kept home has one folder, its own: the home's id is
  the row's id, made with the row and retired with it. `home/3` resets a
  row's kept home (every session in it ends and it is made again empty
  under the same uid) or retires it (its sessions end, the home is removed
  and its uid freed). The box that holds a home drew its uid; CYFR never
  learns it. A retire is retried until the box acknowledges it. Either way
  the brain sessions threads kept for the home are forgotten, so a member
  whose brain ran there starts a new one.

  ## Pipes

  `pipe_open/5` opens, for an attempt of a catalyst whose login need the
  caller resolved (`Opus.Host.Pipe`), a `run` session of a program row in
  the row's kept home under a key, held by an `Opus.Programs.Pipe` process
  that belongs to the row and the key, never to the attempt: a later
  attempt opening the same key attaches to the session while its program
  runs. `pipe_send/5`, `pipe_recv/6` and `pipe_close/4` carry it for an
  attempt that opened it, each in the caller's process. A session no
  attempt uses for the box's idle period ends, and so does every session
  of a row that is deleted (`end_mounts/2`).

  ## Terminals

  `start/3` runs a program row's command, with the words a person typed
  after it, on a terminal of the service's, as a session that belongs to
  the caller's athanor and person and to no page or browser credential
  (`Opus.Programs.Terminal`). Any of that person's surfaces attaches to
  it (`attach/2`), types on it (`input/3`), resizes it (`resize/4`),
  keeps it past a day unwatched (`keep/3`), detaches (`detach/2`, which
  ends nothing) or closes it (`close/2`); `running/1` lists the person's
  sessions, and `Cyfr.Bus.programs/2` announces every change of that
  list. Each call takes the caller's context and is refused when the
  caller no longer stands. A session is reached only by its person at a
  screen, as the gate reads an interactive caller: another person, and a
  caller that is no person at a screen (a key), find no session, whatever
  its state, and none to list or start.
  """

  use Supervisor

  alias Opus.Programs.{Box, Pipe, Session, Terminal}

  @registry Opus.Programs.Registry
  # The refusals of a session route that say its owner, and so its
  # session, is not on the service any more.
  @stale [:stale_boot, :epoch_ahead, :unknown_owner, :lapsed]
  @ended %{lines: [], dropped: 0, running: false}
  # The margin an open's holder needs to answer past the deadline that it
  # passed.
  @answer_margin_ms 1_000
  @relays Opus.Programs.Relays
  # How long a terminal's start waits for the service to run it.
  @start_ms 60_000
  @local "local"

  @typedoc "One program row of one athanor at one epoch."
  @type owner :: Box.owner()

  @typedoc "What a holder signs its session messages with."
  @type grant :: Box.grant()

  @doc """
  Start the controller. Options, from the composition root: `:url` and
  `:root` (the local box's service URL and 32-byte key) and `:cluster`
  (true: no box). With either of the first two absent or invalid the local
  box's start answers `:ignore` and there is no box. The registry comes
  first, then the supervisor of pipe holders and terminals, then the box: a box that dies restarts
  alone, and its holders, refused by the service once its lease lapses,
  hold their owners again.
  """
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: @registry},
        {DynamicSupervisor, name: @relays, strategy: :one_for_one},
        box_child(local_box(opts))
      ],
      strategy: :rest_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end

  # The local box is always a child; its start answers `:ignore` when no
  # service is configured, or while this boot runs as a cluster.
  defp local_box(opts) do
    if Keyword.get(opts, :cluster, false) == true,
      do: [box: @local, url: nil, root: nil],
      else: [box: @local, url: Keyword.get(opts, :url), root: Keyword.get(opts, :root)]
  end

  defp box_child(opts) do
    box = Keyword.fetch!(opts, :box)
    Supervisor.child_spec({Box, Keyword.put(opts, :name, via(box))}, shutdown: 5_000)
  end

  @doc "The name a box registers under."
  @spec via(String.t()) :: {:via, Registry, {atom(), term()}}
  def via(box), do: {:via, Registry, {@registry, {:box, box}}}

  @doc "The name of the local box, the only one."
  @spec local() :: String.t()
  def local, do: @local

  @doc "Whether a box runs on this boot: the backends service is configured."
  @spec running?() :: boolean()
  def running?, do: box_pid(@local) != nil

  defp box_pid(box) do
    if Process.whereis(@registry) do
      case Registry.lookup(@registry, {:box, box}) do
        [{pid, _}] -> pid
        [] -> nil
      end
    end
  end

  # Every row runs on the local box; F7 adds a box to the row.
  defp box_of(_athanor_id), do: @local

  @doc """
  Ask the box to run `owner` for the calling process, its holder, and answer
  its grant once the service admitted the sync. Refused with a reason when
  another member of the cell holds the owner's claim (`:claimed_elsewhere`)
  or the claim row cannot be read (`:claim_unavailable`), when the row no
  longer passes the fence, an env template does not resolve or names an
  attach-only entry (`:disclosure_refused`), the athanor would define more
  than its share of the pool, this member does not hold its slot in the
  cell (`:control_plane_lost`), or the service cannot be reached.
  """
  @spec hold(owner(), pos_integer()) :: {:ok, grant()} | {:error, term()}
  def hold(owner, timeout_ms \\ Box.hold_timeout_ms()),
    do: call(box_of(owner.athanor_id), {:hold, owner, self()}, timeout_ms)

  @doc """
  The calling holder holds `owner` no more; the last holder's release
  releases it on the service. Answers once the service acknowledged it or
  the attempt failed, within 3 s either way.
  """
  @spec release(owner()) :: :ok
  def release(owner) do
    _ = call(box_of(owner.athanor_id), {:release, owner}, Box.release_timeout_ms())
    :ok
  end

  @doc """
  The service's status of one owner — version, lease and programs, as the
  wire names them, with string keys — or nil when it runs none.
  """
  @spec status(String.t(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def status(athanor_id, server_id),
    do: call(box_of(athanor_id), {:status, {athanor_id, server_id}}, Box.control_timeout_ms())

  @doc """
  Release at once, without reading the store, every live owner of the
  athanor whose env templates reference one of `names` (`:any`: any entry),
  its holders told to stand down. Answers the server ids released.
  """
  @spec release_referencing(String.t(), [String.t()] | :any) :: [String.t()]
  def release_referencing(athanor_id, names) do
    case call(box_of(athanor_id), {:release_referencing, athanor_id, names}, 10_000) do
      ids when is_list(ids) -> ids
      {:error, _} -> []
    end
  end

  @doc "Report a service boot id a holder saw, so a restarted service is greeted."
  @spec boot_seen(String.t()) :: :ok
  def boot_seen(boot) when is_binary(boot) do
    case box_pid(@local) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:boot_seen, boot})
    end
  end

  @doc """
  Reset (`:reset`) or retire (`:retire`) the kept home of the athanor's
  program row `row_id`. Answers `:ok` once the box acknowledged it; a retire that could
  not be sent is answered with the reason and stays pending, sent again on
  every tick until it lands.

  Whatever the box answered, the brain session kept on each thread of an
  agent whose head binds the row (`Sanctum.Mount.agents_mounting/2`) is
  forgotten, so its next
  message starts a new session rather than resuming one the home no
  longer holds. A store that cannot forget them turns an `:ok` into
  `{:error, {:unavailable, "Threads"}}`.
  """
  @spec home(String.t(), String.t(), :reset | :retire) :: :ok | {:error, term()}
  def home(athanor_id, row_id, op) when op in [:reset, :retire] do
    answer = call(box_of(athanor_id), {:home, athanor_id, row_id, op}, Box.control_timeout_ms())

    case {answer, forget_sessions(athanor_id, row_id)} do
      {:ok, {:error, _unanswered}} -> {:error, {:unavailable, "Threads"}}
      _forgotten_or_refused -> answer
    end
  end

  defp forget_sessions(athanor_id, row_id) do
    with {:ok, agents} <- Sanctum.Mount.agents_mounting(athanor_id, row_id),
         {:ok, _forgotten} <-
           Arca.ThreadStorage.forget_sessions(Prima.Actor.in_athanor(athanor_id), agents) do
      :ok
    end
  end

  @doc "The ids of every kept home the box holds, as its `homes` answer names them."
  @spec homes() :: {:ok, [String.t()]} | {:error, term()}
  def homes, do: call(@local, :homes, Box.control_timeout_ms())

  defp call(box, message, timeout) do
    case box_pid(box) do
      nil -> {:error, :backends_not_configured}
      pid -> GenServer.call(pid, message, timeout)
    end
  catch
    :exit, _ -> {:error, :backends_unavailable}
  end

  # ============================================================================
  # A row's sessions
  # ============================================================================

  @doc """
  End every running terminal and pipe session of the athanor's program row
  `row_id`: the row was changed or deleted, so nothing runs as it was
  defined any more. Answers at once; each terminal ends `:row_changed`, and
  each pipe holder closes its session and releases its owner.
  """
  @spec end_mounts(String.t(), String.t()) :: :ok
  def end_mounts(athanor_id, row_id) when is_binary(athanor_id) and is_binary(row_id) do
    if Process.whereis(@relays) do
      for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(@relays),
          is_pid(pid),
          do: GenServer.cast(pid, {:row_ended, athanor_id, row_id})
    end

    :ok
  end

  # ============================================================================
  # Terminals
  # ============================================================================

  @typedoc "Why a terminal session ended (`Opus.Programs.Terminal`)."
  @type ended :: :exited | :closed | :idle | :row_changed | :standing

  @typedoc "One of the person's running sessions, as `running/1` answers it."
  @type running :: %{
          session: String.t(),
          row_id: String.t(),
          name: String.t(),
          started_at: DateTime.t(),
          kept: boolean(),
          attached: boolean(),
          by: :person | :aqua
        }

  @doc """
  Start the program row `row_id` of the caller's athanor on a terminal of
  `rows` by `cols`, its pinned command followed by `args`, as a session
  that belongs to the caller's athanor and person
  (`Opus.Programs.Terminal`), started `by` the person or by Aqua. The
  row must be an enabled program; `args` are at most
  #{Prima.LocusBackends.max_argv()} words a person typed, each a string of
  at most 4096 bytes without a NUL, and never anything resolved from a
  vault. Answers the session's id once the service runs it, by
  `deadline` (Unix milliseconds, #{div(60_000, 1000)} s from now unless
  given): past it the start is refused `:deadline`, the box closes
  whatever the service answers later, and a new start can be made at
  once. Refused `:not_standing` (or `:unavailable`) for a caller who does
  not stand, `:not_found`, `:not_a_program` or `:disabled` for the row,
  `:invalid_size` or `:invalid_args` for the rest, and as `hold/2` and
  the session route refuse.
  """
  @spec start(Sanctum.Context.t(), String.t(), %{
          required(:rows) => pos_integer(),
          required(:cols) => pos_integer(),
          required(:args) => [String.t()],
          required(:by) => :person | :aqua,
          optional(:deadline) => integer()
        }) :: {:ok, String.t()} | {:error, term()}
  def start(
        %Sanctum.Context{} = ctx,
        row_id,
        %{rows: rows, cols: cols, args: args, by: by} = opts
      )
      when is_binary(row_id) and by in [:person, :aqua] do
    with {:ok, {athanor_id, user_id} = person} <- person(ctx) |> no_stranger(),
         :ok <- size(rows, cols),
         :ok <- args(args),
         {:ok, row} <- program_row(ctx, row_id) do
      id = "trm_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

      spec = [
        name: terminal_name(id, person),
        id: id,
        athanor_id: athanor_id,
        user_id: user_id,
        row_id: row.id,
        row_name: row.name,
        home_id: if(row.home == "kept", do: row.id),
        owner: %{athanor_id: row.athanor_id, server_id: row.id, epoch: row.epoch},
        argv: args,
        by: by,
        rows: rows,
        cols: cols
      ]

      deadline = Map.get(opts, :deadline, System.system_time(:millisecond) + @start_ms)
      wait = max(deadline - System.system_time(:millisecond), 0) + @answer_margin_ms

      case DynamicSupervisor.start_child(@relays, {Terminal, spec}) do
        {:ok, pid} -> GenServer.call(pid, {:open, deadline}, wait)
        {:error, reason} -> {:error, reason}
      end
    end
  catch
    :exit, {:timeout, _} -> {:error, :deadline}
    :exit, _ -> {:error, :backends_unavailable}
  end

  @doc """
  Attach the calling process to the caller's session `session_id`:
  answered the last of its output (an `Opus.Programs.Output`), the
  terminal's size and whether it is kept, after which the process
  receives `{Opus.Programs, session_id, {:bytes, output}}`, each output
  an `Opus.Programs.Output`, and `{Opus.Programs, session_id, {:ended,
  reason}}` once (`t:ended/0`). Attaching again is attaching once.
  `{:error, :not_found}` for a session that is not running or not the
  caller's person's.
  """
  @spec attach(Sanctum.Context.t(), String.t()) ::
          {:ok,
           %{
             tail: Opus.Programs.Output.t(),
             rows: pos_integer(),
             cols: pos_integer(),
             kept: boolean()
           }}
          | {:error, term()}
  def attach(%Sanctum.Context{} = ctx, session_id),
    do: terminal_call(ctx, session_id, &{:attach, &1, self()})

  @doc "Detach the calling process from the session; it ends nothing and answers `:ok`."
  @spec detach(Sanctum.Context.t(), String.t()) :: :ok
  def detach(%Sanctum.Context{} = ctx, session_id) do
    _ = terminal_call(ctx, session_id, &{:detach, &1, self()})
    :ok
  end

  @doc """
  Type `bytes` on the session's terminal, as they are. `{:error, :ended}`
  once its program no longer runs, `{:error, :unavailable}` when the
  service did not take them.
  """
  @spec input(Sanctum.Context.t(), String.t(), binary()) :: :ok | {:error, term()}
  def input(%Sanctum.Context{}, _session_id, ""), do: :ok

  def input(%Sanctum.Context{} = ctx, session_id, bytes) when is_binary(bytes) do
    with {:ok, grant, session} <- terminal_call(ctx, session_id, &{:use, &1}) do
      bytes
      |> chunks(Prima.LocusBackends.max_chunk_bytes())
      |> Enum.reduce_while(:ok, fn chunk, :ok ->
        case typed(Session.input(grant, session, chunk)) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc "Set the session's terminal to `rows` by `cols`; its program is signalled the change."
  @spec resize(Sanctum.Context.t(), String.t(), pos_integer(), pos_integer()) ::
          :ok | {:error, term()}
  def resize(%Sanctum.Context{} = ctx, session_id, rows, cols) do
    with :ok <- size(rows, cols),
         {:ok, grant, session} <- terminal_call(ctx, session_id, &{:resize, &1, rows, cols}),
         do: typed(Session.resize(grant, session, rows, cols))
  end

  @doc """
  Mark the session kept (`true`), so a day with nothing attached and
  nothing printed does not end it, or not (`false`).
  """
  @spec keep(Sanctum.Context.t(), String.t(), boolean()) :: :ok | {:error, term()}
  def keep(%Sanctum.Context{} = ctx, session_id, kept) when is_boolean(kept),
    do: terminal_call(ctx, session_id, &{:keep, &1, kept})

  @doc """
  End the caller's session `session_id`, carried out whether or not the
  caller waits for it: `{:ok, :closed}` once the service confirmed it,
  `{:ok, :already_gone}` for a session that is not running (or not the
  caller's person's), and `{:error, :unanswered}` when the service did not
  confirm it in time, the box still owing the close. The session ends
  `:closed` either way.
  """
  @spec close(Sanctum.Context.t(), String.t()) ::
          {:ok, :closed | :already_gone} | {:error, :unanswered | term()}
  def close(%Sanctum.Context{} = ctx, session_id) do
    with {:ok, person} <- person(ctx) do
      case terminal_pid(session_id, person) do
        nil -> {:ok, :already_gone}
        pid -> GenServer.call(pid, {:close, person}, Box.close_timeout_ms() + @answer_margin_ms)
      end
    end
  catch
    :exit, {:timeout, _} -> {:error, :unanswered}
    :exit, _ -> {:ok, :already_gone}
  end

  @doc "The caller's person's running sessions in the caller's athanor, oldest first."
  @spec running(Sanctum.Context.t()) :: {:ok, [running()]} | {:error, term()}
  def running(%Sanctum.Context{} = ctx) do
    with {:ok, person} <- person(ctx) do
      pids =
        if Process.whereis(@registry),
          do: Registry.select(@registry, [{{{:terminal, :_}, :"$1", person}, [], [:"$1"]}]),
          else: []

      summaries =
        for pid <- pids, {:ok, summary} <- [summary(pid, person)], do: summary

      {:ok, Enum.sort_by(summaries, & &1.started_at, DateTime)}
    end
  end

  defp summary(pid, person) do
    GenServer.call(pid, {:summary, person}, 5_000)
  catch
    :exit, _ -> {:error, :not_found}
  end

  # The person a session may belong to: the caller stands now (a context
  # validated within the caller bound is used as it is, and any other is
  # read again from the store, `Sanctum.Caller.revalidate_session/1`, as a
  # page's guard does), and is that person at a screen, as the gate reads
  # an interactive caller (`Sanctum.Consent.authorize_interactive/1`). A
  # caller who stands but is no person at a screen, a key among them, is
  # answered as a stranger is: `:stranger`, which finds no session.
  defp person(%Sanctum.Context{athanor_id: athanor_id} = ctx) do
    current =
      if Sanctum.Caller.fresh?(ctx), do: {:ok, ctx}, else: Sanctum.Caller.revalidate_session(ctx)

    case current do
      {:ok, %{authenticated: true, athanor_id: ^athanor_id, user_id: user_id} = current}
      when is_binary(athanor_id) and athanor_id != "" and is_binary(user_id) and user_id != "" ->
        case Sanctum.Consent.authorize_interactive(current) do
          {:ok, :interactive} -> {:ok, {athanor_id, user_id}}
          {:error, _not_at_a_screen} -> {:ok, :stranger}
        end

      {:error, :unavailable} ->
        {:error, :unavailable}

      _not_standing ->
        {:error, :not_standing}
    end
  end

  defp no_stranger({:ok, :stranger}), do: {:error, :not_found}
  defp no_stranger(answer), do: answer

  defp terminal_call(ctx, session_id, message) when is_binary(session_id) do
    with {:ok, person} <- person(ctx) do
      case terminal_pid(session_id, person) do
        nil -> {:error, :not_found}
        pid -> GenServer.call(pid, message.(person), 5_000)
      end
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  defp terminal_name(id, person), do: {:via, Registry, {@registry, {:terminal, id}, person}}

  # The session's process, when it is `person`'s: whose it is is read from
  # the registry, beside its name, before the process is asked anything,
  # so a stranger's answer never depends on the session's state.
  defp terminal_pid(session_id, {_athanor_id, _user_id} = person) when is_binary(session_id) do
    if Process.whereis(@registry) do
      case Registry.lookup(@registry, {:terminal, session_id}) do
        [{pid, ^person}] -> pid
        _none_or_another -> nil
      end
    end
  end

  defp terminal_pid(_session_id, _stranger), do: nil

  defp program_row(ctx, row_id) do
    case Arca.McpServerStorage.get_by_id(Sanctum.Context.actor(ctx), row_id) do
      {:ok, %{transport: "program", enabled: true} = row} -> {:ok, row}
      {:ok, %{transport: "program"}} -> {:error, :disabled}
      {:ok, _not_a_program} -> {:error, :not_a_program}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp size(rows, cols) do
    max = Prima.KeeperProtocol.max_pty_size()

    if is_integer(rows) and is_integer(cols) and rows in 1..max//1 and cols in 1..max//1,
      do: :ok,
      else: {:error, :invalid_size}
  end

  defp args(args) when is_list(args) do
    if length(args) <= Prima.LocusBackends.max_argv() and Enum.all?(args, &arg?/1),
      do: :ok,
      else: {:error, :invalid_args}
  end

  defp args(_args), do: {:error, :invalid_args}

  defp arg?(arg),
    do:
      is_binary(arg) and byte_size(arg) <= 4096 and String.valid?(arg) and
        not String.contains?(arg, <<0>>)

  defp chunks(bytes, size) when byte_size(bytes) <= size, do: [bytes]

  defp chunks(bytes, size),
    do: [
      binary_part(bytes, 0, size)
      | chunks(binary_part(bytes, size, byte_size(bytes) - size), size)
    ]

  # What a write to a terminal answered.
  defp typed({:ok, :running}), do: :ok
  defp typed({:ok, :ended}), do: {:error, :ended}

  defp typed({:error, {:refused, code, _boot}}) when code in [:unknown_session | @stale],
    do: {:error, :ended}

  defp typed({:error, _unanswered}), do: {:error, :unavailable}

  # ============================================================================
  # Pipes
  # ============================================================================

  @doc """
  Open, for the attempt `opener`, the `run` session of the program row
  `row` (a stored `mcp_servers` program row with a kept home) in its kept
  home under `key`, starting its program with `argv` appended unless it
  runs for the key. Answers the session and whether it
  was running (`resumed`); a repeat by the same opener while the session
  is the same answers as the first did. Everything, the owner's
  acquisition and a retry included, fits `deadline` (Unix milliseconds):
  past it the open answers
  `{:error, :deadline}` and leaves nothing it started open. Refused
  otherwise as `hold/2` and the session route refuse.
  """
  @spec pipe_open(map(), String.t(), [String.t()], String.t(), integer()) ::
          {:ok, %{session: String.t(), resumed: boolean()}} | {:error, term()}
  def pipe_open(row, key, argv, opener, deadline)
      when is_binary(key) and is_list(argv) and is_binary(opener) and is_integer(deadline) do
    pipe_open(row, key, argv, opener, deadline, 1)
  end

  # A holder that ended as it was found (its idle period ran out) is
  # started afresh, once. The call is awaited past the deadline by the
  # margin the holder needs to answer that it passed.
  defp pipe_open(row, key, argv, opener, deadline, tries) do
    with {:ok, pid} <- pipe_holder(row, key) do
      wait = max(deadline - System.system_time(:millisecond), 0) + @answer_margin_ms
      GenServer.call(pid, {:open, opener, argv, deadline}, wait)
    end
  catch
    :exit, {reason, _} when reason in [:noproc, :normal] and tries > 0 ->
      pipe_open(row, key, argv, opener, deadline, tries - 1)

    :exit, {:timeout, _} ->
      {:error, :deadline}

    :exit, _ ->
      {:error, :backends_unavailable}
  end

  defp left(deadline), do: max(deadline - System.system_time(:millisecond), 1)

  defp pipe_holder(row, key) do
    owner = %{athanor_id: row.athanor_id, server_id: row.id, epoch: row.epoch}

    args = [
      name:
        {:via, Registry,
         {@registry, {:pipe, owner.athanor_id, owner.server_id, owner.epoch, key}}},
      owner: owner,
      key: key
    ]

    case DynamicSupervisor.start_child(@relays, {Pipe, args}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, {:shutdown, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _ -> {:error, :backends_not_configured}
  end

  @doc """
  The box's open of a session for the holder `holder` of `owner` (a pipe,
  `Opus.Programs.Pipe`, or a terminal, `Opus.Programs.Terminal`), with
  `params` (`program`, `home_id`, `key`, `argv`, and a terminal's `mode`,
  `rows` and `cols`): recorded in the box before the backend is asked, so whatever
  the backend answers under the key is the box's, and answered by
  `deadline` (Unix milliseconds). Answers the session the box gave the
  key, `{:error, :deadline}` past it, or the refusal.
  """
  @spec box_open(map(), pid(), map(), integer()) ::
          {:ok, %{session: String.t(), resumed: boolean()}} | {:error, term()}
  def box_open(owner, holder, params, deadline) do
    wait = max(deadline - System.system_time(:millisecond), 0) + @answer_margin_ms

    case call(box_of(owner.athanor_id), {:session_open, owner, holder, params, deadline}, wait) do
      {:error, :backends_unavailable} -> {:error, :deadline}
      answer -> answer
    end
  end

  @doc """
  The calling holder's key's session ends: the box closes it, and owes the
  close until the backend confirms it. Answers `:ok` once the backend has
  confirmed the close (or nothing of the session runs), and
  `{:error, :unanswered}` when it did not or the close window passed, the
  close still owed; either way only then, so the holder's release of the
  owner after it never outruns it.
  """
  @spec box_close(map(), String.t() | nil, String.t()) :: :ok | {:error, :unanswered}
  def box_close(owner, home_id, key) do
    case call(
           box_of(owner.athanor_id),
           {:session_close, owner, home_id, key},
           Box.close_timeout_ms()
         ) do
      :ok -> :ok
      {:error, _unanswered} -> {:error, :unanswered}
    end
  end

  @doc """
  Write `lines` to the pipe session `session` of the athanor, for the
  attempt `opener` that opened it, within `deadline` (as `pipe_open/6`'s).
  `{:error, :ended}` once its program no longer runs, or when no holder
  holds the session any more; `{:error, :denied}` for a session the opener
  did not open; `{:error, :uncertain}` when the box's answer did not come
  back, since the lines may have reached the program.
  """
  @spec pipe_send(String.t(), String.t(), String.t(), [String.t()], integer()) ::
          :ok | {:error, term()}
  def pipe_send(athanor_id, opener, session, lines, deadline)
      when is_list(lines) and is_integer(deadline) do
    case use_pipe(athanor_id, opener, session) do
      {:ok, grant} ->
        case Session.send(grant, session, lines, left(deadline)) do
          {:ok, :running} ->
            :ok

          {:ok, :ended} ->
            {:error, :ended}

          {:error, {:refused, code, _boot}} when code in [:unknown_session | @stale] ->
            {:error, :ended}

          {:error, reason} ->
            {:error, sent(reason)}
        end

      :none ->
        {:error, :ended}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # What a send's failure says of its lines. An answer the box gave
  # refused them before they were written; one that did not arrive, did
  # not read, or says the box failed inside, may follow their writing.
  defp sent(:backends_unavailable), do: :uncertain
  defp sent({:unreadable, _error}), do: :uncertain
  defp sent({:refused, :internal, _boot}), do: :uncertain
  defp sent(reason), do: reason

  @doc """
  The lines of the pipe session `session` of the athanor past `after_seq`,
  for the attempt `opener` that opened it, waiting up to `max_wait_ms` and
  awaiting the answer until `deadline` (as `pipe_open/6`'s). A session no
  holder holds any more answers no lines and `running: false`, and so does
  one the service no longer knows.
  """
  @spec pipe_recv(
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          integer()
        ) ::
          {:ok,
           %{lines: [Prima.LocusBackends.line()], dropped: non_neg_integer(), running: boolean()}}
          | {:error, term()}
  def pipe_recv(athanor_id, opener, session, after_seq, max_wait_ms, deadline)
      when is_integer(deadline) do
    case use_pipe(athanor_id, opener, session) do
      {:ok, grant} ->
        slack = max(left(deadline) - max_wait_ms, 1)

        case Session.recv(grant, session, after_seq, max_wait_ms, slack) do
          {:ok, answer} ->
            {:ok, Map.take(answer, [:lines, :dropped, :running])}

          {:error, {:refused, code, _boot}} when code in [:unknown_session | @stale] ->
            {:ok, @ended}

          {:error, reason} ->
            {:error, reason}
        end

      :none ->
        {:ok, @ended}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  End the pipe session `session` of the athanor, for the attempt `opener`
  that opened it: its program ended and its owner released. A session no
  holder holds any more answers `:ok`.
  """
  @spec pipe_close(String.t(), String.t(), String.t(), integer()) :: :ok | {:error, term()}
  def pipe_close(athanor_id, opener, session, deadline) when is_integer(deadline) do
    case pipe_pid(session) do
      nil -> :ok
      pid -> GenServer.call(pid, {:close, athanor_id, opener, session}, left(deadline))
    end
  catch
    :exit, _ -> :ok
  end

  defp use_pipe(athanor_id, opener, session) do
    case pipe_pid(session) do
      nil -> :none
      pid -> GenServer.call(pid, {:use, athanor_id, opener, session}, 5_000)
    end
  catch
    :exit, _ -> :none
  end

  defp pipe_pid(session) when is_binary(session) do
    if Process.whereis(@registry) do
      case Registry.lookup(@registry, {:pipe_session, session}) do
        [{pid, _}] -> pid
        [] -> nil
      end
    end
  end
end
