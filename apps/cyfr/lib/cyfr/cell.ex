# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Cell do
  @moduledoc """
  This member's place in the cell: the claimant of its `cell_leases` slot,
  and the roster every singleton's proposal is computed from.

  A **cell** is one deployment — one database, one object store, one set
  of workers, and one or more **members**. A member is a control-plane
  node, and it holds exactly one lease: its slot. Everything else it holds
  — turns, attempts, claimed jobs — is alive because *it* is alive, and a
  peer may take a member's work only after that member's slot has lapsed
  on database time.

  ## The claim

  The writes are `Arca.ControlPlane`'s: `take/3` at start, `renew/1` on a
  timer, `release/0` at stop. Each of them records what it won beside the
  row it wrote, and `held?/0` and `generation/0` answer from that record
  without a query. This process keeps **no parallel copy** of lease state:
  what it wrote is what it reads back.

  The lease is 15 s and the renew tick 5 s, both on database time, so a
  member that stops without releasing is taken over within
  **20 s** — its lease plus its successor's next tick. A renew that finds
  the row taken records the loss before returning, so nothing is admitted
  between the discovery and the next gate.

  ## The roster, and what it proposes

  Most work is not routed: a turn runs on the member that accepted it, an
  execution on the member that admitted it, and ownership is settled after
  the fact by a claim row. Three things must happen once in the cell
  rather than once per member — watching a worker service, holding a
  backend's bridge controller, and running a singleton job — and those are
  proposed by **rendezvous hashing** over the live roster:

      owner(subject) = argmax over live members m of sha256(subject <> "\\0" <> m)

  Rendezvous and not a modulus over a sorted roster: adding a member moves
  only the subjects whose argmax changes — about one in N — and moves them
  *to* the newcomer; removing one moves only its own subjects away. No
  other member's assignments move on a join, which is what lets a join
  invalidate nothing a peer issued.

  **Routing proposes, a row disposes.** The proposal keeps the claim
  uncontended in the healthy case; the `job_claims` row
  (`Arca.JobClaims`) is what admits exactly one holder. Two members with
  different roster copies both proposing themselves cost one wasted
  conditional update, never a second owner. The copy is refreshed on this
  member's own renew tick, so it is at most one tick stale.

  ## The cluster flag

  `CYFR_CLUSTER=1` used to lift the exclusive claim without replacing it.
  It now boots only when every condition in `refusals/1` holds, and a
  cluster member claims its slot like any other. Without the flag, a
  member additionally refuses to boot while a live PEER holds a slot of
  this database: one control plane per database, as before.
  """

  use GenServer

  require Logger

  @lease_ms 15_000
  @renew_ms 5_000

  # How much longer than a lapsed predecessor's own deadline a member
  # waits for its own slot, and the ceiling on that wait.
  @wait_slack_ms 250

  @roster_key {__MODULE__, :roster}

  @doc "Whether `boot` is a live member's boot (`Arca.ControlPlane.live_member?/1`)."
  @spec live_member?(String.t()) :: boolean()
  defdelegate live_member?(boot), to: Arca.ControlPlane

  @doc """
  The cell's live members by node name, as this member last read them.
  Empty before the first read, which proposes nothing and claims nothing.
  """
  @spec roster() :: [String.t()]
  def roster, do: :persistent_term.get(@roster_key, [])

  @doc """
  The member a singleton `subject` should run on, by rendezvous over the
  live roster. `{:error, :no_roster}` while this member has read none — a
  proposal it cannot compute is one it does not make.
  """
  @spec owner_of(String.t()) :: {:ok, String.t()} | {:error, :no_roster}
  def owner_of(subject) when is_binary(subject), do: owner_of(subject, roster())

  @doc """
  The rendezvous owner of `subject` among `members`: the member whose
  `sha256(subject <> "\\0" <> member)` is highest. A tie — two members
  whose digests are equal — is broken by node name, so every member
  computes the same answer from the same roster whatever order it read it
  in.
  """
  @spec owner_of(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, :no_roster}
  def owner_of(_subject, []), do: {:error, :no_roster}

  def owner_of(subject, members) when is_binary(subject) and is_list(members),
    do: {:ok, Enum.max_by(members, &{score(subject, &1), &1})}

  @doc """
  Whether `subject`'s singleton is this member's to propose itself for.
  False while the roster is unread: a member that cannot compute the
  proposal does not claim.
  """
  @spec mine?(String.t()) :: boolean()
  def mine?(subject) when is_binary(subject) do
    case owner_of(subject) do
      {:ok, member} -> member == node_name()
      {:error, :no_roster} -> false
    end
  end

  defp score(subject, member), do: :crypto.hash(:sha256, subject <> <<0>> <> member)

  # ---- the boot refusals -----------------------------------------------------

  @doc """
  What this deployment is missing before `CYFR_CLUSTER=1` may boot, as
  operator-facing sentences. An empty list is a cell that may form.

  A cluster flag is not evidence of distributed ownership, and each of
  these is a way for a deployment to look like a cell and not be one.
  """
  @spec refusals(map()) :: [String.t()]
  def refusals(facts) when is_map(facts) do
    [
      &postgres/1,
      &shared_storage/1,
      &tls_distribution/1,
      &cell_cookie/1,
      &topology/1,
      &worker_key/1
    ]
    |> Enum.flat_map(fn check -> List.wrap(check.(facts)) end)
  end

  @doc """
  What this member can see of the six conditions, for `refusals/1`.
  """
  @spec facts() :: map()
  def facts do
    %{
      repo_adapter: Arca.Repo.adapter(),
      storage_adapter: Application.get_env(:arca, :storage_adapter, Arca.Adapters.Local),
      proto_dist: proto_dist(),
      dist_certificates?: dist_certificates?(),
      cell_cookie: Application.get_env(:cyfr, :cell_cookie),
      node_cookie: node_cookie(),
      topologies: Application.get_env(:libcluster, :topologies, []),
      worker_key: Application.get_env(:cyfr, :worker_key)
    }
  end

  defp postgres(%{repo_adapter: Ecto.Adapters.Postgres}), do: []

  defp postgres(%{repo_adapter: adapter}) do
    """
    CYFR_CLUSTER=1 needs Postgres, and this member's database adapter is \
    #{inspect(adapter)}. SQLite is one file with one writer and no server \
    clock, so members cannot agree which lease stands. Set \
    CYFR_DATABASE=postgres and point every member at one database, or unset \
    CYFR_CLUSTER.\
    """
  end

  defp shared_storage(%{storage_adapter: Arca.Adapters.S3}), do: []

  defp shared_storage(%{storage_adapter: adapter}) do
    """
    CYFR_CLUSTER=1 needs shared object storage, and this member's storage \
    adapter is #{inspect(adapter)}. Local storage is one member's \
    filesystem: two members would each hold half of every estate. Set \
    CYFR_STORAGE=s3 with the bucket and credentials every member shares, or \
    unset CYFR_CLUSTER.\
    """
  end

  defp tls_distribution(%{proto_dist: proto}) when proto not in [:inet_tls, :inet6_tls] do
    """
    CYFR_CLUSTER=1 needs TLS distribution, and this node speaks \
    #{inspect(proto)}. A cell of control planes on plain distribution is an \
    unauthenticated remote shell onto the database. Start every member with \
    `-proto_dist inet_tls` (or inet6_tls) and `-ssl_dist_optfile` naming its \
    certificates, or unset CYFR_CLUSTER.\
    """
  end

  defp tls_distribution(%{dist_certificates?: false}) do
    """
    CYFR_CLUSTER=1 needs TLS distribution with certificates, and this node \
    was started with neither `-ssl_dist_optfile` nor `-ssl_dist_opt`. TLS \
    distribution without configured certificates verifies no peer. Name the \
    member's certificate, key and CA in an `-ssl_dist_optfile`, or unset \
    CYFR_CLUSTER.\
    """
  end

  defp tls_distribution(_facts), do: []

  defp cell_cookie(%{cell_cookie: cookie}) when not is_binary(cookie) do
    """
    CYFR_CLUSTER=1 needs a cell-only cookie, and CYFR_CELL_COOKIE is not \
    set. An ambient ~/.erlang.cookie is the machine's, not the cell's, and \
    a cookie bounds exactly one cell. Set CYFR_CELL_COOKIE to at least 32 \
    random characters on every member, or unset CYFR_CLUSTER.\
    """
  end

  defp cell_cookie(%{cell_cookie: cookie}) when byte_size(cookie) < 32 do
    """
    CYFR_CLUSTER=1 needs a cell-only cookie of at least 32 characters, and \
    CYFR_CELL_COOKIE is #{byte_size(cookie)}. Generate one with \
    `openssl rand -hex 32` and set the same value on every member, or unset \
    CYFR_CLUSTER.\
    """
  end

  defp cell_cookie(%{cell_cookie: cookie, node_cookie: cookie}), do: []

  defp cell_cookie(%{node_cookie: node_cookie}) do
    """
    CYFR_CLUSTER=1 needs this node to be running under the cell's own \
    cookie, and its distribution cookie is #{inspect(node_cookie)}, not \
    CYFR_CELL_COOKIE. An ambient ~/.erlang.cookie is the machine's, not the \
    cell's. Start every member with CYFR_CELL_COOKIE as its distribution \
    cookie (RELEASE_COOKIE, or `-setcookie`), or unset CYFR_CLUSTER.\
    """
  end

  defp topology(%{topologies: [_ | _]}), do: []

  defp topology(_facts) do
    """
    CYFR_CLUSTER=1 needs a discovery topology, and none is configured. A \
    cell that never forms is a set of members that each believe they are a \
    cell. Set CYFR_CLUSTER_NODES to the members' node names, or \
    CYFR_CLUSTER_DNS_QUERY and CYFR_CLUSTER_NODE_BASENAME for a headless \
    service, or unset CYFR_CLUSTER.\
    """
  end

  defp worker_key(%{worker_key: <<_::binary-size(32)>>}), do: []

  defp worker_key(_facts) do
    """
    CYFR_CLUSTER=1 needs CYFR_WORKER_KEY set and identical on every member. \
    Unset, the worker root is random per boot, so a worker's report to a \
    peer fails MAC verification and its assignment is refused. Generate one \
    with `openssl rand -hex 32` and set the same value on every member, or \
    unset CYFR_CLUSTER.\
    """
  end

  defp proto_dist do
    case :init.get_argument(:proto_dist) do
      {:ok, [[proto | _] | _]} -> List.to_atom(proto)
      _ -> :inet_tcp
    end
  end

  defp dist_certificates? do
    match?({:ok, _}, :init.get_argument(:ssl_dist_optfile)) or
      match?({:ok, _}, :init.get_argument(:ssl_dist_opt))
  end

  defp node_cookie do
    case Node.get_cookie() do
      :nocookie -> nil
      cookie -> Atom.to_string(cookie)
    end
  rescue
    # A node without distribution started has no cookie to read.
    _ -> nil
  end

  # ---- the claimant ----------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    # Stopped by its supervisor, this member releases the slot it holds
    # (`terminate/2`), so a successor takes it at once instead of waiting
    # out a row nobody renews.
    Process.flag(:trap_exit, true)

    lease_ms = Keyword.get(opts, :lease_ms, @lease_ms)
    renew_ms = Keyword.get(opts, :renew_ms, @renew_ms)
    cluster? = Keyword.get(opts, :cluster, Application.get_env(:cyfr, :cluster, false)) == true
    me = Cyfr.Boot.id()
    slot = Keyword.get(opts, :node_name, node_name())

    if cluster?,
      do: refuse_unformed_cell!(Keyword.get(opts, :facts, &facts/0)),
      else: refuse_foreign_nodes!()

    state = %{me: me, slot: slot, lease_ms: lease_ms, renew_ms: renew_ms, cluster?: cluster?}

    case take_or_wait(state) do
      {:ok, _won} ->
        refuse_live_peers!(state)
        refresh_roster()
        Process.send_after(self(), :renew, renew_ms)
        {:ok, state}

      {:busy, row} ->
        raise "[Cyfr] FATAL: another control plane (#{row.owner}) holds the slot of node " <>
                "#{slot} until #{DateTime.to_iso8601(row.lease_until)} and is renewing it. " <>
                "Two boots under one node name each run every sweep and accept every turn. " <>
                "Stop the other one; a second member of a cell needs a node name of its own."

      {:error, reason} ->
        raise "[Cyfr] FATAL: this member's cell slot could not be read or written " <>
                "(#{inspect(reason)})."
    end
  end

  @impl true
  def handle_info(:renew, state) do
    case Arca.ControlPlane.renew(state.lease_ms) do
      {:ok, _slot} ->
        :ok

      :taken ->
        # The row is a successor's; this member holds nothing and admits
        # nothing. It asks for the slot back, and gets it only once the
        # successor's own lease has run out.
        Logger.error(
          "[Cyfr.Cell] this member's slot was taken over — refusing work until it is won back"
        )

        reclaim(state)

      :unclaimed ->
        reclaim(state)

      {:error, reason} ->
        # The row could not be reached. What this member believes runs out
        # on its own countdown; nothing is recorded, because a member that
        # cannot read the row does not know it lost it.
        Logger.warning("[Cyfr.Cell] slot not renewed (#{inspect(reason)}); asking again")
    end

    refresh_roster()
    Process.send_after(self(), :renew, state.renew_ms)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    case Arca.ControlPlane.release() do
      :ok ->
        :ok

      :unclaimed ->
        :ok

      :taken ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Cyfr.Cell] slot not released at stop (#{inspect(reason)}); " <>
            "a successor waits it out"
        )
    end

    :persistent_term.erase(@roster_key)
    :ok
  end

  # A slot this member's node already holds belongs to a live boot or a
  # dead one, and only time tells: a live holder renews before its
  # deadline, a dead one never will. Wait for that deadline once — never
  # longer than a lease of our own — and take it again; a row renewed
  # meanwhile is a live boot's and is refused.
  defp take_or_wait(state) do
    case Arca.ControlPlane.take(state.slot, state.me, state.lease_ms) do
      {:busy, row} = busy ->
        wait_ms = DateTime.diff(row.lease_until, Arca.ServerMetaStorage.now!(), :millisecond)

        if wait_ms > 0 and wait_ms <= state.lease_ms + @wait_slack_ms do
          Logger.warning(
            "[Cyfr.Cell] #{row.owner} holds this node's slot until " <>
              "#{DateTime.to_iso8601(row.lease_until)}; waiting #{wait_ms} ms for it to " <>
              "renew or lapse"
          )

          Process.sleep(wait_ms + @wait_slack_ms)
          Arca.ControlPlane.take(state.slot, state.me, state.lease_ms)
        else
          busy
        end

      other ->
        other
    end
  end

  defp reclaim(state) do
    case Arca.ControlPlane.take(state.slot, state.me, state.lease_ms) do
      {:ok, _won} -> Logger.warning("[Cyfr.Cell] slot regained")
      _refused -> :ok
    end
  end

  # The roster is read on the renew tick and nowhere else, so a proposal
  # is at most one tick stale — and a roster that reads the same is not
  # written again, which keeps an unchanging cell from churning a term
  # every member holds.
  defp refresh_roster do
    case Arca.ControlPlane.roster() do
      {:ok, members} ->
        nodes = Enum.map(members, & &1.node)
        if nodes != roster(), do: :persistent_term.put(@roster_key, nodes)

      {:error, _reason} ->
        :ok
    end
  end

  # Without the cluster flag, one control plane per database: a live peer
  # under any other node name is refused, whatever this member's own slot
  # says. Its own slot is given back first, so a refused boot leaves the
  # row as it found it.
  defp refuse_live_peers!(%{cluster?: true}), do: :ok

  defp refuse_live_peers!(state) do
    case Arca.ControlPlane.roster() do
      {:ok, members} ->
        case Enum.reject(members, &(&1.node == state.slot)) do
          [] ->
            :ok

          [peer | _] ->
            _ = Arca.ControlPlane.release()

            raise "[Cyfr] FATAL: another control plane (#{peer.owner} on #{peer.node}) holds " <>
                    "this database until #{DateTime.to_iso8601(peer.lease_until)} and is " <>
                    "renewing it. Two servers on one database each run every sweep and accept " <>
                    "every turn. Stop the other one, or set CYFR_CLUSTER=1 — which needs " <>
                    "Postgres, shared object storage, TLS distribution, a cell cookie, a " <>
                    "discovery topology and a shared worker key."
        end

      {:error, reason} ->
        _ = Arca.ControlPlane.release()
        raise "[Cyfr] FATAL: the cell roster could not be read (#{inspect(reason)})."
    end
  end

  defp refuse_unformed_cell!(facts) when is_function(facts, 0),
    do: refuse_unformed_cell!(facts.())

  defp refuse_unformed_cell!(facts) when is_map(facts) do
    case refusals(facts) do
      [] ->
        :ok

      messages ->
        raise "[Cyfr] FATAL: this deployment cannot form a cell.\n\n" <>
                Enum.map_join(messages, "\n\n", &("  * " <> &1))
    end
  end

  defp refuse_foreign_nodes! do
    case Node.list() do
      [] ->
        :ok

      others ->
        raise "[Cyfr] FATAL: this node is connected to #{inspect(others)} but CYFR_CLUSTER is " <>
                "not set. A cell of control planes needs the multi-node work; a single one " <>
                "must not be distributed."
    end
  end

  defp node_name, do: Atom.to_string(node())
end
