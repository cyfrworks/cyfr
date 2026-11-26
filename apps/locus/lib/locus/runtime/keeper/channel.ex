# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.Keeper.Channel do
  @moduledoc """
  The runtime's keeper where `cyfr-locus` (`apps/locus/keeper`) started
  the service: the runner pool's adapter (`Locus.Runtime.Keeper`) to the
  node's one client of the keeper, `Locus.Keeper`, which owns the
  inherited channel and the attach socket every runner's relay connects
  to, and spawns every runner in the keeper's `runner` uid pool.

  ## A runner

  `spawn/1` runs in the runner's own process (`Locus.Runtime.RunnerProcess`):
  it asks this process which client to spawn through, then asks the
  client itself, so that process owns
  the spawn and hears its events, which `handle_message/2` reads as
  `Locus.Runtime.Keeper.event/1` maps them. The spawn names the runner's
  argv and its explicit environment (only `RUNTIME_*` variables and the
  release's own: the keeper refuses `CYFR_`, `LOCUS_` and `KEEPER_`
  names, and sets `PATH`, `HOME`, `USER`, `LOGNAME` and `TMPDIR` itself),
  and asks for a control channel (`control: true`), carried as stream 4
  on the runner's relay connection. Its pool's spaces are relay spaces
  (`--pool runner:…:relay`), whose only way out is the relay
  (`Prima.RunnerRelay`), the socket on its fd 4, carried as stream 5. The
  client opens that stream once the runner attaches; `send/2`,
  `send_relay/2` and `close_relay/1` write through the client, and
  `release/2` asks it for the runner's retirement: a term signal to its
  process group, the grace to report what it holds, then the kill, and
  every process of the uid killed and everything it left removed before
  another runner gets it. A spawn `cyfr-locus` refuses after it made it
  is heard as `{:refused, code, :release_follows}`, and its release
  follows. The keeper's `give_way` of a runner's place reaches the
  runner's process, before its spawn as after it, as `:give_way`. When the
  channel closes, `cyfr-locus` is exiting: it kills this
  node, then retires every spawn. Every runner's owner hears
  `{:error, :channel_lost}`, and the client stops, taking the runtime
  with it.

  ## The memory bound

  No spawn this adapter asks for names a bound: `cyfr-locus` sets a
  runner's memory and processor by its kind (`Prima.LocusPool`), the
  memory its place was answered with (`place/3`), and gives the runner a
  cgroup of its own at that bound: its VM,
  every guest's linear memory, the pages of its home and the kernel
  memory charged to it, together. A runner that cannot stay under it
  loses every process at once; the leader's `exited` then says
  `memory: "cap"`, read by `cyfr-locus` from the group's own counters,
  and the runner's end at its bound is logged before its owner hears the
  exit and the retirement that follow, as for any other runner's end: the
  pool taints it, the service reports it with the subtree it held, and
  its uid is retired and scrubbed before another runner gets it. Where
  `cyfr-locus` cannot give a runner such a group it refuses the spawn as
  `memory_unavailable`, which the owner hears as
  `{:refused, :memory_unavailable}` (a spawn's refusal, as `refusal/1`
  reads it; any other code the keeper refuses one with is heard as it
  was sent), and this process logs what the deployment lacks, once for
  each run of refusals: the container needs the `writable-cgroups=true`
  security option (Docker Engine 28 or later on a cgroup v2 host). No
  runner is started without its bound instead; the pool keeps none of the
  runners it was refused and backs off (`Locus.Runtime.RunnerPool`).

  ## What a failure answers

  A failed call answers what failed by its kind alone
  (`Locus.Keeper.exit_kind/1`): the client unreachable is
  `{:keeper_unavailable, kind}`, the channel lost
  `{:spawn_failed, :channel_lost}`, a runner the client no longer follows
  `:unknown_runner`. No answer carries a runner's environment or what was
  written to it, and this process never holds either.
  """

  @behaviour Locus.Runtime.Keeper

  use GenServer

  import Kernel, except: [send: 2]

  require Logger

  @pool "runner"

  # `memory_unavailable` is the keeper's word for any bound it cannot
  # enforce, the memory's or the CPU's.
  @memory_unavailable "cyfr-locus cannot bound a runner's memory and CPU in this container, " <>
                        "so it starts none: start the locus service with the security " <>
                        "option writable-cgroups=true (Docker Engine 28 or later on a cgroup v2 " <>
                        "host whose memory and cpu controllers reach the container)"

  @impl Locus.Runtime.Keeper
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc """
  Start the adapter. Options: `:client`, the `Locus.Keeper` every runner is
  spawned through (default `Locus.Keeper`); `:name` (default
  `#{inspect(__MODULE__)}`).
  """
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl Locus.Runtime.Keeper
  def available(true = _inherited?, _opts), do: :ok

  def available(false = _inherited?, _opts) do
    {:error,
     "no keeper channel was inherited (#{Locus.Keeper.channel_env()} is unset, or fd 3 is " <>
       "not the socket it names)"}
  end

  # The keeper options may name the adapter to use (`:server`), as a test
  # does; the pool's runners use the registered one.
  @impl Locus.Runtime.Keeper
  def place(id, whose, opts) when is_list(opts) do
    with {:ok, client} <- client(Keyword.get(opts, :server, __MODULE__)),
         {:ok, memory_bytes} <- Locus.Keeper.place(client, id, whose, self()) do
      {:ok, memory_bytes}
    else
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl Locus.Runtime.Keeper
  def assign(place, whose, until, opts) when is_integer(until) and is_list(opts) do
    with {:ok, client} <- client(Keyword.get(opts, :server, __MODULE__)),
         :ok <- Locus.Keeper.assign(client, place, whose, until) do
      :ok
    else
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl Locus.Runtime.Keeper
  def fence(tag, opts) when is_list(opts) do
    case client(Keyword.get(opts, :server, __MODULE__)) do
      {:ok, client} -> Locus.Keeper.fence(client, tag)
      {:error, reason} -> {:error, reason}
    end
  end

  # A spec may name the adapter to use (`:server`), as a test does; the
  # pool's runners use the registered one.
  @impl Locus.Runtime.Keeper
  def spawn(%{runner: runner, argv: argv, env: env} = spec) do
    adapter = Map.get(spec, :server, __MODULE__)

    request = %{
      place: runner,
      argv: argv,
      env: env,
      pool: @pool,
      control: true,
      heir: Map.get(spec, :heir)
    }

    with {:ok, client} <- client(adapter),
         {:ok, handle} <- Locus.Keeper.spawn(client, request) do
      {:ok,
       Map.merge(handle, %{
         runner: runner,
         adapter: adapter,
         memory_bytes: Map.get(spec, :memory_bytes)
       }), []}
    else
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  @impl Locus.Runtime.Keeper
  def handle_message(%{ref: ref} = channel, {Locus.Keeper, ref, event}),
    do: {:events, [Locus.Runtime.Keeper.event(event)], observe(channel, event)}

  # A `give_way` the keeper sent while no spawn had named the runner's
  # place yet, read once the spawn is.
  def handle_message(%{runner: place} = channel, {Locus.Keeper, {:place, place}, event}),
    do: {:events, [Locus.Runtime.Keeper.event(event)], channel}

  def handle_message(_channel, _message), do: :unknown

  @impl Locus.Runtime.Keeper
  def send(channel, data), do: answer(Locus.Keeper.send_control(channel, data))

  @impl Locus.Runtime.Keeper
  def send_relay(channel, data), do: answer(Locus.Keeper.send_relay(channel, data))

  @impl Locus.Runtime.Keeper
  def taken(channel), do: Locus.Keeper.taken(channel)

  @impl Locus.Runtime.Keeper
  def close_relay(channel), do: Locus.Keeper.close_relay(channel)

  @impl Locus.Runtime.Keeper
  def release(%{server: client} = channel, grace_ms)
      when is_integer(grace_ms) and grace_ms >= 0,
      do: Locus.Keeper.release(client, channel, grace_ms)

  # The keeper's refusals of a spawn: its code, and what an operator makes
  # of it. `memory_unavailable` names what the deployment lacks; a place
  # refused for room is `no_memory`.
  @impl Locus.Runtime.Keeper
  def refusal(:memory_unavailable),
    do: %{reason: "memory_unavailable", message: @memory_unavailable}

  def refusal({:no_memory, _held}), do: refusal("no_memory")

  def refusal(code) when is_binary(code) do
    reason = if Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, code), do: code, else: "refused"
    %{reason: reason, message: "cyfr-locus refused to start a runner (#{reason})"}
  end

  def refusal(_reason),
    do: %{reason: "refused", message: "cyfr-locus refused to start a runner"}

  defp client(adapter) do
    GenServer.call(adapter, :client)
  catch
    :exit, reason -> {:error, {:launcher_unavailable, Locus.Keeper.exit_kind(reason)}}
  end

  defp answer(:ok), do: :ok
  defp answer({:error, reason}), do: {:error, failure(reason)}

  # The client's failures in the runtime's names for them.
  defp failure({:launcher_unavailable, :channel_lost}), do: {:spawn_failed, :channel_lost}
  defp failure({:launcher_unavailable, kind}), do: {:keeper_unavailable, kind}
  defp failure(:unknown_spawn), do: :unknown_runner
  defp failure(reason), do: reason

  # What a runner's events tell this adapter: a runner spawned ends a run
  # of refusals and names the spawn its end is logged under, a refusal at
  # the bound is logged once for each run, and an end at the bound is
  # logged before the owner hears it.
  defp observe(channel, {:spawned, spawn_id, _uid, _pid}) do
    GenServer.cast(channel.adapter, :spawned)
    %{channel | spawn_id: spawn_id}
  end

  defp observe(channel, {:refused, "memory_unavailable"}) do
    GenServer.call(channel.adapter, {:memory_unavailable, channel.runner})
    channel
  catch
    :exit, _reason -> channel
  end

  # cyfr-locus read it from the group's own counters: the kernel killed
  # the runner at its bound, not for the container's limit.
  defp observe(channel, {:exited, exit, :cap}) do
    Logger.warning(
      "[Locus.Runtime.Keeper.Channel] runner #{channel.runner} was ended at its memory bound of " <>
        "#{channel.memory_bytes} bytes (spawn #{channel.spawn_id}, #{format_exit(exit)})"
    )

    channel
  end

  defp observe(channel, _event), do: channel

  defp format_exit({:signal, signal}), do: "signal #{signal}"
  defp format_exit({:status, code}), do: "status #{code}"

  # ---------------------------------------------------------------------------
  # The adapter
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts),
    do: {:ok, %{client: Keyword.get(opts, :client, Locus.Keeper), bound_refused: false}}

  @impl GenServer
  def handle_call(:client, _from, state), do: {:reply, {:ok, state.client}, state}

  # What the deployment lacks is logged once for each run of refusals; a
  # runner spawned again under its bound ends the run.
  def handle_call({:memory_unavailable, runner}, _from, %{bound_refused: false} = state) do
    Logger.error(
      "[Locus.Runtime.Keeper.Channel] runner #{runner} was not started: #{@memory_unavailable}"
    )

    {:reply, :ok, %{state | bound_refused: true}}
  end

  def handle_call({:memory_unavailable, _runner}, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_cast(:spawned, state), do: {:noreply, %{state | bound_refused: false}}

  @impl GenServer
  def handle_info(message, state) do
    Prima.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  # The adapter holds no runner's request, environment or bytes: a runner
  # process asks the client for its spawn itself. The debug log is left
  # out all the same.
  @impl GenServer
  def format_status(status) do
    Map.new(status, fn
      {:log, _log} -> {:log, []}
      other -> other
    end)
  end
end
