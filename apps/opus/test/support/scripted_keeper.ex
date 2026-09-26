# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Test.ScriptedKeeper do
  @moduledoc """
  A keeper (`Opus.Keeper`) whose runners are processes of this VM a test
  drives: each `spawn` starts a runner process that hands the test the
  bytes the service writes and writes what the test tells it, so the
  pool (`Opus.RunnerPool`) and the handles (`Opus.RunnerProcess`) are
  exercised over the real codec with no OS process behind them.

  `start!/0` starts the keeper for the calling test and answers its name,
  which a pool's command carries to it as the `KEEPER` variable of the
  spec's env. `spawns/1` lists every runner spawned, newest first, each
  with its spec and its runner process. `write/2` makes a runner write bytes on
  its channel (the test encodes frames with `Prima.RunnerControl`),
  `read/2` answers what the service wrote it so far, `close/1` closes its
  channel and `exit/2` ends its process with a status, which the keeper
  reports as `exited` and then `released`. A release from the service
  ends the runner as `exit/2` does, after its grace, and is listed by
  `releases/1`. `kill!/1` ends the keeper as a lost channel would: every
  runner's owner hears `{:error, :channel_lost}`. `refuse/2` makes it
  refuse every spawn after the request, as `cyfr-keeper` refuses one it
  cannot bound, until it is told to start runners again, and `refused/1`
  counts the spawns it refused. It holds a runner to the `:memory_bytes`
  of the pool's keeper options, or to none.

  Each runner has a relay stream too: `read_relay/1` answers what the
  service wrote on it, `write_relay/2` makes the runner write on it and
  `end_relay/1` ends it from the runner's side; `relay_closed?/1` says
  whether the service ended it.

  `relayed!/2` routes an attempt's client as a runner's is routed, for a
  test that runs runner code in this VM: through a runner's end of a relay
  (`Opus.Relay.Runner`) joined in this VM to a service's end
  (`Opus.Relay`) bound to the attempt, which verifies and posts every host
  call to the scripted host and performs every pinned fetch.
  """

  @behaviour Opus.Keeper

  use GenServer

  import Kernel, except: [send: 2, exit: 1]

  @impl Opus.Keeper
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @doc "Start a scripted keeper for the calling test, answering its name."
  @spec start!() :: atom()
  def start! do
    name = :"scripted_keeper_#{System.unique_integer([:positive])}"
    ExUnit.Callbacks.start_supervised!({__MODULE__, name: name})
    name
  end

  @impl Opus.Keeper
  def available(_env, _opts), do: :ok

  @impl Opus.Keeper
  def spawn(%{env: %{"KEEPER" => name}} = spec) do
    keeper = String.to_existing_atom(name)

    case GenServer.call(keeper, {:spawn, spec, self()}) do
      {:ok, ref, runner} ->
        {:ok, %{ref: ref, keeper: keeper, runner: runner}, [{:spawned, nil}, :attached]}

      # Refused after the request, as cyfr-keeper answers one it cannot
      # bound: the handle hears it as the keeper's message.
      {:refused, ref, reason} ->
        Kernel.send(self(), {__MODULE__, ref, {:refused, reason}})
        {:ok, %{ref: ref, keeper: keeper, runner: nil}, []}
    end
  end

  @impl Opus.Keeper
  def memory_bytes(opts), do: Keyword.get(opts, :memory_bytes)

  @impl Opus.Keeper
  def refusal(reason),
    do: %{reason: to_string(reason), message: "the scripted keeper refuses (#{reason})"}

  @doc "Refuse every spawn from now on with `reason`, or start runners again with nil."
  @spec refuse(atom(), atom() | nil) :: :ok
  def refuse(keeper, reason), do: GenServer.call(keeper, {:refuse, reason})

  @doc "How many spawns `keeper` refused."
  @spec refused(atom()) :: non_neg_integer()
  def refused(keeper), do: GenServer.call(keeper, :refused)

  @impl Opus.Keeper
  def handle_message(%{ref: ref} = channel, {__MODULE__, ref, event}),
    do: {:events, [event], channel}

  def handle_message(_channel, _message), do: :unknown

  @impl Opus.Keeper
  def send(%{runner: runner}, data),
    do: GenServer.call(runner, {:write_in, IO.iodata_to_binary(data)})

  @impl Opus.Keeper
  def send_relay(%{runner: runner}, data),
    do: GenServer.call(runner, {:relay_in, IO.iodata_to_binary(data)})

  @impl Opus.Keeper
  def close_relay(%{runner: runner}), do: GenServer.call(runner, :relay_close)

  @impl Opus.Keeper
  def release(%{keeper: keeper, ref: ref}, grace_ms),
    do: GenServer.cast(keeper, {:release, ref, grace_ms})

  @impl Opus.Keeper
  def stats, do: :unknown

  @doc "Every runner spawned through `keeper`, newest first: `%{ref, spec, runner, owner}`."
  @spec spawns(atom()) :: [map()]
  def spawns(keeper), do: GenServer.call(keeper, :spawns)

  @doc "Every release the service asked of `keeper`, oldest first: `{runner_id, grace_ms}`."
  @spec releases(atom()) :: [{String.t(), non_neg_integer()}]
  def releases(keeper), do: GenServer.call(keeper, :releases)

  @doc "What the service wrote runner `spawn` (a `spawns/1` entry) so far."
  @spec read(map()) :: binary()
  def read(%{runner: runner}), do: GenServer.call(runner, :read)

  @doc "Make runner `spawn` write `data` on its channel."
  @spec write(map(), iodata()) :: :ok
  def write(%{runner: runner}, data), do: GenServer.call(runner, {:write_out, data})

  @doc "What the service wrote on runner `spawn`'s relay so far."
  @spec read_relay(map()) :: binary()
  def read_relay(%{runner: runner}), do: GenServer.call(runner, :read_relay)

  @doc "Make runner `spawn` write `data` on its relay."
  @spec write_relay(map(), iodata()) :: :ok
  def write_relay(%{runner: runner}, data), do: GenServer.call(runner, {:relay_out, data})

  @doc "End runner `spawn`'s relay from its side."
  @spec end_relay(map()) :: :ok
  def end_relay(%{runner: runner}), do: GenServer.call(runner, :relay_end)

  @doc "Whether the service ended runner `spawn`'s relay."
  @spec relay_closed?(map()) :: boolean()
  def relay_closed?(%{runner: runner}), do: GenServer.call(runner, :relay_closed?)

  @doc """
  `attempt` (`Opus.Test.ScriptedHost.attempt!/2`'s) with its `:client`
  routed through a relay joined in this VM and bound to the attempt, as
  a runner's is: the runner's end (`:endpoint`) and the service's
  (`:relay`), which posts to the host the assignment names and connects
  to what the host pins. Both stop when the test ends. `opts`: `:runner`
  (the runner id the service's end holds, default the attempt's).
  """
  @spec relayed!(map(), keyword()) :: map()
  def relayed!(attempt, opts \\ []) do
    {:ok, assignment} = Prima.Assignment.read(attempt.assignment)
    %{endpoint: endpoint, relay: relay} = relay!(Keyword.get(opts, :runner, attempt.runner))

    :ok =
      Opus.Relay.bind(relay, %{
        assignment: attempt.assignment,
        keys: attempt.keys,
        host_url: assignment.host_url || "http://127.0.0.1:9"
      })

    :ok = Opus.Relay.Runner.bind(endpoint, attempt.attempt)

    client =
      Opus.HostClient.new(attempt.keys, attempt.runner, attempt.boot, %{
        member: assignment.member,
        relay: endpoint
      })

    Map.merge(attempt, %{client: client, relay: relay, endpoint: endpoint})
  end

  @doc """
  An authority bound at one node whose limits are `limits`, reached
  through `edge`, as an assignment carries a consented component's
  (`Opus.Test.ScriptedHost.attempt!/2`'s `:authority`): what the relay's
  service end checks a runner's fetches against, so a test hands its
  handler the same edge and limits the relay holds.
  """
  @spec authority(Prima.Authority.Blob.Edge.t(), Prima.Limits.t()) :: Prima.Authority.t()
  def authority(edge, limits) do
    node = "catalyst:local.relayed"

    %{
      Prima.Authority.zero()
      | cursor: {:bound, node},
        policy: %Prima.Authority.Blob{
          nodes: %{node => %Prima.Authority.Blob.Node{limits: limits, edges: %{}}}
        },
        resources: edge,
        chain: [node]
    }
  end

  @doc """
  A relay joined in this VM, unbound: a runner's end (`:endpoint`,
  `Opus.Relay.Runner`) and a service's end (`:relay`, `Opus.Relay`) for
  the runner `runner`, each writing what the other reads. Both stop when
  the test ends. A test that plays the service binds `:relay` to each
  attempt it assigns (`Opus.Relay.bind/2`); a runner started with
  `relay: endpoint` binds its end itself.
  """
  @spec relay!(String.t()) :: %{endpoint: pid(), relay: pid()}
  def relay!(runner) do
    forwarder = spawn_link(fn -> forward(nil) end)

    endpoint =
      ExUnit.Callbacks.start_supervised!(
        {Opus.Relay.Runner, relay: {:peer, forwarder}},
        id: {:relay_runner, make_ref()}
      )

    relay =
      ExUnit.Callbacks.start_supervised!(
        {Opus.Relay,
         runner: runner,
         write: fn data ->
           Kernel.send(endpoint, {:relay_in, IO.iodata_to_binary(data)})
           :ok
         end},
        id: {:relay, make_ref()}
      )

    Kernel.send(forwarder, {:to, relay})
    %{endpoint: endpoint, relay: relay}
  end

  # What the runner's end writes, handed to the service's end once it is
  # known.
  defp forward(nil) do
    receive do
      {:to, relay} -> forward(relay)
    end
  end

  defp forward(relay) do
    receive do
      {:relay_in, data} ->
        Opus.Relay.deliver(relay, data)
        forward(relay)
    end
  end

  @doc "Close runner `spawn`'s end of its channel."
  @spec close(map()) :: :ok
  def close(%{runner: runner}), do: GenServer.call(runner, :close)

  @doc "End runner `spawn`'s process with `status`."
  @spec exit(map(), integer()) :: :ok
  def exit(%{runner: runner}, status), do: GenServer.call(runner, {:exit, status})

  @doc "End the keeper as a lost channel does."
  @spec kill!(atom()) :: :ok
  def kill!(keeper), do: GenServer.call(keeper, :channel_lost)

  # ---------------------------------------------------------------------------
  # The keeper
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts), do: {:ok, %{spawns: [], releases: [], refusing: nil, refused: 0}}

  @impl GenServer
  def handle_call({:spawn, _spec, _owner}, _from, %{refusing: reason} = state)
      when reason != nil,
      do: {:reply, {:refused, make_ref(), reason}, %{state | refused: state.refused + 1}}

  def handle_call({:spawn, spec, owner}, _from, state) do
    ref = make_ref()
    {:ok, runner} = GenServer.start_link(__MODULE__.Runner, %{owner: owner, ref: ref})
    entry = %{ref: ref, spec: spec, runner: runner, owner: owner}
    {:reply, {:ok, ref, runner}, %{state | spawns: [entry | state.spawns]}}
  end

  def handle_call({:refuse, reason}, _from, state), do: {:reply, :ok, %{state | refusing: reason}}
  def handle_call(:refused, _from, state), do: {:reply, state.refused, state}

  def handle_call(:spawns, _from, state), do: {:reply, state.spawns, state}
  def handle_call(:releases, _from, state), do: {:reply, Enum.reverse(state.releases), state}

  def handle_call(:channel_lost, _from, state) do
    for %{owner: owner, ref: ref} <- state.spawns,
        do: Kernel.send(owner, {__MODULE__, ref, {:error, :channel_lost}})

    {:stop, {:shutdown, :channel_lost}, :ok, state}
  end

  @impl GenServer
  def handle_cast({:release, ref, grace_ms}, state) do
    case Enum.find(state.spawns, &(&1.ref == ref)) do
      nil ->
        {:noreply, state}

      entry ->
        Process.send_after(entry.runner, {:released, grace_ms}, grace_ms)
        {:noreply, %{state | releases: [{entry.spec.runner, grace_ms} | state.releases]}}
    end
  end

  defmodule Runner do
    @moduledoc false
    use GenServer

    @impl true
    def init(state),
      do:
        {:ok, Map.merge(state, %{inbox: "", relay_inbox: "", relay_closed: false, ended: false})}

    @impl true
    def handle_call({:write_in, data}, _from, state),
      do: {:reply, :ok, %{state | inbox: state.inbox <> data}}

    def handle_call(:read, _from, state), do: {:reply, state.inbox, state}

    def handle_call({:relay_in, data}, _from, state),
      do: {:reply, :ok, %{state | relay_inbox: state.relay_inbox <> data}}

    def handle_call(:relay_close, _from, state), do: {:reply, :ok, %{state | relay_closed: true}}
    def handle_call(:read_relay, _from, state), do: {:reply, state.relay_inbox, state}
    def handle_call(:relay_closed?, _from, state), do: {:reply, state.relay_closed, state}

    def handle_call({:relay_out, data}, _from, state) do
      notify(state, {:relay, IO.iodata_to_binary(data)})
      {:reply, :ok, state}
    end

    def handle_call(:relay_end, _from, state) do
      notify(state, :relay_closed)
      {:reply, :ok, state}
    end

    def handle_call({:write_out, data}, _from, state) do
      notify(state, {:control, IO.iodata_to_binary(data)})
      {:reply, :ok, state}
    end

    def handle_call(:close, _from, state) do
      notify(state, :control_closed)
      {:reply, :ok, state}
    end

    def handle_call({:exit, status}, _from, state), do: {:reply, :ok, ended(state, status)}

    @impl true
    def handle_info({:released, _grace_ms}, state), do: {:noreply, ended(state, 137)}

    defp ended(%{ended: true} = state, _status), do: state

    defp ended(state, status) do
      notify(state, :control_closed)
      notify(state, {:exited, {:status, status}})
      notify(state, :released)
      %{state | ended: true}
    end

    defp notify(%{owner: owner, ref: ref}, event),
      do: Kernel.send(owner, {Opus.Test.ScriptedKeeper, ref, event})
  end
end
