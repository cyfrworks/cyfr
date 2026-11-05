# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs do
  @moduledoc """
  The programs controller: what the backends service runs, its sessions and
  its kept homes. Programs are the `mcp_servers` rows whose transport is
  `stdio` (Emissary speaks MCP to them) or `pipe` (a catalyst drives them).

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

  `home/3` resets a login entry's kept home (every session in it ends and
  it is made again empty under the same uid) or retires it (its sessions
  end, the home is removed and its uid freed). The box that holds a home
  drew its uid; CYFR never learns it. A retire is retried until the box
  acknowledges it.

  ## Pipes

  `pipe_open/6` opens, for an attempt of a catalyst whose login need the
  caller resolved (`Opus.Host.Pipe`), a `run` session of a program row in
  a login entry's kept home under a key, held by an `Opus.Programs.Pipe`
  process that belongs to the row, the home and the key, never to the
  attempt: a later attempt opening the same key attaches to the session
  while its program runs. `pipe_send/5`, `pipe_recv/6` and `pipe_close/4`
  carry it for an attempt that opened it, each in the caller's process.
  A session no attempt uses for the box's idle period ends, and so does
  every session in a login entry's home when the entry is revoked,
  suspended or deleted (`end_mounts/2`).

  ## Sign-in

  `sign_in/3` opens a `sign_in` session of a row's login command in a login
  entry's kept home, relayed by an `Opus.Programs.SignIn` process to the one
  subscriber that attaches with the same binding (`sign_in_attach/3`,
  `sign_in_send/3`, `sign_in_close/2`). The binding is the caller's
  athanor, person and credential, read from the context, so a token is
  usable only by the session that asked for it.
  """

  use Supervisor

  alias Opus.Programs.{Box, Pipe, Session, SignIn}

  @registry Opus.Programs.Registry
  # The refusals of a session route that say its owner, and so its
  # session, is not on the service any more.
  @stale [:stale_boot, :epoch_ahead, :unknown_owner, :lapsed]
  @ended %{lines: [], dropped: 0, running: false}
  # A pipe call's deadline when its caller names none, and the margin an
  # open's holder needs to answer past the deadline that it passed.
  @default_wait_ms 25_000
  @answer_margin_ms 1_000
  @relays Opus.Programs.Relays
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
  first, then the sign-in relays, then the boxes: a box that dies restarts
  alone, and its holders, refused by the service once its lease lapses,
  hold their owners again. `:boxes` replaces the local one with a list of box option lists
  (`Opus.Programs.Box.start_link/1`, each without its `:name`).
  """
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    boxes =
      case Keyword.fetch(opts, :boxes) do
        {:ok, boxes} -> boxes
        :error -> [local_box(opts)]
      end

    Supervisor.init(
      [
        {Registry, keys: :unique, name: @registry},
        {DynamicSupervisor, name: @relays, strategy: :one_for_one}
        | Enum.map(boxes, &box_child/1)
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
  Reset (`:reset`) or retire (`:retire`) the kept home `home_id` of the
  athanor. Answers `:ok` once the box acknowledged it; a retire that could
  not be sent is answered with the reason and stays pending, sent again on
  every tick until it lands.
  """
  @spec home(String.t(), String.t(), :reset | :retire) :: :ok | {:error, term()}
  def home(athanor_id, home_id, op) when op in [:reset, :retire] do
    call(box_of(athanor_id), {:home, athanor_id, home_id, op}, Box.control_timeout_ms())
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
  # Sign-in
  # ============================================================================

  @doc """
  Start a sign-in on `row` (a stored `mcp_servers` row with a kept home and
  a login command) in the kept home `home_id`, for the caller `ctx`: its
  owner held, its login command running on a pseudo-terminal. Answers a
  token the same caller attaches to within 30 s.
  """
  @spec sign_in(Sanctum.Context.t(), map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def sign_in(%Sanctum.Context{} = ctx, row, home_id) when is_binary(home_id) do
    token = "si_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    binding = caller(ctx)

    args = [
      name: relay_name(token),
      token: token,
      binding: binding,
      ctx: ctx,
      owner: %{athanor_id: row.athanor_id, server_id: row.id, epoch: row.epoch},
      program: program_name(row),
      home_id: home_id,
      key: key(binding)
    ]

    case DynamicSupervisor.start_child(@relays, {SignIn, args}) do
      {:ok, _pid} -> {:ok, token}
      {:error, {:shutdown, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Make `pid` the subscriber of the sign-in `token`, which `ctx` started."
  @spec sign_in_attach(Sanctum.Context.t(), String.t(), pid()) :: :ok | {:error, term()}
  def sign_in_attach(ctx, token, pid) when is_pid(pid),
    do: relay_call(token, {:attach, caller(ctx), pid})

  @doc "Write `line` to the sign-in's terminal."
  @spec sign_in_send(Sanctum.Context.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def sign_in_send(ctx, token, line) when is_binary(line),
    do: relay_call(token, {:send, caller(ctx), line})

  @doc """
  End every running sign-in and pipe session of the athanor in the kept
  home of the login entry `entry_id`: the entry was revoked, suspended or
  deleted, so nothing runs in its home any more. Answers at once; each
  sign-in relay ends `:entry_ended`, and each pipe holder closes its
  session and releases its owner.
  """
  @spec end_mounts(String.t(), String.t()) :: :ok
  def end_mounts(athanor_id, entry_id) when is_binary(athanor_id) and is_binary(entry_id) do
    if Process.whereis(@relays) do
      for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(@relays),
          is_pid(pid),
          do: GenServer.cast(pid, {:entry_ended, athanor_id, entry_id})
    end

    :ok
  end

  @doc "End the sign-in: its command is ended and its owner released."
  @spec sign_in_close(Sanctum.Context.t(), String.t()) :: :ok | {:error, term()}
  def sign_in_close(ctx, token), do: relay_call(token, {:close, caller(ctx)})

  defp relay_call(token, message) do
    GenServer.call(relay_name(token), message, 35_000)
  catch
    :exit, _ -> {:error, :ended}
  end

  defp relay_name(token), do: {:via, Registry, {@registry, {:sign_in, token}}}

  # ============================================================================
  # Pipes
  # ============================================================================

  @doc """
  Open, for the attempt `opener`, the `run` session of the program row
  `row` (a stored `mcp_servers` row, `pipe` or `stdio` with a kept home)
  in the kept home `home_id` under `key`, starting its program with `argv`
  appended unless it runs for the key. Answers the session and whether it
  was running (`resumed`); a repeat by the same opener while the session
  is the same answers as the first did. Everything, the owner's
  acquisition and a retry included, fits `deadline` (Unix milliseconds;
  #{@default_wait_ms} ms from now when nil): past it the open answers
  `{:error, :deadline}` and leaves nothing it started open. Refused
  otherwise as `hold/2` and the session route refuse.
  """
  @spec pipe_open(map(), String.t(), String.t(), [String.t()], String.t(), integer() | nil) ::
          {:ok, %{session: String.t(), resumed: boolean()}} | {:error, term()}
  def pipe_open(row, home_id, key, argv, opener, deadline \\ nil)
      when is_binary(home_id) and is_binary(key) and is_list(argv) and is_binary(opener) do
    pipe_open(row, home_id, key, argv, opener, deadline || default_deadline(), 1)
  end

  # A holder that ended as it was found (its idle period ran out) is
  # started afresh, once. The call is awaited past the deadline by the
  # margin the holder needs to answer that it passed.
  defp pipe_open(row, home_id, key, argv, opener, deadline, tries) do
    with {:ok, pid} <- pipe_holder(row, home_id, key) do
      wait = max(deadline - System.system_time(:millisecond), 0) + @answer_margin_ms
      GenServer.call(pid, {:open, opener, argv, deadline}, wait)
    end
  catch
    :exit, {reason, _} when reason in [:noproc, :normal] and tries > 0 ->
      pipe_open(row, home_id, key, argv, opener, deadline, tries - 1)

    :exit, {:timeout, _} ->
      {:error, :deadline}

    :exit, _ ->
      {:error, :backends_unavailable}
  end

  defp default_deadline, do: System.system_time(:millisecond) + @default_wait_ms

  defp left(deadline), do: max(deadline - System.system_time(:millisecond), 1)

  defp pipe_holder(row, home_id, key) do
    owner = %{athanor_id: row.athanor_id, server_id: row.id, epoch: row.epoch}

    args = [
      name:
        {:via, Registry,
         {@registry, {:pipe, owner.athanor_id, owner.server_id, owner.epoch, home_id, key}}},
      owner: owner,
      program: program_name(row),
      row_name: row.name,
      home_id: home_id,
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
  The box's open of a pipe session for the holder `holder` of `owner`
  (`Opus.Programs.Pipe`), with `params` (`program`, `home_id`, `key`,
  `argv`): recorded in the box before the backend is asked, so whatever
  the backend answers under the key is the box's, and answered by
  `deadline` (Unix milliseconds). Answers the session the box gave the
  key, `{:error, :deadline}` past it, or the refusal.
  """
  @spec pipe_box_open(map(), pid(), map(), integer()) ::
          {:ok, %{session: String.t(), resumed: boolean()}} | {:error, term()}
  def pipe_box_open(owner, holder, params, deadline) do
    wait = max(deadline - System.system_time(:millisecond), 0) + @answer_margin_ms

    case call(box_of(owner.athanor_id), {:pipe_open, owner, holder, params, deadline}, wait) do
      {:error, :backends_unavailable} -> {:error, :deadline}
      answer -> answer
    end
  end

  @doc """
  The calling holder's key's session ends: the box closes it, and owes the
  close until the backend confirms it.
  """
  @spec pipe_box_close(map(), String.t(), String.t()) :: :ok | {:error, term()}
  def pipe_box_close(owner, home_id, key),
    do:
      call(box_of(owner.athanor_id), {:pipe_close, owner, home_id, key}, Box.control_timeout_ms())

  @doc """
  Write `lines` to the pipe session `session` of the athanor, for the
  attempt `opener` that opened it, within `deadline` (as `pipe_open/6`'s).
  `{:error, :ended}` once its program no longer runs, or when no holder
  holds the session any more; `{:error, :denied}` for a session the opener
  did not open; `{:error, :uncertain}` when the box's answer did not come
  back, since the lines may have reached the program.
  """
  @spec pipe_send(String.t(), String.t(), String.t(), [String.t()], integer() | nil) ::
          :ok | {:error, term()}
  def pipe_send(athanor_id, opener, session, lines, deadline \\ nil) when is_list(lines) do
    deadline = deadline || default_deadline()

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
          integer() | nil
        ) ::
          {:ok,
           %{lines: [Prima.LocusBackends.line()], dropped: non_neg_integer(), running: boolean()}}
          | {:error, term()}
  def pipe_recv(athanor_id, opener, session, after_seq, max_wait_ms, deadline \\ nil) do
    deadline = deadline || System.system_time(:millisecond) + max_wait_ms + @default_wait_ms

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
  @spec pipe_close(String.t(), String.t(), String.t(), integer() | nil) :: :ok | {:error, term()}
  def pipe_close(athanor_id, opener, session, deadline \\ nil) do
    deadline = deadline || default_deadline()

    case pipe_pid(session) do
      nil -> :ok
      pid -> GenServer.call(pid, {:close, athanor_id, opener, session}, left(deadline))
    end
  catch
    :exit, _ -> :ok
  end

  @doc """
  What every pipe session held here mounts: its athanor, its login entry
  (its kept home) and the program row's name, once each, so a sweep can
  end those whose entry no longer serves (`end_mounts/2`).
  """
  @spec mounts() :: [{String.t(), String.t(), String.t()}]
  def mounts do
    if Process.whereis(@relays) do
      for {_id, pid, _type, [Pipe]} <- DynamicSupervisor.which_children(@relays),
          is_pid(pid),
          mount = pipe_mount(pid),
          mount != nil,
          uniq: true,
          do: mount
    else
      []
    end
  end

  defp pipe_mount(pid) do
    GenServer.call(pid, :mount, 5_000)
  catch
    :exit, _ -> nil
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

  # Who asked: the athanor, the person and the credential that admitted them.
  defp caller(%Sanctum.Context{} = ctx),
    do: {ctx.athanor_id, ctx.user_id, ctx.session_token_hash || ctx.api_key_id}

  # One sign-in per caller and row: the session key is the binding's digest.
  defp key(binding) do
    "signin-" <>
      (binding
       |> :erlang.term_to_binary()
       |> Prima.Digest.sha256_hex()
       |> binary_part(0, 32))
  end

  # A sign-in runs the row's login command for its first program.
  defp program_name(row) do
    case Arca.McpServerStorage.config(row)["backends"] do
      [%{"name" => name} | _] -> name
      _ -> "program"
    end
  end
end
