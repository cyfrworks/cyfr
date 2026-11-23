# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.Test.ScriptedKeeper do
  @moduledoc """
  A keeper (`Locus.Runtime.Keeper`) whose runners are processes of this VM a test
  drives: each `spawn` starts a runner process that hands the test the
  bytes the service writes and writes what the test tells it, so the
  pool (`Locus.Runtime.RunnerPool`) and the handles (`Locus.Runtime.RunnerProcess`) are
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
  refuse every spawn after the request, as `cyfr-locus` refuses one it
  cannot bound, until it is told to start runners again, and `refused/1`
  counts the spawns it refused. It holds a runner to the `:memory_bytes`
  of the pool's keeper options, or to none.

  It keeps places as cyfr-locus does (`Prima.KeeperProtocol`, "Places"),
  named by the keeper options' `:name` (options that name no keeper keep
  none, as a test that reads no places starts a runner with none):
  `place/3` makes one for the calling process, `assign/3` changes whose it
  is and answers once it has, refused `bad_request` for a place it does
  not hold, one whose owner dies before a spawn named it is dropped, a
  refused spawn frees the place it named, and a runner's release frees its
  place once the runner is gone. `places/1` answers every place held, by
  its id: whose it is and whether a spawn named it. `assigning/2` holds
  every assign from then on, unapplied and unanswered, until
  `answer_assigns/1` applies and answers them, or refuses every one with
  a reason, applying none; `held_assigns/1` lists those held.

  Each runner has a relay stream too: `read_relay/1` answers what the
  service wrote on it and `write_relay/2` makes the runner write on it;
  `relay_closed?/1` says whether the service ended it. `end_relay/1` ends
  the runner's end of it alone, and `refuse_write/2` refuses the service's
  writes to a runner's channel, writing nothing.

  `relayed!/2` routes an attempt's client as a runner's is routed, for a
  test that runs runner code in this VM: through a runner's end of a relay
  (`Locus.Runtime.Relay.Runner`) joined in this VM to a service's end
  (`Locus.Runtime.Relay`) bound to the attempt, which verifies and posts every host
  call to the scripted host and performs every pinned fetch.
  """

  @behaviour Locus.Runtime.Keeper

  use GenServer

  import Kernel, except: [send: 2, exit: 1]

  @impl Locus.Runtime.Keeper
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @doc """
  Start a scripted keeper for the calling test under `name`, an alias of
  the test module's own, and answer it.
  """
  @spec start!(module()) :: module()
  def start!(name) when is_atom(name) do
    ExUnit.Callbacks.start_supervised!({__MODULE__, name: name})
    name
  end

  @impl Locus.Runtime.Keeper
  def available(_env, _opts), do: :ok

  @impl Locus.Runtime.Keeper
  def place(id, %{kind: _kind} = whose, opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, keeper} -> GenServer.call(keeper, {:place, id, whose})
      :error -> :ok
    end
  end

  @impl Locus.Runtime.Keeper
  def assign(place, %{kind: _kind} = whose, opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, keeper} -> GenServer.call(keeper, {:assign, place, whose})
      :error -> :ok
    end
  end

  @doc """
  How `keeper` answers every assign from now on: `:held`, applying and
  answering none until `answer_assigns/1`; `{:refused, reason}`, applying
  none and answering `{:error, reason}`; or `:answered`, as cyfr-locus does.
  """
  @spec assigning(atom(), :held | {:refused, term()} | :answered) :: :ok
  def assigning(keeper, how), do: GenServer.call(keeper, {:assigning, how})

  @doc "Every assign `keeper` holds, oldest first: `{place, whose}`."
  @spec held_assigns(atom()) :: [{String.t(), map()}]
  def held_assigns(keeper), do: GenServer.call(keeper, :held_assigns)

  @doc "Apply and answer every assign `keeper` holds, and answer every later one at once."
  @spec answer_assigns(atom()) :: :ok
  def answer_assigns(keeper), do: GenServer.call(keeper, :answer_assigns)

  @doc "Every place `keeper` holds, by its id: `%{whose, spawned}`."
  @spec places(atom()) :: %{
          String.t() => %{whose: map(), spawned: boolean(), owner: reference()}
        }
  def places(keeper), do: GenServer.call(keeper, :places)

  @impl Locus.Runtime.Keeper
  def spawn(%{env: %{"KEEPER" => name}} = spec) do
    keeper = String.to_existing_atom(name)

    case GenServer.call(keeper, {:spawn, spec, self()}) do
      {:ok, ref, runner} ->
        {:ok, %{ref: ref, keeper: keeper, runner: runner}, [{:spawned, nil}, :attached]}

      # Refused after the request, as cyfr-locus answers one it cannot
      # bound: the handle hears it as the keeper's message.
      {:refused, ref, reason} ->
        Kernel.send(self(), {__MODULE__, ref, {:refused, reason}})
        {:ok, %{ref: ref, keeper: keeper, runner: nil}, []}
    end
  end

  @impl Locus.Runtime.Keeper
  def memory_bytes(opts), do: Keyword.get(opts, :memory_bytes)

  @impl Locus.Runtime.Keeper
  def refusal(reason),
    do: %{reason: to_string(reason), message: "the scripted keeper refuses (#{reason})"}

  @doc "Refuse every spawn from now on with `reason`, or start runners again with nil."
  @spec refuse(atom(), atom() | nil) :: :ok
  def refuse(keeper, reason), do: GenServer.call(keeper, {:refuse, reason})

  @doc "How many spawns `keeper` refused."
  @spec refused(atom()) :: non_neg_integer()
  def refused(keeper), do: GenServer.call(keeper, :refused)

  @impl Locus.Runtime.Keeper
  def handle_message(%{ref: ref} = channel, {__MODULE__, ref, event}),
    do: {:events, [event], channel}

  def handle_message(_channel, _message), do: :unknown

  @impl Locus.Runtime.Keeper
  def send(%{runner: runner}, data),
    do: GenServer.call(runner, {:write_in, IO.iodata_to_binary(data)})

  @impl Locus.Runtime.Keeper
  def send_relay(%{runner: runner}, data),
    do: GenServer.call(runner, {:relay_in, IO.iodata_to_binary(data)})

  @impl Locus.Runtime.Keeper
  def close_relay(%{runner: runner}), do: GenServer.call(runner, :relay_close)

  @impl Locus.Runtime.Keeper
  def release(%{keeper: keeper, ref: ref}, grace_ms),
    do: GenServer.cast(keeper, {:release, ref, grace_ms})

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

  @doc "Whether the service ended runner `spawn`'s relay."
  @spec relay_closed?(map()) :: boolean()
  def relay_closed?(%{runner: runner}), do: GenServer.call(runner, :relay_closed?)

  @doc """
  `attempt` (`Locus.Runtime.Test.ScriptedHost.attempt!/2`'s) with its `:client`
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
      Locus.Runtime.Relay.bind(relay, %{
        assignment: attempt.assignment,
        keys: attempt.keys,
        host_url: assignment.host_url || "http://127.0.0.1:9"
      })

    :ok = Locus.Runtime.Relay.Runner.bind(endpoint, attempt.attempt)

    client =
      Locus.Runtime.HostClient.new(attempt.keys, attempt.runner, attempt.boot, %{
        member: assignment.member,
        relay: endpoint
      })

    Map.merge(attempt, %{client: client, relay: relay, endpoint: endpoint})
  end

  @doc """
  An authority bound at one node whose limits are `limits`, reached
  through `edge`, as an assignment carries a consented component's
  (`Locus.Runtime.Test.ScriptedHost.attempt!/2`'s `:authority`): what the relay's
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
  `Locus.Runtime.Relay.Runner`) and a service's end (`:relay`, `Locus.Runtime.Relay`) for
  the runner `runner`, each writing what the other reads. Both stop when
  the test ends. A test that plays the service binds `:relay` to each
  attempt it assigns (`Locus.Runtime.Relay.bind/2`); a runner started with
  `relay: endpoint` binds its end itself.
  """
  @spec relay!(String.t()) :: %{endpoint: pid(), relay: pid()}
  def relay!(runner) do
    forwarder = spawn_link(fn -> forward(nil) end)

    endpoint =
      ExUnit.Callbacks.start_supervised!(
        {Locus.Runtime.Relay.Runner, relay: {:peer, forwarder}},
        id: {:relay_runner, make_ref()}
      )

    relay =
      ExUnit.Callbacks.start_supervised!(
        {Locus.Runtime.Relay,
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
        Locus.Runtime.Relay.deliver(relay, data)
        forward(relay)
    end
  end

  @doc "Close runner `spawn`'s end of its channel."
  @spec close(map()) :: :ok
  def close(%{runner: runner}), do: GenServer.call(runner, :close)

  @doc "End runner `spawn`'s process with `status`."
  @spec exit(map(), integer()) :: :ok
  def exit(%{runner: runner}, status), do: GenServer.call(runner, {:exit, status})

  @doc "Answer every write to runner `spawn`'s channel `{:error, reason}` from now on, writing nothing."
  @spec refuse_write(map(), term()) :: :ok
  def refuse_write(%{runner: runner}, reason),
    do: GenServer.call(runner, {:refuse_write, reason})

  @doc "End runner `spawn`'s end of its relay stream alone."
  @spec end_relay(map()) :: :ok
  def end_relay(%{runner: runner}), do: GenServer.call(runner, :relay_end)

  @doc "End the keeper as a lost channel does."
  @spec kill!(atom()) :: :ok
  def kill!(keeper), do: GenServer.call(keeper, :channel_lost)

  # ---------------------------------------------------------------------------
  # The keeper
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    {:ok,
     %{
       spawns: [],
       releases: [],
       refusing: nil,
       refused: 0,
       places: %{},
       assigning: :answered,
       held: []
     }}
  end

  @impl GenServer
  def handle_call({:place, id, _whose}, _from, state) when is_map_key(state.places, id),
    do: {:reply, {:error, :bad_request}, state}

  def handle_call({:place, id, whose}, {owner, _tag}, state) do
    place = %{whose: whose, spawned: false, owner: Process.monitor(owner)}
    {:reply, :ok, %{state | places: Map.put(state.places, id, place)}}
  end

  def handle_call(:places, _from, state), do: {:reply, state.places, state}

  def handle_call({:assign, place, whose}, from, %{assigning: :held} = state),
    do: {:noreply, %{state | held: state.held ++ [{from, place, whose}]}}

  def handle_call({:assign, _place, _whose}, _from, %{assigning: {:refused, reason}} = state),
    do: {:reply, {:error, reason}, state}

  def handle_call({:assign, place, whose}, _from, state) do
    {answer, state} = assigned(state, place, whose)
    {:reply, answer, state}
  end

  def handle_call({:assigning, how}, _from, state), do: {:reply, :ok, %{state | assigning: how}}

  def handle_call(:held_assigns, _from, state),
    do: {:reply, Enum.map(state.held, fn {_from, place, whose} -> {place, whose} end), state}

  def handle_call(:answer_assigns, _from, state) do
    state =
      Enum.reduce(state.held, %{state | held: [], assigning: :answered}, fn {from, place, whose},
                                                                            state ->
        {answer, state} = assigned(state, place, whose)
        GenServer.reply(from, answer)
        state
      end)

    {:reply, :ok, state}
  end

  def handle_call({:freed, ref}, _from, state) do
    case Enum.find(state.spawns, &(&1.ref == ref)) do
      %{spec: %{runner: place}} ->
        {:reply, :ok, %{state | places: Map.delete(state.places, place)}}

      _other ->
        {:reply, :ok, state}
    end
  end

  # A refused spawn frees the place it named.
  def handle_call({:spawn, spec, _owner}, _from, %{refusing: reason} = state)
      when reason != nil do
    state = %{state | refused: state.refused + 1, places: Map.delete(state.places, spec.runner)}
    {:reply, {:refused, make_ref(), reason}, state}
  end

  def handle_call({:spawn, spec, owner}, _from, state) do
    ref = make_ref()
    keeper = self()

    {:ok, runner} =
      GenServer.start_link(__MODULE__.Runner, %{owner: owner, ref: ref, keeper: keeper})

    entry = %{ref: ref, spec: spec, runner: runner, owner: owner}
    places = named(state.places, spec.runner)
    {:reply, {:ok, ref, runner}, %{state | spawns: [entry | state.spawns], places: places}}
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

  # An owner gone before a spawn named its place has the place dropped; a
  # place a spawn named is freed at that spawn's release alone.
  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    places =
      Map.reject(state.places, fn {_id, place} -> place.owner == monitor and not place.spawned end)

    {:noreply, %{state | places: places}}
  end

  # An assign of a place held changes whose it is; cyfr-locus refuses one
  # of a place it does not hold.
  defp assigned(state, place, whose) do
    case state.places do
      %{^place => entry} ->
        {:ok, %{state | places: Map.put(state.places, place, %{entry | whose: whose})}}

      _gone ->
        {{:error, {:refused, "bad_request"}}, state}
    end
  end

  defp named(places, place) do
    case places do
      %{^place => entry} -> Map.put(places, place, %{entry | spawned: true})
      _none -> places
    end
  end

  defmodule Runner do
    @moduledoc false
    use GenServer

    @impl true
    def init(state),
      do:
        {:ok,
         Map.merge(state, %{
           inbox: "",
           relay_inbox: "",
           relay_closed: false,
           ended: false,
           write_refusal: nil
         })}

    @impl true
    def handle_call({:write_in, _data}, _from, %{write_refusal: reason} = state)
        when reason != nil,
        do: {:reply, {:error, reason}, state}

    def handle_call({:write_in, data}, _from, state),
      do: {:reply, :ok, %{state | inbox: state.inbox <> data}}

    def handle_call({:refuse_write, reason}, _from, state),
      do: {:reply, :ok, %{state | write_refusal: reason}}

    def handle_call(:relay_end, _from, state) do
      notify(state, :relay_closed)
      {:reply, :ok, state}
    end

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
      freed(state)
      notify(state, :released)
      %{state | ended: true}
    end

    # The keeper frees the runner's place before its owner hears the release,
    # as cyfr-locus does; a keeper already gone holds none.
    defp freed(state) do
      GenServer.call(state.keeper, {:freed, state.ref})
    catch
      :exit, _reason -> :ok
    end

    defp notify(%{owner: owner, ref: ref}, event),
      do: Kernel.send(owner, {Locus.Runtime.Test.ScriptedKeeper, ref, event})
  end
end
