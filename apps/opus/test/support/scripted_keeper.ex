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
    def init(state), do: {:ok, Map.merge(state, %{inbox: "", ended: false})}

    @impl true
    def handle_call({:write_in, data}, _from, state),
      do: {:reply, :ok, %{state | inbox: state.inbox <> data}}

    def handle_call(:read, _from, state), do: {:reply, state.inbox, state}

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
