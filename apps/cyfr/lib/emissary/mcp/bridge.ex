# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.Bridge do
  @moduledoc """
  The controller of the MCP bridge (`apps/mcp-bridge`): the one process that
  tells the bridge which stdio servers run, and the only holder of the root
  key (`CYFR_MCP_BRIDGE_KEY`).

  An **owner** is one stdio server row of one athanor — the pair
  `(athanor_id, mcp_servers.id)` — served by one
  `Emissary.MCP.ExternalServer`. The bridge runs an owner's backends at a
  version `(g, e)`: `g` is this member's control-plane generation
  (`Arca.ControlPlane.generation/0`; a member that holds no claim speaks
  generation 1) and `e` is the row's epoch.

  ## One claimed controller per backend

  A **backend** is the pair without its epoch, and exactly one member of
  the cell runs it: the `job_claims` row of kind `mcp_backend` under the
  key `"<athanor_id>:<mcp_servers.id>"` (`Arca.JobClaims`, 30 s, renewed
  every tick). A sync takes the row before it reads the store, resolves an
  env template or sends anything, so a member that does not hold it runs
  no backend, asks the vault for nothing, and refuses its server process
  `:claimed_elsewhere` — distinct from `:claim_unavailable`, which is the
  row failing to answer at all. Where a backend *should* run is not
  decided here: the cell proposes an owner and this row disposes, so two
  members proposing the same backend cost one wasted conditional update.

  Four checks decide whether this controller may act for a backend, and
  each answers a different question:

    * the claim's **fence** — has the row been written since this
      controller read it? Every write is a compare-and-set on it, so a
      renew that lands is proof no peer has interleaved;
    * the claim's **owner**, this member's boot id (`Cyfr.Boot.id/0`) —
      whose the row is. A member that restarted, or that lost and won its
      slot back, does not inherit its predecessor's claim, and the same
      fence number means nothing across two owners;
    * the row's **epoch** (`mcp_servers.epoch`) — is the configuration the
      backend runs under still the stored one? A config change, a disable
      and a vault reconcile all raise it, and a controller whose owner
      fails that fence releases the backend and stops its process;
    * this member's **generation** — is the authority the grants were
      issued under still current? It rises only when this member's slot is
      taken over, so a member that won its slot back greets the bridge
      again and re-syncs, and nothing is sent under a generation that is
      not this member's now.

  A renewal round is put ahead of everything else queued, so a claim a
  peer has taken is found before a renewal or a release goes out under it.
  A controller that finds its claim taken **stands down**: it stops the
  backend's server process here, forgets the claim and drops any release
  still pending for it, because the owner on the bridge is the peer's to
  renew and to release now. A claim that merely lapsed — the row still
  this member's, its lease run out — is asked for again, and only a peer
  that got there first turns it into a stand-down.

  ## Messages

  Control messages are POSTed to `<url>/control` one at a time, each signed
  with the control key (`Cyfr.BridgeAuth.control_header/3`) under a sequence
  number that only grows, so the bridge refuses a replayed, reordered or
  delayed one. The bridge answers each without waiting on a backend, so no
  message holds the channel for longer than a store read and a round trip.
  Lease maintenance — `renew` and `release`, with `hello` and `reconcile`
  ahead of them — is sent before any `sync` or `status` still waiting:

    * `hello` at start, and whenever the bridge's boot id or this boot's
      generation changes; then `reconcile`, which releases every owner the
      bridge runs that is not kept here at its version, and a `sync` of
      every owner still registered here;
    * `sync` when a server process starts: the row is read again (fenced:
      the same epoch, enabled, stdio, its athanor active), its env templates
      are resolved through `Sanctum.VaultReader` and sealed for the owner
      and the bridge's lifetime (`Cyfr.BridgeAuth.seal/5`). The resolved
      values live only in the task that sends the message. The bridge
      admits the version and answers at once; its backends start on their
      own time;
    * `renew` every third of the lease for every live owner whose row
      still passes the fence, asking for the lease again (`:mcp_bridge_lease_ms`,
      `CYFR_MCP_BRIDGE_LEASE_MS`: 30 s unless set), and more often — every
      250 ms while a server process waits for its backends, every second
      while any backend is still starting — to learn each owner's state and
      rev. An owner that fails the fence is released; an owner the bridge
      no longer knows has its epoch raised. Either way its process is
      stopped;
    * `release` on every stop path — a server process that stops or exits,
      a failed fence, `release_referencing/2` — retried on every tick until
      the bridge acknowledges it or a later sync of the owner supersedes it;
    * `status` for `mcp_servers.get`, naming one owner. The bridge bounds a
      status to `MAX_STATUS_OWNERS` owners and its answer to the control
      limit, refusing past either as `too_many_owners` or
      `status_too_large`; this controller mirrors the owner bound and reads
      no more of any answer than the limit, so a status it cannot have is
      the typed refusal `{:error, :too_many_owners}` or
      `{:error, :status_too_large}`, never a cut answer, an empty one, or an
      unavailable bridge.

  Every sync asks the bridge to retire a backend that has had no call for
  the idle period (`:mcp_bridge_idle_ms`, `CYFR_MCP_BRIDGE_IDLE_MS`: 15
  minutes unless set) and to start it again for its next call.

  Nothing is sent, and no claim renewed, while this member does not hold
  its slot in the cell (`Arca.ControlPlane.held?/0`), or while its
  generation cannot be read: `sync/1` refuses, queued messages are
  dropped, and both the bridge's leases and the claim rows lapse until a
  tick finds both again.

  ## Grants and readiness

  A server process receives a **grant** for its owner — the bridge's `/mcp`
  URL, the generation, epoch and bridge boot id, and the owner key
  (`Cyfr.BridgeAuth.owner_key/2`) it signs its requests with — as the answer
  to `sync/1`, once every backend of the owner has been ready or failed, or
  15 s after the bridge admitted it, whichever comes first. A re-sync the
  controller starts itself sends the process `{:bridge_owner, grant}`; a
  later change to the owner's tool catalogue, which the bridge reports as a
  new rev, sends it `{:bridge_tools_changed, epoch}`.

  ## Shares

  Every live owner of one athanor together, and every live owner whose row
  one person created (`mcp_servers.created_by`) together, run at most a
  quarter of the bridge's pool of backends; a sync past either share is
  refused. The server's synthetic principal (`"system"`, the creator of a
  row made under `Sanctum.Context.internal/1`) is one person for the share,
  across every athanor, exactly as a real person is.
  """

  use GenServer

  require Logger

  alias Arca.JobClaims
  alias Cyfr.BridgeAuth
  alias Emissary.MCP.BackendDefinition
  alias Emissary.MCP.StatusRedaction
  alias Emissary.MCP.VaultRef

  # The cell's claim on one backend. Its key carries no epoch: a restart at
  # a new epoch is the same backend, and the claim carries across it.
  @claim_kind "mcp_backend"

  @default_lease_ms 30_000
  @default_idle_ms 900_000
  @control_timeout_ms 10_000
  # How long a sync's caller waits, after the bridge admitted the owner, for
  # its backends to be ready or failed.
  @ready_wait_ms 15_000
  @poll_waiting_ms 250
  @poll_starting_ms 1_000
  @release_wait_ms 3_000
  # The most of a control answer this controller reads: the bridge's
  # STATUS_ANSWER_LIMIT (apps/mcp-bridge/server.mjs), which bounds the one
  # answer that can grow — a status — before it is sent.
  @max_response_bytes 1_048_576
  # The bridge reads at most this much of a control message's body.
  @max_control_bytes 1_048_576
  # The most owners one status may name: the bridge's MAX_STATUS_OWNERS
  # (apps/mcp-bridge/server.mjs), past which it refuses `too_many_owners`.
  @max_status_owners 64

  @typedoc "One stdio server of one athanor at one epoch."
  @type owner :: %{athanor_id: String.t(), server_id: String.t(), epoch: pos_integer()}

  @typedoc "What a server process signs its requests to the bridge with."
  @type grant :: %{
          url: String.t(),
          generation: pos_integer(),
          epoch: pos_integer(),
          boot: String.t(),
          owner_key: binary()
        }

  defmodule State do
    @moduledoc false
    # The root and the keys derived from it never reach a log or a crash report.
    @derive {Inspect, except: [:root, :control_key, :seal_key]}
    defstruct [
      :url,
      :root,
      :control_key,
      :seal_key,
      :cyfr_boot,
      :boot,
      :generation,
      :pool_size,
      :inflight,
      :poll_timer,
      generation_source: &Arca.ControlPlane.generation/0,
      lease_ms: 30_000,
      idle_ms: 900_000,
      tick_ms: 10_000,
      ready_wait_ms: 15_000,
      owners: %{},
      # The `mcp_backend` claim this controller holds for each backend, and
      # the keys whose claims it is giving up once the bridge has released
      # their owner.
      claims: %{},
      releasing: %{},
      releases: %{},
      release_waiters: %{},
      # Lease maintenance, sent first; then syncs and status reads.
      urgent: :queue.new(),
      queue: :queue.new()
    ]
  end

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start the controller. Answers `:ignore` unless a bridge URL and a 32-byte
  root key are configured (`:mcp_bridge_url` and `:mcp_bridge_key`, or the
  `:url` and `:root` options), and while `:cluster` is on: a cluster of
  control planes runs no stdio servers. `:lease_ms` sets the lease each
  sync and renewal asks for (default `:mcp_bridge_lease_ms`, else 30 s),
  `:idle_ms` the idle period each sync asks for (default
  `:mcp_bridge_idle_ms`, else 15 minutes), `:tick_ms` the renewal cadence
  (default a third of the lease), `:ready_wait_ms` how long a sync's
  caller waits for its backends (default 15 s) and `:generation` the
  zero-arity function the control-plane generation is read from (default
  `Arca.ControlPlane.generation/0`).

  `:lease_ms` is also the lease each backend claim asks for, and the tick
  is what renews it: a third of the lease by default, so the claim stands
  while the bridge lease it goes with does, and a member that stops
  ticking gives up both together.
  """
  def start_link(opts \\ []) do
    url = Keyword.get(opts, :url, Application.get_env(:cyfr, :mcp_bridge_url))
    root = Keyword.get(opts, :root, Application.get_env(:cyfr, :mcp_bridge_key))
    cluster? = Application.get_env(:cyfr, :cluster, false) == true

    if is_binary(url) and url != "" and is_binary(root) and byte_size(root) == 32 and
         not cluster? do
      GenServer.start_link(__MODULE__, Keyword.merge(opts, url: url, root: root),
        name: __MODULE__
      )
    else
      :ignore
    end
  end

  @doc "Whether a bridge controller runs on this boot."
  @spec running?() :: boolean()
  def running?, do: is_pid(Process.whereis(__MODULE__))

  @doc """
  Ask the bridge to run `owner` for the calling server process, and answer
  its grant once its backends are ready or failed, or the readiness wait
  passed. Refused with a reason when another member of the cell holds the
  backend's claim (`:claimed_elsewhere`) or the claim row cannot be read
  (`:claim_unavailable`), when the row no longer passes the fence, an env
  template does not resolve, the athanor or the row's creator would hold
  more than their share of the pool, the pool is full, this member does
  not hold its slot in the cell, or the bridge cannot be reached.
  """
  @spec sync(owner()) :: {:ok, grant()} | {:error, term()}
  def sync(owner),
    do: call({:sync, owner, self()}, @ready_wait_ms + 3 * @control_timeout_ms)

  @doc """
  Release `owner` on the bridge. Answers once the bridge acknowledged the
  release or the attempt failed, and within 3 s either way; an
  unacknowledged release is retried on every tick.
  """
  @spec release(owner()) :: :ok
  def release(owner) do
    _ = call({:release, owner}, @release_wait_ms)
    :ok
  end

  @doc """
  The bridge's status of one owner — version, lease and backends — or nil
  when it runs none. Refused as `{:error, :too_many_owners}` or
  `{:error, :status_too_large}` when the bridge will not answer within its
  bounds, `{:error, :bridge_unavailable}` when it cannot be reached, and
  `{:error, :control_plane_lost}` while this boot does not own the plane.
  """
  @spec status(String.t(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def status(athanor_id, server_id),
    do: call({:status, {athanor_id, server_id}}, 2 * @control_timeout_ms)

  @doc false
  # The bounds a status is asked and read within, for the test that binds
  # them to the bridge's literals.
  @spec status_bounds() :: %{owners: pos_integer(), bytes: pos_integer()}
  def status_bounds, do: %{owners: @max_status_owners, bytes: @max_response_bytes}

  @doc """
  Release, at once and without reading the store, every live owner of the
  athanor whose env templates reference one of `names` (`:any`: any entry),
  and stop its server process. Answers the server ids released.
  """
  @spec release_referencing(String.t(), [String.t()] | :any) :: [String.t()]
  def release_referencing(athanor_id, names) do
    case call({:release_referencing, athanor_id, names}, @control_timeout_ms) do
      ids when is_list(ids) -> ids
      {:error, _} -> []
    end
  end

  @doc "Report the bridge boot id a server process saw, so a restarted bridge is greeted."
  @spec boot_seen(String.t()) :: :ok
  def boot_seen(boot) when is_binary(boot) do
    if running?(), do: GenServer.cast(__MODULE__, {:boot_seen, boot})
    :ok
  end

  defp call(message, timeout) do
    GenServer.call(__MODULE__, message, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :bridge_not_configured}
    :exit, _ -> {:error, :bridge_unavailable}
  end

  # ============================================================================
  # Server
  # ============================================================================

  @impl true
  def init(opts) do
    root = Keyword.fetch!(opts, :root)

    lease_ms =
      Keyword.get(
        opts,
        :lease_ms,
        Application.get_env(:cyfr, :mcp_bridge_lease_ms, @default_lease_ms)
      )

    state = %State{
      url: String.trim_trailing(Keyword.fetch!(opts, :url), "/"),
      root: root,
      control_key: BridgeAuth.control_key(root),
      seal_key: BridgeAuth.seal_key(root),
      cyfr_boot: Cyfr.Boot.id(),
      lease_ms: lease_ms,
      idle_ms:
        Keyword.get(
          opts,
          :idle_ms,
          Application.get_env(:cyfr, :mcp_bridge_idle_ms, @default_idle_ms)
        ),
      tick_ms: Keyword.get(opts, :tick_ms, div(lease_ms, 3)),
      ready_wait_ms: Keyword.get(opts, :ready_wait_ms, @ready_wait_ms),
      generation_source: Keyword.get(opts, :generation, &Cyfr.ControlPlane.generation/0)
    }

    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_call({:sync, owner, pid}, from, state) do
    key = {owner.athanor_id, owner.server_id}
    epoch = owner.epoch

    cond do
      plane_generation(state) == :not_owner ->
        {:reply, {:error, :control_plane_lost}, state}

      match?(%{epoch: registered} when registered > epoch, state.owners[key]) ->
        {:reply, {:error, :stale_epoch}, state}

      true ->
        state = state |> register(key, epoch, pid, from) |> enqueue({:sync, key})
        {:noreply, dispatch(state)}
    end
  end

  # The server process is stopping, so unless a newer one has registered in
  # its place this member stops running the backend: the claim is given up
  # with the owner, and the next member may take it.
  def handle_call({:release, owner}, from, state) do
    key = {owner.athanor_id, owner.server_id}
    epoch = owner.epoch

    {state, last?} =
      case state.owners[key] do
        nil -> {state, true}
        %{epoch: registered} when registered <= epoch -> {drop_owner(state, key), true}
        _newer -> {state, false}
      end

    state = if last?, do: give_up_claim(state, key), else: state
    state = pend_release(state, key, epoch)

    if Map.has_key?(state.releases, key) do
      state = %{
        state
        | release_waiters: Map.update(state.release_waiters, key, [from], &[from | &1])
      }

      {:noreply, state |> enqueue({:release}) |> dispatch()}
    else
      # Nothing of this backend is this controller's to end.
      {:reply, :ok, dispatch(state)}
    end
  end

  def handle_call({:status, key}, from, state) do
    {:noreply, state |> enqueue({:status, key, from}) |> dispatch()}
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
    Process.send_after(self(), :tick, state.tick_ms)

    state =
      case plane_generation(state) do
        {:ok, generation} ->
          state = check_generation(state, generation)
          state = if state.boot == nil, do: enqueue(state, {:hello}), else: state
          state = if live_keys(state) != [], do: enqueue(state, {:renew}), else: state
          state = enqueue_release(state)
          renew_claims(state)

        :not_owner ->
          state
      end

    {:noreply, state |> dispatch() |> schedule_poll()}
  end

  def handle_info(:poll, state) do
    state = reply_overdue(%{state | poll_timer: nil})

    state =
      if plane_generation(state) != :not_owner and live_keys(state) != [],
        do: enqueue(state, {:renew}),
        else: state

    {:noreply, state |> dispatch() |> schedule_poll()}
  end

  def handle_info({ref, result}, %State{inflight: {ref, job, spec}} = state) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     %{state | inflight: nil} |> settle(job, spec, result) |> dispatch() |> schedule_poll()}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{inflight: {ref, job, spec}} = state
      ) do
    result = {:error, {:crashed, reason}}

    {:noreply,
     %{state | inflight: nil} |> settle(job, spec, result) |> dispatch() |> schedule_poll()}
  end

  # A server process that exits, however it exits, has its owner released
  # and this member's claim on its backend given up.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.owners, fn {_key, entry} -> entry.ref == ref end) do
      {key, entry} ->
        state =
          state |> drop_owner(key) |> pend_release(key, entry.epoch) |> give_up_claim(key)

        {:noreply, state |> enqueue_release() |> dispatch()}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(message, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, message)
    {:noreply, state}
  end

  @impl true
  def format_status(status), do: StatusRedaction.format_status(status)

  # ============================================================================
  # Owners
  # ============================================================================

  # The same process asking again joins the waiters. Another process
  # replaces the registered one; a replaced owner that was live at a lower
  # epoch is released.
  defp register(state, key, epoch, pid, from) do
    case state.owners[key] do
      %{epoch: ^epoch, pid: ^pid} = entry ->
        put_owner(state, key, %{entry | waiters: [from | entry.waiters]})

      previous ->
        state =
          case previous do
            nil ->
              state

            %{epoch: ^epoch} ->
              drop_owner(state, key)

            %{live?: true} ->
              state |> drop_owner(key) |> pend_release(key, previous.epoch)

            _not_live ->
              drop_owner(state, key)
          end

        put_owner(state, key, %{
          pid: pid,
          ref: Process.monitor(pid),
          epoch: epoch,
          generation: nil,
          live?: false,
          person: nil,
          names: [],
          backends: 0,
          waiters: [from],
          rev: nil,
          running?: false,
          ready_by: nil
        })
    end
  end

  defp put_owner(state, key, entry), do: %{state | owners: Map.put(state.owners, key, entry)}

  defp drop_owner(state, key) do
    case Map.pop(state.owners, key) do
      {nil, _owners} ->
        state

      {entry, owners} ->
        Process.demonitor(entry.ref, [:flush])
        for waiter <- entry.waiters, do: GenServer.reply(waiter, {:error, :released})
        %{state | owners: owners}
    end
  end

  # A release names a version this controller ran, and it is this
  # controller's to send only while it holds the backend's claim. A member
  # that stood down writes nothing more for the backend — not even the
  # release its own server process asks for on the way out — because the
  # owner on the bridge belongs to the peer that took the row.
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
  # The backend claims
  # ============================================================================

  # The `job_claims` key of one backend: the pair that names it, without
  # its epoch.
  defp claim_key({athanor_id, server_id}), do: athanor_id <> ":" <> server_id

  defp hold_claim(state, key, claim), do: %{state | claims: Map.put(state.claims, key, claim)}

  # Give the backend up, so the next member may take it. The row is written
  # only once the bridge has released the owner running under it, which is
  # why the two travel in one job: a claim given up while a release may not
  # have arrived would let a peer take the backend and then be ended by
  # this controller's retry.
  defp give_up_claim(state, key) do
    if Map.has_key?(state.claims, key),
      do: enqueue_release(%{state | releasing: Map.put(state.releasing, key, true)}),
      else: state
  end

  defp forget_claims(state, keys) do
    %{state | claims: Map.drop(state.claims, keys), releasing: Map.drop(state.releasing, keys)}
  end

  # The claims whose backends this controller is giving up, each with the
  # freshest row it has read for them.
  defp giving_up(state) do
    Enum.reduce(state.releasing, %{}, fn {key, _true}, acc ->
      case state.claims[key] do
        nil -> acc
        claim -> Map.put(acc, key, claim)
      end
    end)
  end

  # A renewal round goes ahead of everything else queued: what may be sent
  # for a backend is decided by its row, and a claim a peer has taken must
  # be found before a renewal or a release goes out under it.
  defp renew_claims(%State{claims: claims} = state) when claims == %{}, do: state
  defp renew_claims(state), do: enqueue_front(state, {:claims})

  # The row is a peer's now. Stop the backend here — its process, and with
  # it the grant that process holds — forget the claim, and drop any
  # release still pending for it: the owner on the bridge is the peer's to
  # renew and to release, and a release sent from here would end a backend
  # this controller no longer runs.
  defp stand_down(state, {_athanor, server} = key) do
    Logger.warning(
      "[MCP.Bridge] the claim on #{server} is held elsewhere; standing down without releasing it"
    )

    state =
      case state.owners[key] do
        nil ->
          state

        entry ->
          stop_process(entry.pid)
          Enum.each(entry.waiters, &GenServer.reply(&1, {:error, :claimed_elsewhere}))
          state |> put_owner(key, %{entry | waiters: []}) |> drop_owner(key)
      end

    state
    |> forget_claims([key])
    |> Map.update!(:releases, &Map.delete(&1, key))
    |> reply_release_waiters([key])
  end

  # A sync the bridge acknowledged at `epoch` replaces any version of the
  # owner at or below it, so a release still pending for one is moot — and
  # so is giving the backend's claim up, which this controller is running
  # again.
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
  # bridge, and the process stopped. The stop runs in another process,
  # because the server's terminate/2 asks this one to release.
  defp revoke(state, key) do
    state =
      case state.owners[key] do
        nil ->
          state

        entry ->
          stop_process(entry.pid)
          state |> drop_owner(key) |> pend_release(key, entry.epoch)
      end

    give_up_claim(state, key)
  end

  defp stop_process(pid) do
    spawn(fn ->
      DynamicSupervisor.terminate_child(Emissary.MCP.ExternalServerSupervisor, pid)
    end)

    :ok
  end

  defp live_keys(state) do
    for {key, %{live?: true, generation: generation}} <- state.owners,
        generation == state.generation,
        do: key
  end

  # The backends every other live owner holds: in `key`'s athanor, and per
  # person who created an owner's row.
  defp held_by_others(state, {athanor_id, _server} = key) do
    for {{other_athanor, _} = other, %{live?: true} = entry} <- state.owners,
        other != key,
        reduce: {0, %{}} do
      {athanor, people} ->
        athanor = if other_athanor == athanor_id, do: athanor + entry.backends, else: athanor
        people = Map.update(people, entry.person, entry.backends, &(&1 + entry.backends))
        {athanor, people}
    end
  end

  # ============================================================================
  # Readiness
  # ============================================================================

  defp grant_waiters(state, key) do
    entry = state.owners[key]
    grant = grant(state, key, entry)
    Enum.each(entry.waiters, &GenServer.reply(&1, {:ok, grant}))
    put_owner(state, key, %{entry | waiters: []})
  end

  defp overdue?(entry), do: System.monotonic_time(:millisecond) >= entry.ready_by

  defp reply_overdue(state) do
    Enum.reduce(live_keys(state), state, fn key, acc ->
      case acc.owners[key] do
        %{waiters: [_ | _]} = entry -> if overdue?(entry), do: grant_waiters(acc, key), else: acc
        _ -> acc
      end
    end)
  end

  # What a renewal reports of a live owner: its state, and a rev that moves
  # whenever its tool catalogue does.
  defp observe_renewed(state, %{"athanor" => athanor, "server" => server, "e" => epoch} = item) do
    key = {athanor, server}

    case state.owners[key] do
      %{epoch: ^epoch, live?: true} = entry ->
        running? = item["state"] == "running"
        changed? = item["rev"] != entry.rev
        state = put_owner(state, key, %{entry | rev: item["rev"], running?: running?})

        cond do
          entry.waiters != [] and (running? or overdue?(entry)) ->
            grant_waiters(state, key)

          entry.waiters == [] and changed? ->
            send(entry.pid, {:bridge_tools_changed, epoch})
            state

          true ->
            state
        end

      _other ->
        state
    end
  end

  defp observe_renewed(state, _item), do: state

  # Renew sooner than the tick while a process waits for its backends, or
  # any backend is still starting.
  defp schedule_poll(%State{poll_timer: nil} = state) do
    entries = for key <- live_keys(state), do: state.owners[key]

    interval =
      cond do
        Enum.any?(entries, &(&1.waiters != [])) -> @poll_waiting_ms
        Enum.any?(entries, &(not &1.running?)) -> @poll_starting_ms
        true -> nil
      end

    if interval,
      do: %{state | poll_timer: Process.send_after(self(), :poll, interval)},
      else: state
  end

  defp schedule_poll(state), do: state

  # ============================================================================
  # Lifetimes and generations
  # ============================================================================

  # The generation this member speaks while it holds its slot in the cell —
  # 1 for a member that has claimed nothing — or `:not_owner` while it does
  # not, or while its generation cannot be read. Nothing is sent, and no
  # claim renewed, without one.
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

  # This boot won the plane again under a new generation, so every grant it
  # issued names the old one: greet the bridge under the new generation.
  defp check_generation(%State{generation: nil} = state, _generation), do: state

  defp check_generation(state, generation) do
    if generation == state.generation do
      state
    else
      Logger.warning("[MCP.Bridge] the control-plane generation changed; greeting the bridge")
      forget_bridge(state)
    end
  end

  defp observe_boot(state, nil), do: state
  defp observe_boot(%State{boot: nil} = state, _boot), do: state
  defp observe_boot(%State{boot: boot} = state, boot), do: state

  defp observe_boot(state, _other) do
    Logger.warning("[MCP.Bridge] the bridge restarted; greeting it and syncing live owners")
    forget_bridge(state)
  end

  # Every registered owner is synced again after the next hello.
  defp forget_bridge(state) do
    owners =
      Map.new(state.owners, fn {key, entry} ->
        {key, %{entry | live?: false, rev: nil, running?: false}}
      end)

    enqueue(%{state | boot: nil, owners: owners}, {:hello})
  end

  # ============================================================================
  # Lanes
  # ============================================================================

  # One message is in flight at a time, so sequence numbers reach the
  # bridge in the order they were issued. A release is sent before a sync
  # still waiting: a sync of the same owner reads the owner as registered
  # when it is prepared, so it never names a version a release it follows
  # covers.
  defp lane({:sync, _key}), do: :queue
  defp lane({:status, _key, _from}), do: :queue
  defp lane(_job), do: :urgent

  defp enqueue(state, job) do
    if queued?(state, job) do
      state
    else
      Map.update!(state, lane(job), &:queue.in(job, &1))
    end
  end

  defp enqueue_front(state, job) do
    Map.update!(state, lane(job), fn queue ->
      :queue.in_r(job, :queue.filter(&(&1 != job), queue))
    end)
  end

  # A sync in flight for the owner's registered epoch answers its waiters.
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
            |> forget_bridge()
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
                # The keys reach the task through its closure only: a spec
                # is printed wherever the state is, a crash's reason included.
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

  # `state.generation` is the generation this boot speaks now (dispatch/1).
  defp prepare({:hello}, state) do
    body = %{"type" => "hello", "g" => state.generation, "cyfr_boot" => state.cyfr_boot}
    {:send, state |> base_spec(:hello) |> Map.merge(%{boot: "-", body: body})}
  end

  defp prepare({:reconcile}, state) do
    keep =
      for {athanor, server} = key <- live_keys(state),
          do: %{"athanor" => athanor, "server" => server, "e" => state.owners[key].epoch}

    body = %{"type" => "reconcile", "keep" => keep}
    {:send, state |> base_spec(:reconcile) |> Map.put(:body, body)}
  end

  defp prepare({:sync, key}, state) do
    case state.owners[key] do
      nil ->
        :skip

      entry ->
        {athanor_id, server_id} = key
        {athanor_backends, person_backends} = held_by_others(state, key)

        spec =
          state
          |> base_spec(:sync)
          |> Map.merge(%{
            athanor_id: athanor_id,
            server_id: server_id,
            epoch: entry.epoch,
            idle_ms: state.idle_ms,
            share: share(state),
            athanor_backends: athanor_backends,
            person_backends: person_backends
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
        {:send, state |> base_spec(:renew) |> Map.put(:owners, owners)}
    end
  end

  defp prepare({:release}, state) do
    giving_up = giving_up(state)

    if state.releases == %{} and giving_up == %{} do
      :skip
    else
      owners =
        for {{athanor, server}, epoch} <- state.releases,
            do: %{"athanor" => athanor, "server" => server, "e" => epoch}

      spec =
        state
        |> base_spec(:release)
        |> Map.merge(%{
          releases: state.releases,
          giving_up: giving_up,
          body: %{"type" => "release", "owners" => owners}
        })

      {:send, spec}
    end
  end

  defp prepare({:status, {athanor, server}, from}, state) do
    case status_body([%{"athanor" => athanor, "server" => server}]) do
      {:ok, body} ->
        {:send, state |> base_spec(:status) |> Map.put(:body, body)}

      {:error, reason} ->
        GenServer.reply(from, {:error, reason})
        :skip
    end
  end

  # What a task needs to write a claim row: who this member is, and the
  # lease the row is asked for, which is the bridge lease the claim stands
  # for.
  defp claim_spec(spec, state),
    do: Map.merge(spec, %{claim_owner: state.cyfr_boot, claim_lease_ms: state.lease_ms})

  # A status names no more owners than the bridge answers for; one that
  # would is refused here, as the bridge would refuse it, and never sent.
  defp status_body(owners) when length(owners) > @max_status_owners,
    do: {:error, :too_many_owners}

  defp status_body(owners), do: {:ok, %{"type" => "status", "owners" => owners}}

  # The most backends one athanor's owners, or one person's, may run.
  defp share(%State{pool_size: size}) when is_integer(size), do: max(div(size, 4), 1)
  defp share(_state), do: nil

  # ============================================================================
  # Performing: store reads, vault reads and HTTP, in the task
  # ============================================================================

  # A raised exception is reported by its module only: its message can
  # carry a resolved env value.
  defp perform(spec, keys) do
    do_perform(spec, keys)
  rescue
    error -> {:error, {:crashed, error.__struct__}}
  catch
    kind, _reason -> {:error, {:crashed, kind}}
  end

  # The row comes first: a member that does not hold the backend's claim
  # reads no configuration, resolves no env template and sends nothing.
  # `claim/4` answers a live claim of this same member unchanged, so a
  # controller already running the backend asks again without taking the
  # row from itself, and reads back the fence it must write under.
  defp do_perform(%{kind: :sync} = spec, keys) do
    case claim_backend(spec) do
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
        {kept, fenced_out} =
          Enum.split_with(pairs, fn key -> passes_fence?(rows[key], spec.owners[key]) end)

        answer = if kept == [], do: :nothing_to_renew, else: renew(spec, keys.control, kept)
        {:renewed, answer, fenced_out}

      {:error, _} ->
        {:error, :store_unavailable}
    end
  end

  # The bridge is told first and the rows only then, so a claim is given up
  # with nothing of its backend left running under this member's version.
  # A release that may not have arrived keeps its claim and is retried.
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
         config = Arca.McpServerStorage.config(row),
         {:ok, backends} <- BackendDefinition.validate(config["backends"]),
         :ok <- within_shares(spec, row.created_by, length(backends)),
         {:ok, sealed} <- seal_env(spec, keys.seal, backends) do
      body = %{
        "type" => "sync",
        "owner" => %{"athanor" => spec.athanor_id, "server" => spec.server_id},
        "e" => spec.epoch,
        "lease_ms" => spec.lease_ms,
        "idle_ms" => spec.idle_ms,
        "backends" => Enum.map(backends, &definition/1),
        "sealed" => sealed
      }

      case post(spec, keys.control, body) do
        {:http, _status, _boot, _body} = answer ->
          {:synced, answer, BackendDefinition.entry_names(backends), length(backends),
           row.created_by}

        error ->
          error
      end
    end
  end

  defp claim_backend(spec) do
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

  # Renewing is an act of authority, so a lease that has run out is asked
  # for again rather than extended, and a row a peer holds is not written
  # at all. `:taken` and losing the race for a lapsed row are one verdict
  # here — the backend is a peer's — while a store that cannot answer
  # leaves the claim where it is, to be asked again on the next tick.
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

  # A claim is given up once nothing of its backend is left on the bridge:
  # the release landed, or this controller had no owner there to release.
  # `release/1` is itself fenced, so a claim a peer has taken meanwhile is
  # refused rather than reset.
  defp released_claims(spec, answer) do
    landed? = match?({:http, 200, _boot, _body}, answer) or answer == :nothing_to_release

    Enum.flat_map(spec.giving_up, fn {key, claim} ->
      if landed? or not Map.has_key?(spec.releases, key) do
        _ = JobClaims.release(claim)
        [key]
      else
        []
      end
    end)
  end

  # An owner the bridge no longer knows lapsed there: its epoch is raised,
  # so the grant its process holds names a version nothing will run again.
  defp renew(spec, control_key, kept) do
    owners =
      for {athanor, server} = key <- kept,
          do: %{"athanor" => athanor, "server" => server, "e" => spec.owners[key]}

    body = %{"type" => "renew", "lease_ms" => spec.lease_ms, "owners" => owners}
    answer = post(spec, control_key, body)

    with {:http, 200, _boot, %{"unknown" => [_ | _] = unknown}} <- answer do
      for %{"athanor" => athanor, "server" => server, "e" => epoch} <- unknown do
        ctx = Sanctum.Context.internal(athanor_id: athanor, scope: :athanor)
        Arca.McpServerStorage.bump_epoch(Sanctum.Context.actor(ctx), server, epoch)
      end
    end

    answer
  end

  defp definition(backend) do
    %{
      "name" => backend["name"],
      "command" => backend["command"],
      "env_names" => backend["env"] |> Map.keys() |> Enum.sort()
    }
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
  defp fence_verdict(%{row: %{epoch: epoch, enabled: true} = row}, epoch), do: stdio(row)
  defp fence_verdict(%{row: %{enabled: false}}, _epoch), do: {:error, :disabled}
  defp fence_verdict(_fenced, _epoch), do: {:error, :stale_epoch}

  defp stdio(%{transport: "stdio"} = row), do: {:ok, row}
  defp stdio(_row), do: {:error, :not_stdio}

  defp passes_fence?(fenced, epoch), do: match?({:ok, _row}, fence_verdict(fenced, epoch))

  defp within_shares(%{share: nil}, _person, _count), do: :ok

  defp within_shares(spec, person, count) do
    cond do
      spec.athanor_backends + count > spec.share ->
        {:error, {:pool_share, spec.share}}

      Map.get(spec.person_backends, person, 0) + count > spec.share ->
        {:error, {:person_share, spec.share}}

      true ->
        :ok
    end
  end

  defp seal_env(spec, seal_key, backends) do
    owner = %{
      athanor: spec.athanor_id,
      server: spec.server_id,
      generation: spec.generation,
      epoch: spec.epoch
    }

    with {:ok, env} <- resolve_env(spec.athanor_id, backends) do
      BridgeAuth.seal(seal_key, owner, spec.boot, Jason.encode!(env))
    end
  end

  defp resolve_env(athanor_id, backends) do
    Enum.reduce_while(backends, {:ok, %{}}, fn backend, {:ok, acc} ->
      case resolve_backend_env(athanor_id, backend) do
        {:ok, env} -> {:cont, {:ok, Map.put(acc, backend["name"], env)}}
        error -> {:halt, error}
      end
    end)
  end

  defp resolve_backend_env(athanor_id, backend) do
    Enum.reduce_while(backend["env"], {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case resolve_value(athanor_id, value) do
        {:ok, resolved} -> {:cont, {:ok, Map.put(acc, name, resolved)}}
        :error -> {:halt, {:error, {:env_unresolved, backend["name"], name}}}
      end
    end)
  end

  # A template resolves to its single-field entry's value after its scheme;
  # a literal (only the names BackendDefinition allows) is itself; a
  # reference this server does not resolve resolves to nothing.
  defp resolve_value(athanor_id, value) do
    case VaultRef.classify(value) do
      {:vault, %{name: entry} = template} ->
        case Sanctum.VaultReader.unseal_by_name(athanor_id, entry) do
          {:ok, fields} when map_size(fields) == 1 ->
            {:ok, VaultRef.render(template, fields |> Map.values() |> hd())}

          _ ->
            :error
        end

      :unresolved ->
        :error

      :literal ->
        {:ok, value}
    end
  end

  defp post(spec, control_key, body_map) do
    body = Jason.encode!(body_map)

    control = %{
      generation: spec.generation,
      seq: spec.seq,
      cyfr_boot: spec.cyfr_boot,
      boot: spec.boot,
      ts: System.os_time(:millisecond)
    }

    with :ok <- within_control_size(body),
         {:ok, header} <- BridgeAuth.control_header(control_key, control, body) do
      headers = [{"content-type", "application/json"}, {"cyfr-bridge-auth", header}]

      opts = [
        receive_timeout: @control_timeout_ms,
        private_policy: :operator,
        max_response_bytes: @max_response_bytes
      ]

      case Cyfr.Egress.pinned_request(:post, spec.url <> "/control", headers, body, opts) do
        {:ok, status, resp_headers, resp_body} ->
          {:http, status, boot_header(resp_headers), decode(resp_body)}

        # An answer past the limit was stopped mid-read: the bridge answered,
        # so this is a refusal of the answer, not a bridge that could not be
        # reached.
        {:error, {:response_too_large, _read, _limit} = reason} ->
          {:error, reason}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    end
  end

  defp within_control_size(body) when byte_size(body) <= @max_control_bytes, do: :ok
  defp within_control_size(_body), do: {:error, {:control_too_large, @max_control_bytes}}

  @doc false
  # The bridge boot id a response names, from its `Cyfr-Bridge-Boot` header.
  @spec boot_header([{String.t(), String.t()}]) :: String.t() | nil
  def boot_header(headers) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(to_string(name)) == "cyfr-bridge-boot", do: to_string(value)
    end)
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  # ============================================================================
  # Settling answers
  # ============================================================================

  defp settle(state, {:hello} = job, spec, result), do: settle_job(state, job, spec, result)

  defp settle(state, job, spec, result) do
    state |> observe_boot(answer_boot(result)) |> settle_job(job, spec, result)
  end

  defp answer_boot({:http, _status, boot, _body}), do: boot
  defp answer_boot({:synced, answer, _names, _count, _person}), do: answer_boot(answer)
  defp answer_boot({:renewed, answer, _fenced_out}), do: answer_boot(answer)
  defp answer_boot({:claimed, _claim, result}), do: answer_boot(result)
  defp answer_boot({:released, answer, _given_up}), do: answer_boot(answer)
  defp answer_boot(_result), do: nil

  defp settle_job(state, {:hello}, spec, {:http, 200, _boot, %{"boot" => boot} = body})
       when is_binary(boot) do
    Logger.info("[MCP.Bridge] greeted bridge #{boot} under generation #{spec.generation}")

    state = %{
      state
      | boot: boot,
        generation: spec.generation,
        pool_size: get_in(body, ["pool", "size"])
    }

    resyncs = for {key, %{live?: false}} <- state.owners, do: {:sync, key}

    resyncs
    |> Enum.reverse()
    |> Enum.reduce(state, &enqueue_front(&2, &1))
    |> enqueue_front({:reconcile})
  end

  defp settle_job(state, {:hello}, _spec, result) do
    log_failure("hello", result)
    refuse_queued(state, :bridge_unavailable)
  end

  # The bridge released everything not kept, so nothing pending remains.
  defp settle_job(state, {:reconcile}, _spec, {:http, 200, _boot, body}) do
    case body["released"] do
      [_ | _] = released ->
        Logger.info("[MCP.Bridge] reconcile released #{length(released)} owners")

      _ ->
        :ok
    end

    reply_release_waiters(%{state | releases: %{}}, Map.keys(state.release_waiters))
  end

  defp settle_job(state, {:reconcile}, _spec, result) do
    log_failure("reconcile", result)
    state
  end

  # A sync's answer carries the claim its task took, so what this
  # controller holds is recorded before the answer is read: a sync that
  # then fails still gives the row up rather than leaving it standing.
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
         {:synced, {:http, 200, _boot, body}, names, count, person}
       ) do
    case state.owners[key] do
      %{epoch: epoch} = entry when epoch == spec.epoch ->
        entry = %{
          entry
          | live?: true,
            generation: spec.generation,
            names: names,
            backends: count,
            person: person,
            rev: body["rev"],
            running?: body["status"] == "running",
            ready_by: System.monotonic_time(:millisecond) + state.ready_wait_ms
        }

        state = state |> put_owner(key, entry) |> supersede_release(key, epoch)

        cond do
          entry.waiters == [] ->
            send(entry.pid, {:bridge_owner, grant(state, key, entry)})
            state

          entry.running? ->
            grant_waiters(state, key)

          true ->
            state
        end

      _gone_or_replaced ->
        state |> pend_release(key, spec.epoch) |> enqueue_release()
    end
  end

  defp settle_job(state, {:sync, key}, spec, result) do
    reason = refusal(result)

    case state.owners[key] do
      # A newer registration holds the backend here: its own sync keeps
      # the claim, so only the version this one named is released.
      %{epoch: epoch} when epoch != spec.epoch ->
        release_unanswered(state, key, spec, result)

      nil ->
        state |> give_up_claim(key) |> release_unanswered(key, spec, result)

      _entry when reason == :stale_boot ->
        enqueue(state, {:sync, key})

      entry ->
        log_failure("sync", result)
        Enum.each(entry.waiters, &GenServer.reply(&1, {:error, reason}))
        # A re-sync this controller started failed: the process holds a
        # grant the bridge no longer honours.
        if entry.waiters == [], do: stop_process(entry.pid)

        state
        |> put_owner(key, %{entry | waiters: []})
        |> drop_owner(key)
        |> give_up_claim(key)
        |> release_unanswered(key, spec, result)
    end
  end

  defp settle_job(state, {:renew}, _spec, {:renewed, answer, fenced_out}) do
    state = Enum.reduce(fenced_out, state, &revoke(&2, &1))

    state =
      case answer do
        {:http, 200, _boot, %{"renewed" => renewed, "unknown" => unknown}}
        when is_list(renewed) and is_list(unknown) ->
          state = Enum.reduce(unknown, state, &lapsed(&2, &1))
          Enum.reduce(renewed, state, &observe_renewed(&2, &1))

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

  defp settle_job(state, {:release}, spec, {:http, 200, _boot, _body}) do
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

  defp settle_job(state, {:status, key, from}, _spec, {:http, 200, _boot, body}) do
    status = Enum.find(body["owners"] || [], &({&1["athanor"], &1["server"]} == key))
    GenServer.reply(from, {:ok, status})
    state
  end

  defp settle_job(state, {:status, _key, from}, _spec, result) do
    GenServer.reply(from, {:error, refusal(result)})
    state
  end

  defp lapsed(state, %{"athanor" => athanor, "server" => server, "e" => epoch}) do
    key = {athanor, server}

    case state.owners[key] do
      %{epoch: ^epoch, live?: true} ->
        Logger.warning("[MCP.Bridge] the bridge no longer runs #{server}; its epoch was raised")
        revoke(state, key)

      _other ->
        state
    end
  end

  defp lapsed(state, _unknown), do: state

  # A sync whose answer never arrived may have started the owner.
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

    {:ok, owner_key} = BridgeAuth.owner_key(state.root, owner)

    %{
      url: state.url <> "/mcp",
      generation: entry.generation,
      epoch: entry.epoch,
      boot: state.boot,
      owner_key: owner_key
    }
  end

  @refusals %{
    "stale_boot" => :stale_boot,
    "stale_control" => :stale_control,
    "stale_epoch" => :stale_epoch,
    "epoch_ahead" => :epoch_ahead,
    "capacity" => :capacity,
    "lapsed" => :lapsed,
    "conflict" => :conflict,
    "bad_request" => :bad_request,
    "too_large" => :too_large,
    "too_many_owners" => :too_many_owners,
    "status_too_large" => :status_too_large,
    "unavailable" => :bridge_unavailable
  }

  defp refusal({:synced, answer, _names, _count, _person}), do: refusal(answer)
  defp refusal({:renewed, answer, _fenced_out}), do: refusal(answer)
  defp refusal({:claimed, _claim, result}), do: refusal(result)
  defp refusal({:released, answer, _given_up}), do: refusal(answer)
  defp refusal({:http, 401, _boot, _body}), do: :bridge_refused_signature

  defp refusal({:http, status, _boot, %{"error" => code}})
       when status in [400, 409, 413, 503] and is_map_key(@refusals, code),
       do: Map.fetch!(@refusals, code)

  defp refusal({:http, status, _boot, _body}), do: {:bridge_status, status}
  defp refusal({:error, {:transport, _}}), do: :bridge_unavailable
  defp refusal({:error, {:crashed, _}}), do: :bridge_unavailable
  # The one answer that can grow is a status; one the bridge sent past the
  # limit is the refusal the bridge itself gives for it.
  defp refusal({:error, {:response_too_large, _read, _limit}}), do: :status_too_large
  defp refusal({:error, reason}), do: reason
  defp refusal(other), do: {:unexpected, other}

  defp log_failure(what, result) do
    case refusal(result) do
      # Not a failure of this controller: the backend is another member's.
      :claimed_elsewhere ->
        Logger.info("[MCP.Bridge] #{what} refused: another member of the cell holds the backend")

      :bridge_refused_signature ->
        Logger.error(
          "[MCP.Bridge] the bridge refused the #{what} signature — CYFR_MCP_BRIDGE_KEY must " <>
            "be the same value for cyfr and the bridge"
        )

      reason ->
        Logger.warning("[MCP.Bridge] #{what} failed: #{inspect(reason)}")
    end
  end
end
