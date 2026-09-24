# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Cluster.Cell do
  @moduledoc """
  The cell this suite runs against: two real control-plane members, each a
  node of its own started with `:peer`, both against one Postgres database
  and one MinIO bucket, both under `CYFR_CLUSTER=1` and every boot refusal
  `Cyfr.Cell.refusals/1` names.

  Nothing here simulates a peer. A member is an operating-system process
  running the whole `:cyfr` application: its own supervision tree, its own
  endpoint, its own worker service, its own claim on its `cell_leases`
  slot. What one member believes about another it learns
  from the database or from distribution, as a deployment's members do.

  ## The seven refusals, met rather than bypassed

  `CYFR_CLUSTER=1` boots only with Postgres, shared object storage, TLS
  distribution with configured certificates, a cell-only cookie of at
  least 32 characters that is also the node's, a discovery topology, a
  shared worker root, and each member's own host API address. Each member
  here is started with all seven, so the cell that forms is the one the
  refusals describe:

    * Postgres and MinIO come from the environment
      (`Cyfr.Cluster.Store`);
    * the certificates are minted for the run (`certificates/0`) and named
      in an `-ssl_dist_optfile`, so members speak `inet_tls` to each other;
    * the cookie is minted for the run and passed as `-setcookie`, so it
      is both `CYFR_CELL_COOKIE` and the node's own;
    * the topology is `Cluster.Strategy.Epmd` over the members' names, so
      `libcluster` connects them as a deployment's discovery would;
    * the worker root is the suite's, identical on both members;
    * each member binds a host API port of its own and is told the
      loopback address it is reached at, which is what makes an
      assignment's address a real one a case can post to.

  ## The control node is not a member

  The node running ExUnit holds no slot, starts no application and is not
  in the roster. It reaches each member over `:peer`'s standard-io
  channel — so it needs no distribution of its own and cannot be mistaken
  for a third member — and it reads rows through a Postgrex connection of
  its own (`Cyfr.Cluster.Observer`), which stays readable when both
  members are dead. A control node inside the cell would make every
  assertion a fourth party to the race it is watching.

  ## What a case may do to a member

    * `stop/1` — a clean stop: the application shuts down, the member
      releases its slot and every claim it holds, and a successor takes
      them at once.
    * `kill/1` — process death: the node's operating-system process is
      killed outright. Nothing is released; the row's lease is what a
      successor waits out. This is the failure a dead owner is.
    * `partition/2` and `heal/2` — a live owner cut off from its peer over
      distribution alone. It keeps its database connection, keeps
      renewing, and keeps trying to act. This is the failure a *live*
      partitioned owner is, and it is not the same as death.
    * a cut wire (`Cyfr.Cluster.Wire`) — a live member cut off from the
      database or from a worker, over a path only it uses.

  A cell is expensive to start, so one is started for the run and healed
  between cases (`Cyfr.Cluster.Case`).
  """

  use GenServer

  alias Cyfr.Cluster.Store

  @name __MODULE__
  @host ~c"127.0.0.1"

  # Long enough for the whole application to come up on a cold VM under a
  # loaded machine, and short enough that a member that will never boot is
  # a failure rather than a hang.
  @boot_timeout_ms 120_000

  @typedoc """
  One member: its node name, the `:peer` controlling it, the worker
  service id it dispatches under, and the host API port it binds with the
  address it is reached at — `CYFR_HOST_API_URL`, which every assignment
  that member issues carries, so a worker posts that attempt's host calls
  to the member holding it.
  """
  @type member :: %{
          id: atom(),
          node: node(),
          peer: pid(),
          worker: String.t(),
          host_api: String.t(),
          host_api_port: :inet.port_number()
        }

  # ---------------------------------------------------------------------------
  # The run's cell
  # ---------------------------------------------------------------------------

  @doc """
  The cell for this run, started on the first call. Answers the members in
  a stable order — `:a` first — so a case naming "the first member" names
  the same node every run.
  """
  @spec ensure!() :: [member()]
  def ensure! do
    case Process.whereis(@name) do
      nil ->
        {:ok, _pid} = GenServer.start(__MODULE__, [], name: @name)
        # The cell outlives every case, so the run is what ends it. Two
        # operating-system processes left behind would hold this run's
        # node names against the next one.
        ExUnit.after_suite(fn _results -> shutdown() end)
        GenServer.call(@name, :members, @boot_timeout_ms)

      _running ->
        GenServer.call(@name, :members, @boot_timeout_ms)
    end
  end

  @doc "Stop every member and forget the cell."
  @spec shutdown() :: :ok
  def shutdown do
    case Process.whereis(@name) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, @boot_timeout_ms)
    end
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Put back whatever the last case did to the cell: every member running,
  connected to its peers, its store reachable. Answers the members.

  Healing is what makes one expensive cell serve a whole file. It is
  deliberately done *before* a case rather than after one, so a case that
  fails leaves its cell for the next reader to see.
  """
  @spec heal!() :: [member()]
  def heal!, do: GenServer.call(@name, :heal, @boot_timeout_ms)

  @doc "The member by id (`:a`, `:b`)."
  @spec member(atom()) :: member()
  def member(id), do: Enum.find(ensure!(), &(&1.id == id)) || raise("no member #{inspect(id)}")

  @doc "Both members' node names, in order."
  @spec nodes() :: [node()]
  def nodes, do: Enum.map(ensure!(), & &1.node)

  @doc "Stop `id` cleanly: the application shuts down and gives up what it holds."
  @spec stop(atom()) :: :ok
  def stop(id), do: GenServer.call(@name, {:stop, id}, @boot_timeout_ms)

  @doc """
  Kill `id`'s operating-system process. Nothing is released and nothing is
  logged; the member simply stops writing, which is what a successor has
  to notice from the rows alone.
  """
  @spec kill(atom()) :: :ok
  def kill(id), do: GenServer.call(@name, {:kill, id}, @boot_timeout_ms)

  @doc "Start `id` again, boot id and all, and wait until it holds its slot."
  @spec start(atom()) :: member()
  def start(id), do: GenServer.call(@name, {:start, id}, @boot_timeout_ms)

  @doc """
  Cut distribution between two members, leaving both alive and both
  writing. `Cluster.Strategy.Epmd` reconnects on its own interval, so the
  cut is held by `:erlang.set_cookie/2` on one side until `heal/2`.
  """
  @spec partition(atom(), atom()) :: :ok
  def partition(a, b), do: GenServer.call(@name, {:partition, a, b}, @boot_timeout_ms)

  @doc "Let two partitioned members find each other again."
  @spec heal(atom(), atom()) :: :ok
  def heal(a, b), do: GenServer.call(@name, {:heal, a, b}, @boot_timeout_ms)

  @doc """
  Call `{module, function, args}` on `id`, over that member's own control
  channel. The control node is not distributed, so this is the one way in;
  the channel multiplexes, so two processes may be inside a member at
  once.
  """
  @spec call(atom() | member(), module(), atom(), [term()], timeout()) :: term()
  def call(id, module, function, args, timeout \\ 60_000)

  def call(id, module, function, args, timeout) when is_atom(id) and not is_nil(id),
    do: call(member(id), module, function, args, timeout)

  def call(%{peer: peer}, module, function, args, timeout) when is_pid(peer),
    do: :peer.call(peer, module, function, args, timeout)

  @doc "Call on `id` without waiting for an answer — for a call that ends the member."
  @spec cast(atom() | member(), module(), atom(), [term()]) :: :ok
  def cast(id, module, function, args) when is_atom(id) and not is_nil(id),
    do: cast(member(id), module, function, args)

  def cast(%{peer: peer}, module, function, args) when is_pid(peer),
    do: :peer.cast(peer, module, function, args)

  # ---------------------------------------------------------------------------
  # The run's secrets and certificates
  # ---------------------------------------------------------------------------

  @doc """
  The cell cookie: 64 hexadecimal characters, minted once for the run and
  used both as `CYFR_CELL_COOKIE` and as the nodes' distribution cookie,
  which is what refusal 4 asks for.
  """
  @spec cookie() :: String.t()
  def cookie do
    case :persistent_term.get({__MODULE__, :cookie}, nil) do
      nil ->
        minted = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
        :persistent_term.put({__MODULE__, :cookie}, minted)
        minted

      minted ->
        minted
    end
  end

  @doc """
  The `-ssl_dist_optfile` every member is started with, written once for
  the run: one certificate chain for the server side and one for the
  client side, both verifying their peer against the chain's own root.

  `:public_key.pkix_test_data/1` mints them, so the suite needs no
  `openssl` on PATH and leaves nothing behind but a file under the run's
  temporary directory.
  """
  @spec certificates() :: Path.t()
  def certificates do
    case :persistent_term.get({__MODULE__, :dist_optfile}, nil) do
      nil ->
        path = write_dist_optfile()
        :persistent_term.put({__MODULE__, :dist_optfile}, path)
        path

      path ->
        path
    end
  end

  defp write_dist_optfile do
    dir = Path.join(System.tmp_dir!(), "cyfr_cluster_#{System.system_time(:millisecond)}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "dist.conf")

    # The members are named by address, so the certificate has to carry
    # that address: TLS distribution verifies the peer's name against the
    # certificate, and a chain that validates under a name nobody uses is
    # a cell that never forms.
    alternative_names = [
      {:dNSName, ~c"127.0.0.1"},
      {:dNSName, ~c"localhost"},
      {:iPAddress, [127, 0, 0, 1]}
    ]

    subject_alt_name = {:Extension, {2, 5, 29, 17}, false, alternative_names}

    chain = %{
      root: [digest: :sha256, key: {:rsa, 2048, 65_537}],
      intermediates: [],
      peer: [digest: :sha256, key: {:rsa, 2048, 65_537}, extensions: [subject_alt_name]]
    }

    data = :public_key.pkix_test_data(%{server_chain: chain, client_chain: chain})

    options = [
      server: data[:server_config] ++ [verify: :verify_peer, fail_if_no_peer_cert: true],
      client: data[:client_config] ++ [verify: :verify_peer]
    ]

    File.write!(path, IO.iodata_to_binary(:io_lib.format(~c"~tp.~n", [options])))
    path
  end

  # ---------------------------------------------------------------------------
  # The claimant of the run's cell
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    Store.ready!()

    members =
      for {id, worker} <- [{:a, "wrk_cell_a"}, {:b, "wrk_cell_b"}] do
        port = free_port()

        %{
          id: id,
          node: node_name(id),
          peer: nil,
          worker: worker,
          host_api: "http://127.0.0.1:#{port}",
          host_api_port: port
        }
      end

    started = Enum.map(members, &boot/1)
    Enum.each(started, &await_slot!/1)
    formed!(started)

    {:ok, %{members: started}}
  end

  @impl true
  def handle_call(:members, _from, state), do: {:reply, state.members, state}

  def handle_call(:heal, _from, state) do
    members =
      Enum.map(state.members, fn member ->
        if alive?(member), do: member, else: boot(%{member | peer: nil})
      end)

    restore_cookies(members)

    for member <- members, do: await_slot!(member)
    formed!(members)

    {:reply, members, %{state | members: members}}
  end

  def handle_call({:stop, id}, _from, state) do
    member = find!(state, id)

    if member.peer do
      # The application is shut down before the node is: `:peer.stop/1`
      # ends the operating-system process, and a member whose VM
      # disappears has released nothing. A clean stop is the application
      # stopping — its supervision tree unwinds, `Cyfr.Cell.terminate/2`
      # gives the slot back and every claim with it — and that is the
      # failure this distinguishes from `kill/1`.
      safe_call(member, Cyfr.Cluster.Boot, :stop!, [], @boot_timeout_ms)
      :peer.stop(member.peer)
    end

    {:reply, :ok, put_member(state, %{member | peer: nil})}
  end

  def handle_call({:kill, id}, _from, state) do
    member = find!(state, id)

    if member.peer do
      # The controlling process is unlinked first: a peer that dies while
      # this process is linked to it would take the cell's claimant down
      # with the member the case meant to kill.
      Process.unlink(member.peer)
      :peer.cast(member.peer, :erlang, :halt, [1])
      await_down!(member)
    end

    {:reply, :ok, put_member(state, %{member | peer: nil})}
  end

  def handle_call({:start, id}, _from, state) do
    member = boot(%{find!(state, id) | peer: nil})
    await_slot!(member)
    reconnect(put_member(state, member).members)
    {:reply, member, put_member(state, member)}
  end

  def handle_call({:partition, a, b}, _from, state) do
    one = find!(state, a)
    other = find!(state, b)

    # A cookie the peer does not share refuses the connection at the
    # handshake, and `Cluster.Strategy.Epmd`'s reconnect goes on failing
    # for as long as it stands — which is what a partition is, rather
    # than a disconnect that heals on the next tick.
    call(one, :erlang, :set_cookie, [other.node, :partitioned])
    call(other, :erlang, :set_cookie, [one.node, :partitioned])
    call(one, Node, :disconnect, [other.node])
    call(other, Node, :disconnect, [one.node])

    {:reply, :ok, state}
  end

  def handle_call({:heal, a, b}, _from, state) do
    members = [find!(state, a), find!(state, b)]
    restore_cookies(members)
    reconnect(members)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for %{peer: peer} <- state.members, peer != nil do
      try do
        :peer.stop(peer)
      catch
        _kind, _reason -> :ok
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Booting one member
  # ---------------------------------------------------------------------------

  defp boot(member) do
    {:ok, peer, node} =
      :peer.start(%{
        name: member.id |> node_basename() |> String.to_atom(),
        host: @host,
        longnames: true,
        connection: :standard_io,
        wait_boot: @boot_timeout_ms,
        args: peer_args()
      })

    ^node = member.node
    started = %{member | peer: peer}

    push_modules(started)
    configure(started)
    start_application(started)
    started
  end

  defp peer_args do
    paths = Enum.map(:code.get_path(), &to_charlist/1)

    [
      ~c"-setcookie",
      to_charlist(cookie()),
      ~c"-proto_dist",
      ~c"inet_tls",
      ~c"-ssl_dist_optfile",
      to_charlist(certificates()),
      # A member that cannot reach the store must not take its own VM
      # down with it: the cases that sever the store are asserting what
      # the member answers, not that it dies.
      ~c"+SDio",
      ~c"2",
      ~c"-pa"
    ] ++ paths
  end

  # Every module this suite compiled from `test/cluster/support` is a
  # `.exs` file, so it has no beam on disk for a member to load from its
  # code path. The binaries are pushed instead, which also lets a case
  # send a closure to a member: a fun is decoded only where its module
  # exists at the same version.
  defp push_modules(member) do
    for {module, binary} <- Cyfr.Cluster.Support.modules() do
      {:module, ^module} =
        :peer.call(member.peer, :code, :load_binary, [module, ~c"nofile", binary])
    end

    :ok
  end

  defp configure(member) do
    :peer.call(member.peer, Application, :put_all_env, [inherited_env()], @boot_timeout_ms)
    :peer.call(member.peer, Application, :put_all_env, [member_env(member)], @boot_timeout_ms)

    :ok
  end

  # The application environment of this run, as `config/config.exs` and
  # `config/test.exs` built it. A member node runs no Mix, so it would
  # otherwise boot on the defaults compiled into each `.app` file — a
  # different deployment from the one under test.
  defp inherited_env do
    skipped = [:kernel, :stdlib, :elixir, :mix, :ex_unit, :iex, :sasl, :compiler, :logger]

    for {app, _description, _version} <- Application.loaded_applications(),
        app not in skipped,
        env = Application.get_all_env(app),
        env != [],
        do: {app, env}
  end

  # What makes this node a member of a cell rather than the single server
  # the suite's own configuration describes: the shared store, the cluster
  # flag and its six conditions, and the background work `config/test.exs`
  # turns off because a sandbox connection cannot lend itself to a timer.
  defp member_env(member) do
    [
      arca: [
        {Arca.Repo,
         [
           url: Store.database_url(),
           pool_size: 10,
           queue_target: 500,
           queue_interval: 5_000
         ]},
        {:auto_migrate, false},
        {:storage_adapter, Arca.Adapters.S3},
        {:s3, Store.s3_config()},
        {:control_plane_claim_enabled, true}
      ],
      cyfr: [
        {:cluster, true},
        {:cell_cookie, cookie()},
        {:opus_key, Application.fetch_env!(:cyfr, :opus_key)},
        {:retention_scheduler_enabled, true},
        {:cron_scheduler_enabled, true},
        # The security gate runs on every member: this build carries the
        # suite's compile-time skip permission, and turning the runtime
        # switch on is what keeps `Cyfr.Bootstrap` in the member's tree, so
        # each member boots only through its own checked reconcile.
        {:provisioning_boot_enabled, true},
        {:thread_recovery, true},
        {:execution_sweeper_enabled, true},
        {:worker_watch_enabled, true},
        {:execution_archive_watch_enabled, true},
        {:external_server_reconciler_enabled, true},
        {:database_checks_enabled, true},
        # A port of this member's own, and the address it advertises on
        # every assignment it issues. Port 0 would do for a listener
        # nobody names, but a member that cannot say where it is refuses
        # to boot a cell, and a case that posts a host call needs the
        # address to be the one the assignment carries.
        {:host_api_port, member.host_api_port},
        {:host_api_bind, {127, 0, 0, 1}},
        {:host_api_url, member.host_api},
        {:opus_workers, []},
        {EmissaryWeb.Endpoint,
         [
           http: [ip: {127, 0, 0, 1}, port: 0],
           secret_key_base: Application.fetch_env!(:cyfr, EmissaryWeb.Endpoint)[:secret_key_base],
           server: true
         ]}
      ],
      libcluster: [
        {:topologies, [cyfr: [strategy: Cluster.Strategy.Epmd, config: [hosts: all_nodes()]]]}
      ],
      opus: [
        {:service_key, nil},
        {:service_id, member.worker},
        {:port, 0},
        {:bind, "127.0.0.1"},
        {:keeper, :direct}
      ],
      # The established-caller memo is off in `config/test.exs` (a
      # per-request convenience the single-node suite asserts around). A
      # memo that is never warm cannot show what a cell-wide invalidation
      # is for, so a member holds one for its production-shaped TTL.
      sanctum: [{:caller_memo_ttl_ms, 60_000}],
      logger: [{:level, :warning}]
    ]
  end

  defp start_application(member) do
    case :peer.call(member.peer, Cyfr.Cluster.Boot, :start!, [member.worker], @boot_timeout_ms) do
      :ok -> :ok
      other -> raise "member #{member.id} did not boot: #{inspect(other)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Waiting, healing and the rest
  # ---------------------------------------------------------------------------

  defp await_slot!(member) do
    Cyfr.Cluster.Wait.until!(
      fn -> :peer.call(member.peer, Arca.ControlPlane, :held?, [], 10_000) end,
      "member #{member.id} did not win its cell slot"
    )
  end

  # The cell is formed when every member is connected to every other and
  # every member's roster names them all. Both matter and neither implies
  # the other: distribution carries lookups, the roster comes from rows,
  # and a case that started before either had settled would be reading a
  # cell mid-formation rather than the one it means to test.
  defp formed!(members) do
    reconnect(members)
    names = Enum.map(members, &to_string(&1.node)) |> Enum.sort()

    for member <- members do
      Cyfr.Cluster.Wait.until!(
        fn -> length(peers_of(member)) == length(members) - 1 end,
        "member #{member.id} never connected to its peers"
      )

      Cyfr.Cluster.Wait.until!(
        fn -> Enum.sort(roster_of(member)) == names end,
        "member #{member.id} never read the whole roster"
      )
    end

    :ok
  end

  defp peers_of(member) do
    case safe_call(member, Node, :list, []) do
      {:ok, nodes} -> nodes
      :error -> []
    end
  end

  defp roster_of(member) do
    case safe_call(member, Cyfr.Cell, :roster, []) do
      {:ok, roster} -> roster
      :error -> []
    end
  end

  defp await_down!(member) do
    Cyfr.Cluster.Wait.until!(
      fn -> not alive?(member) end,
      "member #{member.id} did not die"
    )
  end

  defp alive?(%{peer: peer} = member) do
    is_pid(peer) and Process.alive?(peer) and
      match?({:ok, true}, safe_call(member, :erlang, :is_alive, []))
  end

  # A call to a member that may be dead, or dying, or unreachable:
  # answered `:error` rather than raising, because every caller here is
  # either healing the cell or asking whether a member is still there.
  defp safe_call(member, module, function, args, timeout \\ 5_000)

  defp safe_call(%{peer: peer}, module, function, args, timeout) when is_pid(peer) do
    {:ok, :peer.call(peer, module, function, args, timeout)}
  catch
    _kind, _reason -> :error
  end

  defp safe_call(_member, _module, _function, _args, _timeout), do: :error

  defp restore_cookies(members) do
    for one <- members, other <- members, one.node != other.node do
      safe_call(one, :erlang, :set_cookie, [other.node, String.to_atom(cookie())])
    end

    :ok
  end

  defp reconnect(members) do
    for one <- members, other <- members, one.node != other.node do
      safe_call(one, Node, :connect, [other.node])
    end

    :ok
  end

  defp find!(state, id),
    do: Enum.find(state.members, &(&1.id == id)) || raise("no member #{inspect(id)}")

  defp put_member(state, member),
    do: %{state | members: Enum.map(state.members, &if(&1.id == member.id, do: member, else: &1))}

  defp node_basename(id), do: "cyfr_cell_#{id}"

  defp node_name(id), do: :"#{node_basename(id)}@#{@host}"

  # A loopback port nothing holds, for a member to bind and to advertise.
  # The socket is closed before the member starts, which is the usual
  # small race and is safe here: the cell is started once, serially, for
  # the whole run.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, {_ip, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp all_nodes, do: Enum.map([:a, :b], &node_name/1)
end
