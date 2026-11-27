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
  the row's id, made at its first session and retired with the row. A
  program's own sign-in, which it writes there, is the folder's and no
  vault entry. `home/3` resets a row's kept home (every session in it ends
  and it is made again empty under the same uid) or retires it (its
  sessions end, the home is removed and its uid freed). The box that holds a home drew its uid; CYFR never
  learns it. A retire is retried until the box acknowledges it. Either way
  the brain sessions threads kept for the home are forgotten, so a member
  whose brain ran there starts a new one.

  ## Terminals

  `start/3` runs a program row's command, with the words its caller gives
  after it, on a terminal of the service's, as a session that belongs to
  its caller and to no page or browser credential
  (`Opus.Programs.Terminal`). A caller is a person at a screen, as the
  gate reads an interactive caller, or a turn of Aqua's, proved from the
  store from the lineage the gate stamps on its chain's call (`turn/2`);
  every call takes the caller's context and is refused when the caller
  no longer stands.

  A person's session: any of that person's surfaces attaches to it
  (`attach/2`), types on it (`input/3`), resizes it (`resize/4`), keeps
  it past a day unwatched (`keep/3`), detaches (`detach/2`, which ends
  nothing) or closes it (`close/2`). Its words are what the person typed.

  A turn's session (`by: :aqua`): that turn alone types on it, reads
  what it printed (`read/3`, `wait/4`) and closes it; its words are the
  turn's own, decided as any of its calls (`Aqua.Loop.Policy`). A
  turn holds a few at
  once; they end with the turn, and one whose program exited answers its
  last output until then.

  The person's browser (`by: :browser`): the one session Aqua's browser
  runs in for a person, held for them by `Opus.Browser`, the only module
  that names its owner (`browser/2`). It is the person's, not a turn's:
  their turns use it through `Opus.Browser`, which acts on it only for a
  caller this module proves (`caller/1`), and no turn's end ends it. It
  starts only the rows of the browser's own definition
  (`Opus.Programs.Definition.browser?/1`), the person's Chrome and the
  second, one session of each at a time. Its
  owner reaches it while the person stands, read from the store.

  `running/1` lists a person's sessions, those their turns started and
  their browser's, and the person may close those too; nothing else of a
  turn's session or of the browser's is theirs, and nothing of a person's
  is a turn's or the browser's. `Cyfr.Bus.programs/2`
  announces every change of that list. Another person, another turn, and
  a caller that is neither (a key), find no session, whatever its state,
  and none to list or start.
  """

  use Supervisor

  alias Opus.Programs.{Box, Session, Terminal}

  @registry Opus.Programs.Registry
  # The refusals of a session route that say its owner, and so its
  # session, is not on the service any more.
  @stale [:stale_boot, :epoch_ahead, :unknown_owner, :lapsed]
  # The margin an open's holder needs to answer past the deadline that it
  # passed.
  @answer_margin_ms 1_000
  @relays Opus.Programs.Relays
  # The most one input carries: the wire's one input message.
  @max_input Prima.LocusBackends.max_chunk_bytes()
  # How long a terminal's start waits for the service to run it.
  @start_ms 60_000
  # The most sessions one turn holds at once.
  @turn_sessions 4
  @local "local"
  @browser_row {:invalid_argument,
                "This program is Aqua's browser, which runs only for Aqua; turn it on or off on the Aqua page."}

  @typedoc "One program row of one athanor at one epoch."
  @type owner :: Box.owner()

  @typedoc "What a holder signs its session messages with."
  @type grant :: Box.grant()

  @doc """
  Start the controller. Options, from the composition root: `:url` and
  `:root` (the local box's service URL and 32-byte key) and `:cluster`
  (true: no box). With either of the first two absent or invalid the local
  box's start answers `:ignore` and there is no box. The registry comes
  first, then the supervisor of terminals, then the box: a box that dies restarts
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
  attach-only entry (`:disclosure_refused`), this member does not hold its
  slot in the cell (`:control_plane_lost`), or the service cannot be
  reached.
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

  Whatever the box answered, the brain session kept on each thread the
  home reaches is forgotten, so its next message starts a new session
  rather than resuming one the home no longer holds: a thread that
  stores the row's id, by its session or by an open turn pinned to it,
  never a thread found by a program brain's name, which a replacement row
  may answer (`Arca.ThreadStorage.forget_sessions/2`). A session a program held
  there is owed its removal in the same transaction, and its holder is
  closed once that commits (`Opus.Brain.forgotten/2`). A store that
  cannot forget them turns an `:ok` into
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
    with {:ok, forgotten} <-
           Arca.ThreadStorage.forget_sessions(Prima.Actor.in_athanor(athanor_id), row_id) do
      Opus.Brain.forgotten(athanor_id, forgotten)
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
  End every running terminal and brain session of the athanor's program
  row `row_id`: the row was changed or deleted, so nothing runs as it was
  defined any more. Answers at once; each terminal and each brain holder
  (`Opus.Brain`) ends `:row_changed`.
  """
  @spec end_mounts(String.t(), String.t()) :: :ok
  def end_mounts(athanor_id, row_id) when is_binary(athanor_id) and is_binary(row_id) do
    for supervisor <- [@relays, Opus.Brain.Holders],
        Process.whereis(supervisor),
        {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(supervisor),
        is_pid(pid),
        do: GenServer.cast(pid, {:row_ended, athanor_id, row_id})

    :ok
  end

  # ============================================================================
  # Terminals
  # ============================================================================

  @typedoc "Why a terminal session ended (`Opus.Programs.Terminal`)."
  @type ended ::
          :exited
          | {:ended_by, Prima.LocusBackends.ended_by()}
          | :restarted
          | :closed
          | :unanswered
          | :idle
          | :row_changed
          | :standing

  @typedoc """
  Who calls: a person at a screen, as a `Sanctum.Context` the gate reads as
  interactive, or a turn of Aqua's, as `{:turn, context, lineage}`: the
  guest-planed context of a call in that turn's chain and the lineage the
  gate stamped on it (`"thread_id"`, `"root_execution_id"`,
  `"parent_execution_id"`), which `turn/2` takes from a provider's
  arguments.
  """
  @type caller ::
          Sanctum.Context.t()
          | {:turn, Sanctum.Context.t(), map()}
          | {:browser, String.t(), String.t()}

  @typedoc """
  Who a caller is to a session (`caller/1`): a person at a screen, a
  running turn of theirs, or their browser.
  """
  @type principal ::
          {String.t(), String.t()}
          | {String.t(), String.t(), String.t()}
          | {String.t(), String.t(), :browser}

  @typedoc "One of the person's running sessions, as `running/1` answers it."
  @type running :: %{
          session: String.t(),
          row_id: String.t(),
          name: String.t(),
          started_at: DateTime.t(),
          kept: boolean(),
          attached: boolean(),
          by: :person | :aqua | :browser
        }

  @typedoc """
  What a turn reads of its session (`read/3`, `wait/4`): its program's
  name and the output from
  byte offset `from` up to `next`, `dropped` bytes before `from` that are
  no longer kept, and whether the program still runs or how it ended.
  """
  @type transcript :: %{
          program: String.t(),
          output: Opus.Programs.Output.t(),
          from: non_neg_integer(),
          next: non_neg_integer(),
          dropped: non_neg_integer(),
          running: boolean(),
          ended: ended() | nil
        }

  @doc """
  The caller's athanor's enabled program rows, each by its id, its name,
  its pinned command and its epoch, by name: what a turn may start, which
  Aqua's browser is not (`start/3`). Nothing of a row's environment, hosts
  or folder.
  """
  @spec rows(caller()) ::
          {:ok,
           %{
             programs: [
               %{id: String.t(), name: String.t(), command: String.t(), epoch: pos_integer()}
             ]
           }}
          | {:error, term()}
  def rows(caller) do
    with {:ok, _principal} <- who(caller) |> no_stranger(),
         {:ok, rows} <- Arca.McpServerStorage.list(caller_actor(caller)) do
      programs =
        for %{transport: "program", enabled: true} = row <- rows,
            not Opus.Programs.Definition.browser?(row),
            {:ok, %{"command" => command}} <- [Jason.decode(row.config_json || "{}")],
            is_binary(command),
            do: %{id: row.id, name: row.name, command: command, epoch: row.epoch}

      {:ok, %{programs: programs}}
    else
      {:error, :database_error} -> {:error, :unavailable}
      other -> other
    end
  end

  @doc "The most sessions one turn holds at once."
  @spec turn_sessions() :: pos_integer()
  def turn_sessions, do: @turn_sessions

  @doc """
  The caller a provider's call in a turn's chain is: its context and the
  lineage the gate stamped on its arguments (`Sanctum.Dispatch`), the
  arguments a guest sent under those names dropped before it. Which turn
  that is, and whether it is one, `start/3` and every call after it prove
  from the store.
  """
  @spec turn(Sanctum.Context.t(), map()) :: caller()
  def turn(%Sanctum.Context{} = ctx, args) when is_map(args),
    do:
      {:turn, ctx,
       Map.take(args, ~w(thread_id root_execution_id parent_execution_id called_by_page))}

  @doc """
  The person's browser as a caller: the owner of the session Aqua's
  browser runs in for the person `user_id` of `athanor_id`, held by
  `Opus.Browser` alone, which names it here and nowhere else. Every call
  made with it reads from the store that the person stands; it starts
  only the rows of the browser's own definition.
  """
  @spec browser(String.t(), String.t()) :: caller()
  def browser(athanor_id, user_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(user_id) and user_id != "",
      do: {:browser, athanor_id, user_id}

  @doc """
  A start of `what` refused for room, as the reason its sentence is
  (`Prima.Refusal`, `{:program_full, what, held, names}`): `held` the
  keeper's account of what holds the memory, its holdings of the
  person's own athanor carrying their subjects only where they are
  programs' and terminals' (`Prima.LocusPool.t:held/0`); or nil for a
  start refused for want of a program's place, which carries none.
  `names` are the names of the person's own rows among those subjects,
  read under `actor`, the person's own scope, first: a subject of a row
  the actor cannot read (deleted, or of an athanor they left) is no name
  and is counted by its kind, and what anyone else holds is only ever
  `held`'s one sum, which names nobody. A store that does not answer
  names nothing.
  """
  @spec full(Prima.Actor.t(), String.t(), Prima.LocusPool.held() | nil) ::
          {:program_full, String.t(), Prima.LocusPool.held() | nil, %{String.t() => String.t()}}
  def full(%Prima.Actor{}, what, nil) when is_binary(what), do: {:program_full, what, nil, %{}}

  def full(%Prima.Actor{} = actor, what, held) when is_binary(what) and is_map(held),
    do: {:program_full, what, held, held_names(actor, held)}

  @doc """
  The names of `actor`'s own rows among the subjects of `held` (`full/3`
  says how they are read), by subject; none for no `held`.
  """
  @spec held_names(Prima.Actor.t(), Prima.LocusPool.held() | nil) :: %{String.t() => String.t()}
  def held_names(%Prima.Actor{}, nil), do: %{}
  def held_names(%Prima.Actor{} = actor, %{mine: mine}), do: holder_names(actor, mine)

  defp holder_names(actor, mine) do
    subjects =
      for %{subject: subject} when is_binary(subject) <- mine, into: MapSet.new(), do: subject

    with true <- MapSet.size(subjects) > 0,
         {:ok, rows} <- Arca.McpServerStorage.list(actor) do
      for %{id: id, name: name} <- rows, MapSet.member?(subjects, id), into: %{}, do: {id, name}
    else
      _none_or_unread -> %{}
    end
  end

  @doc """
  Who `caller` is to a session, proved from the store as every call
  here proves it: `{athanor, user}` for a person at a screen,
  `{athanor, user, turn}` for a running turn of theirs that made the call
  itself, `{athanor, user, :browser}` for their browser, and `:stranger`
  for a caller that stands but is none of these (a key, a frame, a
  component a turn started, a paused or superseded turn). Refused
  `:not_standing` for a person who no longer stands and `:unavailable`
  when the store cannot answer.
  """
  @spec caller(caller()) ::
          {:ok, principal() | :stranger} | {:error, :not_standing | :unavailable}
  def caller(caller), do: who(caller)

  @doc """
  Start the program row `row_id` of the caller's athanor on a terminal of
  `rows` by `cols`, its pinned command followed by `args`, as a session
  that belongs to the caller (`Opus.Programs.Terminal`): a person's to
  that person, started `by: :person`, a turn's to that turn, started
  `by: :aqua`, the browser's to the person's browser, started
  `by: :browser`. The row must be an enabled program, and the browser's
  a row of its own definition (`:not_browser` otherwise), one session of
  each row at a time (`:already_running`), and those rows start for no other caller
  (an `:invalid_argument` saying so). The browser's start names
  `held_by`, the process that holds the session for the person
  (`Opus.Browser`): the session lives as long as that process, from the
  moment it is asked for, starting or started, and ends `:closed` when it
  is gone (`:invalid_args` without one); `args` are at most
  #{Prima.LocusBackends.max_argv()} words, each readable text
  (`Opus.Programs.Words.readable?/1`) of at most 4096 bytes, as an `Opus.Programs.Words` (a plain list is
  wrapped here), which the session holds wrapped: a person's words are
  what that person typed; a turn's are its own, decided as any of its
  calls. Neither is ever resolved from a vault. With `epoch`, the row must
  still be at that epoch (the one the call names), else `:row_changed`.
  A turn holds at most #{@turn_sessions} sessions at once, ended ones it has not
  stopped among them: the next is refused `:too_many_sessions`. Answers
  the session's id once the service runs it, by `deadline` (Unix
  milliseconds, #{div(60_000, 1000)} s from now unless given): past it
  the start is refused `:deadline`, the box closes whatever the service
  answers later, and a new start can be made at once. Refused
  `:not_standing` (or `:unavailable`) for a caller who does not stand,
  `:not_found` for a caller who is neither, `:not_found`,
  `:not_a_program` or `:disabled` for the row, `:invalid_size` or
  `:invalid_args` for the rest, and as `hold/2` and the session route
  refuse.
  """
  @spec start(caller(), String.t(), %{
          required(:rows) => pos_integer(),
          required(:cols) => pos_integer(),
          required(:args) => Opus.Programs.Words.t() | [String.t()],
          optional(:epoch) => pos_integer() | nil,
          optional(:deadline) => integer(),
          optional(:held_by) => pid()
        }) :: {:ok, String.t()} | {:error, term()}
  def start(caller, row_id, %{rows: rows, cols: cols, args: args} = opts)
      when is_binary(row_id) do
    args = Opus.Programs.Words.new(args)

    with {:ok, principal} <- who(caller) |> no_stranger(),
         :ok <- size(rows, cols),
         :ok <- args(args),
         {:ok, held_by} <- held_by(principal, Map.get(opts, :held_by)),
         :ok <- room(principal),
         {:ok, row} <- program_row(caller_actor(caller), row_id),
         :ok <- browser_row(principal, row),
         :ok <- at_epoch(row, Map.get(opts, :epoch)),
         owner = %{athanor_id: row.athanor_id, server_id: row.id, epoch: row.epoch},
         home_id = if(row.home == "kept", do: row.id),
         deadline = Map.get(opts, :deadline, System.system_time(:millisecond) + @start_ms) do
      {athanor_id, user_id, turn_id} = parts(principal)

      spec = [
        athanor_id: athanor_id,
        user_id: user_id,
        turn_id: turn_id,
        row_id: row.id,
        row_name: row.name,
        home_id: home_id,
        owner: owner,
        argv: args,
        by: by(principal),
        held_by: held_by,
        rows: rows,
        cols: cols
      ]

      principal
      |> started(spec, deadline, _again? = true)
      |> roomless(caller_actor(caller), row.name)
    end
  catch
    :exit, _ -> {:error, :backends_unavailable}
  end

  # One try of a start is one id and one lifetime. One of a boot the
  # service no longer runs is refused before anything of it runs, and is
  # made again once, when the try before it has gone.
  defp started(principal, spec, deadline, again?) do
    with {:ok, {id, lifetime}} <- new_terminal(principal, spec[:owner], spec[:home_id]) do
      named = [name: terminal_name(id, principal), id: id, lifetime: lifetime] ++ spec
      wait = max(deadline - System.system_time(:millisecond), 0) + @answer_margin_ms

      case DynamicSupervisor.start_child(@relays, {Terminal, named}) do
        {:ok, pid} ->
          ended = Process.monitor(pid)

          case open(pid, deadline, wait) do
            {:error, {:refused, :stale_boot, _boot}} when again? ->
              receive do
                {:DOWN, ^ended, :process, ^pid, _reason} ->
                  started(principal, spec, deadline, false)
              after
                wait -> {:error, :deadline}
              end

            answer ->
              Process.demonitor(ended, [:flush])
              answer
          end

        # A browser's row whose session already runs (`Terminal`).
        :ignore ->
          {:error, :already_running}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # A start refused for room is said by its sentence, the person's own
  # holdings named under the person's own scope (`full/3`).
  defp roomless({:error, {:refused, {:capacity, held}, _boot}}, actor, name),
    do: {:error, full(actor, name, held)}

  defp roomless({:error, {:refused, :capacity, _boot}}, actor, name),
    do: {:error, full(actor, name, nil)}

  defp roomless(answer, _actor, _name), do: answer

  # The terminal's id, made by the box, whose root proves it: the handle
  # of the one lifetime this try is, fixed before anything is asked.
  defp new_terminal(principal, owner, home_id) do
    call(
      box_of(owner.athanor_id),
      {:terminal_id, principal, owner, home_id},
      Box.control_timeout_ms()
    )
  end

  # A start refused for its deadline is ended by its session's owner,
  # which owes the box its close: an answer the owner gives after the
  # caller stopped waiting never leaves a session nobody started.
  defp open(pid, deadline, wait) do
    GenServer.call(pid, {:open, deadline}, wait)
  catch
    :exit, {:timeout, _} ->
      GenServer.cast(pid, :refused)
      {:error, :deadline}

    :exit, _ ->
      {:error, :backends_unavailable}
  end

  @doc """
  Attach the calling process to the caller's session `session_id`:
  answered the last of its output (an `Opus.Programs.Output`), the
  terminal's size and whether it is kept, after which the process
  receives `{Opus.Programs, session_id, {:bytes, delivery, output}}`,
  each output an `Opus.Programs.Output` and each delivery a fresh random
  token, the next only once it said it took the last by its token
  (`taken/3`); `{Opus.Programs, session_id, {:tail, delivery, output}}`
  when more came meanwhile than is kept for it, the last
  #{div(256 * 1024, 1024)} KiB, to show in place of what it showed; and
  `{Opus.Programs, session_id, {:ended, reason}}` once (`t:ended/0`),
  after what is held for it, whatever it owes. Attaching again is
  attaching once.
  `{:error, :not_found}` for a session that is not running or not the
  caller's own: a person's screen attaches to no session a turn started.
  """
  @spec attach(caller(), String.t()) ::
          {:ok,
           %{
             tail: Opus.Programs.Output.t(),
             rows: pos_integer(),
             cols: pos_integer(),
             kept: boolean()
           }}
          | {:error, term()}
  def attach(caller, session_id),
    do: terminal_call(caller, session_id, &{:attach, &1, self()})

  @doc "Detach the calling process from the session; it ends nothing and answers `:ok`."
  @spec detach(caller(), String.t()) :: :ok
  def detach(caller, session_id) do
    _ = terminal_call(caller, session_id, &{:detach, &1, self()})
    :ok
  end

  @doc """
  Type `bytes` on the caller's own session's terminal, as they are: at
  most #{div(@max_input, 1024)} KiB a call, the wire's one input
  (`Prima.LocusBackends.max_chunk_bytes/0`; `{:error, :too_large}` past it), so one
  call holds the caller, and the service, for one write alone.
  `{:error, :ended}` once its program no longer runs,
  `{:error, :unavailable}` when the service did not take them.
  """
  @spec input(caller(), String.t(), binary()) :: :ok | {:error, term()}
  def input(_caller, _session_id, ""), do: :ok

  def input(_caller, _session_id, bytes)
      when is_binary(bytes) and byte_size(bytes) > @max_input,
      do: {:error, :too_large}

  def input(caller, session_id, bytes) when is_binary(bytes) do
    with {:ok, grant, session} <- terminal_call(caller, session_id, &{:use, &1}),
         do: typed(Session.input(grant, session, bytes))
  end

  @doc """
  The calling process, attached to the session, took the delivery whose
  token is `delivery` (a page's browser drew it): when that is the one
  outstanding for it, it is handed what came since, or the next output.
  Until it says so it is handed nothing more, and what comes meanwhile
  is kept for it, the last #{div(256 * 1024, 1024)} KiB at most
  (`Opus.Programs.Terminal`); any other token answers `:ok` and changes
  nothing. `{:error, :not_found}` for a session it is not attached to.
  """
  @spec taken(caller(), String.t(), String.t()) :: :ok | {:error, term()}
  def taken(caller, session_id, delivery) when is_binary(delivery),
    do: terminal_call(caller, session_id, &{:taken, &1, self(), delivery})

  @doc "Set the session's terminal to `rows` by `cols`; its program is signalled the change."
  @spec resize(caller(), String.t(), pos_integer(), pos_integer()) ::
          :ok | {:error, term()}
  def resize(caller, session_id, rows, cols) do
    with :ok <- size(rows, cols),
         {:ok, grant, session} <- terminal_call(caller, session_id, &{:resize, &1, rows, cols}),
         do: typed(Session.resize(grant, session, rows, cols))
  end

  @doc """
  Mark the session kept (`true`), so a day with nothing attached and
  nothing printed does not end it, or not (`false`).
  """
  @spec keep(caller(), String.t(), boolean()) :: :ok | {:error, term()}
  def keep(caller, session_id, kept) when is_boolean(kept),
    do: terminal_call(caller, session_id, &{:keep, &1, kept})

  @doc """
  What the caller's own session printed after byte offset `offset`, as it
  stands now (`t:transcript/0`): the session keeps the last
  #{div(256 * 1024, 1024)} KiB of its output, counted from its first byte,
  and answers at most #{div(Opus.Programs.Terminal.read_bytes(), 1024)} KiB a call; bytes before
  what it keeps are counted, not answered. A session whose program
  exited by itself still answers its last output, and that it ended,
  until its turn ends or it is stopped. `{:error, :not_found}` for a
  session that is not the caller's own.
  """
  @spec read(caller(), String.t(), non_neg_integer()) ::
          {:ok, transcript()} | {:error, term()}
  def read(caller, session_id, offset) when is_integer(offset) and offset >= 0,
    do: terminal_call(caller, session_id, &{:read, &1, offset})

  @doc """
  `read/3`, once the session has printed past `offset` and then printed
  nothing for half a second (`Opus.Programs.Terminal`), or its program
  has ended, or `ms` has passed, whichever comes first: with `:infinity`,
  as long as that takes, and `ms` at most what a timer holds
  (`Prima.Operation.longest_wait_ms/0`, which `Opus.Programs.Provider`
  checks at the arguments). A session of the caller's own with no process,
  its run lost with the holder at a restart of CYFR, answers
  `{:error, :ended}`, read from what its id names (`Opus.Programs.Box`,
  "A terminal's id"); any other `{:error, :not_found}`. A session whose
  process lives but did not answer in time is still running:
  `{:error, :still_running}`.
  """
  @spec wait(caller(), String.t(), non_neg_integer(), non_neg_integer() | :infinity) ::
          {:ok, transcript()} | {:error, term()}
  def wait(caller, session_id, offset, ms)
      when is_integer(offset) and offset >= 0 and
             ((is_integer(ms) and ms >= 0) or ms == :infinity) do
    with {:ok, principal} <- who(caller) do
      case terminal_pid(session_id, principal, :owner) do
        nil ->
          lost(caller, session_id)

        pid ->
          # Every check has passed: from here a post answers a turn's wait
          # early (`Sanctum.RunningTasks.wake/1`).
          :ok = Sanctum.RunningTasks.waiting()
          waited(pid, {:wait, principal, offset, ms}, answer_timeout(ms), caller, session_id)
      end
    end
  end

  # How long the caller waits on the terminal's answer: past its own time,
  # within what a timer holds (`Prima.Operation.longest_wait_ms/0`).
  defp answer_timeout(:infinity), do: :infinity

  defp answer_timeout(ms),
    do: min(ms + @answer_margin_ms + 5_000, Prima.Operation.longest_wait_ms())

  # A wait the process answers; one it did not answer in time still runs,
  # and one whose process went meanwhile is read as gone.
  defp waited(pid, message, timeout, caller, session_id) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :still_running}
    :exit, _gone -> lost(caller, session_id)
  end

  # A session with no process to answer: ended, when its id names one of
  # the caller's own; otherwise not found, as a stranger's id reads.
  defp lost(caller, session_id) do
    with {:ok, principal} <- who(caller) do
      case call(@local, {:terminal_named, session_id, principal}, Box.control_timeout_ms()) do
        {:ok, whose, _lifetime} ->
          if reaches?(principal, whose, :owner),
            do: {:error, :ended},
            else: {:error, :not_found}

        _none_or_unread ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  End the caller's session `session_id`, carried out whether or not the
  caller waits for it: `{:ok, :closed}` once the service confirmed it,
  `{:ok, :already_gone}` for a session that is not running (or not the
  caller's), and `{:error, :unanswered}` when the service did not
  confirm it in time, the box still owing the close. A session with no
  process here, after a restart of CYFR too, is closed by the lifetime its
  id names (`Opus.Programs.Box`, "A terminal's id") and is `:already_gone`
  only once the service confirmed that; an id that names no lifetime the
  caller may close is `:already_gone` with the service not asked. The
  session ends
  `:closed` of a close confirmed and `:unanswered` of one that was not,
  said so to every process attached. A person closes their own sessions, those their
  turns started and their browser's; a turn or the browser closes only
  its own.
  """
  @spec close(caller(), String.t()) ::
          {:ok, :closed | :already_gone} | {:error, :unanswered | term()}
  def close(caller, session_id) do
    with {:ok, principal} <- who(caller) do
      case terminal_pid(session_id, principal, :closing) do
        nil ->
          close_gone(session_id, principal)

        pid ->
          close_terminal(pid, principal, session_id)
      end
    end
  catch
    :exit, _ -> {:error, :unanswered}
  end

  defp close_terminal(pid, principal, session_id) do
    GenServer.call(pid, {:close, principal}, Box.close_timeout_ms() + @answer_margin_ms)
  catch
    :exit, {:timeout, _} -> {:error, :unanswered}
    :exit, _ -> close_gone(session_id, principal)
  end

  # A session with no process is gone once its lifetime's place is back.
  # Who may ask that is who could have closed it, read from its id; to
  # anyone else, as for an id CYFR made no lifetime of, it is gone.
  defp close_gone(session_id, principal) do
    case call(@local, {:terminal_named, session_id, principal}, Box.control_timeout_ms()) do
      {:ok, whose, lifetime} ->
        if reaches?(principal, whose, :closing) do
          with :ok <- box_close(lifetime), do: {:ok, :already_gone}
        else
          {:ok, :already_gone}
        end

      :none ->
        {:ok, :already_gone}

      # No box could read the id, so nothing says what it names is gone.
      {:error, _unread} ->
        {:error, :unanswered}
    end
  end

  @doc """
  The caller's running sessions in the caller's athanor, oldest first: a
  person's own, those the person's turns started (`by: :aqua`) and their
  browser's (`by: :browser`); a turn's or the browser's own.
  """
  @spec running(caller()) :: {:ok, [running()]} | {:error, term()}
  def running(caller) do
    with {:ok, principal} <- who(caller) do
      pids =
        if Process.whereis(@registry),
          do: Registry.select(@registry, listing(principal)),
          else: []

      summaries =
        for pid <- pids, {:ok, summary} <- [summary(pid, principal)], do: summary

      {:ok, Enum.sort_by(summaries, & &1.started_at, DateTime)}
    end
  end

  # A person lists their own sessions, their turns' and their browser's; a
  # turn or the browser its own.
  defp listing({athanor_id, user_id} = person) do
    [
      {{{:terminal, :_}, :"$1", person}, [], [:"$1"]},
      {{{:terminal, :_}, :"$1", {athanor_id, user_id, :_}}, [], [:"$1"]}
    ]
  end

  defp listing({_athanor_id, _user_id, _turn_id} = turn),
    do: [{{{:terminal, :_}, :"$1", turn}, [], [:"$1"]}]

  defp listing(:stranger), do: []

  defp summary(pid, principal) do
    GenServer.call(pid, {:summary, principal}, 5_000)
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  End every session the turn `turn_id` of the athanor started, as its turn
  ended (`:standing`): its process stops, and the box closes its session;
  one still opening refuses its start. Called once the turn's row is
  marked ended, so a start that registered too late for this call reads
  that mark before it opens anything and is refused
  (`Opus.Programs.Terminal`). Answers at once.
  """
  @spec end_turn(String.t(), String.t()) :: :ok
  def end_turn(athanor_id, turn_id) when is_binary(athanor_id) and is_binary(turn_id) do
    if Process.whereis(@registry) do
      for pid <-
            Registry.select(@registry, [
              {{{:terminal, :_}, :"$1", {athanor_id, :_, turn_id}}, [], [:"$1"]}
            ]),
          do: GenServer.cast(pid, {:turn_ended, turn_id})
    end

    :ok
  end

  @doc false
  # Whether the person stands on this CYFR (`Sanctum.Caller.stands?/1`)
  # and the athanor is active and theirs, read from the store and from no
  # context: the one reading of a session's standing, for its owner as
  # for a turn's call.
  @spec stands(String.t(), String.t()) :: {:ok, boolean()} | {:error, :unavailable}
  def stands(athanor_id, user_id) do
    with {:ok, true} <- Sanctum.Caller.stands?(user_id),
         {:ok, athanor} <- Sanctum.Tenancy.Athanors.get(athanor_id) do
      {:ok, athanor.status == "active" and athanor.owner_user_id == user_id}
    else
      {:ok, false} -> {:ok, false}
      {:error, :not_found} -> {:ok, false}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  @doc false
  # The status of the turn `turn_id` of the athanor, read from the store:
  # nil for a turn it does not hold, `{:error, :unavailable}` when it
  # cannot answer. A turn keeps its sessions while it is open and uses
  # them only while it is running.
  @spec turn_status(String.t(), String.t()) :: {:ok, String.t() | nil} | {:error, :unavailable}
  def turn_status(athanor_id, turn_id) do
    case Arca.TurnStorage.get(Prima.Actor.in_athanor(athanor_id), turn_id) do
      {:ok, %{status: status}} -> {:ok, status}
      {:error, :not_found} -> {:ok, nil}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # Who the caller is to a session: `{athanor, user}` for a person at a
  # screen, `{athanor, user, turn}` for a turn, `:stranger` for a caller
  # that stands but is neither.
  defp who(%Sanctum.Context{} = ctx), do: person(ctx)

  defp who({:turn, %Sanctum.Context{} = ctx, lineage}) when is_map(lineage),
    do: turn_of(ctx, lineage)

  # The person's browser stands while its person does, read from the store
  # and from no context, as a session's owner reads its person.
  defp who({:browser, athanor_id, user_id}) when is_binary(athanor_id) and is_binary(user_id) do
    case stands(athanor_id, user_id) do
      {:ok, true} -> {:ok, {athanor_id, user_id, :browser}}
      {:ok, false} -> {:error, :not_standing}
      {:error, :unavailable} -> {:error, :unavailable}
    end
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

  # The turn a chain's call comes from, proved from the store and never
  # from an argument: the context is a call inside a running chain
  # (guest-planed, which no screen's context is, and no context returns
  # from) that the gate reads as interactive there
  # (`Sanctum.Consent.authorize_interactive_in_chain/1`, a person's own
  # sign-in; a key's chain is not); the call is the turn's own, not a
  # component's it started (the lineage's parent is its root); its person
  # stands; and the store holds a running turn of the lineage's thread, in
  # the context's athanor, whose root is the lineage's root and which that
  # person asked for. A turn that is paused, ending or not yet
  # running again is a stranger to its own sessions: they stay and go on
  # printing, and it uses them once it runs. The lineage is the gate's
  # (`Sanctum.Dispatch` drops what a guest sends under its names and stamps
  # its own), and which turn is the person's own is the store's one rule
  # (`Arca.TurnStorage.own_turn/3`): a page's call through the turn and a
  # component's are none. Anything else is a stranger.
  defp turn_of(%Sanctum.Context{plane: :guest, authenticated: true} = ctx, lineage)
       when is_binary(ctx.athanor_id) and ctx.athanor_id != "" and is_binary(ctx.user_id) and
              ctx.user_id != "" do
    %{athanor_id: athanor_id, user_id: user_id} = ctx

    with {:ok, :interactive} <- Sanctum.Consent.authorize_interactive_in_chain(ctx),
         {:ok, true} <- stands(athanor_id, user_id),
         {:ok, %{status: "running", id: turn_id}} <-
           Arca.TurnStorage.own_turn(Sanctum.Context.actor(ctx), user_id, lineage) do
      {:ok, {athanor_id, user_id, turn_id}}
    else
      {:ok, %{status: _not_running}} -> {:ok, :stranger}
      {:error, reason} when reason in [:by_page, :by_component, :not_open] -> {:ok, :stranger}
      {:error, {:surface_not_permitted, _method}} -> {:ok, :stranger}
      {:error, :not_authenticated} -> {:ok, :stranger}
      {:ok, false} -> {:error, :not_standing}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp turn_of(%Sanctum.Context{}, _lineage), do: {:ok, :stranger}

  defp caller_actor(%Sanctum.Context{} = ctx), do: Sanctum.Context.actor(ctx)
  defp caller_actor({:turn, ctx, _lineage}), do: Sanctum.Context.actor(ctx)
  defp caller_actor({:browser, athanor_id, _user_id}), do: Prima.Actor.in_athanor(athanor_id)

  defp parts({athanor_id, user_id}), do: {athanor_id, user_id, nil}
  defp parts({athanor_id, user_id, :browser}), do: {athanor_id, user_id, nil}
  defp parts({athanor_id, user_id, turn_id}), do: {athanor_id, user_id, turn_id}

  # The browser's session is held by one process, named at its start; no
  # other session is.
  defp held_by({_athanor_id, _user_id, :browser}, pid) when is_pid(pid), do: {:ok, pid}
  defp held_by({_athanor_id, _user_id, :browser}, _none), do: {:error, :invalid_args}
  defp held_by(_principal, _pid), do: {:ok, nil}

  defp by({_athanor_id, _user_id}), do: :person
  defp by({_athanor_id, _user_id, :browser}), do: :browser
  defp by({_athanor_id, _user_id, _turn_id}), do: :aqua

  # The browser's owner starts the row of the browser's own definition and
  # no other, so no program of the person's becomes reachable through it;
  # and that row starts for nobody else, so neither a person's terminal
  # nor a turn's run holds the browser's profile or drives its Chrome
  # past the person's browser setting.
  defp browser_row({_athanor_id, _user_id, :browser}, row) do
    if Opus.Programs.Definition.browser?(row), do: :ok, else: {:error, :not_browser}
  end

  defp browser_row(_principal, row) do
    if Opus.Programs.Definition.browser?(row), do: {:error, @browser_row}, else: :ok
  end

  # A turn holds at most `@turn_sessions` sessions at once; the person's
  # browser one of each row, which its session holds as it starts
  # (`Opus.Programs.Terminal`); a person's starts are bounded by the box.
  defp room({_athanor_id, _user_id, :browser}), do: :ok

  defp room({_athanor_id, _user_id, _turn_id} = turn) do
    held =
      if Process.whereis(@registry),
        do: Registry.count_select(@registry, [{{{:terminal, :_}, :_, turn}, [], [true]}]),
        else: 0

    if held < @turn_sessions, do: :ok, else: {:error, :too_many_sessions}
  end

  defp room(_person), do: :ok

  defp at_epoch(_row, nil), do: :ok
  defp at_epoch(%{epoch: epoch}, epoch), do: :ok
  defp at_epoch(_row, _shown), do: {:error, :row_changed}

  defp no_stranger({:ok, :stranger}), do: {:error, :not_found}
  defp no_stranger(answer), do: answer

  defp terminal_call(caller, session_id, message, timeout \\ 5_000) when is_binary(session_id) do
    with {:ok, principal} <- who(caller) do
      case terminal_pid(session_id, principal, :owner) do
        nil -> {:error, :not_found}
        pid -> GenServer.call(pid, message.(principal), timeout)
      end
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  defp terminal_name(id, principal),
    do: {:via, Registry, {@registry, {:terminal, id}, principal}}

  # The session's process, when the caller may reach it: whose it is is
  # read from the registry, beside its name, before the process is asked
  # anything, so a stranger's answer never depends on the session's
  # state. Only its owner reaches it, but for a close, which a person may
  # also make of a session one of their turns started.
  defp terminal_pid(session_id, principal, reach) when is_binary(session_id) do
    if Process.whereis(@registry) do
      case Registry.lookup(@registry, {:terminal, session_id}) do
        [{pid, owner}] -> if reaches?(principal, owner, reach), do: pid
        [] -> nil
      end
    end
  end

  defp reaches?(:stranger, _owner, _reach), do: false
  defp reaches?(owner, owner, _reach), do: true
  defp reaches?({athanor_id, user_id}, {athanor_id, user_id, _turn}, :closing), do: true
  defp reaches?(_principal, _owner, _reach), do: false

  defp program_row(actor, row_id) do
    case Arca.McpServerStorage.get_by_id(actor, row_id) do
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

  defp args(%Opus.Programs.Words{list: args}) when is_list(args) do
    if length(args) <= Prima.LocusBackends.max_argv() and Enum.all?(args, &arg?/1),
      do: :ok,
      else: {:error, :invalid_args}
  end

  defp arg?(arg),
    do: is_binary(arg) and byte_size(arg) <= 4096 and Opus.Programs.Words.readable?(arg)

  # What a write to a terminal answered.
  defp typed({:ok, :running}), do: :ok
  defp typed({:ok, :ended}), do: {:error, :ended}

  # The terminal's own reader says why it ended; a write to it is refused
  # as to any ended session.
  defp typed({:ok, {:ended_by, _cause}}), do: {:error, :ended}

  defp typed({:error, {:refused, code, _boot}}) when code in [:unknown_session | @stale],
    do: {:error, :ended}

  defp typed({:error, _unanswered}), do: {:error, :unavailable}

  # ============================================================================
  # A holder's sessions
  # ============================================================================

  @doc """
  A new lifetime of `named` (its `program`, `key`, `mode`, `:run` unless it
  names one, and `home_id`) under `grant` and of its service boot: one
  process, which `box_open/4` opens and `box_close/1` ends.
  """
  @spec lifetime(grant(), map()) :: Box.lifetime()
  defdelegate lifetime(grant, named), to: Box

  @doc """
  The box's open of `lifetime` for the holder `holder`, the only open
  there is (a tool server's, a brain's and a terminal's), with `params`
  (`argv`, and a terminal's `rows` and `cols`), answered by `deadline`
  (Unix milliseconds). Answers the lifetime's session, `{:error,
  :deadline}` past it, `{:error, :control_plane_lost}` for a member
  without its slot, `:packs_unready` or `:packs_moved` for a program that
  loads the person's packs whose copy could not be made ready before it
  (`Opus.Programs.Session`), or the refusal: `lifetime_over` for one closed or
  ended, and `stale_boot` for one of another boot of the service, whose
  caller holds again and mints another. An open that is never given has
  its lifetime closed (`Opus.Programs.Box`, "Sessions").
  """
  @spec box_open(Box.lifetime(), pid(), map(), integer()) ::
          {:ok, %{session: String.t(), resumed: boolean()}} | {:error, term()}
  def box_open(lifetime, holder, params, deadline) do
    wait = max(deadline - System.system_time(:millisecond), 0) + @answer_margin_ms
    message = {:session_open, lifetime, holder, params, deadline}

    case call(box_of(lifetime.athanor), message, wait) do
      {:error, :backends_unavailable} -> {:error, :deadline}
      answer -> answer
    end
  end

  @doc """
  End `lifetime`, and no other: the box owes the close until the service
  confirms it. Answers `:ok` once the service has confirmed that nothing
  of the lifetime is held, and so its place is back, whether or not this
  box knew of it, and `{:error, :unanswered}` when it did not, the close
  window passed or the box could send nothing; either way only then, so
  the holder's release of the owner after it never outruns it.
  """
  @spec box_close(Box.lifetime()) :: :ok | {:error, :unanswered}
  def box_close(lifetime) do
    case call(box_of(lifetime.athanor), {:session_close, lifetime}, Box.close_timeout_ms()) do
      :ok -> :ok
      {:error, _unanswered} -> {:error, :unanswered}
    end
  end
end
