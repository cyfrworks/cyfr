# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs.Box do
  @moduledoc """
  The controller of one box: one backends service Locus serves (over
  `Prima.LocusBackends`), the one process that tells it which programs run
  and the only holder of its service key. `Opus.Programs` starts one per
  box and routes to it; the local box, named by `.env`
  (`CYFR_LOCUS_BACKENDS_URL`, `CYFR_LOCUS_BACKENDS_KEY`), is the only one.

  An **owner** is one `mcp_servers` row of one athanor whose transport is
  `stdio` or `pipe` — the pair `(athanor_id, mcp_servers.id)` — held by one
  or more **holders**: the processes that speak over its sessions (an
  `Emissary.External.Server` for a stdio row, a sign-in relay). The service
  runs an owner's programs at a version `(g, e)`: `g` is this member's
  control-plane generation (`Arca.ControlPlane.generation/0`; a member that
  holds no claim speaks generation 1) and `e` is the row's epoch. An owner
  lives while one of its holders does; the last one's stop or exit releases
  it.

  ## One claimed controller per owner

  Exactly one member of the cell runs an owner: the `job_claims` row of kind
  `mcp_backend` under the key `"<athanor_id>:<mcp_servers.id>"`
  (`Arca.JobClaims`, renewed every tick). A sync takes the row before it
  reads the store, resolves an env template or sends anything, so a member
  that does not hold it runs nothing, asks the vault for nothing, and
  refuses its holder `:claimed_elsewhere` — distinct from
  `:claim_unavailable`, the row failing to answer at all.

  Four checks decide whether this controller may act for an owner: the
  claim's **fence** (every write is a compare-and-set on it), the claim's
  **owner** (this member's boot id, `Prima.Boot.id/0`), the row's **epoch**
  (a config change, a disable and a vault reconcile raise it, and an owner
  that fails that fence is released and its holders told to stand down),
  and this member's **generation** (it rises only when this member's slot
  is taken over, so a member that won its slot back greets the service
  again and re-syncs).

  A renewal round is put ahead of everything else queued. A controller that
  finds its claim taken **stands down**: it tells the owner's holders
  `{Opus.Programs, :stand_down, {athanor_id, server_id}}`, forgets the
  claim and drops any release still pending for it, because the owner on
  the service is the peer's now. Opus names no holder's module: each holder
  stops itself on that message.

  ## Messages

  Control messages are POSTed to the service's control route one at a time,
  each encoded at the protocol version and signed with the control key under
  a sequence number that only grows. Every answer is read strictly at the
  same version. Lease maintenance — `renew`, `release` and `home`, with
  `hello` and `reconcile` ahead of them — is sent before any `sync` or
  `status` still waiting:

    * `hello` at start, and whenever the service's boot id or this boot's
      generation changes; then `reconcile`, which releases every owner the
      service runs that is not kept here at its version, and a `sync` of
      every owner still registered here;
    * `sync` when a holder asks for its owner: the row is read again
      (fenced: the same epoch, enabled, `stdio` or `pipe`, its athanor
      active), its programs read from its backends and its program columns
      (`Opus.Programs.Definition.programs/2`), its env templates resolved
      through `Sanctum.VaultReader.unseal_disclosed/2` and sealed for the
      owner and the service's lifetime. A template naming an attach-only
      entry refuses the sync `:disclosure_refused` before any entry is
      unsealed. The service admits the version and answers at once: nothing
      starts until a holder opens a session, so the grant is answered then;
    * `renew` every third of the lease for every live owner whose row still
      passes the fence; an owner that fails the fence is released, an owner
      the service no longer knows has its epoch raised, and either way its
      holders are told to stand down;
    * `release` on every stop path, retried on every tick until the
      service acknowledges it or a later sync supersedes it;
    * `home`, resetting or retiring one kept home (`home/4`); a retire that
      does not land is retried on every tick until it does;
    * `status` for `mcp_servers.get`, naming one owner, refused as
      `{:error, :too_many_owners}` or `{:error, :status_too_large}` past the
      wire's bounds, never cut.

  Every sync asks the service to end a session with no `send` and no `recv`
  for the idle period (the `locus_backends_idle_ms` platform setting). The
  lease and idle periods are read at every tick.

  Nothing is sent, and no claim renewed, while this member does not hold its
  slot in the cell (`Arca.ControlPlane.held?/0`) or its generation cannot be
  read.

  A refusal is its code (`Prima.LocusBackends.classes/0`) as an atom, except
  that a bad signature is `:backends_refused_signature`, an unavailable
  service `:backends_unavailable`, another protocol version
  `:protocol_mismatch`, and an answer that does not read at its status
  `{:backends_status, status}`.

  ## Grants

  A holder receives a **grant** for its owner — the service's session route,
  the owner, its generation and epoch, the service boot id, the idle period
  the service ends a session after, and the owner key
  (`Prima.LocusBackends.owner_key/2`) it signs its session messages with —
  as the answer to `Opus.Programs.hold/1` once the service admitted the
  sync. A re-sync the controller starts itself sends every holder
  `{Opus.Programs, :owner, grant}`.

  ## Shares

  Every live owner of one athanor together defines at most a quarter of the
  service's pool in programs; a sync past that share is refused.
  """

  use GenServer

  require Logger

  alias Arca.JobClaims
  alias Opus.Programs.{Definition, StatusRedaction}
  alias Prima.LocusBackends
  alias Prima.VaultRef

  # The cell's claim on one owner. Its key carries no epoch: a restart at a
  # new epoch is the same owner, and the claim carries across it.
  @claim_kind "mcp_backend"

  @control_timeout_ms 10_000
  @release_wait_ms 3_000

  @typedoc """
  One program row of one athanor at one epoch, as a holder names it; `sign_in: true` says the holder is a
  sign-in relay, which renewal admits while the row's login entry waits to
  be signed in again.
  """
  @type owner :: %{
          required(:athanor_id) => String.t(),
          required(:server_id) => String.t(),
          required(:epoch) => pos_integer(),
          optional(:sign_in) => boolean()
        }

  @typedoc "What a holder signs its session messages to the service with."
  @type grant :: %{
          url: String.t(),
          athanor: String.t(),
          server: String.t(),
          generation: pos_integer(),
          epoch: pos_integer(),
          boot: String.t(),
          idle_ms: pos_integer(),
          owner_key: binary()
        }

  defmodule State do
    @moduledoc false
    # The root and the keys derived from it never reach a log or a crash report.
    @derive {Inspect, except: [:root, :control_key, :seal_key]}
    defstruct [
      :box,
      :url,
      :root,
      :control_key,
      :seal_key,
      :cyfr_boot,
      :boot,
      :generation,
      :pool_size,
      :inflight,
      generation_source: &Arca.ControlPlane.generation/0,
      # The periods the caller fixed; the rest are read at every tick.
      fixed: [],
      lease_ms: 30_000,
      idle_ms: 900_000,
      tick_ms: 10_000,
      owners: %{},
      # The `mcp_backend` claim this controller holds for each owner, and
      # the keys whose claims it is giving up once the service has released
      # their owner.
      claims: %{},
      releasing: %{},
      releases: %{},
      release_waiters: %{},
      # Kept homes to reset or retire: {athanor, home_id} => %{op, waiters}.
      homes: %{},
      # Lease maintenance, sent first; then syncs and status reads.
      urgent: :queue.new(),
      queue: :queue.new()
    ]
  end

  # ============================================================================
  # Start
  # ============================================================================

  @doc """
  Start the controller of one box. Answers `:ignore` unless `:url` is a
  non-empty URL and `:root` a 32-byte service key.

  ## Options

    * `:box` — the box's name, under which `Opus.Programs` finds it; required.
    * `:name` — the process name; required.
    * `:url`, `:root` — the service's base URL (a trailing `/` dropped) and
      its 32-byte key, from which the control and seal keys derive.
    * `:lease_ms`, `:idle_ms` — fixed for the controller's life when given;
      otherwise the `locus_backends_lease_ms` and `locus_backends_idle_ms`
      platform settings as they read at every tick.
    * `:tick_ms` — the renewal cadence; default a third of the lease.
    * `:generation` — the zero-arity function this member's generation is
      read from: `{:ok, generation}`, `:none` (generation 1) or anything
      else (nothing is sent). Default `Arca.ControlPlane.generation/0`.
  """
  def start_link(opts) do
    url = Keyword.get(opts, :url)
    root = Keyword.get(opts, :root)

    if is_binary(url) and url != "" and is_binary(root) and byte_size(root) == 32 do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    else
      :ignore
    end
  end

  @doc false
  def child_spec(opts),
    do: %{id: {__MODULE__, Keyword.fetch!(opts, :box)}, start: {__MODULE__, :start_link, [opts]}}

  @doc "How long `Opus.Programs.hold/1` waits on a box."
  @spec hold_timeout_ms() :: pos_integer()
  def hold_timeout_ms, do: 3 * @control_timeout_ms

  @doc "How long a release waits on a box."
  @spec release_timeout_ms() :: pos_integer()
  def release_timeout_ms, do: @release_wait_ms

  @doc "How long a status or a home message waits on a box."
  @spec control_timeout_ms() :: pos_integer()
  def control_timeout_ms, do: 2 * @control_timeout_ms

  # ============================================================================
  # Server
  # ============================================================================

  @impl true
  def init(opts) do
    root = Keyword.fetch!(opts, :root)

    state =
      periods(%State{
        box: Keyword.fetch!(opts, :box),
        url: String.trim_trailing(Keyword.fetch!(opts, :url), "/"),
        root: root,
        control_key: LocusBackends.control_key(root),
        seal_key: LocusBackends.seal_key(root),
        cyfr_boot: Prima.Boot.id(),
        fixed: Keyword.take(opts, [:lease_ms, :idle_ms, :tick_ms]),
        generation_source: Keyword.get(opts, :generation, &Arca.ControlPlane.generation/0)
      })

    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_call({:hold, owner, pid}, from, state) do
    key = {owner.athanor_id, owner.server_id}
    epoch = owner.epoch

    cond do
      plane_generation(state) == :not_owner ->
        {:reply, {:error, :control_plane_lost}, state}

      match?(%{epoch: registered} when registered > epoch, state.owners[key]) ->
        {:reply, {:error, :stale_epoch}, state}

      match?(
        %{epoch: ^epoch, live?: true, generation: g} when g == state.generation,
        state.owners[key]
      ) and not Map.has_key?(state.owners[key].holders, pid) ->
        # A live owner at this version answers a new holder at once: its
        # sessions are the holder's to open. A holder asking again was
        # refused by the service under its grant, so the owner is synced
        # again.
        entry = state.owners[key]
        state = put_owner(state, key, add_holder(entry, pid, owner))
        {:reply, {:ok, grant(state, key, entry)}, state}

      true ->
        state = state |> register(key, epoch, pid, from, owner) |> enqueue({:sync, key})
        {:noreply, dispatch(state)}
    end
  end

  # A holder is stopping: it holds the owner no more, and once no holder
  # does, this member stops running it — the owner is released and the
  # claim given up with it, so the next member may take it.
  def handle_call({:release, owner}, {pid, _tag} = from, state) do
    key = {owner.athanor_id, owner.server_id}
    epoch = owner.epoch

    {state, last?} =
      case state.owners[key] do
        nil ->
          {state, true}

        %{epoch: registered} = entry when registered <= epoch ->
          entry = remove_holder(entry, pid)

          if entry.holders == %{},
            do: {state |> put_owner(key, entry) |> drop_owner(key), true},
            else: {put_owner(state, key, entry), false}

        _newer ->
          {state, false}
      end

    if last? do
      state = state |> give_up_claim(key) |> pend_release(key, epoch)

      if Map.has_key?(state.releases, key) do
        state = %{
          state
          | release_waiters: Map.update(state.release_waiters, key, [from], &[from | &1])
        }

        {:noreply, state |> enqueue({:release}) |> dispatch()}
      else
        # Nothing of this owner is this controller's to end.
        {:reply, :ok, dispatch(state)}
      end
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:status, key}, from, state) do
    {:noreply, state |> enqueue({:status, key, from}) |> dispatch()}
  end

  def handle_call(:homes, from, state) do
    {:noreply, state |> enqueue({:homes, from}) |> dispatch()}
  end

  def handle_call({:home, athanor, home_id, op}, from, state) do
    if plane_generation(state) == :not_owner do
      {:reply, {:error, :control_plane_lost}, state}
    else
      hkey = {athanor, home_id}

      homes =
        Map.update(state.homes, hkey, %{op: op, waiters: [from]}, fn pending ->
          # A retire covers a reset still waiting; a reset never undoes a retire.
          op = if pending.op == :retire, do: :retire, else: op
          %{pending | op: op, waiters: [from | pending.waiters]}
        end)

      {:noreply, %{state | homes: homes} |> enqueue({:home, hkey}) |> dispatch()}
    end
  end

  def handle_call({:release_referencing, athanor_id, names}, _from, state) do
    keys =
      for {{^athanor_id, _server} = key, %{names: [_ | _] = referenced}} <- state.owners,
          names == :any or Enum.any?(referenced, &(&1 in names)),
          do: key

    state = Enum.reduce(keys, state, &revoke(&2, &1))
    {:reply, Enum.map(keys, &elem(&1, 1)), state |> enqueue_release() |> dispatch()}
  end

  @impl true
  def handle_cast({:boot_seen, boot}, state) do
    {:noreply, state |> observe_boot(boot) |> dispatch()}
  end

  @impl true
  def handle_info(:tick, state) do
    state = periods(state)
    Process.send_after(self(), :tick, state.tick_ms)

    state =
      case plane_generation(state) do
        {:ok, generation} ->
          state = check_generation(state, generation)
          state = if state.boot == nil, do: enqueue(state, {:hello}), else: state
          state = if live_keys(state) != [], do: enqueue(state, {:renew}), else: state
          state = Enum.reduce(Map.keys(state.homes), state, &enqueue(&2, {:home, &1}))
          state = enqueue_release(state)
          renew_claims(state)

        :not_owner ->
          state
      end

    {:noreply, dispatch(state)}
  end

  def handle_info({ref, result}, %State{inflight: {ref, job, spec}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | inflight: nil} |> settle(job, spec, result) |> dispatch()}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{inflight: {ref, job, spec}} = state
      ) do
    result = {:error, {:crashed, reason}}
    {:noreply, %{state | inflight: nil} |> settle(job, spec, result) |> dispatch()}
  end

  # A holder that exits, however it exits, holds its owner no more; the last
  # one's exit releases the owner and gives up this member's claim.
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Enum.find(state.owners, fn {_key, entry} -> entry.holders[pid] == ref end) do
      {key, entry} ->
        entry = remove_holder(entry, pid)

        if entry.holders == %{} do
          state =
            state
            |> put_owner(key, entry)
            |> drop_owner(key)
            |> pend_release(key, entry.epoch)
            |> give_up_claim(key)

          {:noreply, state |> enqueue_release() |> dispatch()}
        else
          {:noreply, put_owner(state, key, entry)}
        end

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(message, state) do
    Prima.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  @impl true
  def format_status(status), do: StatusRedaction.format_status(status)

  # ============================================================================
  # Owners and holders
  # ============================================================================

  # A holder at the registered epoch joins the owner and waits on its sync.
  # A higher epoch replaces the owner: its holders, which hold a version
  # nothing will run again, are told to stand down, and a live one is
  # released.
  defp register(state, key, epoch, pid, from, owner) do
    case state.owners[key] do
      %{epoch: ^epoch} = entry ->
        put_owner(state, key, %{add_holder(entry, pid, owner) | waiters: [from | entry.waiters]})

      previous ->
        state =
          case previous do
            nil ->
              state

            %{live?: true} ->
              notify_holders(previous, key, pid)
              state |> drop_owner(key) |> pend_release(key, previous.epoch)

            _not_live ->
              notify_holders(previous, key, pid)
              drop_owner(state, key)
          end

        put_owner(state, key, %{
          holders: %{pid => Process.monitor(pid)},
          sign_ins: if(sign_in?(owner), do: MapSet.new([pid]), else: MapSet.new()),
          epoch: epoch,
          generation: nil,
          live?: false,
          names: [],
          programs: 0,
          waiters: [from]
        })
    end
  end

  # A holder whose owner map says `sign_in: true` holds the owner for a
  # sign-in session (`Opus.Programs.SignIn`): renewal admits it while the
  # row's login entry waits to be signed in again (`mount/2`).
  defp add_holder(entry, pid, owner) do
    entry =
      if Map.has_key?(entry.holders, pid),
        do: entry,
        else: %{entry | holders: Map.put(entry.holders, pid, Process.monitor(pid))}

    if sign_in?(owner), do: %{entry | sign_ins: MapSet.put(entry.sign_ins, pid)}, else: entry
  end

  defp sign_in?(owner), do: Map.get(owner, :sign_in) == true

  defp remove_holder(entry, pid) do
    case Map.pop(entry.holders, pid) do
      {nil, _holders} ->
        entry

      {ref, holders} ->
        Process.demonitor(ref, [:flush])
        %{entry | holders: holders, sign_ins: MapSet.delete(entry.sign_ins, pid)}
    end
  end

  # The owner's entry is admitted for its sign-ins alone: every other
  # holder is told to stand down and holds it no more.
  defp stand_down_all_but_sign_ins(state, key) do
    case state.owners[key] do
      nil ->
        state

      entry ->
        others =
          for {pid, _ref} <- entry.holders, not MapSet.member?(entry.sign_ins, pid), do: pid

        Enum.each(others, &send(&1, {Opus.Programs, :stand_down, key}))
        put_owner(state, key, Enum.reduce(others, entry, &remove_holder(&2, &1)))
    end
  end

  # Every holder but `except` is told the owner is not its to use.
  defp notify_holders(entry, key, except \\ nil) do
    for {pid, _ref} <- entry.holders,
        pid != except,
        do: send(pid, {Opus.Programs, :stand_down, key})

    :ok
  end

  defp put_owner(state, key, entry), do: %{state | owners: Map.put(state.owners, key, entry)}

  defp drop_owner(state, key) do
    case Map.pop(state.owners, key) do
      {nil, _owners} ->
        state

      {entry, owners} ->
        for {_pid, ref} <- entry.holders, do: Process.demonitor(ref, [:flush])
        for waiter <- entry.waiters, do: GenServer.reply(waiter, {:error, :released})
        %{state | owners: owners}
    end
  end

  # A release names a version this controller ran, and it is this
  # controller's to send only while it holds the owner's claim. A member
  # that stood down writes nothing more for the owner.
  defp pend_release(state, key, epoch) do
    if Map.has_key?(state.claims, key),
      do: %{state | releases: Map.update(state.releases, key, epoch, &max(&1, epoch))},
      else: state
  end

  defp enqueue_release(%State{releases: releases, releasing: releasing} = state)
       when releases == %{} and releasing == %{},
       do: state

  defp enqueue_release(state), do: enqueue(state, {:release})

  # ============================================================================
  # The owner claims
  # ============================================================================

  defp claim_key({athanor_id, server_id}), do: athanor_id <> ":" <> server_id

  defp hold_claim(state, key, claim), do: %{state | claims: Map.put(state.claims, key, claim)}

  # The row is written only once the service has released the owner running
  # under it, which is why the two travel in one job.
  defp give_up_claim(state, key) do
    if Map.has_key?(state.claims, key),
      do: enqueue_release(%{state | releasing: Map.put(state.releasing, key, true)}),
      else: state
  end

  defp forget_claims(state, keys) do
    %{state | claims: Map.drop(state.claims, keys), releasing: Map.drop(state.releasing, keys)}
  end

  defp giving_up(state) do
    Enum.reduce(state.releasing, %{}, fn {key, _true}, acc ->
      case state.claims[key] do
        nil -> acc
        claim -> Map.put(acc, key, claim)
      end
    end)
  end

  defp renew_claims(%State{claims: claims} = state) when claims == %{}, do: state
  defp renew_claims(state), do: enqueue_front(state, {:claims})

  # The row is a peer's now: the holders stand down, the claim is forgotten
  # and no release goes out for an owner this controller no longer runs.
  defp stand_down(state, {_athanor, server} = key) do
    Logger.warning(
      "[Opus.Programs] the claim on #{server} is held elsewhere; standing down without releasing it"
    )

    state =
      case state.owners[key] do
        nil ->
          state

        entry ->
          notify_holders(entry, key)
          Enum.each(entry.waiters, &GenServer.reply(&1, {:error, :claimed_elsewhere}))
          state |> put_owner(key, %{entry | waiters: []}) |> drop_owner(key)
      end

    state
    |> forget_claims([key])
    |> Map.update!(:releases, &Map.delete(&1, key))
    |> reply_release_waiters([key])
  end

  defp supersede_release(state, key, epoch) do
    state = %{state | releasing: Map.delete(state.releasing, key)}

    case state.releases do
      %{^key => pending} when pending <= epoch ->
        reply_release_waiters(%{state | releases: Map.delete(state.releases, key)}, [key])

      _ ->
        state
    end
  end

  # Out of service here first — no renewal, no grant — then released on the
  # service, and the holders told to stand down.
  defp revoke(state, key) do
    state =
      case state.owners[key] do
        nil ->
          state

        entry ->
          notify_holders(entry, key)
          state |> drop_owner(key) |> pend_release(key, entry.epoch)
      end

    give_up_claim(state, key)
  end

  defp live_keys(state) do
    for {key, %{live?: true, generation: generation}} <- state.owners,
        generation == state.generation,
        do: key
  end

  # The programs every other live owner in `key`'s athanor defines.
  defp held_by_others(state, {athanor_id, _server} = key) do
    for {{^athanor_id, _} = other, %{live?: true} = entry} <- state.owners,
        other != key,
        reduce: 0 do
      held -> held + entry.programs
    end
  end

  defp grant_waiters(state, key) do
    entry = state.owners[key]
    grant = grant(state, key, entry)
    Enum.each(entry.waiters, &GenServer.reply(&1, {:ok, grant}))
    put_owner(state, key, %{entry | waiters: []})
  end

  # ============================================================================
  # Lifetimes and generations
  # ============================================================================

  defp plane_generation(state) do
    if Arca.ControlPlane.held?() do
      case state.generation_source.() do
        {:ok, generation} when is_integer(generation) and generation > 0 -> {:ok, generation}
        :none -> {:ok, 1}
        _unreadable -> :not_owner
      end
    else
      :not_owner
    end
  end

  defp check_generation(%State{generation: nil} = state, _generation), do: state

  defp check_generation(state, generation) do
    if generation == state.generation do
      state
    else
      Logger.warning("[Opus.Programs] the control-plane generation changed; greeting the service")

      forget_service(state)
    end
  end

  defp observe_boot(state, nil), do: state
  defp observe_boot(%State{boot: nil} = state, _boot), do: state
  defp observe_boot(%State{boot: boot} = state, boot), do: state

  defp observe_boot(state, _other) do
    Logger.warning(
      "[Opus.Programs] the backends service restarted; greeting it and syncing live owners"
    )

    forget_service(state)
  end

  # Every registered owner is synced again after the next hello.
  defp forget_service(state) do
    owners = Map.new(state.owners, fn {key, entry} -> {key, %{entry | live?: false}} end)
    enqueue(%{state | boot: nil, owners: owners}, {:hello})
  end

  # ============================================================================
  # Lanes
  # ============================================================================

  defp lane({:sync, _key}), do: :queue
  defp lane({:status, _key, _from}), do: :queue
  defp lane({:homes, _from}), do: :queue
  defp lane(_job), do: :urgent

  defp enqueue(state, job) do
    if queued?(state, job),
      do: state,
      else: Map.update!(state, lane(job), &:queue.in(job, &1))
  end

  defp enqueue_front(state, job) do
    Map.update!(state, lane(job), fn queue ->
      :queue.in_r(job, :queue.filter(&(&1 != job), queue))
    end)
  end

  defp queued?(%State{inflight: {_ref, {:sync, key} = job, %{epoch: epoch}}} = state, job) do
    match?(%{epoch: ^epoch}, state.owners[key]) or :queue.member(job, state.queue)
  end

  defp queued?(state, job), do: :queue.member(job, Map.fetch!(state, lane(job)))

  defp next_job(state) do
    case :queue.out(state.urgent) do
      {{:value, job}, urgent} ->
        {job, %{state | urgent: urgent}}

      {:empty, _urgent} ->
        case :queue.out(state.queue) do
          {{:value, job}, queue} -> {job, %{state | queue: queue}}
          {:empty, _queue} -> :empty
        end
    end
  end

  defp dispatch(%State{inflight: nil} = state) do
    case next_job(state) do
      :empty ->
        state

      {job, state} ->
        generation = plane_generation(state)

        cond do
          generation == :not_owner ->
            state |> refuse(job, :control_plane_lost) |> dispatch()

          job != {:hello} and state.boot != nil and generation != {:ok, state.generation} ->
            state
            |> forget_service()
            |> enqueue_front(job)
            |> enqueue_front({:hello})
            |> dispatch()

          job != {:hello} and state.boot == nil ->
            state |> enqueue_front(job) |> enqueue_front({:hello}) |> dispatch()

          true ->
            {:ok, speaking} = generation

            case prepare(job, %{state | generation: speaking}) do
              :skip ->
                dispatch(state)

              {:send, spec} ->
                # The keys reach the task through its closure only.
                keys = %{control: state.control_key, seal: state.seal_key}
                task = Task.async(fn -> perform(spec, keys) end)
                %{state | inflight: {task.ref, job, spec}}
            end
        end
    end
  end

  defp dispatch(state), do: state

  defp refuse(state, {:sync, key}, reason) do
    case state.owners[key] do
      %{waiters: [_ | _] = waiters} = entry ->
        Enum.each(waiters, &GenServer.reply(&1, {:error, reason}))
        state = put_owner(state, key, %{entry | waiters: []})
        if entry.live?, do: state, else: state |> drop_owner(key) |> give_up_claim(key)

      _other ->
        state
    end
  end

  defp refuse(state, {:status, _key, from}, reason) do
    GenServer.reply(from, {:error, reason})
    state
  end

  defp refuse(state, {:release}, _reason),
    do: reply_release_waiters(state, Map.keys(state.release_waiters))

  defp refuse(state, {:home, hkey}, reason), do: home_failed(state, hkey, reason)

  defp refuse(state, {:homes, from}, reason) do
    GenServer.reply(from, {:error, reason})
    state
  end

  defp refuse(state, _job, _reason), do: state

  defp refuse_queued(state, reason) do
    jobs = :queue.to_list(state.urgent) ++ :queue.to_list(state.queue)

    Enum.reduce(
      jobs,
      %{state | urgent: :queue.new(), queue: :queue.new()},
      &refuse(&2, &1, reason)
    )
  end

  # ============================================================================
  # Building messages
  # ============================================================================

  defp base_spec(state, kind) do
    %{
      kind: kind,
      url: state.url,
      cyfr_boot: state.cyfr_boot,
      boot: state.boot,
      generation: state.generation,
      seq: System.unique_integer([:monotonic, :positive]),
      lease_ms: state.lease_ms
    }
  end

  defp prepare({:hello}, state) do
    body = %{type: :hello, g: state.generation, cyfr_boot: state.cyfr_boot}
    {:send, state |> base_spec(:hello) |> Map.merge(%{boot: "-", body: body})}
  end

  defp prepare({:reconcile}, state) do
    keep =
      for {athanor, server} = key <- live_keys(state),
          do: %{athanor: athanor, server: server, e: state.owners[key].epoch}

    {:send, state |> base_spec(:reconcile) |> Map.put(:body, %{type: :reconcile, keep: keep})}
  end

  defp prepare({:sync, key}, state) do
    case state.owners[key] do
      nil ->
        :skip

      entry ->
        {athanor_id, server_id} = key

        spec =
          state
          |> base_spec(:sync)
          |> Map.merge(%{
            athanor_id: athanor_id,
            server_id: server_id,
            epoch: entry.epoch,
            idle_ms: state.idle_ms,
            share: share(state),
            athanor_programs: held_by_others(state, key)
          })
          |> claim_spec(state)

        {:send, spec}
    end
  end

  defp prepare({:claims}, %State{claims: claims}) when claims == %{}, do: :skip

  defp prepare({:claims}, state),
    do:
      {:send, state |> base_spec(:claims) |> Map.put(:claims, state.claims) |> claim_spec(state)}

  defp prepare({:renew}, state) do
    case live_keys(state) do
      [] ->
        :skip

      keys ->
        owners = Map.new(keys, &{&1, state.owners[&1].epoch})
        signing = for key <- keys, MapSet.size(state.owners[key].sign_ins) > 0, do: key

        {:send,
         state
         |> base_spec(:renew)
         |> Map.merge(%{owners: owners, signing: MapSet.new(signing)})}
    end
  end

  defp prepare({:release}, state) do
    giving_up = giving_up(state)

    if state.releases == %{} and giving_up == %{} do
      :skip
    else
      owners =
        for {{athanor, server}, epoch} <- state.releases,
            do: %{athanor: athanor, server: server, e: epoch}

      spec =
        state
        |> base_spec(:release)
        |> Map.merge(%{
          releases: state.releases,
          giving_up: giving_up,
          body: %{type: :release, owners: owners}
        })

      {:send, spec}
    end
  end

  defp prepare({:home, {athanor, home_id} = hkey}, state) do
    case state.homes[hkey] do
      nil ->
        :skip

      %{op: op} ->
        body = %{type: :home, op: op, athanor: athanor, home_id: home_id}
        {:send, state |> base_spec(:home) |> Map.merge(%{body: body, home: hkey, op: op})}
    end
  end

  defp prepare({:homes, _from}, state),
    do: {:send, state |> base_spec(:homes) |> Map.put(:body, %{type: :homes})}

  defp prepare({:status, {athanor, server}, from}, state) do
    if LocusBackends.max_status_owners() < 1 do
      GenServer.reply(from, {:error, :too_many_owners})
      :skip
    else
      body = %{type: :status, owners: [%{athanor: athanor, server: server}]}
      {:send, state |> base_spec(:status) |> Map.put(:body, body)}
    end
  end

  defp claim_spec(spec, state),
    do: Map.merge(spec, %{claim_owner: state.cyfr_boot, claim_lease_ms: state.lease_ms})

  # The most programs one athanor's owners may define.
  defp share(%State{pool_size: size}) when is_integer(size), do: max(div(size, 4), 1)
  defp share(_state), do: nil

  # ============================================================================
  # Performing: store reads, vault reads and HTTP, in the task
  # ============================================================================

  # A raised exception is reported by its module only: its message can carry
  # a resolved env value.
  defp perform(spec, keys) do
    do_perform(spec, keys)
  rescue
    error -> {:error, {:crashed, error.__struct__}}
  catch
    kind, _reason -> {:error, {:crashed, kind}}
  end

  defp do_perform(%{kind: :sync} = spec, keys) do
    case claim_owner(spec) do
      {:ok, claim} -> {:claimed, claim, sync_claimed(spec, keys)}
      refused -> refused
    end
  end

  defp do_perform(%{kind: :claims} = spec, _keys) do
    {:claims_held, Map.new(spec.claims, &{elem(&1, 0), keep_claim(&1, spec)})}
  end

  defp do_perform(%{kind: :renew} = spec, keys) do
    pairs = Map.keys(spec.owners)

    case Arca.McpServerStorage.fenced(pairs) do
      {:ok, rows} ->
        verdicts =
          Map.new(pairs, fn key ->
            verdict =
              if passes_fence?(rows[key], spec.owners[key]),
                do: mount(rows[key], MapSet.member?(spec.signing, key)),
                else: :out

            {key, verdict}
          end)

        {kept, fenced_out} = Enum.split_with(pairs, &(verdicts[&1] != :out))
        signing_only = Enum.filter(pairs, &(verdicts[&1] == :sign_in_only))
        answer = if kept == [], do: :nothing_to_renew, else: renew(spec, keys.control, kept)
        {:renewed, answer, fenced_out, signing_only}

      {:error, _} ->
        {:error, :store_unavailable}
    end
  end

  defp do_perform(%{kind: :release} = spec, keys) do
    answer =
      if spec.releases == %{},
        do: :nothing_to_release,
        else: post(spec, keys.control, spec.body)

    {:released, answer, released_claims(spec, answer)}
  end

  defp do_perform(spec, keys), do: post(spec, keys.control, spec.body)

  defp sync_claimed(spec, keys) do
    owner = %{athanor_id: spec.athanor_id, server_id: spec.server_id, epoch: spec.epoch}

    with {:ok, row} <- fence_one(owner),
         {:ok, backends} <- Definition.validate(Arca.McpServerStorage.config(row)["backends"]),
         programs = Definition.programs(row, backends),
         :ok <- within_share(spec, length(programs)),
         {:ok, sealed} <- seal_env(spec, keys.seal, programs) do
      # A definition's warnings never stop its programs: the administrator
      # was told when it was saved, and each sync says so once in the log.
      for warning <- Definition.warnings(backends) do
        Logger.warning(
          "[Opus.Programs] server #{spec.server_id} of athanor " <>
            "#{spec.athanor_id} starts with a warning: #{warning}"
        )
      end

      body = %{
        type: :sync,
        owner: %{athanor: spec.athanor_id, server: spec.server_id},
        e: spec.epoch,
        lease_ms: spec.lease_ms,
        idle_ms: spec.idle_ms,
        programs: Enum.map(programs, &Definition.wire/1),
        sealed: sealed
      }

      case post(spec, keys.control, body) do
        {:http, _status, _boot, _body} = answer ->
          {:synced, answer, Definition.entry_names(backends), length(programs)}

        error ->
          error
      end
    end
  end

  defp claim_owner(spec) do
    case JobClaims.claim(
           @claim_kind,
           claim_key({spec.athanor_id, spec.server_id}),
           spec.claim_owner,
           spec.claim_lease_ms
         ) do
      {:ok, claim} -> {:ok, claim}
      {:busy, _peers} -> {:error, :claimed_elsewhere}
      {:error, :database_error} -> {:error, :claim_unavailable}
    end
  end

  defp keep_claim({key, claim}, spec) do
    case JobClaims.renew(claim, spec.claim_lease_ms) do
      {:ok, renewed} -> {:ok, renewed}
      :taken -> :lost
      :lapsed -> retake_claim(key, spec)
      {:error, :database_error} -> :unverified
    end
  end

  defp retake_claim(key, spec) do
    case JobClaims.claim(@claim_kind, claim_key(key), spec.claim_owner, spec.claim_lease_ms) do
      {:ok, claim} -> {:ok, claim}
      {:busy, _peers} -> :lost
      {:error, :database_error} -> :unverified
    end
  end

  defp released_claims(spec, answer) do
    landed? =
      match?({:http, 200, _boot, %{released: _}}, answer) or answer == :nothing_to_release

    Enum.flat_map(spec.giving_up, fn {key, claim} ->
      if landed? or not Map.has_key?(spec.releases, key) do
        _ = JobClaims.release(claim)
        [key]
      else
        []
      end
    end)
  end

  # An owner the service no longer knows lapsed there: its epoch is raised,
  # so the grant its holders hold names a version nothing will run again.
  defp renew(spec, control_key, kept) do
    owners =
      for {athanor, server} = key <- kept,
          do: %{athanor: athanor, server: server, e: spec.owners[key]}

    body = %{type: :renew, lease_ms: spec.lease_ms, owners: owners}
    answer = post(spec, control_key, body)

    with {:http, 200, _boot, %{unknown: [_ | _] = unknown}} <- answer do
      for %{athanor: athanor, server: server, e: epoch} <- unknown do
        ctx = Sanctum.Context.internal(athanor_id: athanor, scope: :athanor)
        Arca.McpServerStorage.bump_epoch(Sanctum.Context.actor(ctx), server, epoch)
      end
    end

    answer
  end

  defp fence_one(owner) do
    key = {owner.athanor_id, owner.server_id}

    case Arca.McpServerStorage.fenced([key]) do
      {:ok, rows} -> fence_verdict(rows[key], owner.epoch)
      {:error, _} -> {:error, :store_unavailable}
    end
  end

  defp fence_verdict(nil, _epoch), do: {:error, :not_found}
  defp fence_verdict(%{athanor_active: false}, _epoch), do: {:error, :archived}
  defp fence_verdict(%{row: %{epoch: epoch, enabled: true} = row}, epoch), do: program(row)
  defp fence_verdict(%{row: %{enabled: false}}, _epoch), do: {:error, :disabled}
  defp fence_verdict(_fenced, _epoch), do: {:error, :stale_epoch}

  defp program(%{transport: transport} = row) when transport in ["stdio", "pipe"], do: {:ok, row}
  defp program(_row), do: {:error, :not_a_program}

  defp passes_fence?(fenced, epoch), do: match?({:ok, _row}, fence_verdict(fenced, epoch))

  # A kept stdio row runs in the home of the login entry it names, so each
  # renewal asks again that the entry is an active login entry of the
  # row's athanor naming the row: one revoked, suspended by a restore or
  # deleted releases the owner. A vault that cannot answer releases it too:
  # nothing runs in a home whose entry cannot be shown live. An entry a
  # restore left needs_reauth is admitted for a sign-in alone, as
  # `Sanctum.Mount.login_entry/4` with `for: :sign_in` admits it: an owner
  # held by a sign-in keeps it (`:sign_in_only`), and its other holders, an
  # MCP server's sessions, stand down. A pipe row's entry is its catalyst's
  # need's, checked where the need is resolved.
  defp mount(%{row: %{transport: "stdio", home: "kept"} = row}, signing?) do
    ctx = Sanctum.Context.internal(athanor_id: row.athanor_id, scope: :athanor)

    with true <- is_binary(row.login_entry_id) || :out,
         {:ok, entry} <-
           Sanctum.Mount.login_entry(ctx, row.login_entry_id, row.name, for: :sign_in) do
      cond do
        entry.status == "active" -> :live
        signing? -> :sign_in_only
        true -> :out
      end
    else
      _refused -> :out
    end
  end

  defp mount(_fenced, _signing?), do: :live

  defp within_share(%{share: nil}, _count), do: :ok

  defp within_share(spec, count) do
    if spec.athanor_programs + count > spec.share,
      do: {:error, {:pool_share, spec.share}},
      else: :ok
  end

  defp seal_env(spec, seal_key, programs) do
    owner = %{
      athanor: spec.athanor_id,
      server: spec.server_id,
      generation: spec.generation,
      epoch: spec.epoch
    }

    with {:ok, env} <- resolve_env(spec.athanor_id, programs) do
      LocusBackends.seal(seal_key, owner, spec.boot, Jason.encode!(env))
    end
  end

  defp resolve_env(athanor_id, programs) do
    with :ok <- check_env(athanor_id, programs) do
      unseal_env(athanor_id, programs)
    end
  end

  # From metadata alone (`Sanctum.Vault.disclosed?/2`): a reference this
  # server does not resolve, or an entry missing, inactive or attach-only,
  # refuses the sync before any entry is unsealed.
  defp check_env(athanor_id, programs) do
    ctx = Sanctum.Context.internal(athanor_id: athanor_id, scope: :athanor)

    Enum.find_value(programs, :ok, fn program ->
      Enum.find_value(program.env, fn {name, value} ->
        case VaultRef.classify(value) do
          {:vault, %{name: entry}} ->
            cond do
              Sanctum.Vault.disclosed?(ctx, entry) -> nil
              active?(athanor_id, entry) -> {:error, :disclosure_refused}
              true -> {:error, {:env_unresolved, program.name, name}}
            end

          :unresolved ->
            {:error, {:env_unresolved, program.name, name}}

          :literal ->
            nil
        end
      end)
    end)
  end

  defp active?(athanor_id, entry) do
    match?(
      {:ok, %{^entry => {_rev, _digest}}},
      Sanctum.VaultReader.revisions(athanor_id, [entry])
    )
  end

  defp unseal_env(athanor_id, programs) do
    Enum.reduce_while(programs, {:ok, %{}}, fn program, {:ok, acc} ->
      case resolve_program_env(athanor_id, program) do
        {:ok, env} -> {:cont, {:ok, Map.put(acc, program.name, env)}}
        error -> {:halt, error}
      end
    end)
  end

  defp resolve_program_env(athanor_id, program) do
    Enum.reduce_while(program.env, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case resolve_value(athanor_id, value) do
        {:ok, resolved} -> {:cont, {:ok, Map.put(acc, name, resolved)}}
        {:error, :disclosure_refused} -> {:halt, {:error, :disclosure_refused}}
        :error -> {:halt, {:error, {:env_unresolved, program.name, name}}}
      end
    end)
  end

  defp resolve_value(athanor_id, value) do
    case VaultRef.classify(value) do
      {:vault, %{name: entry} = template} ->
        case Sanctum.VaultReader.unseal_disclosed(athanor_id, entry) do
          {:ok, fields} when map_size(fields) == 1 ->
            {:ok, VaultRef.render(template, fields |> Map.values() |> hd())}

          {:error, :disclosure_refused} ->
            {:error, :disclosure_refused}

          _ ->
            :error
        end

      :unresolved ->
        :error

      :literal ->
        {:ok, value}
    end
  end

  defp post(spec, control_key, message) do
    control = %{
      generation: spec.generation,
      seq: spec.seq,
      cyfr_boot: spec.cyfr_boot,
      boot: spec.boot,
      ts: System.os_time(:millisecond)
    }

    with {:ok, body} <- encode(message),
         {:ok, header} <- LocusBackends.control_header(control_key, control, body) do
      headers = [{"content-type", "application/json"}, {LocusBackends.auth_header(), header}]

      opts = [
        receive_timeout: @control_timeout_ms,
        private_policy: :operator,
        max_response_bytes: answer_bytes(message.type)
      ]

      url = spec.url <> LocusBackends.route(:control)

      case Sanctum.Egress.pinned_request(:post, url, headers, body, opts) do
        {:ok, 200, resp_headers, resp_body} ->
          {:http, 200, boot_header(resp_headers), read_answer(message.type, resp_body)}

        {:ok, status, resp_headers, resp_body} ->
          {:http, status, boot_header(resp_headers), read_refusal(resp_body)}

        {:error, {:response_too_large, _read, _limit} = reason} ->
          {:error, reason}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    end
  end

  defp encode(message) do
    case LocusBackends.encode_control(message) do
      {:ok, body} -> {:ok, body}
      {:error, {:too_large, :control, _bytes, max}} -> {:error, {:control_too_large, max}}
      {:error, error} -> {:error, LocusBackends.refusal_for(error)}
    end
  end

  defp answer_bytes(:status), do: LocusBackends.max_status_answer_bytes()
  defp answer_bytes(_type), do: LocusBackends.max_control_bytes()

  defp read_answer(type, body) do
    case LocusBackends.read_answer(type, body) do
      {:ok, answer} -> answer
      {:error, error} -> {:unreadable, error}
    end
  end

  defp read_refusal(body) do
    case LocusBackends.read_refusal(body) do
      {:ok, code} -> {:refused, code}
      {:error, error} -> {:unreadable, error}
    end
  end

  @doc false
  # The service boot id a response names, from its `x-cyfr-boot` header.
  @spec boot_header([{String.t(), String.t()}]) :: String.t() | nil
  def boot_header(headers) do
    name = LocusBackends.boot_header()

    Enum.find_value(headers, fn {header, value} ->
      if String.downcase(to_string(header)) == name, do: to_string(value)
    end)
  end

  # ============================================================================
  # Settling answers
  # ============================================================================

  defp settle(state, {:hello} = job, spec, result), do: settle_job(state, job, spec, result)

  defp settle(state, job, spec, result) do
    state |> observe_boot(answer_boot(result)) |> settle_job(job, spec, result)
  end

  defp answer_boot({:http, _status, boot, _body}), do: boot
  defp answer_boot({:synced, answer, _names, _count}), do: answer_boot(answer)
  defp answer_boot({:renewed, answer, _fenced_out, _signing_only}), do: answer_boot(answer)
  defp answer_boot({:claimed, _claim, result}), do: answer_boot(result)
  defp answer_boot({:released, answer, _given_up}), do: answer_boot(answer)
  defp answer_boot(_result), do: nil

  defp settle_job(state, {:hello}, spec, {:http, 200, _boot, %{boot: boot, pool: pool}}) do
    Logger.info(
      "[Opus.Programs] greeted the backends service #{boot} under generation #{spec.generation}"
    )

    state = %{state | boot: boot, generation: spec.generation, pool_size: pool.size}

    resyncs = for {key, %{live?: false}} <- state.owners, do: {:sync, key}

    resyncs
    |> Enum.reverse()
    |> Enum.reduce(state, &enqueue_front(&2, &1))
    |> enqueue_front({:reconcile})
  end

  defp settle_job(state, {:hello}, _spec, result) do
    log_failure("hello", result)
    refuse_queued(state, :backends_unavailable)
  end

  defp settle_job(state, {:reconcile}, _spec, {:http, 200, _boot, %{released: released}}) do
    if released != [],
      do: Logger.info("[Opus.Programs] reconcile released #{length(released)} owners")

    reply_release_waiters(%{state | releases: %{}}, Map.keys(state.release_waiters))
  end

  defp settle_job(state, {:reconcile}, _spec, result) do
    log_failure("reconcile", result)
    state
  end

  defp settle_job(state, {:sync, key} = job, spec, {:claimed, claim, result}),
    do: state |> hold_claim(key, claim) |> settle_job(job, spec, result)

  defp settle_job(state, {:claims}, _spec, {:claims_held, verdicts}) do
    Enum.reduce(verdicts, state, fn
      {key, {:ok, claim}}, acc -> hold_claim(acc, key, claim)
      {key, :lost}, acc -> stand_down(acc, key)
      {_key, :unverified}, acc -> acc
    end)
  end

  defp settle_job(state, {:claims}, _spec, result) do
    log_failure("claims", result)
    state
  end

  defp settle_job(
         state,
         {:sync, key},
         spec,
         {:synced, {:http, 200, _boot, %{status: _status}}, names, count}
       ) do
    case state.owners[key] do
      %{epoch: epoch} = entry when epoch == spec.epoch ->
        entry = %{
          entry
          | live?: true,
            generation: spec.generation,
            names: names,
            programs: count
        }

        state = state |> put_owner(key, entry) |> supersede_release(key, epoch)

        if entry.waiters == [] do
          grant = grant(state, key, entry)
          for {pid, _ref} <- entry.holders, do: send(pid, {Opus.Programs, :owner, grant})
          state
        else
          grant_waiters(state, key)
        end

      _gone_or_replaced ->
        state |> pend_release(key, spec.epoch) |> enqueue_release()
    end
  end

  defp settle_job(state, {:sync, key}, spec, result) do
    reason = refusal(result)

    case state.owners[key] do
      %{epoch: epoch} when epoch != spec.epoch ->
        release_unanswered(state, key, spec, result)

      nil ->
        state |> give_up_claim(key) |> release_unanswered(key, spec, result)

      _entry when reason == :stale_boot ->
        enqueue(state, {:sync, key})

      entry ->
        log_failure("sync", result)
        Enum.each(entry.waiters, &GenServer.reply(&1, {:error, reason}))
        # A re-sync this controller started failed: the holders hold a grant
        # the service no longer honours.
        if entry.waiters == [], do: notify_holders(entry, key)

        state
        |> put_owner(key, %{entry | waiters: []})
        |> drop_owner(key)
        |> give_up_claim(key)
        |> release_unanswered(key, spec, result)
    end
  end

  defp settle_job(state, {:renew}, _spec, {:renewed, answer, fenced_out, signing_only}) do
    state = Enum.reduce(fenced_out, state, &revoke(&2, &1))
    state = Enum.reduce(signing_only, state, &stand_down_all_but_sign_ins(&2, &1))

    state =
      case answer do
        {:http, 200, _boot, %{unknown: unknown}} ->
          Enum.reduce(unknown, state, &lapsed(&2, &1))

        :nothing_to_renew ->
          state

        other ->
          log_failure("renew", other)
          state
      end

    enqueue_release(state)
  end

  defp settle_job(state, {:renew}, _spec, result) do
    log_failure("renew", result)
    state
  end

  defp settle_job(state, {:release} = job, spec, {:released, answer, given_up}),
    do: state |> forget_claims(given_up) |> settle_job(job, spec, answer)

  defp settle_job(state, {:release}, spec, :nothing_to_release),
    do: reply_release_waiters(state, Map.keys(spec.releases))

  defp settle_job(state, {:release}, spec, {:http, 200, _boot, %{released: _released}}) do
    releases =
      Enum.reduce(spec.releases, state.releases, fn {key, epoch}, acc ->
        case acc do
          %{^key => pending} when pending <= epoch -> Map.delete(acc, key)
          _ -> acc
        end
      end)

    reply_release_waiters(%{state | releases: releases}, Map.keys(spec.releases))
  end

  defp settle_job(state, {:release}, spec, result) do
    if refusal(result) != :stale_boot, do: log_failure("release", result)
    reply_release_waiters(state, Map.keys(spec.releases))
  end

  # A home message the service answered is done, unless a later one for the
  # same home arrived meanwhile and asked for more.
  defp settle_job(state, {:home, hkey}, spec, {:http, 200, _boot, %{home_id: _, state: _}}) do
    case state.homes[hkey] do
      %{op: op, waiters: waiters} when op == spec.op ->
        Enum.each(waiters, &GenServer.reply(&1, :ok))
        %{state | homes: Map.delete(state.homes, hkey)}

      _later ->
        enqueue(state, {:home, hkey})
    end
  end

  defp settle_job(state, {:home, hkey}, _spec, result) do
    log_failure("home", result)
    home_failed(state, hkey, refusal(result))
  end

  defp settle_job(state, {:homes, from}, _spec, {:http, 200, _boot, %{homes: homes}}) do
    GenServer.reply(from, {:ok, homes})
    state
  end

  defp settle_job(state, {:homes, from}, _spec, result) do
    GenServer.reply(from, {:error, refusal(result)})
    state
  end

  defp settle_job(state, {:status, key, from}, _spec, {:http, 200, _boot, %{owners: owners}}) do
    status = Enum.find(owners, &({&1.athanor, &1.server} == key))
    GenServer.reply(from, {:ok, status && wire(status)})
    state
  end

  defp settle_job(state, {:status, _key, from}, _spec, result) do
    GenServer.reply(from, {:error, refusal(result)})
    state
  end

  # A reset that failed is answered as failed and forgotten: the person asks
  # again. A retire is answered too, but stays pending and is sent again on
  # every tick until the service acknowledges it, since its entry is gone and
  # nothing would ask again.
  defp home_failed(state, hkey, reason) do
    case state.homes[hkey] do
      nil ->
        state

      %{op: :retire, waiters: waiters} = pending ->
        Enum.each(waiters, &GenServer.reply(&1, {:error, reason}))
        %{state | homes: Map.put(state.homes, hkey, %{pending | waiters: []})}

      %{waiters: waiters} ->
        Enum.each(waiters, &GenServer.reply(&1, {:error, reason}))
        %{state | homes: Map.delete(state.homes, hkey)}
    end
  end

  defp lapsed(state, %{athanor: athanor, server: server, e: epoch}) do
    key = {athanor, server}

    case state.owners[key] do
      %{epoch: ^epoch, live?: true} ->
        Logger.warning(
          "[Opus.Programs] the backends service no longer runs #{server}; its epoch was raised"
        )

        revoke(state, key)

      _other ->
        state
    end
  end

  # An owner report as the wire names it, which is how a status answers.
  # An absent member (nil) stays absent, as the wire spells it.
  defp wire(%{} = map),
    do: for({key, value} <- map, value != nil, into: %{}, do: {to_string(key), wire(value)})

  defp wire(list) when is_list(list), do: Enum.map(list, &wire/1)
  defp wire(atom) when is_atom(atom) and atom not in [nil, true, false], do: Atom.to_string(atom)
  defp wire(value), do: value

  # A sync whose answer never arrived may have admitted the owner.
  defp release_unanswered(state, key, spec, {:error, {kind, _}})
       when kind in [:transport, :crashed],
       do: state |> pend_release(key, spec.epoch) |> enqueue_release()

  defp release_unanswered(state, _key, _spec, _result), do: state

  defp reply_release_waiters(state, keys) do
    {waiting, rest} = Map.split(state.release_waiters, keys)
    for {_key, waiters} <- waiting, waiter <- waiters, do: GenServer.reply(waiter, :ok)
    %{state | release_waiters: rest}
  end

  defp grant(state, {athanor_id, server_id}, entry) do
    owner = %{
      athanor: athanor_id,
      server: server_id,
      generation: entry.generation,
      epoch: entry.epoch
    }

    {:ok, owner_key} = LocusBackends.owner_key(state.root, owner)

    %{
      url: state.url <> LocusBackends.route(:session),
      athanor: athanor_id,
      server: server_id,
      generation: entry.generation,
      epoch: entry.epoch,
      boot: state.boot,
      idle_ms: state.idle_ms,
      owner_key: owner_key
    }
  end

  @renamed_refusals %{
    unauthorized: :backends_refused_signature,
    unavailable: :backends_unavailable,
    version: :protocol_mismatch
  }

  @doc false
  # A wire refusal code as the controller and its holders answer it.
  @spec refusal_name(LocusBackends.code()) :: atom()
  def refusal_name(code), do: Map.get(@renamed_refusals, code, code)

  defp refusal({:synced, answer, _names, _count}), do: refusal(answer)
  defp refusal({:renewed, answer, _fenced_out, _signing_only}), do: refusal(answer)
  defp refusal({:claimed, _claim, result}), do: refusal(result)
  defp refusal({:released, answer, _given_up}), do: refusal(answer)
  defp refusal({:http, 401, _boot, _body}), do: :backends_refused_signature
  defp refusal({:http, _status, _boot, {:unreadable, {:version, _}}}), do: :protocol_mismatch

  defp refusal({:http, status, _boot, {:refused, code}} = answer) do
    if LocusBackends.status(code) == status,
      do: refusal_name(code),
      else: refusal(put_elem(answer, 3, :unreadable))
  end

  defp refusal({:http, status, _boot, _body}), do: {:backends_status, status}
  defp refusal({:error, {:transport, _}}), do: :backends_unavailable
  defp refusal({:error, {:crashed, _}}), do: :backends_unavailable
  defp refusal({:error, {:response_too_large, _read, _limit}}), do: :status_too_large
  defp refusal({:error, reason}), do: reason
  defp refusal(other), do: {:unexpected, other}

  defp periods(%State{fixed: fixed} = state) do
    lease_ms = Keyword.get_lazy(fixed, :lease_ms, fn -> setting("locus_backends_lease_ms") end)

    %{
      state
      | lease_ms: lease_ms,
        idle_ms: Keyword.get_lazy(fixed, :idle_ms, fn -> setting("locus_backends_idle_ms") end),
        tick_ms: Keyword.get(fixed, :tick_ms, div(lease_ms, 3))
    }
  end

  defp setting(key) do
    {:ok, value} = Arca.PlatformSettings.effective(key)
    value
  end

  defp log_failure(what, result) do
    case refusal(result) do
      :claimed_elsewhere ->
        Logger.info("[Opus.Programs] #{what} refused: another member of the cell holds the owner")

      :backends_refused_signature ->
        Logger.error(
          "[Opus.Programs] the backends service refused the #{what} signature — " <>
            "CYFR_LOCUS_BACKENDS_KEY must be the same value for cyfr and locus-backends"
        )

      reason ->
        Logger.warning("[Opus.Programs] #{what} failed: #{inspect(reason)}")
    end
  end
end
